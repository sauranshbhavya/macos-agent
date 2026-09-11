import { AsyncLocalStorage } from "node:async_hooks";
import type { FastifyReply, FastifyRequest } from "fastify";
import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { errorBody } from "../errors.js";
import { ProviderRejected, ProviderTimedOut, ProviderUnavailable } from "./upstream.js";

/**
 * The two things every model route does around its provider call: bound it in time, and turn what it
 * threw into one of §7.2's codes (SONNY-131).
 *
 * **These are copies, and the originals are still in `routes/model.ts`.** Say that plainly, because
 * the first version of this header did not (PR #144, F3): it argued that copying "would have given
 * §12's deadline behaviour and §7.2's failure mapping two implementations that can drift" and then
 * said "so they are here" — which reads as if the duplication had been avoided. It was created, on
 * purpose, and it is real:
 *
 * ```
 * git grep -n "function withDeadlines"      -- server/src   ->  routing.ts:32, routes/model.ts:143
 * git grep -n "function sendUpstreamFailure" -- server/src   ->  routing.ts:67, routes/model.ts:95
 * ```
 *
 * **Why a copy rather than a move.** Both were private declarations inside `routes/model.ts`, which
 * is on SONNY-131's never-touch list — it is "the four text routes" — so deleting them there was not
 * that ticket's to do. **SONNY-316** is the ticket that points the four text routes at this file and
 * deletes the originals, and until it lands there are genuinely two implementations of §12's
 * deadline wrapper and §7.2's failure mapping. **Do not edit one of them and assume the other
 * followed.**
 *
 * Nothing here is new behaviour: the bodies are byte-identical to SONNY-130's, so `SONNY-316` is a
 * deletion rather than a merge.
 */

/**
 * Run `work` under the route's total deadline (§12), with an `AbortSignal` bounded by its upstream
 * deadline.
 *
 * **Two deadlines and not one, because they fail in different places.** The signal ends a provider
 * call that is still open. The total-deadline race ends a handler that is stuck anywhere else —
 * parsing a pathological body, an adapter that resolved and then hung. Without the second, §12's
 * "server total deadline" column would be a number nothing enforces, and the failure it describes
 * would arrive as whatever the platform in front does when it gives up, which the client cannot tell
 * apart from a dead network.
 */
export async function withDeadlines<T>(
  deadlines: { readonly upstream: number; readonly total: number },
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const upstreamTimer = setTimeout(() => controller.abort(), deadlines.upstream);
  let totalTimer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work(controller.signal),
      new Promise<never>((_resolve, reject) => {
        totalTimer = setTimeout(() => {
          controller.abort();
          reject(new ProviderTimedOut("the route's total deadline elapsed"));
        }, deadlines.total);
      }),
    ]);
  } finally {
    clearTimeout(upstreamTimer);
    if (totalTimer !== undefined) clearTimeout(totalTimer);
  }
}

/**
 * Every upstream failure a model route can produce, as §7.2 names it.
 *
 * **Keyed on the thrown type, never on a status this gateway saw.** §9.3 states the client-side
 * version of the same rule and gives the reason: several statuses carry more than one code with
 * opposite semantics. `provider.rejected` and `provider.unavailable` are both 502 and the client
 * retries exactly one of them.
 *
 * Anything this does not recognise is rethrown, so it reaches the root error handler and is logged
 * at `error` with its stack — §7.2 case 6's retryable 500. Swallowing it into a `502` here would
 * make this gateway's own bugs look like a provider's.
 */
