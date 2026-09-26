import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import type { Agent, ModelInvocation } from "../src/agent/agent.js";
import { memoryModelCallLedger } from "../src/agent/credits.js";
import type { ServerTaskMessage } from "../src/agent/protocol.js";
import { SCREENSHOT_TTL_MS, TaskRunner } from "../src/agent/tasks/runner.js";
import { memoryTaskStore } from "../src/agent/tasks/store.js";
import { TEST_TOKEN_RATES } from "./support/agent.js";

const ACCOUNT = "0b9c3a52-7c55-4f1e-8d3c-0000000000b1";
const DEVICE = "d0d0d0d0-1111-4222-8333-444455556666";

function runnerWith(
  agent: Agent,
  options: {
    now?: () => Date;
    modelCallDeadlineMs?: number;
    balance?: number;
    topUp?: (accountId: string, needed: number) => Promise<boolean>;
  } = {},
) {
  const store = memoryTaskStore();
  const ledger = memoryModelCallLedger(options.balance ?? 1000);
  const delivered: ServerTaskMessage[] = [];
  const runner = new TaskRunner({
    store,
    ledger,
    rates: TEST_TOKEN_RATES,
    agentFor: () => agent,
    deliver: (_task, messages) => delivered.push(...messages),
    now: options.now ?? (() => new Date()),
    log: { info: () => {}, error: () => {} },
    ...(options.modelCallDeadlineMs === undefined ? {} : { modelCallDeadlineMs: options.modelCallDeadlineMs }),
    ...(options.topUp === undefined ? {} : { topUp: options.topUp }),
  });
  return { runner, store, ledger, delivered };
}

async function start(runner: TaskRunner, task = randomUUID()): Promise<string> {
  await runner.start(ACCOUNT, DEVICE, {
    v: 1,
    type: "task.start",
    id: randomUUID(),
    task,
    seq: 1,
    body: { goal: "Look", origin: "composer", private: false, unattended: false, mode: "normal", context: {} },
  });
  return task;
}

const observeOnce: Agent = {
  turn: (context) =>
    Promise.resolve({
      messages:
        context.transcript.some((m) => m.type === "observation")
          ? [{ type: "finish", body: { status: "completed", summary: "Seen." } }]
          : [{ type: "observe", body: { app: "com.apple.Notes", ax: false, screenshot: true } }],
    }),
};

describe("TaskRunner", () => {
  it("drops a kept screenshot once it is older than its time to live", async () => {
    let clock = new Date("2026-09-10T12:00:00Z");
    const { runner } = runnerWith({ turn: () => new Promise(() => {}) }, { now: () => clock });
    const first = await start(runner);
    await runner.receive(ACCOUNT, {
      v: 1,
      type: "observation",
      id: randomUUID(),
      task: first,
      seq: 2,
      re: 1,
      body: { generation: 1, screenshot: { media_type: "image/png", data: "AAAA", width: 1, height: 1 } },
    });
    expect(runner.tasksWithScreenshots).toBe(1);

    clock = new Date(clock.getTime() + SCREENSHOT_TTL_MS);
    const second = await start(runner);
    await runner.receive(ACCOUNT, {
      v: 1,
      type: "observation",
      id: randomUUID(),
      task: second,
      seq: 2,
      re: 1,
      body: { generation: 1, screenshot: { media_type: "image/png", data: "BBBB", width: 1, height: 1 } },
    });
    expect(runner.tasksWithScreenshots).toBe(1);
  });

  it("never writes a screenshot's pixels into the transcript", async () => {
    const { runner, store } = runnerWith(observeOnce);
    const task = await start(runner);
    await runner.idle();
    await runner.receive(ACCOUNT, {
      v: 1,
      type: "observation",
      id: randomUUID(),
      task,
      seq: 2,
      re: 1,
      body: { generation: 1, screenshot: { media_type: "image/png", data: "SECRETPIXELS", width: 1, height: 1 } },
    });
    await runner.idle();
    const transcript = await store.transcript(task);
    expect(JSON.stringify(transcript)).not.toContain("SECRETPIXELS");
  });

  it("ends a task model_unavailable when a model call outlives its deadline, and charges nothing", async () => {
    const hanging: Agent = {
      async turn(context) {
        await context.modelCall(
          { agent: "planner", tier: "fast", maxInputTokens: 100, maxOutputTokens: 100 },
          () => new Promise<ModelInvocation<null>>(() => {}),
        );
        return { messages: [] };
      },
    };
    const { runner, ledger, delivered } = runnerWith(hanging, { modelCallDeadlineMs: 30 });
    await start(runner);
    await runner.idle();
    expect(delivered.at(-1)).toMatchObject({ type: "finish", body: { reason: "model_unavailable" } });
    expect([...ledger.calls.values()][0]!.settle).toMatchObject({ credits: 0, outcome: "provider_error" });
  });

  describe("when a model call can't be held", () => {
    const oneCall: Agent = {
      async turn(context) {
        const value = await context.modelCall(
          { agent: "planner", tier: "fast", maxInputTokens: 100, maxOutputTokens: 100 },
          async () => ({ value: "ok", provider: "test", model: "test", usage: { inputTokens: 10, outputTokens: 10 } }),
        );
        return { messages: [{ type: "finish", body: { status: "completed", summary: value } }] };
      },
    };

    it("asks for an automatic top-up for what the call needs, then makes the call", async () => {
      const asked: [string, number][] = [];
      let ledger: ReturnType<typeof memoryModelCallLedger> | undefined;
      const h = runnerWith(oneCall, {
        balance: 0,
        topUp: async (accountId, needed) => {
          asked.push([accountId, needed]);
          ledger?.setBalance(500);
          return true;
        },
      });
      ledger = h.ledger;
      await start(h.runner);
      await h.runner.idle();
      // The fast tier is one credit per thousand tokens each way: 200 tokens hold 0.2 credits.
      expect(asked).toEqual([[ACCOUNT, 0.2]]);
      expect(h.delivered.at(-1)).toMatchObject({ type: "finish", body: { status: "completed", summary: "ok" } });
    });

    it("ends the task out of credits when no top-up is made", async () => {
      let asked = 0;
      const h = runnerWith(oneCall, {
        balance: 0,
        topUp: async () => {
          asked += 1;
          return false;
        },
      });
      await start(h.runner);
      await h.runner.idle();
      expect(asked).toBe(1);
      expect(h.delivered.at(-1)).toMatchObject({ type: "finish", body: { reason: "credits_exhausted" } });
      expect(h.ledger.calls.size).toBe(0);
    });

    it("ends the task out of credits when the deployment sells no top-up", async () => {
      const h = runnerWith(oneCall, { balance: 0 });
      await start(h.runner);
      await h.runner.idle();
      expect(h.delivered.at(-1)).toMatchObject({ type: "finish", body: { reason: "credits_exhausted" } });
    });
  });

  it("stops a closed account's running turns and ends their tasks", async () => {
    const thinking: Agent = {
      turn: (context) =>
        new Promise((_resolve, reject) => context.signal.addEventListener("abort", () => reject(new Error("aborted")))),
    };
    const { runner, store } = runnerWith(thinking);
    const task = await start(runner);
    await new Promise((resolve) => setTimeout(resolve, 10));
    await runner.stopAccount(ACCOUNT);
    await runner.idle();
    expect((await store.task(task))?.status).toBe("failed");
  });
});
