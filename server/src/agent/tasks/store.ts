/**
 * Where V2 tasks and their transcripts live (migration 0024).
 *
 * A task's transcript is every message of the task in the order it was stored: `in` from the Mac,
 * `out` to the Mac, and `note` for the agents' own records, which never leave the gateway. `seq`
 * counts per direction. The transcript is the whole of a task's state: an agent's next turn is a
 * function of it, which is what lets any gateway process resume a task after a restart.
 */
import type { Mode } from "../protocol.js";

export type TaskStatus = "live" | "completed" | "failed" | "cancelled";
export type EndedStatus = Exclude<TaskStatus, "live">;
export type Direction = "in" | "out" | "note";

export interface TaskRecord {
  readonly id: string;
  readonly accountId: string;
  readonly deviceId: string;
  readonly status: TaskStatus;
  readonly isPrivate: boolean;
  readonly unattended: boolean;
  readonly goal: string;
  readonly origin: string;
  readonly mode: Mode;
  readonly priorTask: string | null;
  readonly lastSeqIn: number;
  readonly lastSeqOut: number;
  readonly turns: number;
  readonly modelCalls: number;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  readonly endedAt: Date | null;
}

export interface StoredMessage {
  readonly direction: Direction;
  readonly seq: number;
  /** The other side's seq this message answers. */
  readonly re: number | null;
  readonly msgId: string;
  readonly type: string;
  readonly body: unknown;
  readonly createdAt: Date;
}

export interface NewTask {
  readonly id: string;
  readonly accountId: string;
  readonly deviceId: string;
  readonly isPrivate: boolean;
  readonly unattended: boolean;
  readonly goal: string;
  readonly origin: string;
  readonly mode: Mode;
  readonly priorTask: string | null;
  /** The task.start message itself, stored as inbound seq 1. */
  readonly start: { readonly msgId: string; readonly body: unknown };
}

export interface InboundMessage {
  readonly seq: number;
  readonly re: number | null;
  readonly msgId: string;
  readonly type: string;
  readonly body: unknown;
}

export interface TurnEntry {
  readonly direction: "out" | "note";
  readonly re: number | null;
  readonly msgId: string;
  readonly type: string;
  readonly body: unknown;
}

export type CreateOutcome = "created" | "duplicate" | "conflict";

/**
 * - `duplicate`: this message id, or this seq, was already stored. Ignore it.
 * - `gap`: the seq skips one the gateway never stored. The Mac must resend from `lastSeqIn + 1`.
 * - `ended`: the task is no longer live.
 */
export type InboundOutcome = "appended" | "duplicate" | "gap" | "ended" | "unknown";

export interface SweepOutcome {
  readonly deleted: number;
  readonly abandoned: number;
}

export interface TaskStore {
  touchDevice(deviceId: string, accountId: string, now: Date): Promise<void>;
  createTask(task: NewTask, now: Date): Promise<CreateOutcome>;
  task(id: string): Promise<TaskRecord | undefined>;
  appendInbound(taskId: string, message: InboundMessage, now: Date): Promise<InboundOutcome>;
  /**
   * Stores one turn's notes and outbound messages together and counts the turn. With `end`, the
   * task ends in the same transaction, and a private task is deleted there and then.
   * Returns the stored outbound messages with their seqs, or undefined if the task is no longer
   * live.
   */
  appendTurn(
    taskId: string,
    entries: readonly TurnEntry[],
    now: Date,
    end?: EndedStatus,
  ): Promise<StoredMessage[] | undefined>;
  transcript(taskId: string): Promise<StoredMessage[]>;
  outboundAfter(taskId: string, seq: number): Promise<StoredMessage[]>;
  /** Counts one model call against the task and returns the new count. */
  countModelCall(taskId: string): Promise<number>;
  /** Ends a live task with no further message. A private task is deleted. */
  end(taskId: string, status: EndedStatus, now: Date): Promise<void>;
  /**
   * Deletes ordinary tasks that ended more than `retentionMs` ago, and fails live tasks nobody has
   * touched for `abandonAfterMs`, deleting them if private.
   */
  sweep(now: Date, limits: { retentionMs: number; abandonAfterMs: number }): Promise<SweepOutcome>;
}

