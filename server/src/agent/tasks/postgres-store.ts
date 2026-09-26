import type pg from "pg";
import type { WithConnection } from "../../db/connection.js";
import type { Mode } from "../protocol.js";
import {
  ABANDONED_FINISH,
  type CreateOutcome,
  type EndedStatus,
  type InboundOutcome,
  type StoredMessage,
  type SweepOutcome,
  type TaskRecord,
  type TaskStatus,
  type TaskStore,
} from "./store.js";

/** How many ended tasks one sweep deletes at most, so a backlog can't hold a long transaction. */
export const SWEEP_BATCH = 500;

/** One sweep at a time across gateway processes, as `content/expiry.ts` does it. */
const SWEEP_LOCK_KEY = 8_134_102;

interface TaskRow {
  id: string;
  account_id: string;
  device_id: string;
  status: TaskStatus;
  private: boolean;
  unattended: boolean;
  goal: string;
  origin: string;
  mode: Mode;
  prior_task: string | null;
  last_seq_in: number;
  last_seq_out: number;
  last_seq_note: number;
  turns: number;
  model_calls: number;
  created_at: Date;
  updated_at: Date;
  ended_at: Date | null;
}

interface MessageRow {
  direction: StoredMessage["direction"];
  seq: number;
  re: number | null;
  msg_id: string;
  type: string;
  body: unknown;
  created_at: Date;
}

function recordOf(row: TaskRow): TaskRecord {
  return {
    id: row.id,
    accountId: row.account_id,
    deviceId: row.device_id,
    status: row.status,
    isPrivate: row.private,
    unattended: row.unattended,
    goal: row.goal,
    origin: row.origin,
    mode: row.mode,
    priorTask: row.prior_task,
    lastSeqIn: row.last_seq_in,
    lastSeqOut: row.last_seq_out,
    turns: row.turns,
    modelCalls: row.model_calls,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    endedAt: row.ended_at,
  };
}

function messageOf(row: MessageRow): StoredMessage {
  return {
    direction: row.direction,
    seq: row.seq,
    re: row.re,
    msgId: row.msg_id,
    type: row.type,
    body: row.body,
    createdAt: row.created_at,
  };
}

