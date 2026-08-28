import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { deleteStoredResponsesForAccount } from "../idempotency/store.js";
import { expireContentBatch, expireSnapshots, sweepClosedAccountContent } from "./store.js";

/**
 * The content clock, running (SONNY-134). Contract §10.3.
 *
 * **The requirement this file exists for is one sentence: "Expiry must actually run and be
 * observable, not be a column nobody enforces."** An `expires_at` that nothing sweeps is a promise
 * written down beside data that is still there, and it reads exactly like a kept one. So there is a
 * timer in the running process, a row in `sonny.content_deletion` for every pass that took
 * something, a log line for every pass including the ones that took nothing, and a command a
 * founder can run by hand.
 *
 * **This is the difference from `pruneExpiredResponses`**, whose own doc comment says "nothing
 * schedules this". That was right for its ticket — a stored response expires on its own terms and a
 * stale one is merely unusable. It is not right here: the thirty days is a promise about personal
 * data, and the only thing that keeps it is something actually deleting rows.
 */

/**
 * Rows per batch.
 *
 * **Bounded because these rows are large.** A screenshot is around a megabyte and an audio part can
 * be ten, so an unbounded `DELETE` is a long transaction holding locks while live requests insert
 * beside it. Five hundred is small enough to commit quickly and large enough that a day's backlog
 * clears in a handful of passes.
 */
export const EXPIRY_BATCH_ROWS = 500;

/**
 * Batches per sweep.
 *
 * A ceiling rather than "until empty", so one pass cannot run unboundedly long against a table that
 * has been left unswept for months — the sweep would hold a connection from a small pool for as
 * long as it took. What is left over is taken by the next pass an hour later, and the log says how
 * many rows went so a backlog is visible rather than silent.
 */
export const EXPIRY_MAX_BATCHES = 20;

export interface SweepResult {
  readonly contentRows: number;
  readonly snapshots: number;
  /** Content taken from one closed account this pass, if there was one waiting. */
  readonly closedAccountRows: number;
  /** True when the batch ceiling was reached, so a reader knows more is waiting. */
  readonly more: boolean;
}

/**
 * One sweep: expired content in batches, then any snapshot that has reached its own end.
 *
 * Snapshots are swept second and separately because they are on a different clock — §10.3's third
 * one — and because today almost every snapshot carries no expiry at all (`store.ts` says why the
 * NULL is the honest value). The call is here so that the day a founder sets a lifecycle, the sweep
 * that enforces it already runs.
 */
export async function sweepExpiredContent(client: pg.Client): Promise<SweepResult> {
  let contentRows = 0;
  let batches = 0;
  for (; batches < EXPIRY_MAX_BATCHES; batches += 1) {
    const removed = await expireContentBatch(client, EXPIRY_BATCH_ROWS);
    contentRows += removed;
    if (removed < EXPIRY_BATCH_ROWS) break;
  }
  const snapshots = await expireSnapshots(client);
  // **The recovery half of `DELETE /v1/account`, and the only thing that reaches accounts closed
  // before this branch existed.** `store.ts` carries the reasoning; what matters here is that it
  // runs on the same timer as the clock, so a wipe that could not finish inside its own request is
  // finished by something that runs whether anyone asks or not.
  const closed = await sweepClosedAccountContent(client, deleteStoredResponsesForAccount);
  return {
    contentRows,
    snapshots,
    closedAccountRows: closed?.contentRows ?? 0,
    more: batches >= EXPIRY_MAX_BATCHES || closed !== undefined,
  };
}

/**
 * The advisory-lock key one sweeper holds while it runs.
 *
 * **Two instances of this gateway must not sweep at once.** They would not corrupt anything — the
 * batch statement's `LIMIT` subquery means the loser simply deletes rows the winner already took —
 * but they would double the write load and produce two `content_deletion` rows for one clock tick,
 * which makes the record of what expired harder to read than no record at all. `pg_try_advisory_lock`
 * refuses rather than waits, so a second instance skips this tick instead of queueing behind it.
 *
 * An arbitrary constant, distinct from any other advisory lock this codebase takes — which today is
 * none, so it is the first and the comment is here for the second.
 */
const SWEEP_LOCK_KEY = 8_134_001;

export interface SweeperOptions {
  readonly withConnection: WithConnection;
  readonly intervalMs: number;
  readonly log: {
    info: (data: object, message: string) => void;
    error: (data: object, message: string) => void;
  };
}

/**
 * Run the sweep once, under the advisory lock. Returns `undefined` when another instance held it.
 *
 * The lock is taken and released on one connection inside a single `withConnection`, which is what
 * makes it session-scoped and self-releasing: the pool hands the connection back at the end of the
 * callback, and a connection that dies mid-sweep drops its locks with it. There is no state to
 * clean up after a crash, which is the property that makes this safe to run from a timer nobody
 * watches.
 */
export async function sweepOnce(
  options: Pick<SweeperOptions, "withConnection">,
): Promise<SweepResult | undefined> {
  return options.withConnection(async (client) => {
    const { rows } = await client.query<{ locked: boolean }>(
      "SELECT pg_try_advisory_lock($1) AS locked",
      [SWEEP_LOCK_KEY],
    );
    if (rows[0]?.locked !== true) return undefined;
    try {
      return await sweepExpiredContent(client);
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [SWEEP_LOCK_KEY]);
    }
  });
}

/**
 * Start the timer, and return the function that stops it.
 *
 * **Started from `server.ts` and never from `buildApp`**, which is the same split that file already
 * draws between building the server and listening: a test builds an app hundreds of times and none
 * of them should start a timer that talks to a database. It follows that the sweeper is not covered
 * by a test that builds an app — `sweepOnce` and `sweepExpiredContent` are what the tests drive,
 * and what this function adds over them is a `setInterval` and an error boundary.
 *
 * **`unref` so the timer never holds the process open.** A container told to stop should stop; a
 * pending sweep is not work worth delaying a shutdown for, since the next instance's first tick
 * takes whatever this one did not.
 *
 * **A failed sweep is logged and the timer keeps running.** The failure that matters here is a
 * database that is briefly unavailable, and a sweeper that stopped on the first one would leave the
 * clock silently unenforced for as long as the process lived — the exact shape "a column nobody
 * enforces" describes, arrived at from the other direction.
 */
export function startContentExpirySweeper(options: SweeperOptions): () => void {
  let running = false;
  const tick = async (): Promise<void> => {
    // A sweep that overruns its interval must not start a second one beside itself. The advisory
    // lock would refuse it anyway; this keeps the process from holding two connections to find out.
    if (running) return;
    running = true;
    try {
      const result = await sweepOnce(options);
      if (result === undefined) {
        options.log.info({}, "content expiry sweep skipped: another instance holds the lock");
      } else {
        options.log.info(
          {
            contentRows: result.contentRows,
            snapshots: result.snapshots,
            closedAccountRows: result.closedAccountRows,
            more: result.more,
          },
          "content expiry sweep",
        );
      }
    } catch (error) {
      options.log.error({ err: error }, "content expiry sweep failed");
    } finally {
      running = false;
    }
  };

  const timer = setInterval(() => void tick(), options.intervalMs);
  timer.unref();
  // The first sweep runs at once rather than one interval from now, so a restart is not a gap in
  // the clock — and so that a deployment's logs say whether expiry works without waiting an hour.
  void tick();
  return () => clearInterval(timer);
}
