import type pg from "pg";
import type { WithConnection } from "../db/connection.js";

/**
 * The key store contract §9.2's guarantees are kept in (SONNY-300).
 *
 * Everything here takes a `pg.Client` rather than reaching for a connection of its own, so a caller
 * can run a claim inside its own transaction. **That is not a stylistic preference — it is what makes
 * the metering guarantee usable.** SONNY-133 has to write its event and take its claim atomically,
 * or a crash between the two produces exactly the double-billing §9.2's second bullet exists to
 * forbid. `claimMeteringEvent` on the caller's own client and inside the caller's own `BEGIN` is the
 * only shape that closes that window.
 *
 * The state machine is written out in `0011`'s header beside the column it lives in. What this file
 * adds is the ordering: **the fingerprint is compared before every other branch**, so §9.2's third
 * guarantee holds whether the row is in flight, holding a response, or released.
 */

/**
 * The scope an unauthenticated POST's key lives in.
 *
 * `sonny.account.id` is `gen_random_uuid()` (migration 0002), which is v4 and cannot produce this
 * value, so nothing a real account owns can collide with it. `0011`'s header argues why this is a
 * sentinel rather than a nullable column.
 */
export const UNAUTHENTICATED_SCOPE = "00000000-0000-0000-0000-000000000000";

/** §9.2's twenty-four hours, in seconds. The response clock, not the row's. */
export const RESPONSE_TTL_SECONDS = 24 * 60 * 60;

/**
 * How long an `in_flight` claim is believed, in seconds.
 *
 * A holder past this instant is assumed dead. Something has to assume that: a process killed
 * mid-request would otherwise hold its key against every retry forever, and the row it left behind
 * is indistinguishable from a live one from any other process's side.
 *
 * **The interval this has to cover is claim → `onSend`, and that is not the same as a route's
 * deadline** — which is what this comment used to claim, saying §12's longest total deadline is 105 s
 * "so a request that is genuinely still running can never have its key taken". PR #142's review
 * measured the gap, and SONNY-322 closed it. **This is the one place the relationship is stated**,
 * which is what that ticket asked for: the lease was a constant with no guarantee behind it.
 *
 * Every route's claim-to-`onSend` interval is now bounded by something this process owns, and each
 * bound sits below this constant:
 *
 * | route family                        | bounded by                                   | worst case |
 * |-------------------------------------|----------------------------------------------|-----------|
 * | the JSON routes                     | §12's total deadline (`model/limits.ts`)      | 105 s     |
 * | `POST /v1/transcriptions`           | `BODY_READ_DEADLINE_MS` + its total deadline  | 165 s     |
 *
 * The transcription row is the one that used to be unbounded: its body is `multipart/form-data`,
 * consumed by `request.parts()` **inside** the handler, so the read happens *after* the `preHandler`
 * hook takes the claim and *outside* `withDeadlines`, which `routes/model.ts` applies to the upstream
 * call alone. `routes/model.ts` runs that read under `BODY_READ_DEADLINE_MS` (90 s) and destroys
 * the request stream when it elapses, so 90 s + 75 s = 165 s, fifteen seconds under this lease. **It
 * is the tighter of the two rows above and the one this lease is sized for**: the JSON routes sit 75
 * seconds inside it. (An earlier version of this sentence said "the same margin the JSON routes
 * already had", which was true when both were fifteen and stopped being true when this constant rose
 * to 180.) **`model/limits.ts` derives its 90 s from §12's client timeout for the route, not from
 * this constant** — this one moved to make room for it, which is the opposite of what this sentence
 * used to say. `model.test.ts` asserts the inequality and the margin rather than all three numbers,
 * so a later change to one of them cannot quietly reopen this.
 *
 * **`app.ts`'s `requestTimeout` is not what holds this, and it is worth saying why**, because it is
 * the obvious candidate. It bounds receipt of a request rather than a handler, and it is enforced on
 * Node's thirty-second connection sweep: measured at Fastify 5.12.1 / Node v22.23.1, a 2000 ms
 * setting answered at 89955 ms and a 35000 ms setting at 60003 ms. A bound that cannot be held to
 * within a minute cannot carry a fifteen-second margin. It is a backstop against connection
 * occupancy; the arithmetic above is held at the route.
 *
 * **One hundred and eighty seconds, raised from 120 by the founders on 2026-09-05** (option A on PR
 * #208's F4). The number that actually needed to move was the upload's: §12 gives
 * `POST /v1/transcriptions` a 90-second *client* timeout and the first version of this arithmetic
 * solved for the body read with the lease held fixed, producing 30 s — the gateway giving up at a
 * third of the budget its own client waits, on the one route where the upload is the slow part. The
 * lease is this repository's own constant and answers to nothing outside the gateway, so it is the
 * side that moved. **The cost was named and accepted rather than discovered:** a process killed
 * mid-request now holds its idempotency key for three minutes rather than two before a repeat can
 * take it. What it buys is that a three-minute recording on a weak connection can actually be
 * delivered.
 *
 * **The lease still exists, and the fencing token still matters, because a bound is not a
 * guarantee.** A process killed mid-request runs no deadline at all — which is the case this
 * constant was always for — so a claim can still be taken from a row whose holder is gone.
 * `claim_token` means a superseded holder's `complete` or `release` matches zero rows instead of
 * landing on its successor's claim.
 */
