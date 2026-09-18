import type pg from "pg";
import { accountForSupabaseUser } from "./attribution.js";
import type { Provider } from "./identity.js";

/**
 * The one check a sign-in makes before `resolve()`: would it split a provider-side user across two
 * live accounts (SONNY-129, founders' option A of 2026-09-18)?
 *
 * **What goes wrong without it.** Supabase links a sign-in to an existing user whenever the verified
 * addresses match, so someone who signed up by email code and later presses Google comes back from
 * Supabase as the *same* user. The identity rule's 2026-08-22 decision then creates a second account
 * for the Google identity, filed under that same user — and `accountForSupabaseUser` answers
 * `ambiguous` for any user two live accounts name, so the gate and refresh refuse every token that
 * user holds. Signing in again lands on the same user and cannot help, and closing either account sits
 * behind the same gate. Reproduced against a real Postgres before this was written; the reverse
 * order, Google first and then an email code, reaches the same state, and `oauth.db.test.ts`
 * holds both.
 *
 * **So the sign-in is refused instead, before anything is created.** The alternatives were on the
 * record and both lost: tying each session to its account alone keeps the lockout reachable through
 * account closure, which signs out every session of a closed account's provider-side users; and
 * landing the sign-in on the existing account is merging on an email address, which the founders
 * refused on 2026-08-22 for the recycled mailbox. A refusal keeps one person on one account in the
 * ordinary case and refuses to guess in the ambiguous one — the principle that decision encoded.
 *
 * **What it is not.** It is not the identity rule and changes nothing `resolve()` decides; the rule
 * is the account model, and this ticket may not reshape it. It reads the two facts the rule's own
 * tables already hold and answers whether the sign-in may proceed to the rule at all.
 */
export type SignInGuardVerdict =
  /** Nothing is split: `resolve()` may run. */
  | { readonly proceed: true }
  /**
   * The provider-side user already belongs to a live account this sign-in would not land on. The
   * route answers `409 auth.account_exists`.
   */
  | { readonly proceed: false; readonly reason: "belongs_to_another_account" }
  /**
   * The provider-side user already belongs to two live accounts — the state this guard exists to
   * prevent, and one migration 0023 measured absent where it applied. Refused the way the gate and
   * refresh refuse it, because every token for this user would be refused anyway.
   */
  | { readonly proceed: false; readonly reason: "already_ambiguous" };

export async function signInGuardVerdict(
  client: pg.Client,
  supabaseUserId: string,
  provider: Provider,
  subject: string,
): Promise<SignInGuardVerdict> {
  const owner = await accountForSupabaseUser(client, supabaseUserId);
  if (!("accountId" in owner)) {
    return owner.ambiguous
      ? { proceed: false, reason: "already_ambiguous" }
      : { proceed: true };
  }
  // Where rule 1 would land: the live account already holding this `(provider, subject)`, if any.
  // The same exclusions `accountForSupabaseUser` applies, so the two answers are about one population.
  const target = await client.query<{ account_id: string }>(
    `SELECT i.account_id
       FROM sonny.identity i
       JOIN sonny.account a ON a.id = i.account_id
      WHERE i.provider = $1 AND i.subject = $2 AND NOT i.account_closed AND a.deleted_at IS NULL`,
    [provider, subject],
  );
  // **Proceed only when rule 1 lands on the account this user already belongs to.** Anything else —
  // no identity yet, so rule 2 or 3 would create an account; or an identity on a *different* account,
  // which rule 1 would re-point at this user — leaves the user naming two live accounts.
  return target.rows[0]?.account_id === owner.accountId
    ? { proceed: true }
    : { proceed: false, reason: "belongs_to_another_account" };
}

/**
 * Run `work` while holding a lock on one provider-side user, so the guard and the `resolve()` behind
 * it cannot interleave with another sign-in for the same user.
 *
 * **The race it closes.** Two sign-ins for one brand-new user — an email code and Google pressed at
 * once — would both find the user unowned, both proceed, and create two accounts under it, which is
 * the lockout this file exists to prevent, reached by timing instead of by order.
 *
 * **A session-level lock rather than a transaction-level one, because `resolve()` owns its own
 * transaction.** It issues its own `BEGIN` and `COMMIT`, so wrapping it in an outer transaction would
 * have its `COMMIT` end ours and release an `xact` lock early. `pg_advisory_lock` outlives both, and
 * the `finally` releases it on every path this code can take. A connection that dies holding it
 * releases it with the connection. Nothing inside `work` makes a network call, so the hold is bounded
 * by the database statements it runs and the pool's statement timeout.
 *
 * `hashtext` over a namespaced key, the shape `auth/codes.ts` already uses for its mailbox lock. Two
 * users that collide on the hash serialise against each other and nothing worse.
 */
export async function withProviderUserLock<T>(
  client: pg.Client,
  supabaseUserId: string,
  work: () => Promise<T>,
): Promise<T> {
  const key = `sonny.sign_in:${supabaseUserId}`;
  await client.query("SELECT pg_advisory_lock(hashtext($1))", [key]);
  try {
    return await work();
  } finally {
    await client.query("SELECT pg_advisory_unlock(hashtext($1))", [key]);
  }
}
