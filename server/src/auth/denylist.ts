import type pg from "pg";
import { EXPIRY_SKEW_TOLERANCE_SECONDS } from "./clock.js";

/**
 * The list of provider-side sessions this gateway has stopped honouring, and the whole of it
 * (SONNY-237).
 *
 * **What it closes.** A Supabase access token is self-contained, so `auth/token.ts` verifies it
 * locally with the project's JWT secret and never asks the provider — which is what keeps an
 * authenticated request off the provider's latency and availability, and is equally why this gateway
 * cannot un-issue a token. `POST /v1/auth/signout` revokes the *refresh* family, so no new access
 * token can be minted; the one already in the user's hand kept verifying until its own `exp` plus
 * `EXPIRY_SKEW_TOLERANCE_SECONDS`, which is an hour on Supabase's default. That is a working session
 * left behind on a shared or borrowed Mac by someone who pressed Sign out. Migration 0022's header
 * carries the provider evidence for the claim this keys on.
 *
 * **Why this is its own module rather than a clause in `attribution.ts`.** That file's docstring is
 * an argument about exactly which columns it may read — joining the wrong one would let a token
 * minted for a superseded provider-side user attribute to the account again — and `POST
 * /v1/auth/refresh` calls it with no session in hand at all. Folding a second question into that
 * query would also collapse two different refusals into one message: "this session no longer belongs
 * to an active account" is not what happened when a user signed out. The two questions stay two
 * functions, and the gate asks both on the one connection it already leases.
 *
 * **The cost, stated rather than left to be found.** This is a second statement on every
 * authenticated request whose token carries a session claim — one extra round trip to Postgres on the
 * connection attribution was going to check out anyway, not a second connection. It is a primary-key
 * lookup on a table bounded by one token lifetime's worth of sign-outs. A token with no session claim
 * skips it entirely, because there is nothing to look up.
 *
 * **What it does not close, and this is the honest residual.** Supabase's `session_id` claim is
 * `omitempty` and GoTrue itself handles its absence — `internal/api/logout.go:52` logs
 * `"user has an empty session_id claim"` and then logs the user out *globally*, whatever scope was
 * asked for. A token that carries no session claim therefore cannot be denylisted, and keeps
 * verifying to its own `exp` exactly as before. `routes/auth.ts` logs when that happens rather than
 * letting a sign-out look complete; `auth/gate.ts` and `server/README.md` state the residual.
 */

/**
 * Is this provider-side session one the gateway has been told to stop honouring?
 *
 * **No time predicate, and that is a decision rather than an omission.** A row lives until the
 * revoked token's `exp` plus the tolerance, so a row that has outlived its own `expires_at` names a
 * token `verifyAccessToken` has already refused — the gate never reaches this function for it. Adding
 * `AND expires_at > now()` would therefore change no answer while introducing a way for a clock
 * disagreement between this process and Postgres to *un*-revoke a live session, which is the one
 * direction this table must not fail in.
 *
 * The id is bound as `uuid`, so a malformed string would raise Postgres' `22P02` out of a request
 * path rather than returning no rows. `verifyAccessToken` refuses a `session_id` that is not a UUID
 * before this is reached, which is the same division of labour `attribution.ts` documents for `sub`.
 */
export async function isProviderSessionRevoked(
  client: pg.Client,
  providerSessionId: string,
): Promise<boolean> {
  const found = await client.query(
    "SELECT 1 FROM sonny.revoked_provider_session WHERE session_id = $1",
    [providerSessionId],
  );
  return found.rows.length > 0;
}

/**
 * The instant a revoked session's row may be dropped: the token's own expiry plus the tolerance the
 * gate grants past it.
 *
 * **`exp` alone is thirty seconds short and the shortfall is exactly the window that matters.**
 * `clock.ts` accepts a token for `EXPIRY_SKEW_TOLERANCE_SECONDS` past `exp` in one direction, so a
 * row pruned at `exp` would leave a window in which `verifyAccessToken` says yes and this table has
 * forgotten the session. PR #104's F9 found the same understatement in three prose statements of
 * this window; here it would have been an off-by-thirty-seconds in a `DELETE`.
 */
export function denylistedUntil(accessTokenExpiresAt: Date): Date {
  return new Date(accessTokenExpiresAt.getTime() + EXPIRY_SKEW_TOLERANCE_SECONDS * 1000);
}