async function transaction<T>(client: pg.Client, work: () => Promise<T>): Promise<T> {
  await client.query("BEGIN");
  try {
    const result = await work();
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

async function lockTask(client: pg.Client, taskId: string): Promise<TaskRow | undefined> {
  const { rows } = await client.query<TaskRow>(
    "SELECT * FROM sonny.agent_task WHERE id = $1 FOR UPDATE",
    [taskId],
  );
  return rows[0];
}

/** Ends a locked live task. A private task's rows go with it. */
async function endLocked(
  client: pg.Client,
  row: TaskRow,
  status: EndedStatus,
  now: Date,
): Promise<void> {
  if (row.private) {
    await client.query("DELETE FROM sonny.agent_task WHERE id = $1", [row.id]);
    return;
  }
  await client.query(
    "UPDATE sonny.agent_task SET status = $2, ended_at = $3, updated_at = $3 WHERE id = $1",
    [row.id, status, now],
  );
}

export function postgresTaskStore(withConnection: WithConnection): TaskStore {
  return {
    touchDevice: (deviceId, accountId, now) =>
      withConnection(async (client) => {
        await client.query(
          `INSERT INTO sonny.device (id, account_id, last_seen_at) VALUES ($1, $2, $3)
           ON CONFLICT (id) DO UPDATE SET account_id = EXCLUDED.account_id, last_seen_at = EXCLUDED.last_seen_at`,
          [deviceId, accountId, now],
        );
      }),

    createTask: (task, now) =>
      withConnection((client) =>
        transaction(client, async (): Promise<CreateOutcome> => {
          const inserted = await client.query(
            `INSERT INTO sonny.agent_task
               (id, account_id, device_id, status, private, unattended, goal, origin, mode, prior_task,
                last_seq_in, created_at, updated_at)
             VALUES ($1, $2, $3, 'live', $4, $5, $6, $7, $8, $9, 1, $10, $10)
             ON CONFLICT (id) DO NOTHING`,
            [
              task.id,
              task.accountId,
              task.deviceId,
              task.isPrivate,
              task.unattended,
              task.goal,
              task.origin,
              task.mode,
              task.priorTask,
              now,
            ],
          );
          if (inserted.rowCount === 0) {
            const { rows } = await client.query<{ account_id: string }>(
              "SELECT account_id FROM sonny.agent_task WHERE id = $1",
              [task.id],
            );
            return rows[0]?.account_id === task.accountId ? "duplicate" : "conflict";
          }
          const message = await client.query(
            `INSERT INTO sonny.agent_message (task_id, direction, seq, msg_id, type, body, created_at)
             VALUES ($1, 'in', 1, $2, 'task.start', $3, $4)
             ON CONFLICT (msg_id) DO NOTHING`,
            [task.id, task.start.msgId, JSON.stringify(task.start.body), now],
          );
          if (message.rowCount === 0) {
            await client.query("DELETE FROM sonny.agent_task WHERE id = $1", [task.id]);
            return "conflict";
          }
          return "created";
        }),
      ),

    task: (id) =>
      withConnection(async (client) => {
        const { rows } = await client.query<TaskRow>("SELECT * FROM sonny.agent_task WHERE id = $1", [id]);
        return rows[0] === undefined ? undefined : recordOf(rows[0]);
      }),

    appendInbound: (taskId, message, now) =>
      withConnection((client) =>
        transaction(client, async (): Promise<InboundOutcome> => {
          const row = await lockTask(client, taskId);
          if (row === undefined) return "unknown";
          if (message.seq <= row.last_seq_in) return "duplicate";
          const seen = await client.query("SELECT 1 FROM sonny.agent_message WHERE msg_id = $1", [message.msgId]);
          if (seen.rowCount !== 0) return "duplicate";
          if (row.status !== "live") return "ended";
          if (message.seq !== row.last_seq_in + 1) return "gap";
          await client.query(
            `INSERT INTO sonny.agent_message (task_id, direction, seq, re, msg_id, type, body, created_at)
             VALUES ($1, 'in', $2, $3, $4, $5, $6, $7)`,
            [taskId, message.seq, message.re, message.msgId, message.type, JSON.stringify(message.body), now],
          );
          await client.query(
            "UPDATE sonny.agent_task SET last_seq_in = $2, updated_at = $3 WHERE id = $1",
            [taskId, message.seq, now],
          );
          return "appended";
        }),
      ),

    appendTurn: (taskId, entries, now, end) =>
      withConnection((client) =>
        transaction(client, async () => {
          const row = await lockTask(client, taskId);
          if (row === undefined || row.status !== "live") return undefined;
          let lastSeqOut = row.last_seq_out;
          let lastSeqNote = row.last_seq_note;
          const stored: StoredMessage[] = [];
          for (const entry of entries) {
            const seq = entry.direction === "out" ? ++lastSeqOut : ++lastSeqNote;
            await client.query(
              `INSERT INTO sonny.agent_message (task_id, direction, seq, re, msg_id, type, body, created_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
              [taskId, entry.direction, seq, entry.re, entry.msgId, entry.type, JSON.stringify(entry.body), now],
            );
            if (entry.direction === "out") stored.push({ ...entry, seq, createdAt: now });
          }
          await client.query(
            `UPDATE sonny.agent_task
                SET last_seq_out = $2, last_seq_note = $3, turns = turns + 1, updated_at = $4
              WHERE id = $1`,
            [taskId, lastSeqOut, lastSeqNote, now],
          );
          if (end !== undefined) await endLocked(client, row, end, now);
          return stored;
        }),
      ),

    transcript: (taskId) =>
      withConnection(async (client) => {
        const { rows } = await client.query<MessageRow>(
          `SELECT direction, seq, re, msg_id, type, body, created_at
             FROM sonny.agent_message WHERE task_id = $1 ORDER BY ord`,
          [taskId],
        );
        return rows.map(messageOf);
      }),

    outboundAfter: (taskId, seq) =>
      withConnection(async (client) => {
        const { rows } = await client.query<MessageRow>(
          `SELECT direction, seq, re, msg_id, type, body, created_at
             FROM sonny.agent_message WHERE task_id = $1 AND direction = 'out' AND seq > $2
            ORDER BY seq`,
          [taskId, seq],
        );
        return rows.map(messageOf);
      }),

    countModelCall: (taskId) =>
      withConnection(async (client) => {
        const { rows } = await client.query<{ model_calls: number }>(
          "UPDATE sonny.agent_task SET model_calls = model_calls + 1 WHERE id = $1 RETURNING model_calls",
          [taskId],
        );
        return rows[0]?.model_calls ?? 0;
      }),

    end: (taskId, status, now) =>
      withConnection((client) =>
        transaction(client, async () => {
          const row = await lockTask(client, taskId);
          if (row !== undefined && row.status === "live") await endLocked(client, row, status, now);
        }),
      ),

    sweep: (now, limits) =>
      withConnection(async (client): Promise<SweepOutcome> => {
        const { rows } = await client.query<{ locked: boolean }>(
          "SELECT pg_try_advisory_lock($1) AS locked",
          [SWEEP_LOCK_KEY],
        );
        if (rows[0]?.locked !== true) return { deleted: 0, abandoned: 0 };
        try {
          const retainedSince = new Date(now.getTime() - limits.retentionMs);
          const idleSince = new Date(now.getTime() - limits.abandonAfterMs);
          const abandonedPrivate = await client.query(
            `DELETE FROM sonny.agent_task
              WHERE id IN (SELECT id FROM sonny.agent_task
                            WHERE status = 'live' AND private AND updated_at <= $1 LIMIT $2)`,
            [idleSince, SWEEP_BATCH],
          );
          // Each abandoned task gets its `finish` in the same statement that ends it, so a Mac that
          // reconnects later is replayed the end rather than left waiting on a task that is over.
          const abandoned = await client.query(
            `WITH ended AS (
               UPDATE sonny.agent_task SET status = 'failed', ended_at = $2, updated_at = $2,
                      last_seq_out = last_seq_out + 1
                WHERE id IN (SELECT id FROM sonny.agent_task
                              WHERE status = 'live' AND updated_at <= $1 LIMIT $3)
                RETURNING id, last_seq_out
             )
             INSERT INTO sonny.agent_message (task_id, direction, seq, re, msg_id, type, body, created_at)
             SELECT id, 'out', last_seq_out, NULL, gen_random_uuid(), 'finish', $4::jsonb, $2 FROM ended`,
            [idleSince, now, SWEEP_BATCH, JSON.stringify(ABANDONED_FINISH)],
          );
          const deleted = await client.query(
            `DELETE FROM sonny.agent_task
              WHERE id IN (SELECT id FROM sonny.agent_task
                            WHERE ended_at IS NOT NULL AND ended_at <= $1 LIMIT $2)`,
            [retainedSince, SWEEP_BATCH],
          );
          return {
            deleted: deleted.rowCount ?? 0,
            abandoned: (abandoned.rowCount ?? 0) + (abandonedPrivate.rowCount ?? 0),
          };
        } finally {
          await client.query("SELECT pg_advisory_unlock($1)", [SWEEP_LOCK_KEY]);
        }
      }),
  };
}
