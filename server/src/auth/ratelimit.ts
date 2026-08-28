import { createHash } from "node:crypto";
import type pg from "pg";

/**
 * Fixed-window rate limiting for the auth endpoints, and — since SONNY-135 — for an authenticated
 * account's own request rate.
 *
 * **The limits exist for two different reasons and are therefore two different buckets.** Per
 * address stops one mailbox being flooded; per source stops one caller enumerating addresses or
 * using the endpoint as a free email-sending service, which the contract names as the specific
 * hazard of an unlimited code endpoint.
 *
 * **The counter is incremented and tested in ONE statement.** SONNY-125 measured what a
 * read-then-write costs under concurrency against a cap: two racing requests both read the old
 * value and both wrote, overshooting it, and the naive implementation reported success. A rate limit
 * has exactly that shape, and an auth endpoint is where the race would be exercised deliberately
 * rather than stumbled into.
 */

export interface Limit {
  readonly max: number;
  readonly windowSeconds: number;
}

/**
 * Chosen to be survivable by a real person and useless to a sender.
 *
 * Per address, 3 in 15 minutes: a user who mistypes, retries, and then asks for one more is fine;
 * anyone trying to mail-bomb an address gets three. Per source, 10 in an hour: comfortably above a
 * household or an office behind one address, and far below anything worth using as a mailer.
 *
 * **These are the gateway's own limits and they sit under Supabase's, not instead of them.**
 * Supabase's custom-SMTP tier allows 30 messages/hour across the whole project, so these ceilings
 * must stay below it or the project limit becomes the real one and returns an error we do not
 * control. Recorded because the two are easy to change independently and only one of them is ours.
 */
export const CODE_REQUEST_PER_ADDRESS: Limit = { max: 3, windowSeconds: 15 * 60 };
export const CODE_REQUEST_PER_SOURCE: Limit = { max: 10, windowSeconds: 60 * 60 };
/**
 * Verification is guessing, so it is tighter and keyed to the address being guessed at.
 *
 * **This is an attacker-controlled lockout, and that is a deliberate trade rather than an oversight**
 * (PR #87 R18). Anyone who knows an address can burn its five attempts and lock the real user out
 * of verifying for the rest of the window — they cannot sign in, though they can still request a
 * fresh code, and the window is fifteen minutes rather than a day. The alternative is no limit on
 * guessing, which trades a bounded, self-clearing nuisance for an unbounded attack on the code's
 * own entropy. Keying the limit to the *source* instead would move the lockout rather than remove
 * it and would be trivially defeated by rotating source addresses. Recorded so the next person to
 * meet a support ticket about it knows it was chosen.
 */
export const CODE_VERIFY_PER_ADDRESS: Limit = { max: 5, windowSeconds: 15 * 60 };
/**
 * **Verification also has a per-SOURCE ceiling, and its absence was a working enumeration
 * primitive** (PR #87 fifth round, F1).
 *
 * The per-address limit above is keyed on the address being guessed at, so it bounds guessing at one
 * mailbox and bounds nothing at all when every request names a different one. Measured on the route
 * before this existed: **200 distinct addresses probed from one source, 0 refused** — while
 * `email/start`, which has had a per-source limit since the first commit, refused 192 of 200 in the
 * same run from the same source. Each of those 200 also spent a `verifyEmailCode` call against the
 * provider's own quota.
 *
 * 30 in an hour: far above a person mistyping a six-digit code a few times, or a household behind
 * one address with several people signing in, and far below anything usable for enumerating a user
 * list. Deliberately looser than `email/start`'s 10, because verifying is what a legitimate user
 * does repeatedly and requesting is not.
 *
 * **Its own bucket kind**, not shared with `email/start`'s source bucket: two limits with different
 * ceilings counted against one counter is one limit, and it would be whichever is smaller.
 *
 * **What "far above a household" does not cover, added after it was pointed out** (PR #87 sixth
 * round). A public address is not a household. Behind a mobile carrier's CGNAT or a shared VPN exit,
 * 30 verifies an hour is a ceiling for *every Sonny user on that egress at once*, and they cannot
 * see each other to know why. And under the `TRUSTED_PROXIES`-unset misconfiguration this constant
 * adds a **second** deployment-wide cap that did not exist before — 30 verifies an hour for
 * everybody — beside `CODE_REQUEST_PER_SOURCE`'s 10. Neither is a reason to drop the limit: without
 * it the route was a working enumeration primitive. Both are reasons to configure the proxy list,
 * and to revisit these numbers when there is real traffic to size them against rather than a guess.
 */
export const CODE_VERIFY_PER_SOURCE: Limit = { max: 30, windowSeconds: 60 * 60 };

