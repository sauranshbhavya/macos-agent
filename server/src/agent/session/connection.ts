/**
 * One Mac's WebSocket session: the per-message half of what the HTTP hooks do for a request.
 *
 * Auth and the version gate ran on the upgrade request. From then on this class re-checks the
 * token before it expires (`reauth.required`, then `reauth`), limits the account's message rate,
 * ignores a repeated message id, keeps the socket alive with pings, and hands task messages to the
 * runner one at a time, in the order they arrived.
 */
import { randomUUID } from "node:crypto";
import type { RawData, WebSocket } from "ws";
import type { AuthVerdict, AuthenticatedCaller } from "../../auth/gate.js";
import {
  clientMessageSchema,
  PROTOCOL_VERSION,
  type ClientMessage,
  type ErrorCode,
  type ServerMessage,
  type ServerTaskMessage,
} from "../protocol.js";
import type { TaskRunner } from "../tasks/runner.js";
import type { TaskStore } from "../tasks/store.js";
import { CLOSE_CODE, DRAIN_RECONNECT_AFTER_MS, type GoodbyeReason } from "./close.js";
import type { SessionPeer, SessionRegistry } from "./registry.js";

export interface SessionTiming {
  readonly heartbeatMs: number;
  readonly helloTimeoutMs: number;
  /** How long before the access token expires the gateway asks for a fresh one. */
  readonly reauthLeadMs: number;
}

export const DEFAULT_SESSION_TIMING: SessionTiming = {
  heartbeatMs: 20_000,
  helloTimeoutMs: 10_000,
  reauthLeadMs: 120_000,
};

/** Screenshots are capped at 3 MB before base64, so a frame over 6 MiB is never legitimate. */
export const MAX_PAYLOAD_BYTES = 6 * 1024 * 1024;

/** How many recent message ids a session remembers to drop exact repeats. */
const REMEMBERED_IDS = 1024;

export interface SessionLog {
  info(data: object, message: string): void;
  warn(data: object, message: string): void;
  error(data: object, message: string): void;
}

export interface SessionDeps {
  readonly runner: TaskRunner;
  readonly store: TaskStore;
  readonly registry: SessionRegistry;
  readonly authenticate: (token: string, now: Date) => Promise<AuthVerdict>;
  readonly now: () => Date;
  readonly timing: SessionTiming;
  readonly log: SessionLog;
}

type ConnectionMessage = Extract<ClientMessage, { type: "hello" | "reauth" }>;
type TaskMessage = Exclude<ClientMessage, ConnectionMessage>;

export class SessionConnection implements SessionPeer {
  private caller: AuthenticatedCaller;
  private device: string | undefined;
  private readonly sessionId = randomUUID();
  private readonly seen = new Set<string>();
  private queue: Promise<void> = Promise.resolve();
  private alive = true;
  private closed = false;
  private readonly timers = new Set<NodeJS.Timeout>();
  private expiryTimers: NodeJS.Timeout[] = [];

  constructor(
    private readonly socket: WebSocket,
    caller: AuthenticatedCaller,
    private readonly deps: SessionDeps,
  ) {
    this.caller = caller;
    deps.registry.add(this);
    socket.on("message", (data, isBinary) => this.onFrame(data, isBinary));
    socket.on("pong", () => {
      this.alive = true;
    });
    socket.on("close", () => this.cleanUp());
    socket.on("error", (error) => deps.log.warn({ err: error }, "session socket error"));
    this.later(deps.timing.helloTimeoutMs, () => {
      if (this.device === undefined) this.closeWith(CLOSE_CODE.protocol, "no hello");
    });
    const heartbeat = setInterval(() => this.beat(), deps.timing.heartbeatMs);
    heartbeat.unref();
    this.timers.add(heartbeat);
    this.scheduleExpiry();
  }

  get accountId(): string {
    return this.caller.accountId;
  }

  get deviceId(): string | undefined {
    return this.device;
  }

  get providerSessionId(): string | undefined {
    return this.caller.providerSessionId;
  }

  sendTask(messages: readonly ServerTaskMessage[]): void {
    for (const message of messages) this.send(message);
  }

  goodbye(reason: GoodbyeReason): void {
    if (this.closed) return;
    this.send({
      v: PROTOCOL_VERSION,
      type: "goodbye",
      id: randomUUID(),
      body: reason === "draining" ? { reason, reconnect_after_ms: DRAIN_RECONNECT_AFTER_MS } : { reason },
    });
    this.closeWith(CLOSE_CODE[reason], reason);
  }

  private send(message: ServerMessage): void {
    if (this.closed || this.socket.readyState !== this.socket.OPEN) return;
    this.socket.send(JSON.stringify(message));
  }

  private sendError(code: ErrorCode, message: string, ref?: string): void {
    this.send({
      v: PROTOCOL_VERSION,
      type: "error",
      id: randomUUID(),
      body: { code, message, ...(ref === undefined ? {} : { ref }) },
    });
  }

  private closeWith(code: number, reason: string): void {
    if (this.closed) return;
    this.closed = true;
    this.socket.close(code, reason);
    this.cleanUp();
  }

  private cleanUp(): void {
    this.closed = true;
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
    this.deps.registry.remove(this);
  }

