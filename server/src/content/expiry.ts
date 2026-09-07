import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { deleteStoredResponsesForAccount, pruneExpiredResponses } from "../idempotency/store.js";
import { LONGEST_TOTAL_DEADLINE_MS } from "../entitlement/period.js";
import {
  ClosedAccountSweepFailed,
  expireContentBatch,
  expireSnapshots,
  sweepClosedAccountContent,
} from "./store.js";

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
 * **`pruneExpiredResponses` runs on this sweep too, and it did not until PR #148's review** (F2).
 * This paragraph used to draw a distinction — that function's own doc comment says "nothing
 * schedules this", and that was right for its ticket, since a stale stored response is merely
 * unusable rather than wrong. What the distinction missed is that a stored response body is
 * *content*: the reply this gateway served, kept in `sonny.idempotency_key`. Once this branch
 * claimed a residual was "bounded by that table's own twenty-four hours", something had to enforce
 * the bound, and the sweeper this file builds was already the right place. `sweepExpiredContent`
 * carries what stays SONNY-318's.
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

/**
 * How long one of this sweep's statements may run, in milliseconds — **the sweeper's own budget,
 * not a route's** (SONNY-427, PR #223's F2).
 *
 * `db/pool.ts` bounds every statement on the gateway's pool at §12's `auth.upstream`, because that
 * is what a *request* may spend waiting. This sweep leases from the same pool and is not a request:
 * it is a timer in the process, holding nobody's connection open, answering to no caller. Running it
 * under a number derived for routes is a category error, and it has a measured cost — PR #223's
 * review put four consecutive passes under a bound smaller than one account's delete and every pass
 * threw `57014` having removed nothing, while a control converged in two.
 *
 * **Not every statement here is batched, which is why the budget matters rather than being
 * belt-and-braces.** `expireContentBatch` and `pruneExpiredResponses` take 500 rows at a time;
 * `expireSnapshots` is one CTE over every expired snapshot, and `sweepClosedAccountContent` wipes a
 * whole account in a fixed sequence with no `LIMIT` in it. Batching those two is the other way to
 * fix this and is deliberately not what this branch did: the account wipe is also the request path's
 * own function, whose semantics this round does not change, and batching it would split the single
 * `sonny.content_deletion` row it writes — a shape SONNY-436 owns.
 *
 * **The number is §12's longest `total`, computed rather than written**, so it moves if the table
 * does and a new route cannot be missed — the same derivation `entitlement/period.ts` already makes
 * for the reservation window. What it says is that no statement in this gateway outlives the longest
 * thing the product ever waits for. Against the review's measurement of a heavy account — 400 rows
 * of about 470 KiB, 183 MB of table, deleted in 79 ms — that is about three orders of magnitude of
 * headroom, and it is still a bound: a pass wedged behind somebody else's lock ends and is retried
 * on the next tick instead of holding a pooled connection for ever.
 */
export const SWEEP_STATEMENT_TIMEOUT_MS = LONGEST_TOTAL_DEADLINE_MS;

export interface SweepResult {
  readonly contentRows: number;
  readonly snapshots: number;
  /** Content taken from one closed account this pass, if there was one waiting. */
  readonly closedAccountRows: number;
  /** Stored idempotency response bodies cleared past their twenty-four hours. */
  readonly storedResponses: number;
  /** True when the batch ceiling was reached, so a reader knows more is waiting. */
  readonly more: boolean;
  /** The closed account this pass wiped, if it found one to wipe. */
  readonly closedAccountId?: string;
  /**
   * The closed account this pass could not wipe, and why (SONNY-427).
   *
   * **A pass used to report nothing at all when this happened.** The throw escaped
   * `sweepExpiredContent` and the sweeper's boundary logged one anonymous error, so the three groups
   * of work that had already committed went unreported and the stuck account was never named — one
   * log line an hour saying only that something failed. It is carried here instead, which is an
   * in-process value and a log line and touches no `sonny.content_deletion` row.
   */
  readonly closedAccountFailure?: { readonly accountId: string; readonly message: string };
}