/** An in-memory store for tests and for a gateway run without a database. */
export function memoryTaskStore(): TaskStore & { readonly devices: Map<string, string> } {
  interface Row {
    record: TaskRecord;
    messages: StoredMessage[];
    lastSeqNote: number;
  }
  const tasks = new Map<string, Row>();
  const messageIds = new Set<string>();
  const devices = new Map<string, string>();

  const live = (id: string): Row | undefined => {
    const row = tasks.get(id);
    return row?.record.status === "live" ? row : undefined;
  };
  const remove = (id: string): void => {
    const row = tasks.get(id);
    if (row === undefined) return;
    for (const message of row.messages) messageIds.delete(message.msgId);
    tasks.delete(id);
  };
  const finish = (row: Row, status: EndedStatus, now: Date): void => {
    row.record = { ...row.record, status, endedAt: now, updatedAt: now };
    if (row.record.isPrivate) remove(row.record.id);
  };

  return {
    devices,
    touchDevice(deviceId, accountId) {
      devices.set(deviceId, accountId);
      return Promise.resolve();
    },
    createTask(task, now) {
      const existing = tasks.get(task.id);
      if (existing !== undefined) {
        return Promise.resolve(existing.record.accountId === task.accountId ? "duplicate" : "conflict");
      }
      if (messageIds.has(task.start.msgId)) return Promise.resolve("conflict");
      const record: TaskRecord = {
        id: task.id,
        accountId: task.accountId,
        deviceId: task.deviceId,
        status: "live",
        isPrivate: task.isPrivate,
        unattended: task.unattended,
        goal: task.goal,
        origin: task.origin,
        mode: task.mode,
        priorTask: task.priorTask,
        lastSeqIn: 1,
        lastSeqOut: 0,
        turns: 0,
        modelCalls: 0,
        createdAt: now,
        updatedAt: now,
        endedAt: null,
      };
      messageIds.add(task.start.msgId);
      tasks.set(task.id, {
        record,
        lastSeqNote: 0,
        messages: [
          {
            direction: "in",
            seq: 1,
            re: null,
            msgId: task.start.msgId,
            type: "task.start",
            body: task.start.body,
            createdAt: now,
          },
        ],
      });
      return Promise.resolve("created");
    },
    task(id) {
      return Promise.resolve(tasks.get(id)?.record);
    },
    appendInbound(taskId, message, now) {
      const row = tasks.get(taskId);
      if (row === undefined) return Promise.resolve("unknown");
      if (messageIds.has(message.msgId) || message.seq <= row.record.lastSeqIn) {
        return Promise.resolve("duplicate");
      }
      if (row.record.status !== "live") return Promise.resolve("ended");
      if (message.seq !== row.record.lastSeqIn + 1) return Promise.resolve("gap");
      messageIds.add(message.msgId);
      row.messages.push({ direction: "in", ...message, createdAt: now });
      row.record = { ...row.record, lastSeqIn: message.seq, updatedAt: now };
      return Promise.resolve("appended");
    },
    appendTurn(taskId, entries, now, end) {
      const row = live(taskId);
      if (row === undefined) return Promise.resolve(undefined);
      const stored: StoredMessage[] = [];
      let lastSeqOut = row.record.lastSeqOut;
      for (const entry of entries) {
        const seq = entry.direction === "out" ? ++lastSeqOut : ++row.lastSeqNote;
        const message: StoredMessage = { ...entry, seq, createdAt: now };
        messageIds.add(entry.msgId);
        row.messages.push(message);
        if (entry.direction === "out") stored.push(message);
      }
      row.record = { ...row.record, lastSeqOut, turns: row.record.turns + 1, updatedAt: now };
      if (end !== undefined) finish(row, end, now);
      return Promise.resolve(stored);
    },
    transcript(taskId) {
      return Promise.resolve([...(tasks.get(taskId)?.messages ?? [])]);
    },
    outboundAfter(taskId, seq) {
      const messages = tasks.get(taskId)?.messages ?? [];
      return Promise.resolve(messages.filter((m) => m.direction === "out" && m.seq > seq));
    },
    countModelCall(taskId) {
      const row = tasks.get(taskId);
      if (row === undefined) return Promise.resolve(0);
      row.record = { ...row.record, modelCalls: row.record.modelCalls + 1 };
      return Promise.resolve(row.record.modelCalls);
    },
    end(taskId, status, now) {
      const row = live(taskId);
      if (row !== undefined) finish(row, status, now);
      return Promise.resolve();
    },
    sweep(now, limits) {
      let deleted = 0;
      let abandoned = 0;
      for (const row of [...tasks.values()]) {
        const { record } = row;
        if (record.status === "live") {
          if (now.getTime() - record.updatedAt.getTime() >= limits.abandonAfterMs) {
            finish(row, "failed", now);
            abandoned += 1;
          }
        } else if (record.endedAt !== null && now.getTime() - record.endedAt.getTime() >= limits.retentionMs) {
          remove(record.id);
          deleted += 1;
        }
      }
      return Promise.resolve({ deleted, abandoned });
    },
  };
}