  private later(delayMs: number, work: () => void): NodeJS.Timeout {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      work();
    }, Math.max(0, delayMs));
    timer.unref();
    this.timers.add(timer);
    return timer;
  }

  private beat(): void {
    if (!this.alive) {
      this.deps.log.info({ account: this.accountId }, "session missed a heartbeat; closing");
      this.closed = true;
      this.socket.terminate();
      this.cleanUp();
      return;
    }
    this.alive = false;
    this.socket.ping();
  }

  /** Asks for a fresh token ahead of expiry, and closes the session if none comes in time. */
  private scheduleExpiry(): void {
    for (const timer of this.expiryTimers) {
      clearTimeout(timer);
      this.timers.delete(timer);
    }
    const remaining = this.caller.accessTokenExpiresAt.getTime() - this.deps.now().getTime();
    this.expiryTimers = [
      this.later(remaining - this.deps.timing.reauthLeadMs, () =>
        this.send({
          v: PROTOCOL_VERSION,
          type: "reauth.required",
          id: randomUUID(),
          body: { expires_at_ms: this.caller.accessTokenExpiresAt.getTime() },
        }),
      ),
      this.later(remaining, () => this.goodbye("auth_expired")),
    ];
  }

  private onFrame(data: RawData, isBinary: boolean): void {
    if (this.closed) return;
    if (isBinary) {
      this.closeWith(CLOSE_CODE.protocol, "binary frames are not part of the protocol");
      return;
    }
    if (!this.deps.registry.allow(this.accountId, this.deps.now().getTime())) {
      this.sendError("rate_limited", "Too many messages.");
      this.closeWith(CLOSE_CODE.rate_limited, "rate limited");
      return;
    }
    let json: unknown;
    try {
      json = JSON.parse(rawText(data));
    } catch {
      this.sendError("malformed", "The message is not JSON.");
      return;
    }
    const parsed = clientMessageSchema.safeParse(json);
    if (!parsed.success) {
      const record = typeof json === "object" && json !== null ? (json as Record<string, unknown>) : {};
      const ref = typeof record["id"] === "string" && /^[0-9a-f-]{36}$/.test(record["id"]) ? record["id"] : undefined;
      if (record["v"] !== PROTOCOL_VERSION) {
        this.sendError("unsupported_version", `This gateway speaks protocol version ${PROTOCOL_VERSION}.`, ref);
      } else {
        this.sendError("malformed", "The message does not match the protocol.", ref);
      }
      return;
    }
    const message = parsed.data;
    if (this.seen.has(message.id)) return;
    this.seen.add(message.id);
    if (this.seen.size > REMEMBERED_IDS) this.seen.delete(this.seen.values().next().value!);

    this.queue = this.queue
      .then(() => this.handle(message))
      .catch((error: unknown) => {
        this.deps.log.error({ err: error, type: message.type }, "a session message could not be handled");
        this.sendError("internal", "The gateway could not handle that message.", message.id);
      });
  }

  private async handle(message: ClientMessage): Promise<void> {
    if (this.closed) return;
    switch (message.type) {
      case "hello":
        return this.hello(message);
      case "reauth":
        return this.reauth(message);
      default:
        if (this.device === undefined) {
          this.sendError("malformed", "Send hello first.", message.id);
          this.closeWith(CLOSE_CODE.protocol, "no hello");
          return;
        }
        return this.taskMessage(message);
    }
  }

  private async hello(message: Extract<ClientMessage, { type: "hello" }>): Promise<void> {
    if (this.device !== undefined) {
      this.sendError("malformed", "hello was already received.", message.id);
      return;
    }
    const { deps } = this;
    this.device = message.body.device_id;
    deps.registry.bindDevice(this, this.device);
    await deps.store.touchDevice(this.device, this.accountId, deps.now());
    const { tasks, replay } = await deps.runner.resume(
      this.accountId,
      message.body.resume.map((entry) => ({ task: entry.task, lastSeqIn: entry.last_seq_in })),
    );
    this.send({
      v: PROTOCOL_VERSION,
      type: "welcome",
      id: randomUUID(),
      body: {
        session_id: this.sessionId,
        server_time_ms: deps.now().getTime(),
        max_payload_bytes: MAX_PAYLOAD_BYTES,
        heartbeat_seconds: Math.max(1, Math.round(deps.timing.heartbeatMs / 1000)),
        tasks: tasks.map((task) => ({ task: task.task, state: task.state, last_seq_in: task.lastSeqIn })),
      },
    });
    await replay();
  }

  private async reauth(message: Extract<ClientMessage, { type: "reauth" }>): Promise<void> {
    const verdict = await this.deps.authenticate(message.body.access_token, this.deps.now());
    if (!verdict.ok || verdict.caller.accountId !== this.accountId) {
      this.deps.log.info(
        { account: this.accountId, refused: verdict.ok ? "another account" : verdict.logMessage },
        "session reauth refused",
      );
      this.goodbye("auth_expired");
      return;
    }
    this.caller = verdict.caller;
    this.scheduleExpiry();
  }

  private async taskMessage(message: TaskMessage): Promise<void> {
    const { runner } = this.deps;
    if (message.type === "task.start") {
      const outcome = await runner.start(this.accountId, this.device!, message);
      if (outcome === "conflict") {
        this.sendError("task_conflict", "That task id is already in use.", message.id);
      }
      return;
    }
    const outcome = await runner.receive(this.accountId, message);
    if (outcome === "unknown") {
      this.sendError("unknown_task", "The gateway has no such task.", message.id);
    } else if (outcome === "gap") {
      this.sendError("sequence_gap", "A message before this one never arrived. Resend from welcome.", message.id);
    }
  }
}

function rawText(data: RawData): string {
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}
