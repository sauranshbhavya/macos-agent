/**
 * Test support for V2 sessions: a scripted agent, an app wired with in-memory stores, and a real
 * `ws` client that speaks the protocol.
 */
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";
import type { FastifyInstance } from "fastify";
import { buildApp, type AppOverrides } from "../../src/app.js";
import type { AuthProvider, VerifiedSession } from "../../src/auth/provider.js";
import type { Agent, AgentFactory, OutboundMessage, TurnContext, TurnResult } from "../../src/agent/agent.js";
import { memoryModelCallLedger } from "../../src/agent/credits.js";
import type { ClientMessage, ServerMessage } from "../../src/agent/protocol.js";
import { memoryTaskStore, type TaskStore } from "../../src/agent/tasks/store.js";
import { testConfig } from "./config.js";
import { signedInConnectionTo } from "./connection.js";
import { creditPlansDocument } from "./credit.js";
import { fakeEntitlementStore } from "./entitlement.js";
import { accessTokenFor } from "./tokens.js";
import { WithoutOAuth } from "./without-oauth.js";

export const AGENT_ACCOUNT = "0b9c3a52-7c55-4f1e-8d3c-0000000000a1";
export const AGENT_USER = "5a1d2c3b-0000-4000-8000-0000000000a1";

export { TEST_TOKEN_RATES } from "./credit.js";

export const TEST_CREDIT_PLANS_WITH_RATES = creditPlansDocument({
  defaultPlan: "test-plan-a",
  plans: [{ key: "test-plan-a", monthlyCredits: 1000 }],
});