/**
 * One sweep: expired content in batches, then any snapshot that has reached its own end.
 *
 * Snapshots are swept second and separately because they are on a different clock — §10.3's third
 * one — and because today almost every snapshot carries no expiry at all (`store.ts` says why the
 * NULL is the honest value). The call is here so that the day a founder sets a lifecycle, the sweep
 * that enforces it already runs.
 */
export async function sweepExpiredContent(
  client: pg.Client,
  /** Closed accounts an earlier pass could not wipe; see `sweepClosedAccountContent` (SONNY-427). */
  skipAccountIds: readonly string[] = [],
): Promise<SweepResult> {
  let contentRows = 0;
  let batches = 0;
  for (; batches < EXPIRY_MAX_BATCHES; batches += 1) {
    const removed = await expireContentBatch(client, EXPIRY_BATCH_ROWS);
    contentRows += removed;
    if (removed < EXPIRY_BATCH_ROWS) break;
  }
  const snapshots = await expireSnapshots(client);

  /**
   * **The idempotency store's own twenty-four hours, actually running** (PR #148's review, F2).
   *
   * `pruneExpiredResponses` was written by SONNY-300 and proved by a test, and had **no production
   * call site** — every reference to it outside its own definition was a test or a comment, this
   * file's header among them. So three sentences on this branch described a residual as "bounded by
   * that table's own twenty-four hours" when nothing enforced the bound: measured, a response body
   * back-dated thirty days past `response_expires_at` survived a full sweep. The twenty-four hours
   * bounded *replayability* — an expired response is already treated as absent at read time — and
   * never bounded retention.
   *
   * **It belongs on this sweep rather than on a timer of its own**, which is the whole argument for
   * doing it here: this branch built the one thing in the gateway that deletes on a clock, and a
   * second scheduler for a second clock is two things to know about and two to notice have stopped.
   * SONNY-318 filed the gap and its *policy* half stays there — whether the rows themselves should
   * ever be removed, and what unbounded row growth costs on a real deployment — because the rows
   * carry `metering_claimed_at` and removing one would hand its key a second metering event. This
   * clears payloads and keeps rows, which is what that function has always done.
   */
  const storedResponses = await pruneExpiredResponses(client, EXPIRY_BATCH_ROWS);

  // **The recovery half of `DELETE /v1/account`, and the only thing that reaches accounts closed
  // before this branch existed.** `store.ts` carries the reasoning; what matters here is that it
  // runs on the same timer as the clock, so a wipe that could not finish inside its own request is
  // finished by something that runs whether anyone asks or not.
  //
  // **Caught rather than propagated** (SONNY-427). One account that cannot be wiped used to end the
  // whole pass, discarding the report of the three groups above — which had already committed — and
  // naming nothing. The failure is now part of the result, and its account is handed back so the
  // caller can leave it until later; everything else this pass did is still reported.
  let closed;
  let closedAccountFailure;
  try {
    closed = await sweepClosedAccountContent(
      client,
      deleteStoredResponsesForAccount,
      skipAccountIds,
    );
  } catch (error) {
    if (!(error instanceof ClosedAccountSweepFailed)) throw error;
    closedAccountFailure = {
      accountId: error.accountId,
      message: error.cause instanceof Error ? error.cause.message : String(error.cause),
    };
  }
  return {
    contentRows,
    snapshots,
    closedAccountRows: closed?.contentRows ?? 0,
    storedResponses,
    // A full prune batch means more is waiting, the same reading as a full content batch. A failed
    // account is `more` too: something is still there, and the next pass has work whether or not it
    // is this account's.
    more:
      batches >= EXPIRY_MAX_BATCHES ||
      closed !== undefined ||
      closedAccountFailure !== undefined ||
      storedResponses >= EXPIRY_BATCH_ROWS,
    ...(closed !== undefined ? { closedAccountId: closed.accountId } : {}),
    ...(closedAccountFailure !== undefined ? { closedAccountFailure } : {}),
  };
}

/**
 * What the deferral list should be after a pass, given what it was before (SONNY-427).
 *
 * **A pure function because the branch that matters is the one that is easy to get wrong**: a
 * deferral that is never cleared is an abandonment, and nothing about the sweeper's timer makes that
 * observable. Three cases, and each is a real state rather than a defensive one:
 *
 * - a pass that failed on an account defers it, so the next pass takes the one behind it;
 * - a pass that found nothing left to take clears the list, because the accounts it was holding back
 *   are now the only ones there are and they are due another attempt;
 * - a pass that took an account changes nothing — the queue is moving, and the deferred ones wait
 *   until it has finished moving.
 */