export const CLAIM_LEASE_SECONDS = 180;

/** What a claim attempt turned out to be. The hook maps each to a contract §7.2 answer. */
export type ClaimOutcome =
  /**
   * The key is this request's. Run the handler, then `completeClaim` or `releaseClaim` — **passing
   * `token` back**, which is what makes those act on this claim rather than on whatever claim the row
   * is on by the time they run.
   */
  | { readonly kind: "claimed"; readonly token: string }
  /** §9.2 bullet 1: a stored response inside its window. Replay it, run nothing. */
  | { readonly kind: "replay"; readonly response: StoredResponse }
  /** §9.2 bullet 4: another request holds this key. `retryAfterSeconds` is what remains of its lease. */
  | { readonly kind: "in_flight"; readonly retryAfterSeconds: number }
  /** §9.2 bullet 3: this key was used for a different body. */
  | { readonly kind: "conflict" };

export interface StoredResponse {
  readonly status: number;
  readonly body: Buffer;
  readonly contentType: string | undefined;
  /** The `Sonny-Request-Id` the original exchange carried. `0011`'s header says why it is replayed. */
  readonly requestId: string | undefined;
}

export interface ClaimRequest {
  readonly accountScope: string;
  readonly key: string;
  readonly route: string;
  readonly fingerprint: string;
}

interface KeyRow {
  request_fingerprint: string;
  state: string;
  lease_remaining_seconds: string | number | null;
  response_live: boolean;
  response_status: number | null;
  response_content_type: string | null;
  response_body: Buffer | null;
  response_request_id: string | null;
}

/**
 * Take the key for this request, or say why it cannot be taken.
 *
 * **One transaction, and the row is locked before it is judged.** Two requests presenting one key at
 * the same instant are the case §9.2 bullet 4 is about, and reading the row outside a lock would let
 * both see "nothing in flight" and both call the provider — the exact outcome the bullet forbids.
 *
 * **The insert comes first and the select second, which is the order that survives a race on a key
 * nobody has used yet.** `SELECT … FOR UPDATE` locks nothing when there is no row, so two concurrent
 * first-attempts would both find nothing and both insert, and one would fail on the primary key. An
 * `INSERT … ON CONFLICT DO NOTHING` instead blocks the loser until the winner commits and then
 * returns no row, at which point the select below finds the winner's row and answers `in_flight` —
 * which is the correct answer rather than an error.
 */