/**
 * How many requests one signed-in account may make in a minute: **120**.
 *
 * **This is an abuse ceiling, not an allowance** (SONNY-135). The distinction is what keeps it out
 * of SONNY-212's territory: an allowance is what a plan buys and is measured over a billing period,
 * while this bounds how fast a single credential can be driven and clears by waiting a minute. The
 * two refusals are different codes for exactly that reason — §7.2 gives `limit.rate` a `Retry-After`
 * and denies `limit.spend` one, "because waiting seconds does not fix it".
 *
 * **Sized against the busiest thing Sonny legitimately does.** A screen-control session is at most
 * twelve iterations, one gateway call each, and every one of them waits on a vision round trip
 * measured in seconds (§12 gives that route a 90-second upstream deadline). So a real session cannot
 * approach two calls a second even if the model answered instantly, and a user running several
 * sessions and a few planning calls at once is still an order of magnitude below this. A leaked
 * token driven flat out by a script meets it immediately, which is the case it exists for — and the
 * spend cap is what bounds that token over the period, since 120 a minute is a great deal over a
 * month.
 *
 * **Keyed on the account and never on the address**, unlike the four limits above: those protect an
 * unauthenticated endpoint, where the caller has no identity yet and the source is all there is.
 * Here the caller is verified, so the bucket is the thing being protected — and keying this one on
 * the source would put every user behind one office NAT or one carrier CGNAT into a shared ceiling,
 * which the `CODE_VERIFY_PER_SOURCE` docstring above already records as the cost of doing that where
 * there was no alternative. Here there is one.
 */
export const ACCOUNT_REQUESTS: Limit = { max: 120, windowSeconds: 60 };

/**
 * Salted hash of a bucket key. Raw addresses and source identifiers are personal data, and a table
 * of them is a liability that buys nothing — rate limiting only ever needs equality.
 *
 * The salt comes from configuration and has no default: an unsalted hash of an email address is a
 * rainbow-table lookup away from the address itself.
 */
export function bucketKey(
  kind: "addr" | "src" | "verify" | "verifysrc" | "acct",
  value: string,
  salt: string,
): string {
  if (!salt) throw new Error("rate-limit salt is not configured");
  return `${kind}:${createHash("sha256").update(`${salt}:${kind}:${value}`).digest("hex")}`;
}

export interface Verdict {
  readonly allowed: boolean;
  readonly count: number;
  readonly retryAfterSeconds: number;
}

function windowStart(limit: Limit, now: Date): Date {
  const ms = limit.windowSeconds * 1000;
  return new Date(Math.floor(now.getTime() / ms) * ms);
}

/**
 * Consume one unit against `bucket`, atomically.
 *
 * **`sonny.auth_rate_limit`'s name is historical and its shape is not.** The table is
 * `(bucket, window_start, count)` and knows nothing about authentication; SONNY-135 counts an
 * account's request rate in it rather than adding a second counter beside it, for the reason the
 * host decision gives about the spend cap — a second mechanism for the same question is how the
 * question ends up answered by neither. The `kind` prefix on every bucket key is what keeps the two
 * populations from ever meeting.
 *
 * The whole mechanism is the single `INSERT … ON CONFLICT DO UPDATE … WHERE`: the row is created or
 * incremented in one statement, and the `WHERE` on the update is what refuses the increment once the
 * ceiling is reached. Two concurrent callers cannot both read a stale count, because neither reads
 * one — the second waits on the first's row lock and then re-evaluates against the committed value.
 */
export async function consume(
  client: pg.Client,
  bucket: string,
  limit: Limit,
  now: Date = new Date(),
): Promise<Verdict> {
  const start = windowStart(limit, now);
  const result = await client.query<{ count: number }>(
    `INSERT INTO sonny.auth_rate_limit (bucket, window_start, count)
     VALUES ($1, $2, 1)
     ON CONFLICT (bucket, window_start) DO UPDATE
       SET count = sonny.auth_rate_limit.count + 1
       WHERE sonny.auth_rate_limit.count < $3
     RETURNING count`,
    [bucket, start, limit.max],
  );

  const retryAfterSeconds = Math.max(
    1,
    Math.ceil((start.getTime() + limit.windowSeconds * 1000 - now.getTime()) / 1000),
  );

  // No row returned means the WHERE refused the increment: the ceiling was already reached.
  if (result.rows.length === 0) {
    return { allowed: false, count: limit.max, retryAfterSeconds };
  }
  return { allowed: true, count: result.rows[0]!.count, retryAfterSeconds };
}

/** Old windows are dead weight; nothing reads them once their window has passed. */
export async function sweep(client: pg.Client, olderThan: Date): Promise<number> {
  const result = await client.query(
    "DELETE FROM sonny.auth_rate_limit WHERE window_start < $1",
    [olderThan],
  );
  return result.rowCount ?? 0;
}