/**
 * Record a revoked session, and prune what has expired, in one statement.
 *
 * **Retention is the founders' decision of 2026-08-30**: a row is kept until the token would have
 * expired anyway and is then pruned, because a row whose token has passed its own expiry can no
 * longer authorise anything. There is no scheduler and no configurable retention — the prune rides
 * on the write, so the table is bounded by the sign-outs of one token lifetime and a gateway nobody
 * signs out of holds rows that cost storage and change no answer.
 *
 * **`now` is the server's clock and is passed in rather than read here**, so a test can place the
 * prune's boundary exactly; the same reason `token.ts` takes its `now`. It is never a value a caller
 * sent.
 *
 * **`revoked_at` is refreshed on conflict, and choosing that over keeping the first ask is a
 * decision the storage makes for us** (PR #215's F2). Migration 0022 calls this column the thing
 * that makes a support question answerable at all, so it has to mean one thing on every path. "The
 * first time this gateway was asked" cannot: the prune destroys the row, so a session re-revoked
 * after some *other* user's sign-out pruned it has no first ask left to report, and the column would
 * silently mean "the first ask, or a later one, depending on traffic nobody involved can see".
 * "The most recent ask" is reachable on every path, and it is also the reading that keeps one row
 * internally consistent: `expires_at` already describes the latest token this session was signed out
 * with, and a `revoked_at` from a token lifetime earlier describes a different act sitting beside it.
 *
 * **`GREATEST` on conflict, because a second sign-out must never shorten the first.** Two sign-outs
 * for one session are ordinary — a client retrying a `502`, or a `504` the caller retries under §9.3
 * — and they may present different tokens of the same session, since `session_id` survives a
 * refresh. Taking the later expiry keeps the row covering every token the gateway has been shown.
 * **What it cannot cover is a token of the same session that was never presented here and outlives
 * the ones that were.** In practice the presented token is the newest, because refreshing is what
 * produces a newer one and the client signs out with what it holds; a client that signed out with a
 * stale token while holding a fresher one would leave the fresher one working to its own `exp`. That
 * is a narrower residual than the one this table closes, and it is written down rather than assumed
 * away.
 *
 * **The prune and the upsert touch the same row, and what happens then is the `ON CONFLICT` arm
 * running on the tuple the prune matched — not a fresh insert.** Measured on Postgres 17.11 by
 * running this exact statement, lifted out of this file rather than retyped, with `revoked_at` as
 * the discriminator: `DO UPDATE` sets only the columns it names, so a genuine insert restamps that
 * column and an update cannot. With no pre-existing row it comes back stamped today; with an
 * expired row belonging to a **different** session it comes back stamped today, which is the control
 * saying the prune really does delete; and with an expired row belonging to **this** session it
 * comes back carrying the planted timestamp. Both controls fire, so the probe can produce either
 * answer. **The delete and the conflict check do not race and neither loses**: a data-modifying
 * `WITH` runs on the statement's own snapshot while the arbiter reads a dirty one, so the row is
 * still there to conflict on, and nothing raises. The outcome is what this function wants either
 * way — one row, the later expiry — which is why the mechanism went unnoticed while the sentence
 * describing it was wrong twice.
 *
 * **This paragraph is the second correction of the same three lines, and the reason it earned one is
 * the sentence rather than the code.** The first version carried an `AND session_id <> $1` on the
 * prune to sidestep an interaction that does not happen, and that condition is gone for the reason
 * `token.ts` gives for deleting its unreachable `4n+1` guard: a condition that cannot change an
 * answer is not a second defence, it is a claim the next reader will reason from. The replacement
 * then asserted the opposite mechanism, equally unmeasured, and it is the sentence somebody would
 * reason from when they next change the statement — which is exactly the cost that guard was deleted
 * for, arriving in prose instead of in code. `re-revokes a session whose own row has already expired`
 * in `denylist.db.test.ts` reads `revoked_at` back for that reason: it is the one assertion that can
 * tell an update on the pruned tuple from a fresh insert, and the version of that test which did not
 * read it passed under both.
 */
export async function revokeProviderSession(
  client: pg.Client,
  providerSessionId: string,
  expiresAt: Date,
  now: Date,
): Promise<void> {
  await client.query(
    `WITH pruned AS (
       DELETE FROM sonny.revoked_provider_session WHERE expires_at <= $3
     )
     INSERT INTO sonny.revoked_provider_session (session_id, revoked_at, expires_at)
     VALUES ($1, $3, $2)
     ON CONFLICT (session_id) DO UPDATE
       SET expires_at = GREATEST(EXCLUDED.expires_at, sonny.revoked_provider_session.expires_at),
           revoked_at = EXCLUDED.revoked_at`,
    [providerSessionId, expiresAt, now],
  );
}

/**
 * How many rows the table holds. Nothing on the request path calls this; it is what lets a test
 * assert the prune happened rather than assert that a `DELETE` was written.
 */
export async function revokedProviderSessionCount(client: pg.Client): Promise<number> {
  const counted = await client.query<{ n: string }>(
    "SELECT count(*)::text AS n FROM sonny.revoked_provider_session",
  );
  return Number(counted.rows[0]!.n);
}