export async function claimKey(client: pg.Client, request: ClaimRequest): Promise<ClaimOutcome> {
  await client.query("BEGIN");
  try {
    const inserted = await client.query<{ claim_token: string }>(
      `INSERT INTO sonny.idempotency_key
         (account_scope, idempotency_key, route, request_fingerprint,
          claim_token, state, claimed_at, lease_expires_at)
       VALUES ($1, $2, $3, $4, gen_random_uuid(), 'in_flight', now(),
               now() + make_interval(secs => $5))
       ON CONFLICT (account_scope, idempotency_key) DO NOTHING
       RETURNING claim_token`,
      [request.accountScope, request.key, request.route, request.fingerprint, CLAIM_LEASE_SECONDS],
    );
    const insertedToken = inserted.rows[0]?.claim_token;
    if (insertedToken !== undefined) {
      await client.query("COMMIT");
      return { kind: "claimed", token: insertedToken };
    }

    // `response_live` and `lease_remaining_seconds` are computed by Postgres rather than by
    // comparing timestamps in Node, so both clocks are the database's. A gateway whose own clock has
    // drifted would otherwise replay an expired response, or refuse a key whose lease it thinks is
    // still running, and neither failure would leave a trace.
    const existing = await client.query<KeyRow>(
      `SELECT request_fingerprint,
              state,
              EXTRACT(EPOCH FROM (lease_expires_at - now()))    AS lease_remaining_seconds,
              (response_expires_at IS NOT NULL
                 AND response_expires_at > now()
                 AND response_body IS NOT NULL)                 AS response_live,
              response_status, response_content_type, response_body, response_request_id
         FROM sonny.idempotency_key
        WHERE account_scope = $1 AND idempotency_key = $2
          FOR UPDATE`,
      [request.accountScope, request.key],
    );

    const row = existing.rows[0];
    if (row === undefined) {
      // The row was there for the insert's conflict and gone by the select. Nothing in this codebase
      // deletes one — `pruneExpiredResponses` clears payloads and keeps rows — so this is a hand
      // edit or a restore mid-flight. Answering `conflict` refuses the request rather than guessing;
      // it is the only branch here that is not reachable by any code path in the tree.
      await client.query("COMMIT");
      return { kind: "conflict" };
    }

    // Before every other branch: §9.2's third guarantee does not depend on what state the row is in.
    if (row.request_fingerprint !== request.fingerprint) {
      await client.query("COMMIT");
      return { kind: "conflict" };
    }

    const leaseRemaining = Number(row.lease_remaining_seconds ?? 0);
    if (row.state === "in_flight" && leaseRemaining > 0) {
      await client.query("COMMIT");
      // Rounded up so the value is never 0, which a client would read as "immediately" and spend its
      // one retry on a request that is certainly still running.
      return { kind: "in_flight", retryAfterSeconds: Math.max(1, Math.ceil(leaseRemaining)) };
    }

    if (row.state === "completed" && row.response_live && row.response_body !== null) {
      await client.query("COMMIT");
      return {
        kind: "replay",
        response: {
          status: row.response_status ?? 200,
          body: row.response_body,
          contentType: row.response_content_type ?? undefined,
          requestId: row.response_request_id ?? undefined,
        },
      };
    }

    // Everything left is re-claimable: `released`, an `in_flight` whose holder is gone, and a
    // `completed` whose twenty-four hours have passed. **`metering_claimed_at` is deliberately not
    // touched**, and that omission is the whole of what makes "at most once per key, ever" survive a
    // re-attempt: this row may run again, and it may not bill again.
    const reclaimed = await client.query<{ claim_token: string }>(
      `UPDATE sonny.idempotency_key
          SET route = $3, state = 'in_flight', claimed_at = now(),
              claim_token = gen_random_uuid(),
              lease_expires_at = now() + make_interval(secs => $4),
              completed_at = NULL, response_expires_at = NULL,
              response_status = NULL, response_content_type = NULL,
              response_body = NULL, response_request_id = NULL
        WHERE account_scope = $1 AND idempotency_key = $2
        RETURNING claim_token`,
      [request.accountScope, request.key, request.route, CLAIM_LEASE_SECONDS],
    );
    await client.query("COMMIT");
    // The row was locked `FOR UPDATE` above and nothing deletes rows, so this always returns one.
    return { kind: "claimed", token: reclaimed.rows[0]!.claim_token };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

export interface CompletedResponse {
  readonly status: number;
  readonly body: Buffer;
  readonly contentType: string | undefined;
  readonly requestId: string;
}

/**
 * Store this key's response and start its twenty-four hours.
 *
 * **`claim_token` is the guard that matters, and `state = 'in_flight'` alone is not enough** — which
 * is what this comment used to claim, saying the state guard stops "a late write overwriting a
 * response some *other* request has since stored". That is true only when the successor has already
 * *completed*. When the successor is still **in flight**, `state = 'in_flight'` matches its row, and
 * a superseded holder's completion lands on it: the ghost's body is stored and replayed for
 * twenty-four hours while the successor's real answer is dropped, because by then the state guard
 * matches nothing. PR #142's review measured exactly that ordering; the token closes it, because a
 * superseded holder's token is no longer the row's.
 */
export async function completeClaim(
  client: pg.Client,
  request: { readonly accountScope: string; readonly key: string; readonly token: string },
  response: CompletedResponse,
): Promise<void> {
  await client.query(
    `UPDATE sonny.idempotency_key
        SET state = 'completed', completed_at = now(),
            response_expires_at = now() + make_interval(secs => $6),
            response_status = $3, response_content_type = $4, response_body = $5,
            response_request_id = $7
      WHERE account_scope = $1 AND idempotency_key = $2
        AND state = 'in_flight' AND claim_token = $8`,
    [
      request.accountScope,
      request.key,
      response.status,
      response.contentType ?? null,
      response.body,
      RESPONSE_TTL_SECONDS,
      response.requestId,
      request.token,
    ],
  );
}

/**
 * Give the key back, keeping the row and its metering claim.
 *
 * **This is the founder decision of 2026-08-28 in one statement.** §9.2 says a repeat returns the
 * stored response; §9.3 says `limit.rate`, `provider.unavailable`, `provider.timeout`,
 * `server.error` and `server.unavailable` are retryable *with the same key*. Storing those and
 * replaying them makes every retryable row in that table safe but useless — a 429 becomes a
 * twenty-four-hour ban on that operation and a 503 during a deploy freezes everything in flight. So
 * a retryable failure releases instead, and the retry really runs.
 *
 * What stops that from being a double-bill is the line this function does **not** contain:
 * `metering_claimed_at` is never cleared, so the re-attempt finds the claim already taken and writes
 * no second event. The re-attempt's own usage goes unbilled, which is the direction §9.2's second
 * bullet chooses deliberately — "a client retry unable to double-bill a user" errs toward the user.
 *
 * **`claim_token` is why "give the key back" cannot mean somebody else's key.** Without it a holder
 * whose lease had expired would release its *successor's* live claim, and a third request would
 * claim immediately and call the provider while the successor was still running — §9.2 bullet 4
 * defeated by the very mechanism that is supposed to keep retries honest. Measured in PR #142's
 * review; the token makes a superseded release match zero rows.
 */
export async function releaseClaim(
  client: pg.Client,
  request: { readonly accountScope: string; readonly key: string; readonly token: string },
): Promise<void> {
  await client.query(
    `UPDATE sonny.idempotency_key
        SET state = 'released', completed_at = now(),
            response_expires_at = NULL, response_status = NULL,
            response_content_type = NULL, response_body = NULL, response_request_id = NULL
      WHERE account_scope = $1 AND idempotency_key = $2
        AND state = 'in_flight' AND claim_token = $3`,
    [request.accountScope, request.key, request.token],
  );
}

/**
 * ## The read API SONNY-133 consumes — dated 2026-08-28, SONNY-300
 *
 * `claimMeteringEvent` returns `true` for exactly one caller per `(accountScope, key)`, ever, and
 * `false` for every caller after it. That single fact is contract §9.2's second bullet, and it is
 * the sentence that makes a client retry unable to double-bill a user.
 *
 * **Call it inside the same transaction as the metering write.** It takes the caller's own
 * `pg.Client` for that reason: `BEGIN`, claim, insert the event, `COMMIT`. Claiming outside the
 * transaction leaves a window where the claim is taken and the event is not — a crash there loses
 * the event permanently, which is the same money in the other direction.
 *
 * **A request with no `Idempotency-Key` has no row and therefore no claim to take**, and this
 * function answers `false` for it, which SONNY-133 must not read as "already metered". The gateway
 * serves a keyless POST unprotected by founder decision of 2026-08-28 (the only client sends the
 * header on every POST), so metering such a request is the caller's decision to make on the key's
 * absence — check for the key before calling, rather than inferring it from a `false`. The two
 * cases are distinguishable and must be distinguished: `meteringEventClaimed` below reports whether
 * a row exists at all.
 */
export async function claimMeteringEvent(
  client: pg.Client,
  request: { readonly accountScope: string; readonly key: string },
): Promise<boolean> {
  const claimed = await client.query(
    `UPDATE sonny.idempotency_key
        SET metering_claimed_at = now()
      WHERE account_scope = $1 AND idempotency_key = $2 AND metering_claimed_at IS NULL
      RETURNING 1`,
    [request.accountScope, request.key],
  );
  return claimed.rowCount === 1;
}

/**
 * Whether this key's one metering event has already been taken.
 *
 * Read-only, and answers three states rather than two: `null` when no row exists for the key at all
 * (a keyless request, or one this gateway never saw), `true` when the claim is taken, `false` when
 * the row exists and the claim is still available. SONNY-133 needs the three apart — see
 * `claimMeteringEvent`'s note on why `false` and "no row" are different answers.
 */
export async function meteringEventClaimed(
  client: pg.Client,
  request: { readonly accountScope: string; readonly key: string },
): Promise<boolean | null> {
  const { rows } = await client.query<{ claimed: boolean }>(
    `SELECT (metering_claimed_at IS NOT NULL) AS claimed
       FROM sonny.idempotency_key
      WHERE account_scope = $1 AND idempotency_key = $2`,
    [request.accountScope, request.key],
  );
  return rows[0]?.claimed ?? null;
}

/**
 * Clear the payload of every response past its twenty-four hours, keeping the row.
 *
 * **Not a delete, and `0011`'s header says why**: the row carries `metering_claimed_at`, and
 * deleting it at twenty-four hours would hand the same key a second metering event on day two.
 * `state` moves to `released` so the key is re-claimable, which is what an expired response already
 * means to `claimKey`, and `completed_at` is cleared with the rest — it recorded a completion whose
 * response this statement is erasing, and leaving it set would have the row describe a stored answer
 * that is no longer there. Nothing reads it today; the point is that nothing should be able to read
 * a false value from it later (PR #142's review, recorded residual).
 *
 * Returns how many rows it cleared. **Nothing schedules this** — the gateway runs no timer and this
 * ticket adds none; it exists so that clearing is a call rather than a migration, and so a test can
 * drive it. Recorded as owed on a follow-up ticket rather than left implicit.
 */
export async function pruneExpiredResponses(client: pg.Client, limit = 1000): Promise<number> {
  const pruned = await client.query(
    `UPDATE sonny.idempotency_key
        SET state = 'released', response_status = NULL, response_content_type = NULL,
            response_body = NULL, response_request_id = NULL, response_expires_at = NULL,
            completed_at = NULL
      WHERE (account_scope, idempotency_key) IN (
              SELECT account_scope, idempotency_key
                FROM sonny.idempotency_key
               WHERE response_body IS NOT NULL AND response_expires_at <= now()
               LIMIT $1)`,
    [limit],
  );
  return pruned.rowCount ?? 0;
}

/**
 * Drop the stored responses belonging to one account, keeping its rows and their metering claims.
 *
 * `DELETE /v1/account` is a privacy wipe, and this table is the one place in the gateway that holds
 * response *content* outside the route that produced it. Nothing calls this yet: the deletion route
 * is `routes/auth.ts`'s and outside this ticket's region, so the call site is filed rather than
 * written. It is here so that the call is one line when that ticket comes to make it, and so that
 * the omission is visible in this file rather than only in a ticket.
 */
export async function deleteStoredResponsesForAccount(
  client: pg.Client,
  accountScope: string,
  /**
   * Bound the clear to keys taken at or before this instant (SONNY-404, PR #207's F1). `claimed_at`
   * is when the key was taken, which is the closest this table has to when the content happened.
   * `undefined` is the account-close path and means every key.
   */
  claimedAtOrBefore?: Date,
): Promise<number> {
  const cleared =
    claimedAtOrBefore === undefined
      ? await client.query(
          `UPDATE sonny.idempotency_key
              SET state = 'released', response_status = NULL, response_content_type = NULL,
                  response_body = NULL, response_request_id = NULL, response_expires_at = NULL
            WHERE account_scope = $1 AND response_body IS NOT NULL`,
          [accountScope],
        )
      : await client.query(
          `UPDATE sonny.idempotency_key
              SET state = 'released', response_status = NULL, response_content_type = NULL,
                  response_body = NULL, response_request_id = NULL, response_expires_at = NULL
            WHERE account_scope = $1 AND response_body IS NOT NULL AND claimed_at <= $2`,
          [accountScope, claimedAtOrBefore],
        );
  return cleared.rowCount ?? 0;
}

/**
 * The three operations the request hooks need, behind an interface.
 *
 * **The seam exists so the hook's decisions are testable without a Postgres**, which is the same
 * reason `PoolOptions.createPool` exists one directory over. Every branch in `hook.ts` — replay,
 * both conflicts, release-on-retryable, the oversize response — is a decision about a `ClaimOutcome`
 * and about what to store, and none of it is about SQL. Behind a real database those tests would run
 * only when `DATABASE_URL` is set, which is not the flagged `npm test`, so the behaviours contract
 * §9.2 names would be unverified in the run this repository actually gates on.
 *
 * `postgresKeyStore` is the implementation the running gateway uses, and `idempotency.db.test.ts`
 * is what proves the SQL beneath it against a real Postgres.
 */
export interface KeyStore {
  claim: (request: ClaimRequest) => Promise<ClaimOutcome>;
  complete: (
    request: { readonly accountScope: string; readonly key: string; readonly token: string },
    response: CompletedResponse,
  ) => Promise<void>;
  release: (request: {
    readonly accountScope: string;
    readonly key: string;
    readonly token: string;
  }) => Promise<void>;
}

/**
 * The `KeyStore` over a real connection source.
 *
 * Each operation takes its own connection and gives it back — `claimKey` runs one transaction and
 * the other two run one statement — so nothing here holds a connection across the handler. That is
 * the property `gate.ts` names as keeping a small pool from deadlocking against itself, and it
 * matters more here than there: this store is entered twice per request, once before the handler and
 * once after it.
 */
export function postgresKeyStore(withConnection: WithConnection): KeyStore {
  return {
    claim: (request) => withConnection((client) => claimKey(client, request)),
    complete: (request, response) =>
      withConnection((client) => completeClaim(client, request, response)),
    release: (request) => withConnection((client) => releaseClaim(client, request)),
  };
}
