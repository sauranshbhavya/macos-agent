import { createHash } from "node:crypto";
import type pg from "pg";

/**
 * Fixed-window rate limiting for the auth endpoints.
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
/** Verification is guessing, so it is tighter and keyed to the address being guessed at. */
export const CODE_VERIFY_PER_ADDRESS: Limit = { max: 5, windowSeconds: 15 * 60 };

/**
 * Salted hash of a bucket key. Raw addresses and source identifiers are personal data, and a table
 * of them is a liability that buys nothing — rate limiting only ever needs equality.
 *
 * The salt comes from configuration and has no default: an unsalted hash of an email address is a
 * rainbow-table lookup away from the address itself.
 */
export function bucketKey(kind: "addr" | "src" | "verify", value: string, salt: string): string {
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
