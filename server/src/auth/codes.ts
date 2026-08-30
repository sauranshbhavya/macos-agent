import type pg from "pg";

/**
 * The gateway's record of every sign-in code it asked Supabase to send.
 *
 * **Every function here is keyed on the MAILBOX — `rateLimitEmailKey(email)` — and never on
 * `normalizeEmail(email)`** (PR #87 third round, F4). The two exist for opposite reasons and this
 * file needs the folding one. `normalizeEmail` is the *identity* key and keeps plus-tags apart,
 * because merging two addresses merges two accounts. A code does not live in an identity; it lives
 * in an inbox, and `a@x`, `a+1@x` and `a+2@x` are one inbox.
 *
 * Keyed the identity way, three simultaneous `email/start` calls for those three spellings shared
 * one rate-limit bucket — which folds — and each wrote and invalidated its own issuance row — which
 * did not. **Three live, independently guessable codes in one inbox**, against the guarantee this
 * branch states in three places as a single-live-code guarantee. Reproduced against
 * a real database before it was fixed. The parameter is named `mailboxKey` rather than `email`
 * throughout so that passing the wrong one has to be done deliberately.
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
  mailboxKey: string,
  sourceHash: string,
  now: Date = new Date(),
): Promise<{ id: string; expiresAt: Date }> {
  const expiresAt = new Date(now.getTime() + CODE_LIFETIME_SECONDS * 1000);
  const result = await client.query<{ id: string }>(
    `INSERT INTO sonny.sign_in_code_issue (mailbox_key, issued_at, expires_at, source_hash)
     VALUES ($1, $2, $3, $4) RETURNING id`,
    [mailboxKey, now, expiresAt, sourceHash],
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
 *
 * **"Most recent" is `issue_seq`, never `issued_at`** (SONNY-353, migration 0017). This ordered by
 * `issued_at DESC` with no tie-break, and `issued_at` is not unique — so for two codes sharing an
 * instant there was no defined newest and Postgres could return either, unstably across plans and
 * versions. It decides which code a verify redeems, so the failure is silent in both directions:
 * the wrong code verifies and the right one does not, and nothing records that two were candidates.
 * `issue_seq` is an identity column, and per mailbox it is exactly issuance order because
 * `issueCode` below holds an advisory lock on the mailbox across its invalidate-and-insert.
 *
 * **`issued_at DESC` is the second key and it is not belt-and-braces** (PR #171 cycle 2, F1). Every
 * row written before 0017 carries the sentinel `issue_seq = 0`, so `issue_seq` alone leaves that
 * whole population tied — and measured, the query then returns the **oldest** of them. Those rows
 * mostly have distinct `issued_at` and were ordered correctly before 0017, so ordering on the
 * sequence alone would have made this query *worse* for exactly the population the migration exists
 * to fix. The second key costs nothing for post-migration rows, whose `issue_seq` is distinct and
 * decides before it is ever consulted — the clock-rewind case included — and recovers the old
 * answer for the inherited ones.
 */
export async function consumeLatest(
  client: pg.Client,
  mailboxKey: string,
  now: Date = new Date(),
): Promise<boolean> {
  const result = await client.query(
    `UPDATE sonny.sign_in_code_issue
        SET consumed_at = $2
      WHERE id = (
        SELECT id FROM sonny.sign_in_code_issue
         WHERE mailbox_key = $1 AND consumed_at IS NULL AND expires_at > $2
         ORDER BY issue_seq DESC, issued_at DESC LIMIT 1
        FOR UPDATE SKIP LOCKED
      )`,
    [mailboxKey, now],
  );
  return (result.rowCount ?? 0) > 0;
}

/**
 * How long after issuance the distinct failure codes stay disclosable.
 *
 * **The signal has to decay, and this is where it decays to nothing** (PR #87 fifth round, F1). The
 * first version had no time bound at all: an address that completed a sign-in once still answered
 * `auth.code_used` **400 simulated days later**, so the fact of having an account was permanent and
 * free to read.
 *
 * One code lifetime *past expiry*, rather than a number chosen for feeling about right. It has to
 * exceed `CODE_LIFETIME_SECONDS` or `auth.code_expired` could never be returned at all — the code is
 * not expired until then. One more lifetime after that covers the real case it exists for: a user
 * who watched their code run out and typed it anyway. Past that, "ask for a new code" is the answer
 * to every one of the three, so the distinction has stopped being worth anything to the person
 * entitled to it while still being worth something to a stranger.
 */
export const FAILURE_DISCLOSURE_SECONDS = CODE_LIFETIME_SECONDS * 2;

