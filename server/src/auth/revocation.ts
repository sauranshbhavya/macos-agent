import type pg from "pg";
import { ProviderRejected, type AuthProvider } from "./provider.js";

/**
 * Revoking the provider-side sessions of a closed account, in a way that survives the provider
 * failing halfway through.
 *
 * **The defect this exists for** (PR #87 third round, F1). `DELETE /v1/account` committed the close
 * and then walked the account's identities calling `signOutAllForUser`. The walk lived in memory and
 * rethrew anything that was not `ProviderRejected`, so one transient provider error meant every
 * identity ordered after it was never attempted — and nothing recorded that. Worse, the account was
 * already closed by then, and a closed account cannot be attributed to its caller any more
 * (`accountForSupabaseUser` filters it out, correctly), so the caller could never reach the route
 * again. The failure was permanent by construction: reproduced as an account closed and committed, a
 * 500 to the user, a third identity never revoked, and a retry answering 401.
 *
 * Two changes, and the second is the one that matters:
 *
 * 1. **Catch and continue.** One identity's failure must not decide whether the others are tried.
 *    That alone converts "one stranded session" into "one stranded session instead of several",
 *    which is better and is not a fix.
 * 2. **Write down what is still owed.** `sonny.identity.provider_session_revoked_at` is NULL until a
 *    provider call actually returns, so the outstanding work is a query rather than a lost stack
 *    frame. That is what gives a post-closure transient failure a path to eventual completion: the
 *    deletion route drains the backlog on the way in, and `npm run revocations` reports it from outside,
 *    needing no caller who can still authenticate.
 *
 * **What this deliberately does not do is retry in a loop inside the request.** A provider that is
 * down stays down for longer than a request should wait, and a caller blocked on it learns nothing
 * they can act on. The request records the debt and returns; something else pays it.
 */

export interface RevocationOutcome {
  /** Identities whose provider-side sessions are now recorded as revoked by this call. */
  readonly revoked: number;
  /** Identities attempted and still owed. Their rows keep `provider_session_revoked_at` NULL. */
  readonly failed: number;
  /** One line per failure, provider-side user id and the error's name — never the error object. */
  readonly failures: readonly { readonly supabaseUserId: string; readonly reason: string }[];
}

interface Owed {
  readonly supabase_user_id: string;
}

/**
 * Attempt every outstanding revocation for one closed account, or — with no account id — for every
 * closed account that still has one owed.
 *
 * **`ProviderRejected` counts as done, and nothing else does.** The provider saying "no such user"
 * or "already gone" is the state being asked for; a timeout, a 500 or a network error is not, and
 * marking those done would be recording an event that did not happen in the one table that exists to
 * say whether it did.
 *
 * Rows are claimed one at a time with `FOR UPDATE SKIP LOCKED`, so two drains running at once — the
 * route and the CLI, or two instances — divide the work rather than duplicating it or deadlocking
 * over it. `signOutAllForUser` is idempotent at the provider, but a drain that depends on that is a
 * drain resting on someone else's implementation detail.
 */
export async function drainOwedRevocations(
  client: pg.Client,
  provider: AuthProvider,
  options: { accountId?: string; limit?: number } = {},
): Promise<RevocationOutcome> {
  const limit = options.limit ?? 100;
  let revoked = 0;
  const failures: { supabaseUserId: string; reason: string }[] = [];

  for (let attempted = 0; attempted < limit; attempted += 1) {
    // One claim per iteration, each in its own transaction: the provider call must not happen inside
    // a transaction holding row locks, because it is a network call of unbounded duration.
    await client.query("BEGIN");
    let owed: Owed | undefined;
    try {
      const claim = await client.query<Owed>(
        `SELECT supabase_user_id
           FROM sonny.identity
          WHERE account_closed
            AND provider_session_revoked_at IS NULL
            AND supabase_user_id IS NOT NULL
            AND ($1::uuid IS NULL OR account_id = $1::uuid)
            -- Both sides cast to text on purpose: supabase_user_id is a uuid column, and binding
            -- this list as uuid[] turns any malformed element into a 22P02 raised by the database
            -- rather than a value this function can see and refuse.
            AND supabase_user_id::text <> ALL($2::text[])
          ORDER BY id
          LIMIT 1
          FOR UPDATE SKIP LOCKED`,
        [options.accountId ?? null, failures.map((f) => f.supabaseUserId)],
      );
      owed = claim.rows[0];
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }
    if (!owed) break;

    try {
      await provider.signOutAllForUser(owed.supabase_user_id);
    } catch (error) {
      if (!(error instanceof ProviderRejected)) {
        // Transient, or unknown, which is treated as transient. The row keeps its NULL, so the next
        // drain finds it again; this run excludes it so one dead user cannot spin the loop.
        failures.push({
          supabaseUserId: owed.supabase_user_id,
          reason: (error as Error)?.name || "Error",
        });
        continue;
      }
      // The provider has no such session. That is the state we wanted, so it is recorded as done.
    }

    // **Every identity naming this provider-side user**, not just the row that was claimed: one
    // `signOutAllForUser` revokes all of that user's sessions, so marking one row would leave the
    // others owed forever and every drain would call the provider again for nothing.
    await client.query(
      `UPDATE sonny.identity
          SET provider_session_revoked_at = now()
        WHERE supabase_user_id = $1
          AND account_closed
          AND provider_session_revoked_at IS NULL`,
      [owed.supabase_user_id],
    );
    revoked += 1;
  }

  return { revoked, failed: failures.length, failures };
}

/** How many revocations are still owed, for the health of a deployment rather than for a request. */
export async function owedRevocationCount(client: pg.Client): Promise<number> {
  const { rows } = await client.query<{ n: number }>(
    `SELECT count(*)::int AS n FROM sonny.identity
      WHERE account_closed AND provider_session_revoked_at IS NULL AND supabase_user_id IS NOT NULL`,
  );
  return rows[0]?.n ?? 0;
}
