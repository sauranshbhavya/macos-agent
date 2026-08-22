import type pg from "pg";

/**
 * The gateway's record of every sign-in code it asked Supabase to send.
 *
 * **It never stores the code.** Supabase Auth issues and verifies it. This exists for the one thing
 * Supabase cannot give us: the contract's three distinct failures.
 *
 * Supabase returns a single `otp_expired` whose message reads "Token has expired or is invalid" for
 * a wrong code, an expired code and an already-used code alike — verified against its documentation
 * on 2026-08-21. The contract requires `auth.code_invalid`, `auth.code_expired` and `auth.code_used`
 * as distinct codes, because SONNY-127 rate-limits them differently and SONNY-128 has to say three
 * different things to the user. They are therefore derived from issuance state here, which is
 * information the gateway has and the provider's error does not carry.
 */

export type VerifyFailure = "auth.code_invalid" | "auth.code_expired" | "auth.code_used";

/** Ten minutes, matching the `expires_in: 600` the contract's §3.6 response advertises. */
export const CODE_LIFETIME_SECONDS = 600;

export async function recordIssue(
  client: pg.Client,
  emailNorm: string,
  sourceHash: string,
  now: Date = new Date(),
): Promise<{ id: string; expiresAt: Date }> {
  const expiresAt = new Date(now.getTime() + CODE_LIFETIME_SECONDS * 1000);
  const result = await client.query<{ id: string }>(
    `INSERT INTO sonny.sign_in_code_issue (email_norm, issued_at, expires_at, source_hash)
     VALUES ($1, $2, $3, $4) RETURNING id`,
    [emailNorm, now, expiresAt, sourceHash],
  );
  return { id: result.rows[0]!.id, expiresAt };
}

/**
 * Mark the most recent live issuance for this address consumed, atomically.
 *
 * **One statement, and the `WHERE consumed_at IS NULL` is the single-use guarantee.** Two concurrent
 * verifies of the same code produce one winner: the loser's update matches no row and it is told
 * `auth.code_used`. Doing this as a read-then-write would let both succeed and mint two sessions
 * from one code, which is the shape SONNY-125 measured going wrong against a spend cap.
 */
export async function consumeLatest(
  client: pg.Client,
  emailNorm: string,
  now: Date = new Date(),
): Promise<boolean> {
  const result = await client.query(
    `UPDATE sonny.sign_in_code_issue
        SET consumed_at = $2
      WHERE id = (
        SELECT id FROM sonny.sign_in_code_issue
         WHERE email_norm = $1 AND consumed_at IS NULL AND expires_at > $2
         ORDER BY issued_at DESC LIMIT 1
        FOR UPDATE SKIP LOCKED
      )`,
    [emailNorm, now],
  );
  return (result.rowCount ?? 0) > 0;
}

/**
 * Which of the three failures this was, from issuance state.
 *
 * Called only after Supabase has already rejected the code, so the question is never "is this
 * right?" — it is "why was it wrong?", and the ordering below is the answer's precedence.
 *
 * **Used beats expired beats invalid**, deliberately. A code that was used and has since also
 * expired is `auth.code_used`, because that is the fact the user needs: asking for a new one is the
 * fix either way, but "you already used that" and "that ran out" are different sentences and only
 * one of them is true about what they did.
 */
export async function classifyFailure(
  client: pg.Client,
  emailNorm: string,
  now: Date = new Date(),
): Promise<VerifyFailure> {
  const latest = await client.query<{ consumed_at: Date | null; expires_at: Date }>(
    `SELECT consumed_at, expires_at FROM sonny.sign_in_code_issue
      WHERE email_norm = $1 ORDER BY issued_at DESC LIMIT 1`,
    [emailNorm],
  );
  const row = latest.rows[0];
  // Nothing was ever issued to this address. Someone is guessing at an address, not at a code.
  if (!row) return "auth.code_invalid";
  if (row.consumed_at !== null) return "auth.code_used";
  if (row.expires_at.getTime() <= now.getTime()) return "auth.code_expired";
  // Live, unconsumed issuance, and the provider still refused it: the digits were wrong.
  return "auth.code_invalid";
}

/**
 * Invalidate every live code for an address.
 *
 * Called when a new code is issued, so that **the newest code is the only one that works** — which
 * is the founder's own manual-test item ("request a second code before using the first, and confirm
 * which one works"). Leaving both live would widen the guessing surface for no benefit, and leaving
 * the *older* one live would be indefensible.
 */
export async function invalidateLive(
  client: pg.Client,
  emailNorm: string,
  now: Date = new Date(),
): Promise<number> {
  const result = await client.query(
    `UPDATE sonny.sign_in_code_issue SET consumed_at = $2
      WHERE email_norm = $1 AND consumed_at IS NULL AND expires_at > $2`,
    [emailNorm, now],
  );
  return result.rowCount ?? 0;
}

/**
 * Invalidate every live code for an address and record the new one, **as one indivisible step**
 * (PR #87 second round, F11).
 *
 * `invalidateLive` then `recordIssue` as two statements is not the same thing, and concurrency is
 * where the difference shows. Three simultaneous `email/start` calls for one address each
 * invalidated what they could see and each inserted afterwards, and none of them could see the other
 * two's inserts — so the address ended with **three** live issuances where the design promises one.
 * The per-address ceiling is three, so three is exactly the number an attacker can arrange, and
 * "the newest code is the only one that works" — which is the founder's own manual-test item —
 * quietly stopped being true.
 *
 * **A transaction alone does not fix it**, which is why there is a lock. Under READ COMMITTED each
 * transaction's `UPDATE` still cannot see a row another transaction has inserted but not committed,
 * so all three would still invalidate nothing of each other's and all three would still insert. The
 * writers have to be serialised, and there is no existing row to lock for the first code ever issued
 * at an address — so the lock is taken on the address itself.
 *
 * `pg_advisory_xact_lock` is released by the transaction end, including a rollback, so no path
 * leaves it held. `hashtext` folds into 32 bits: two unrelated addresses can collide and briefly
 * serialise, which costs one of them a few milliseconds and is the only consequence.
 *
 * **What this deliberately does not make transactional is the send**, which happens before the call
 * and cannot be rolled back. Two racing callers still cause two mails; what they can no longer do is
 * leave our record claiming two codes are live.
 */
export async function issueCode(
  client: pg.Client,
  emailNorm: string,
  sourceHash: string,
  now: Date = new Date(),
): Promise<{ id: string; expiresAt: Date; invalidated: number }> {
  await client.query("BEGIN");
  try {
    await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`sonny.code:${emailNorm}`]);
    const invalidated = await invalidateLive(client, emailNorm, now);
    const issued = await recordIssue(client, emailNorm, sourceHash, now);
    await client.query("COMMIT");
    return { ...issued, invalidated };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}