/**
 * Which of the three failures this was — **disclosed only to a caller who can be seen to be in the
 * flow, and otherwise reduced to `auth.code_invalid`.**
 *
 * Called only after Supabase has already rejected the code, so the question is never "is this
 * right?" — it is "why was it wrong?", and the ordering below is the answer's precedence.
 *
 * **Used beats expired beats invalid**, deliberately. A code that was used and has since also
 * expired is `auth.code_used`, because that is the fact the user needs: asking for a new one is the
 * fix either way, but "you already used that" and "that ran out" are different sentences and only
 * one of them is true about what they did.
 *
 * ---
 *
 * **The three distinct codes ARE an account-existence oracle, and that had to be resolved rather
 * than traded away** (PR #87 fifth round, F1). Reproduced: one unauthenticated request per address
 * carrying a code known to be wrong, never calling `email/start`, returned `auth.code_used` for a
 * mailbox whose owner had signed in — something the attacker did not cause and could not otherwise
 * observe — `auth.code_expired` for one that had asked and never used, and `auth.code_invalid` for
 * addresses with nothing. That is a working enumeration primitive, and it sat on the one route four
 * review rounds never examined, because every round established the no-oracle property on
 * `email/start` and stated it for the system.
 *
 * **The resolution is not to collapse the codes.** The contract requires three because SONNY-128 has
 * to say three different things, and the person entitled to hear them is the one who just asked for
 * a code at that address and is typing it. That person is distinguishable from a stranger, and the
 * table already stores what distinguishes them:
 *
 * 1. **`source_hash` must match the caller's.** It is written at issuance and it is a salted hash of
 *    the requesting source, so a caller who did not originate the code cannot match it and is told
 *    `auth.code_invalid` — which is true of what they hold. An attacker who first calls `email/start`
 *    to get a matching row learns nothing either: their own request replaces the row, and a live
 *    unconsumed issuance classifies `auth.code_invalid` regardless of who the mailbox belongs to.
 * 2. **The issuance must be recent**, per `FAILURE_DISCLOSURE_SECONDS` above.
 *
 * **Both, not either**, and the second exists because the first is weaker than its name suggests.
 * `sourceHash` is a salted hash of `request.ip`. It is not forgeable over the wire — never
 * transmitted, and the salt has no default — but it says *where a request came from*, not *who sent
 * it*, and that gap has two sizes:
 *
 * - **The configured case, which is the one worth reading twice.** Even with `TRUSTED_PROXIES` set
 *   correctly, everyone behind one public address shares a source hash. So this distinguishes "the
 *   person who asked for this code" from "somebody at a different egress" — and **not** from a
 *   co-tenant on the same NAT. Measured (PR #87 sixth round): with `trustProxy: ['10.0.0.1']`, a
 *   co-tenant on the victim's public address gets `auth.code_used` where a caller elsewhere gets
 *   `auth.code_invalid`. A household or an office is the small version; a mobile carrier's CGNAT
 *   egress or a shared VPN exit is the large one. What such a caller learns is bounded — whether a
 *   *known* address consumed its code, inside `FAILURE_DISCLOSURE_SECONDS` of an issuance — and it
 *   is narrower than the oracle this gate closed, and it is real.
 * - **The misconfigured case**: with `TRUSTED_PROXIES` unset behind a load balancer every request
 *   reports the balancer's address, so every source hash collapses to one value and the match is
 *   vacuous for the whole deployment. Same misconfiguration the per-source rate limit degrades
 *   under, documented in `config.ts`.
 *
 * The recency bound applies in both, which is why there are two conditions rather than one.
 *
 * **The unconditional fix is a flow token** — `email/start` returning an opaque value that
 * `email/verify` echoes back, tying disclosure to *this exchange* rather than to a network location.
 * That is a change to two request/response shapes and lands on SONNY-128; it is not built, and it is
 * the lever if the residual above is ever judged too wide.
 *
 * **What this narrows, stated because it is a contract change and not a silent one.** SONNY-127's
 * acceptance criterion says "an expired code, a reused code, and a wrong code each fail with the
 * contract's distinct errors" without qualification. For the caller the criterion was written about
 * — the one completing a sign-in — it still holds exactly. For a caller who cannot be seen to have
 * asked for the code, it does not, and that caller is the attacker. Recorded in
 * `docs/sonny-backend-api-contract.md` §3.6 and in the changelog, the way the rule-2 supersession
 * was.
 */
interface Issuance {
  readonly consumed_at: Date | null;
  readonly expires_at: Date;
  readonly issued_at: Date;
  readonly source_hash: string;
}

/**
 * The mailbox's most recent issuance, whatever state it is in — consumed and expired rows included,
 * because `classifyFailure` exists to tell those apart.
 *
 * **Ordered by `issue_seq`, never by `issued_at`** (SONNY-353, migration 0017), the same change and
 * the same reason as `consumeLatest` above. This one decides which of the three distinct failures a
 * caller is disclosed, and it reads `source_hash` — so under the old ordering two codes sharing an
 * instant could hand the disclosure gate the *other* issuance's source hash, and a caller who did
 * originate the live code could be told `auth.code_invalid` while the row that answered was one
 * they had nothing to do with.
 *
 * **Same two keys as `consumeLatest`, for the reason recorded there**, and it matters more here:
 * this is the query that reads `source_hash`, so the pre-migration population reading as one tie
 * would have handed the disclosure gate the oldest row's hash rather than the newest's.
 */