export function sendUpstreamFailure(
  request: FastifyRequest,
  reply: FastifyReply,
  error: unknown,
): FastifyReply {
  if (error instanceof ProviderTimedOut) {
    request.log.info({ err: error }, "upstream timed out");
    return reply.status(504).send(
      errorBody("provider.timeout", "The upstream provider did not answer in time.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderUnavailable) {
    request.log.warn({ err: error }, "upstream unavailable");
    return reply.status(502).send(
      errorBody("provider.unavailable", "The upstream provider could not be reached.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderRejected) {
    request.log.warn({ err: error }, "upstream rejected the request");
    return reply.status(502).send(
      errorBody("provider.rejected", "The upstream provider refused this request.", request.id, {
        retryable: false,
      }),
    );
  }
  throw error;
}

/**
 * Postgres's own code for a statement the server cancelled — `query_canceled`, class 57.
 *
 * Read off the error rather than off its message, for `sendUpstreamFailure`'s own reason one screen
 * up: a string is the provider's to reword and a code is not.
 */
const QUERY_CANCELED = "57014";

/** The three statements below are transaction control and carry no user work. */
const TRANSACTION_CONTROL: ReadonlySet<string> = new Set(["BEGIN", "COMMIT", "ROLLBACK"]);

/**
 * Run `work` under §12's total deadline on a connection it holds, and end it there — **never race
 * it**.
 *
 * **`withDeadlines` is the wrong instrument for every caller of this one, and the rule is PR #212's
 * F1 rather than a preference.** That wrapper is a `Promise.race`, so when the deadline wins it
 * *abandons* the work. Harmless when the work is one HTTP call; a correctness defect when it holds
 * the pooled client the handler leased, because `withConnection`'s `finally` then releases a
 * connection the abandoned work is still issuing statements on — `pg` does not refuse a query on a
 * released client, and the pool hands the same client object to the next `connect()`, so those
 * statements land inside whatever transaction the next request has open. **A deadline around work
 * that holds a database connection is never a race that abandons.**
 *
 * **Nor is it the cooperative poll `DELETE /v1/account` uses, and that is a measurement rather than
 * a taste.** That route's work is a *loop* of provider calls, so a signal read between calls is a
 * real bound. The four content-deletion routes' work is not shaped that way: every path they drive
 * in `content/store.ts` — `taskOwnership`, `deleteContentForTask`, `deleteContentForTasks`,
 * `clearScreenshotsForTask`, `deleteContentForAccount` and `deleteStoredResponsesForAccount` — is a
 * fixed sequence of set-based statements with no loop anywhere, so the time is spent *inside* a
 * statement and the gaps between them are where it is not. A poll between statements would be a
 * bound that cannot fire on the one failure mode this work actually has.
 *
 * **So the bound is Postgres's own `statement_timeout`, which is the one instrument that ends a
 * running statement.** A cancelled statement rejects with `57014`, the store's own `catch` rolls
 * back, and the connection is left healthy and released normally — the work is over before the
 * handler answers, which is exactly what the race could not promise.
 *
 * **The budget is a deadline and not a duration, which is what makes it §12's *total*.** A
 * per-statement timeout of 15 s over a six-statement handler is a 90-second bound wearing §12's
 * number, so the remaining budget is recomputed before every statement and an exhausted one is
 * refused without a round trip. The cost is one extra round trip per statement; these are deletion
 * routes rather than a hot path, and the alternative is a promise the table does not make.
 *
 * **Transaction control is exempt from both the bound and the refusal, and that is the whole of the
 * connection-safety argument.** A `ROLLBACK` that this helper refused leaves the connection in an
 * aborted-transaction state, and `withConnection` then returns it to the pool poisoned: the next
 * request's first statement fails with `current transaction is aborted`. That is this ticket's own
 * defect reached through its own fix, so `BEGIN`, `COMMIT` and `ROLLBACK` pass through unbounded.
 * They carry no user work, and the statements that do are already bounded ahead of them.
 *
 * **The refusal is the whole of that reason, and a second reason this comment used to give is not
 * real** (PR #221's review). It also said Postgres might *cancel* a `ROLLBACK` under a
 * one-millisecond remainder; the reviewer could not reproduce that in 300 trials of `BEGIN; SET
 * statement_timeout TO 1; <a statement that is cancelled>; ROLLBACK;` — 300 cancellations of the
 * statement, which is the control, and **0** `current transaction is aborted`. Postgres disables the
 * statement timer before it does the transaction-completion work, so these statements are not
 * cancellable this way at all. The exemption is unchanged and right; only the sentence was stronger
 * than the evidence.
 */
export async function withDatabaseDeadline<T>(
  deadline: { readonly total: number },
  client: pg.Client,
  work: (bounded: pg.Client) => Promise<T>,
): Promise<T> {
  const expiresAt = Date.now() + deadline.total;
  let applied = false;

  const bounded = new Proxy(client, {
    get(target, property, receiver) {
      if (property !== "query") return Reflect.get(target, property, receiver);
      return async (...args: unknown[]): Promise<unknown> => {
        const text = typeof args[0] === "string" ? args[0].trim().toUpperCase() : "";
        if (TRANSACTION_CONTROL.has(text)) {
          return (target.query as (...rest: unknown[]) => Promise<unknown>).apply(target, args);
        }
        const remaining = expiresAt - Date.now();
        // **`<=` and not `<`, and that one character is the difference between this bound and no
        // bound at all** (PR #221's review, F1). `SET statement_timeout TO 0` is Postgres for *no
        // timeout*, so a remainder of exactly zero — reachable whenever `Date.now()` here equals
        // `expiresAt` — would otherwise be handed to the backend as a licence to run forever, and
        // the request would answer its ordinary 200 with §12's promise silently switched off. The
        // shipped guard was already right and nothing held it: the loosened mutant survived the
        // whole suite. `refuses a remainder of exactly zero…` in `content.test.ts` is what holds it
        // now, on a frozen clock, and it asserts the empty statement list as well as the throw —
        // the throw alone cannot tell a refusal apart from a `TO 0` that failed for some other
        // reason.
        if (remaining <= 0) {
          throw new ProviderTimedOut("the route's total deadline elapsed");
        }
        // Interpolated because `SET` takes no bind parameter, and safe because the value is this
        // arithmetic and never anything a caller supplied.
        await target.query(`SET statement_timeout TO ${Math.ceil(remaining)}`);
        applied = true;
        return (target.query as (...rest: unknown[]) => Promise<unknown>).apply(target, args);
      };
    },
  });

  try {
    return await work(bounded);
  } catch (error) {
    if ((error as { code?: string } | null)?.code === QUERY_CANCELED) {
      throw new ProviderTimedOut("the route's total deadline elapsed");
    }
    throw error;
  } finally {
    // **Session-level, so it outlives this lease unless it is cleared.** The reset is best-effort
    // and its own failure is never allowed to replace the outcome above: a connection too broken to
    // accept `RESET` is one whose next user will fail on its own terms, and masking a completed
    // deletion's answer with that would be the worse of the two.
    if (applied) {
      try {
        await client.query("RESET statement_timeout");
      } catch {
        // Deliberately swallowed; see above.
      }
    }
  }
}

/**
 * §12's total deadline for the request under way, carried to every lease a handler's stores take
 * (SONNY-434).
 *
 * **Why a request scope and not a wrapper at the route, which is what the four content-deletion
 * routes have.** Those handlers lease a connection themselves and hand the bounded client to store
 * functions that take one. The three account routes — `GET /v1/account/entitlements`, and the read
 * and the consent switch in `routes/credits.ts` — never hold a client: `EntitlementStore` and
 * `CreditStore` lease *internally* by construction, which is SONNY-300's seam and the reason their
 * transactions cannot be merged with anything. So the handler has no client to wrap, and the
 * alternative — a store built per request over one leased client — reshapes every store factory and
 * every fixture that constructs one. This leaves both stores exactly as they are and puts the budget
 * where the lease is taken: `underTotalDeadline` starts the request's budget, and the `WithConnection`
 * `leasingUnderTotalDeadline` returns reads what is left of it before each lease and hands that to
 * `withDatabaseDeadline`, whose per-statement `SET statement_timeout` is the instrument SONNY-428
 * built and PR #212's F1 requires. One budget for the whole handler, however many leases it takes —
 * the consent switch takes two, its write and the re-read it answers with, and a per-lease budget
 * would have been thirty seconds wearing §12's fifteen.
 *
 * **Outside a declared deadline nothing changes, and that is the property rather than a fallback.**
 * A lease taken by anything that did not call `underTotalDeadline` — the gate's admit and settle on
 * the same `EntitlementStore`, the top-up charge's reads on the same `CreditStore`, which has §12's
 * own row and its own answer when its deadline elapses — goes through untouched and stays on the
 * pool's per-statement bound (SONNY-427). A wrapper that widened every lease to fifteen seconds
 * would have loosened routes this ticket never named.
 *
 * **A budget already spent refuses before the lease, not after it.** The wrapper refuses the first
 * statement of an exhausted budget without a round trip; refusing here as well means an exhausted
 * request does not take a pooled connection to be told no.
 */
const totalDeadlineOfThisRequest = new AsyncLocalStorage<{ readonly expiresAt: number }>();

/** Run `work` as one request under `deadline.total`; every lease inside it shares that budget. */
export function underTotalDeadline<T>(
  deadline: { readonly total: number },
  work: () => Promise<T>,
): Promise<T> {
  return totalDeadlineOfThisRequest.run({ expiresAt: Date.now() + deadline.total }, work);
}

/** `withConnection`, bounding each lease by what is left of the request's budget — if it has one. */
export function leasingUnderTotalDeadline(withConnection: WithConnection): WithConnection {
  return async <T>(work: (client: pg.Client) => Promise<T>): Promise<T> => {
    const request = totalDeadlineOfThisRequest.getStore();
    if (request === undefined) return withConnection(work);
    const remaining = request.expiresAt - Date.now();
    if (remaining <= 0) throw new ProviderTimedOut("the route's total deadline elapsed");
    return withConnection((client) => withDatabaseDeadline({ total: remaining }, client, work));
  };
}