export class QuietAuthProvider extends WithoutOAuth implements AuthProvider {
  readonly signedOut: string[] = [];
  async sendEmailCode() {
    return { providerRequestId: undefined };
  }
  async verifyEmailCode(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async refresh(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async signOut(accessToken: string) {
    this.signedOut.push(accessToken);
  }
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

export interface ScriptedStep {
  /** The messages this turn sends. */
  readonly messages: readonly OutboundMessage[];
  /** A model call to make first, with the usage it reports. */
  readonly modelCall?: { readonly inputTokens: number; readonly outputTokens: number };
}

/**
 * An agent that replays a fixed list of turns. Turn N runs after the Mac's Nth reply, so its state
 * is the transcript, as a real agent's is.
 */
export function scriptedAgent(steps: readonly ScriptedStep[], seen?: TurnContext[]): AgentFactory {
  return (): Agent => ({
    async turn(context): Promise<TurnResult> {
      seen?.push(context);
      const replies = context.transcript.filter((m) => m.direction === "in" && m.type !== "task.start").length;
      const step = steps[replies];
      if (step === undefined) {
        return { messages: [{ type: "finish", body: { status: "completed", summary: "Done." } }] };
      }
      if (step.modelCall !== undefined) {
        const usage = step.modelCall;
        await context.modelCall(
          { agent: "planner", tier: "fast", maxInputTokens: 10_000, maxOutputTokens: 2_000 },
          () => Promise.resolve({ value: null, usage, provider: "test", model: "test-model" }),
        );
      }
      return { notes: [{ type: "scripted.turn", body: { replies } }], messages: step.messages };
    },
  });
}

export function proposeOpen(app = "Notes", final = false): OutboundMessage {
  return {
    type: "propose",
    body: {
      agent: "planner",
      final,
      actions: [
        {
          action_id: randomUUID(),
          effect: "navigate",
          operation: { name: "open_app", version: 1, args: { app } },
        },
      ],
    },
  };
}

export interface Harness {
  readonly app: FastifyInstance;
  readonly url: string;
  readonly store: ReturnType<typeof memoryTaskStore>;
  readonly ledger: ReturnType<typeof memoryModelCallLedger>;
  readonly provider: QuietAuthProvider;
  close(): Promise<void>;
}

export async function startHarness(
  overrides: AppOverrides & {
    readonly store?: ReturnType<typeof memoryTaskStore>;
    readonly ledger?: ReturnType<typeof memoryModelCallLedger>;
  } = {},
): Promise<Harness> {
  const store = overrides.store ?? memoryTaskStore();
  const ledger = overrides.ledger ?? memoryModelCallLedger(1000);
  const provider = new QuietAuthProvider();
  const app = buildApp(
    testConfig({ creditPlans: TEST_CREDIT_PLANS_WITH_RATES }),
    { provider, withConnection: signedInConnectionTo({ account: AGENT_ACCOUNT, where: "in a V2 session test" }) },
    {
      entitlementStore: fakeEntitlementStore(),
      agentTaskStore: store,
      agentLedger: ledger,
      agentTiming: { heartbeatMs: 60_000, helloTimeoutMs: 2_000, reauthLeadMs: 1_000 },
      ...overrides,
    },
  );
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = (app.server.address() as AddressInfo).port;
  return {
    app,
    url: `ws://127.0.0.1:${port}/v2/session`,
    store,
    ledger,
    provider,
    close: () => app.close(),
  };
}

export interface ClosedWith {
  readonly code: number;
  readonly reason: string;
}

/** A Mac as far as the protocol goes: it sends messages and waits for the ones it expects. */
export class TestMac {
  readonly received: ServerMessage[] = [];
  readonly closed: Promise<ClosedWith>;
  private waiters: Array<{ match: (m: ServerMessage) => boolean; resolve: (m: ServerMessage) => void }> = [];
  private seqByTask = new Map<string, number>();

  private constructor(readonly socket: WebSocket) {
    socket.on("message", (data) => {
      const message = JSON.parse(String(data)) as ServerMessage;
      this.received.push(message);
      this.waiters = this.waiters.filter((waiter) => {
        if (!waiter.match(message)) return true;
        waiter.resolve(message);
        return false;
      });
    });
    this.closed = new Promise((resolve) => {
      socket.on("close", (code, reason) => resolve({ code, reason: String(reason) }));
    });
  }

  static async connect(
    url: string,
    options: { token?: string; version?: string } = {},
  ): Promise<TestMac> {
    const socket = new WebSocket(url, {
      headers: {
        authorization: `Bearer ${options.token ?? accessTokenFor(AGENT_USER)}`,
        "sonny-client-version": options.version ?? "2.0.0",
      },
    });
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("unexpected-response", (request, response) => {
        request.destroy();
        socket.terminate();
        reject(new Error(`upgrade refused with ${response.statusCode}`));
      });
      socket.once("error", reject);
    });
    return new TestMac(socket);
  }

  send(message: ClientMessage | Record<string, unknown>): void {
    this.socket.send(JSON.stringify(message));
  }

  hello(deviceId: string, resume: Array<{ task: string; last_seq_in: number; last_seq_out?: number }> = []): void {
    this.send({
      v: 1,
      type: "hello",
      id: randomUUID(),
      body: {
        device_id: deviceId,
        app_version: "2.0.0",
        os_version: "26.0",
        manifest: {
          operations: [{ name: "open_app", version: 1 }],
          screen: { tools: [] },
          permissions: { accessibility: "granted", screen_recording: "granted", automation: [] },
        },
        resume: resume.map((entry) => ({ ledger: [], last_seq_out: entry.last_seq_out ?? 0, ...entry })),
      },
    });
  }

  nextSeq(task: string): number {
    const seq = (this.seqByTask.get(task) ?? 0) + 1;
    this.seqByTask.set(task, seq);
    return seq;
  }

  /** Continues a task's numbering after a reconnect. */
  setSeq(task: string, seq: number): void {
    this.seqByTask.set(task, seq);
  }

  startTask(task: string, body: Partial<Extract<ClientMessage, { type: "task.start" }>["body"]> = {}): string {
    const id = randomUUID();
    this.send({
      v: 1,
      type: "task.start",
      id,
      task,
      seq: this.nextSeq(task),
      body: {
        goal: "Open Notes",
        origin: "composer",
        private: false,
        unattended: false,
        mode: "normal",
        context: {},
        ...body,
      },
    });
    return id;
  }

  /** Answers a propose with every action done. Returns the message sent. */
  outcomeFor(propose: ServerMessage, id: string = randomUUID()): ClientMessage {
    if (propose.type !== "propose") throw new Error(`expected a propose, got ${propose.type}`);
    const message: ClientMessage = {
      v: 1,
      type: "outcome",
      id,
      task: propose.task,
      seq: this.nextSeq(propose.task),
      re: propose.seq,
      body: {
        results: propose.body.actions.map((action) => ({
          action_id: action.action_id,
          status: "done" as const,
          effect: action.effect,
        })),
      },
    };
    this.send(message);
    return message;
  }

  next(match: (message: ServerMessage) => boolean, timeoutMs = 3000): Promise<ServerMessage> {
    const already = this.received.find(match);
    if (already !== undefined) {
      this.received.splice(this.received.indexOf(already), 1);
      return Promise.resolve(already);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for a message")), timeoutMs);
      this.waiters.push({
        match,
        resolve: (message) => {
          clearTimeout(timer);
          this.received.splice(this.received.indexOf(message), 1);
          resolve(message);
        },
      });
    });
  }

  nextOfType(type: ServerMessage["type"], timeoutMs?: number): Promise<ServerMessage> {
    return this.next((message) => message.type === type, timeoutMs);
  }

  close(): void {
    this.socket.close();
  }
}

/**
 * A memory store whose `method` throws for its first `times` calls, the way a database connection
 * that drops for a moment does.
 */
export function flakyStore(
  method: keyof TaskStore,
  times = 1,
  store: ReturnType<typeof memoryTaskStore> = memoryTaskStore(),
): ReturnType<typeof memoryTaskStore> {
  let failures = times;
  const original = (store[method] as (...args: unknown[]) => Promise<unknown>).bind(store);
  (store as unknown as Record<string, unknown>)[method] = (...args: unknown[]) => {
    if (failures > 0) {
      failures -= 1;
      return Promise.reject(new Error("Connection terminated unexpectedly"));
    }
    return original(...args);
  };
  return store;
}

export function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
