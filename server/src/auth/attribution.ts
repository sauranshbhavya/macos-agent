import type pg from "pg";

/**
 * Which Sonny account a provider-side user belongs to — **or a refusal, never a guess** (PR #87
 * second round, F6).
 *
 * `supabase_user_id` carries no uniqueness constraint and never can: the whole design lets several
 * identities name one Supabase user, which is what makes two `auth.users` rows resolve to one
 * account. What it does *not* license is two **live accounts** naming one Supabase user. That state
 * is the identity rule having failed somewhere upstream, and the routes that resolve a caller this
 * way were meeting it with `ORDER BY … LIMIT 1` — picking a winner, deterministically and
 * arbitrarily. On `DELETE /v1/account` that is choosing which of a user's accounts to destroy on the
 * strength of a tiebreak; on refresh it is handing out a session for whichever account sorted first.
 *
 * So the query asks for two and refuses on two. **The `ORDER BY` is gone with the tiebreak it fed**:
 * with no winner to pick there is nothing left for a row order to decide, and leaving one in would
 * suggest this still chooses.
 *
 * `NOT i.account_closed` matches rule 1's exclusion: an identity a closed account left behind
 * attributes nobody, exactly as it signs nobody in.
 *
 * **This reads `sonny.identity.supabase_user_id` — the CURRENT id — and must never read
 * `sonny.identity_provider_user`** (SONNY-196, SONNY-230). That table is the history of every
 * provider-side user an identity has named, and it exists so a **superseded** id can be revoked and
 * reported. Joining it here would do the exact opposite of what it is for: it would let a token
 * minted for a superseded provider-side user attribute to the account again, which is the thing
 * these two tickets are about preventing. A superseded id resolves to no live identity, so this
 * query finds nothing and the gate answers 401 — that is the property, and
 * `supersession.db.test.ts` pins it in both directions.
 *
 * **Moved here from `routes/auth.ts` by SONNY-203**, unchanged, because it is now what the
 * authenticated-route gate runs on every protected request as well as what the refresh route runs.
 * `auth/identity.ts` would have been the other home; it holds the identity-linking *rule*, which is
 * settled and deliberately not being touched by this ticket.
 *
 * **`supabase_user_id` is compared as `uuid`, and the caller is what keeps that safe.** The column is
 * `uuid`, so a malformed string bound here raises Postgres' `22P02` rather than returning no rows —
 * a 500 out of a request path instead of a refusal. `verifyAccessToken` refuses a `sub` that is not a
 * UUID before this is reached, and that is where the guard belongs: this function's job is the
 * account question, not input validation for a claim it never saw.
 */
export type Attribution = { readonly accountId: string } | { readonly ambiguous: boolean };

export async function accountForSupabaseUser(
  client: pg.Client,
  supabaseUserId: string,
): Promise<Attribution> {
  const owned = await client.query<{ account_id: string }>(
    `SELECT DISTINCT i.account_id
       FROM sonny.identity i
       JOIN sonny.account a ON a.id = i.account_id
      WHERE i.supabase_user_id = $1 AND NOT i.account_closed AND a.deleted_at IS NULL
      LIMIT 2`,
    [supabaseUserId],
  );
  if (owned.rows.length === 1) return { accountId: owned.rows[0]!.account_id };
  return { ambiguous: owned.rows.length > 1 };
}