async function latestIssuance(client: pg.Client, mailboxKey: string): Promise<Issuance | undefined> {
  const latest = await client.query<Issuance>(
    `SELECT consumed_at, expires_at, issued_at, source_hash FROM sonny.sign_in_code_issue
      WHERE mailbox_key = $1 ORDER BY issue_seq DESC, issued_at DESC LIMIT 1`,
    [mailboxKey],
  );
  return latest.rows[0];
}

/**
 * Did this caller ask for the code that is currently outstanding at this mailbox?
 *
 * **The single question everything about a mailbox is disclosed on**, extracted so that the two
 * places that ask it cannot drift apart: `classifyFailure` below, and the per-address rate-limit
 * refusal in `routes/auth.ts`. Two conditions, and the second exists because the first has a
 * deployment-shaped hole — see `classifyFailure`'s note, which is the long form of this.
 *
 * **What it is not.** `sourceHash` is a salted hash of `request.ip`. It is not forgeable over the
 * wire — it is never transmitted, and the salt has no default — but it is **identical for everyone
 * behind one public address**, so this distinguishes "somebody at the caller's egress asked for this
 * code" from "somebody elsewhere did". That is a weaker statement than the function's name suggests
 * and it is the honest one.
 */
export async function callerOriginatedLatestCode(
  client: pg.Client,
  mailboxKey: string,
  now: Date,
  callerSourceHash?: string,
): Promise<boolean> {
  const row = await latestIssuance(client, mailboxKey);
  if (!row) return false;
  // `callerSourceHash` is optional so that a caller with no source to offer gets the safe answer
  // rather than a type error, and `undefined === row.source_hash` is never true.
  if (callerSourceHash === undefined || callerSourceHash !== row.source_hash) return false;
  return now.getTime() - row.issued_at.getTime() < FAILURE_DISCLOSURE_SECONDS * 1000;
}

export async function classifyFailure(
  client: pg.Client,
  mailboxKey: string,
  now: Date = new Date(),
  callerSourceHash?: string,
): Promise<VerifyFailure> {
  const row = await latestIssuance(client, mailboxKey);
  // Nothing was ever issued to this address. Someone is guessing at an address, not at a code.
  if (!row) return "auth.code_invalid";

  // **The disclosure gate.** Everything past here says something about the mailbox rather than about
  // the code, so it is said only to a caller entitled to hear it.
  const originated = callerSourceHash !== undefined && callerSourceHash === row.source_hash;
  const recent = now.getTime() - row.issued_at.getTime() < FAILURE_DISCLOSURE_SECONDS * 1000;
  if (!originated || !recent) return "auth.code_invalid";

  if (row.consumed_at !== null) return "auth.code_used";
  if (row.expires_at.getTime() <= now.getTime()) return "auth.code_expired";
  // Live, unconsumed issuance, and the provider still refused it: the digits were wrong.
  return "auth.code_invalid";
}

/**
 * Invalidate every live issuance for a mailbox.
 *
 * Called when a new code is issued, so that **at most one code can be redeemed** — the founder's own
 * manual-test item ("request a second code before using the first, and confirm which one works").
 *
 * **The precise claim is "at most one can be REDEEMED", not "only the newest works"** (PR #87 fifth
 * round, F7). Three places on this branch said the stronger thing and it is not true for plus-tag
 * spellings: the send at `routes/auth.ts` passes the *identity* address, so `victim@x`, `victim+1@x`
 * and `victim+2@x` are three distinct addresses at Supabase, which keys an OTP per literal address —
 * three provider-side codes reach one inbox and the provider will still accept any of them. What
 * this function controls is our own record, and `consumeLatest` reads a single folded `mailbox_key`,
 * so the second genuinely-valid code comes back `auth.code_used`. The user-visible effect is the
 * same; the sentence describing it was wider than the mechanism.
 *
 * Not reproducible against this suite, and the reason is worth knowing before someone tries: the
 * test fake's `verifyEmailCode` returns the same session for any input, so no test here can
 * distinguish per-address OTPs at all. Traced rather than measured, and stated as traced.
 */
export async function invalidateLive(
  client: pg.Client,
  mailboxKey: string,
  now: Date = new Date(),
): Promise<number> {
  const result = await client.query(
    `UPDATE sonny.sign_in_code_issue SET consumed_at = $2
      WHERE mailbox_key = $1 AND consumed_at IS NULL AND expires_at > $2`,
    [mailboxKey, now],
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
 * the single-live-code guarantee — which the founder's own manual-test item checks — quietly stopped
 * holding even in our own record.
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
  mailboxKey: string,
  sourceHash: string,
  now: Date = new Date(),
): Promise<{ id: string; expiresAt: Date; invalidated: number }> {
  await client.query("BEGIN");
  try {
    await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`sonny.code:${mailboxKey}`]);
    const invalidated = await invalidateLive(client, mailboxKey, now);
    const issued = await recordIssue(client, mailboxKey, sourceHash, now);
    await client.query("COMMIT");
    return { ...issued, invalidated };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}