export function deferralsAfter(
  deferred: ReadonlySet<string>,
  result: SweepResult,
): ReadonlySet<string> {
  if (result.closedAccountFailure !== undefined) {
    return new Set([...deferred, result.closedAccountFailure.accountId]);
  }
  if (result.closedAccountId === undefined) return new Set();
  return deferred;
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
  /** Closed accounts an earlier pass could not wipe (SONNY-427). */
  skipAccountIds: readonly string[] = [],
): Promise<SweepResult | undefined> {
  return options.withConnection(async (client) => {
    /**
     * **The sweeper's own budget, on the connection it leased** (SONNY-427).
     *
     * Session-level rather than `SET LOCAL`, because this pass spans several transactions of its
     * own — each sweep function does its own `BEGIN`/`COMMIT` — and a `LOCAL` setting would go with
     * the first of them. `RESET` puts the connection back to the pool's own bound rather than to no
     * bound, which is the property `db/pool.ts` carries the measurement for: the pool's value
     * arrives in the startup packet, so it is what a `RESET` returns to. That is what lets this
     * connection be handed to a route immediately afterwards.
     */
    await client.query(`SET statement_timeout TO ${SWEEP_STATEMENT_TIMEOUT_MS}`);
    try {
      const { rows } = await client.query<{ locked: boolean }>(
        "SELECT pg_try_advisory_lock($1) AS locked",
        [SWEEP_LOCK_KEY],
      );
      if (rows[0]?.locked !== true) return undefined;
      try {
        return await sweepExpiredContent(client, skipAccountIds);
      } finally {
        await client.query("SELECT pg_advisory_unlock($1)", [SWEEP_LOCK_KEY]);
      }
    } finally {
      /**
       * **Best-effort, and the residual is stated rather than hidden.** A connection too broken to
       * accept a `RESET` is one whose next user fails on its own terms, and letting that failure
       * replace the sweep's outcome would be the worse of the two — the same reasoning
       * `model/routing.ts`'s helper records for its own reset. The difference worth naming is the
       * direction: a leaked value here is *wider* than the pool's, so if it ever happened a route on
       * that connection would be bounded at this number instead of §12's. Every sweep function
       * rolls its own transaction back on failure, so an aborted transaction cannot reach here,
       * which leaves a dead socket as the only way in — and a dead socket is not reused.
       */
      await client.query("RESET statement_timeout").catch(() => {});
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
  /**
   * Closed accounts a pass could not wipe, held across ticks so the ones behind them move
   * (SONNY-427).
   *
   * **Cleared as soon as a pass finds nothing else to take**, which is what keeps a deferral from
   * becoming an abandonment: the list exists to let the rest of the queue through, so once the rest
   * is through the deferred accounts are due another attempt. A permanently failing account is
   * therefore retried every other pass and named in the log each time, rather than either blocking
   * everything or being silently dropped. Per process, so a restart also retries — a transient cause
   * deserves that.
   */
  let deferred: ReadonlySet<string> = new Set<string>();
  const tick = async (): Promise<void> => {
    // A sweep that overruns its interval must not start a second one beside itself. The advisory
    // lock would refuse it anyway; this keeps the process from holding two connections to find out.
    if (running) return;
    running = true;
    try {
      const result = await sweepOnce(options, [...deferred]);
      if (result === undefined) {
        options.log.info({}, "content expiry sweep skipped: another instance holds the lock");
      } else {
        deferred = deferralsAfter(deferred, result);
        options.log.info(
          {
            contentRows: result.contentRows,
            snapshots: result.snapshots,
            closedAccountRows: result.closedAccountRows,
            storedResponses: result.storedResponses,
            more: result.more,
            // Named, rather than leaving an operator with one anonymous error an hour.
            ...(result.closedAccountFailure !== undefined
              ? { closedAccountFailure: result.closedAccountFailure, deferred: deferred.size }
              : {}),
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
