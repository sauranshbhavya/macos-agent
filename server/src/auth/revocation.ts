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
 * 2. **Write down what is still owed.** `sonny.identity_provider_user.provider_session_revoked_at`
 *    is NULL until a provider call actually returns, so the outstanding work is a query rather than
 *    a lost stack frame. That is what gives a post-closure transient failure a path to eventual completion: the
 *    deletion route drains **its own account** after the close — not a backlog, which this line
 *    used to claim (PR #87 fifth round, F8) — and `npm run revocations` reports what is left from
 *    outside, needing no caller who can still authenticate.
 *
 * **What this deliberately does not do is retry in a loop inside the request.** A provider that is
 * down stays down for longer than a request should wait, and a caller blocked on it learns nothing
 * they can act on. The request records the debt and returns; something else pays it.
 */

/**
 * **What "owed" means, in one place, because four queries have to agree about it.**
 *
 * A provider-side user id is owed a revocation when nothing has recorded one for it AND either:
 *
 * - the account holding the identity that named it is **closed** — the original case (0006), the
 *   user asked to be gone and their Supabase sessions should go with them; or
 * - the identity has since named a **different** id, so this one is **superseded** — SONNY-230. The
 *   superseded provider-side user may still hold live sessions, and before 0014 nothing anywhere
 *   said so: `resolve()`'s `COALESCE($5, supabase_user_id)` overwrote the column that named it, and
 *   `npm run revocations` was correct to report nothing while being wrong about the world.
 *
 * **Both disjuncts rest on `provider_session_revoked_at` meaning "no revocation is outstanding for
 * this id", never "this id has been revoked at least once"** (PR #164 review, F1). Under the second
 * reading one stamp makes an id un-owed forever, and every close after it revokes nothing.
 *
 * **What keeps the first reading true is that each of the two disjuncts clears the stamp when it
 * becomes true** (SONNY-358, migration 0015). That is the whole mechanism, and it is deliberately
 * the same two conditions rather than a third thing to keep in step: an account closing clears it
 * (`identity_close_owes_a_revocation`), an id being superseded clears it, and 0014's earlier rule —
 * the identity observing the id again — clears it as well. 0014 had only that last one, which is
 * safe only while a revoked user can come back no way but signing in, and three routes falsify
 * that: refreshing, not coming back at all, and coming back as a different provider-side user.
 *
 * **And a stamp implies only that the provider was ASKED.** It cannot imply the sessions are gone,
 * because `ProviderRejected` is recorded as done and any 4xx but 429 is `ProviderRejected` — so a
 * mechanism answering 401 or 403 with every session alive writes the same stamp a real revocation
 * writes. Nothing in this file may rest on the stronger reading.
 *
 * **What 0015 buys against a wrong stamp is narrower than "not for ever", and the narrower statement
 * is the honest one** (PR #167 review, F5). A wrong stamp is corrected only where a NEW obligation
 * arrives — a reopen and re-close, or a supersession. For a user who closes their account and never
 * comes back, no transition fires again, this function reads 0 and the hard delete goes through,
 * exactly as before. That case is closed by narrowing the classifier, which is SONNY-313's.
 *
 * **The second disjunct does not require a closed account, and that is the point.** A supersession
 * on a *live* account is exactly the state SONNY-196 is about — Supabase re-keyed the subject
 * underneath us — and waiting for a close before revoking would mean never revoking it.
 *
 * **Exported, and that is the whole of what makes the sentence below true** (PR #164 review, F4).
 * **The headline above said "three queries" for a further round while this paragraph said four**
 * (PR #164 cycle 2, C-F3) — a docstring whose own two halves disagreed about the number the fix was
 * about, which is the same shape as the claim it was written to correct.
 * This docstring used to say the fragment was shared by "three queries … because 0009 exists
 * entirely because the delete guard and the drain had drifted apart on one clause" — while the one
 * query site outside this file that *could* have shared it, `owedByAccount` in `../revocations.ts`,
 * had a hand-written byte-identical copy, because the constant was a `const` with no `export` and
 * could not be imported. Nothing was wrong at runtime; what was wrong was a comment asserting a
 * structural guarantee the code did not provide, which is exactly the state 0009 was written about.
 *
 * Five query sites share it now — `grep -cE '^[^*]*[$][{]OWED_PREDICATE[}]' src/auth/revocation.ts
 * src/revocations.ts` → 4 and 1 at `e28d4fa`. **Two things about that command, both of which cost a
 * wrong number first.** A plain `grep -c '${OWED_PREDICATE}'` answers a clean zero on both files:
 * BRE reads `$` as an end-of-line anchor, so the pattern can never match, which is the false-zero
 * shape `CLAUDE.md` names three times. And `grep -Fc`, the obvious repair, answers **5** here — it
 * matches this sentence, because the citation for a count is itself an occurrence of what is being
 * counted. That is `CLAUDE.md`'s own warning about a parenthesis written while writing a
 * parenthesis, and it was live in this docstring for one commit. `^[^*]*` requires the match to
 * reach the start of the line with no `*` in between, which excludes a doc-comment line and no
 * query. The sites: the drain's claim, the **snapshot beside it** that records which rows that call is about to
 * discharge (SONNY-365 — it was four before this one), the drain's mark-done, `owedRevocationCount`
 * here, and `owedByAccount` there. **The sixth copy is the delete guard's, inside migration 0014,
 * and it is unavoidable** — a trigger body cannot import TypeScript. It is the reason `0009` is
 * cited above rather than merely remembered, and it is the copy to change first when this changes.
 *
 * The fragment carries no parameters and no caller input; it is a constant, and it names the
 * aliases `i` (`sonny.identity`) and `pu` (`sonny.identity_provider_user`), so every query
 * interpolating it must use those.
 */
export const OWED_PREDICATE = "AND (i.account_closed OR pu.superseded_at IS NOT NULL)";

export interface RevocationOutcome {
  /**
   * Provider-side users this drain asked the provider about and got a returning answer for.
   *
   * **Counted per provider-side user, not per identity** — which is what it always meant, since one
   * `signOutAllForUser` takes every session of one user and the stamp below fans out to every row
   * naming it. Before 0014 the unit of the count and the unit of the table disagreed, which is the
   * mismatch SONNY-230 fell through.
   *
   * **It is not a count of rows stamped, and the difference is not new** (SONNY-365). The mark-done
   * can decline to stamp what the call covered — because the row stopped being owed while the call
   * was in flight, which `supersession.db.test.ts` has pinned since PR #164 at `revoked === 2`
   * against one stamped row, or because a fresh obligation arrived, which is this ticket's. Either
   * way the id stays owed and the next iteration claims it again. This said "whose sessions are now
   * recorded as revoked by this call", which the older of those two cases already falsified.
   * **`owedRevocationCount` is the number that says what is still outstanding**; this one says how
   * much work the drain did.
   */
  readonly revoked: number;
  /** Attempted and still owed. Their rows keep `provider_session_revoked_at` NULL. */
  readonly failed: number;
  /** One line per failure, provider-side user id and the error's name — never the error object. */
  readonly failures: readonly { readonly supabaseUserId: string; readonly reason: string }[];
}

/**
 * One row the drain is about to discharge, with the episode it was in when the drain claimed.
 *
 * A claim takes **one** row and a discharge covers **every** owed row naming that provider-side
 * user, so the set is read at claim time rather than at mark-done time — see `drainOwedRevocations`.
 * `revocation_episode` is a `bigint` and comes back as a string, which is what `pg` does with `int8`
 * and is left alone: it is only ever handed straight back to Postgres as `bigint[]`.
 */
interface ClaimedRow {
  readonly supabase_user_id: string;
  readonly row_id: string;
  readonly revocation_episode: string;
}

/**
 * Attempt every outstanding revocation for one account, or — with no account id — for every account
 * that still has one owed. **"Owed" is `OWED_PREDICATE` above and includes a superseded id on a
 * live account**, so this is no longer a walk over closed accounts alone.
 *
 * **`ProviderRejected` counts as done, and nothing else does.** The provider saying "no such user"
 * or "already gone" is the state being asked for; a timeout, a 500 or a network error is not, and
 * marking those done would be recording an event that did not happen in the one table that exists to
 * say whether it did.
 *
 * Rows are claimed one at a time by **taking a lease** — one atomic `UPDATE … RETURNING` that writes
 * `revocation_claimed_at` and returns the row it wrote — so two drains running at once (the route
 * and the CLI, or two instances) divide the work rather than duplicating it or deadlocking over it.
 * **That claim used to be a row lock released at COMMIT, before the provider call**, so it divided
 * the work only when two drains collided in the same instant (PR #87 fifth round, F3).
 * `signOutAllForUser` is idempotent at the provider, but a drain that depends on that is a drain
 * resting on someone else's implementation detail.
 *
 * **And past the lease window it rests on it again, which the sentence above does not say** (PR #87
 * sixth round, a record correction rather than a defect). A lease bounds the duplicate-call window;
 * it does not remove it. Measured: a drain still inside `signOutAllForUser` with its lease aged past
 * `sonny.revocation_lease_seconds()` is re-claimed by a second drain, and the provider is called
 * twice for that user. That is inherent to a lease and it is the right trade — the alternative is
 * holding a transaction and a row lock across a network call of unbounded duration — but the honest
 * statement of what F3 bought is **"any provider call longer than 300 seconds"** rather than "the
 * entire provider call", and there is no timeout on `signOutAllForUser` to bound it further. A real
 * adapter should set one; whichever ticket lands it owns that.
 *
 * **A returning call discharges the obligation it CLAIMED and no other** (SONNY-365, migration
 * 0016). The claim and the mark-done fan out to different things — one row is claimed, every owed
 * row naming that provider-side user is discharged — so a lease alone could never carry the
 * identity of what was being worked on. `revocation_episode` does: each row counts the obligations
 * it has had, every event that creates one increments it, the claim reads the counter for the whole
 * set it is about to discharge, and the mark-done stamps only rows still carrying what it read. A
 * mismatch means an obligation arrived that this provider call cannot have covered, and the row
 * stays owed instead of being silently written off.
 *
 * **The lease does not overlap with that and cannot substitute for it.** PR #167 measured that a
 * reopen-and-re-close is fast enough that the first drain's lease is still live when the new
 * obligation lands — so the window this fix closes is *inside* the lease window rather than past
 * it, and a longer lease would have made it wider rather than narrower. What the obligation-creating
 * triggers do to the lease is clear it, which is right for a different reason: a lease says
 * "somebody is calling the provider about this right now", and the fresh obligation nobody has
 * called about yet must be claimable immediately.
 *
 * **A refused stamp costs one extra provider call and is not reported as a distinct outcome.** The
 * row keeps `provider_session_revoked_at` NULL and its claim was cleared by the trigger, so the
 * next pass of this loop claims it and calls the provider again for the new obligation — the same
 * within-one-run recovery `supersession.db.test.ts` already relies on, bounded by `limit`.
 * `RevocationOutcome` grows no field for it: `revoked` counts provider calls and always did (see
 * its own note), and what is still outstanding is `owedRevocationCount`, which is the number an
 * operator acts on and the number `npm run revocations` prints.
 */
export async function drainOwedRevocations(
  client: pg.Client,
  provider: AuthProvider,
  options: { accountId?: string; limit?: number; now?: Date; signal?: AbortSignal } = {},
): Promise<RevocationOutcome> {
  const limit = options.limit ?? 100;
  const now = options.now ?? new Date();
  let revoked = 0;
  const failures: { supabaseUserId: string; reason: string }[] = [];

  for (let attempted = 0; attempted < limit; attempted += 1) {
    // **One atomic UPDATE takes the lease and returns what it took** (PR #87 fifth round, F3).
    //
    // This was `BEGIN; SELECT … FOR UPDATE SKIP LOCKED; COMMIT` followed by the provider call — and
    // the COMMIT released the row lock *before* the call, so the lock covered one SELECT rather than
    // the work it was claiming. The unguarded window was the entire provider call. Reproduced with a
    // provider taking 300ms: two drains started 100ms apart called `signOutAllForUser` twice for the
    // same user. Two started simultaneously divided correctly, which is why an ad-hoc test would
    // have found nothing.
    //
    // The lease is written by the statement that selects the row, so there is no window between
    // choosing and claiming. No transaction is held across the network call, which is what the old
    // comment here was right to avoid, and a drain that dies mid-call leaves a lease that expires
    // rather than a claim nobody recorded.
    //
    // **And the same statement reads the episodes of everything it is about to discharge**
    // (SONNY-365). The claim takes one row; the mark-done covers every owed row naming that
    // provider-side user, because one `signOutAllForUser` ends every session of that user. Those
    // two units are different, and that difference is where the episode identity used to be lost —
    // the sibling rows were never claimed, so nothing about them recorded which obligation this
    // call was answering.
    //
    // Reading them here rather than at mark-done time is the whole point: it must be the set and
    // the episodes as they stood **before** the provider call, so that an obligation created during
    // the call cannot be mistaken for one this call covered. Two statements would leave a window
    // between choosing the set and recording its episodes, which is a smaller copy of the defect.
    // One statement has one snapshot. The `claimed` CTE's own write is not visible to the SELECT
    // beside it, which costs nothing here: a claim changes no episode and clears no stamp, so the
    // claimed row satisfies the SELECT's predicate either way and is always in the result.
    const claim = await client.query<ClaimedRow>(
      `WITH claimed AS (
         UPDATE sonny.identity_provider_user SET revocation_claimed_at = $3::timestamptz
          WHERE id = (
            SELECT pu.id
              FROM sonny.identity_provider_user pu
              JOIN sonny.identity i ON i.id = pu.identity_id
             WHERE pu.provider_session_revoked_at IS NULL
               ${OWED_PREDICATE}
               AND ($1::uuid IS NULL OR i.account_id = $1::uuid)
               -- Both sides cast to text on purpose: supabase_user_id is a uuid column, and binding
               -- this list as uuid[] turns any malformed element into a 22P02 raised by the database
               -- rather than a value this function can see and refuse.
               AND pu.supabase_user_id::text <> ALL($2::text[])
               AND (pu.revocation_claimed_at IS NULL
                    OR pu.revocation_claimed_at
                         < $3::timestamptz - make_interval(secs => sonny.revocation_lease_seconds()))
             ORDER BY pu.id
             LIMIT 1
             FOR UPDATE OF pu SKIP LOCKED
          )
          RETURNING supabase_user_id
       )
       SELECT c.supabase_user_id,
              pu.id AS row_id,
              pu.revocation_episode::text AS revocation_episode
         FROM claimed c
         JOIN sonny.identity_provider_user pu ON pu.supabase_user_id = c.supabase_user_id
         JOIN sonny.identity i ON i.id = pu.identity_id
        WHERE pu.provider_session_revoked_at IS NULL
          ${OWED_PREDICATE}`,
      [options.accountId ?? null, failures.map((f) => f.supabaseUserId), now],
    );
    const claimed = claim.rows;
    const owed = claimed[0];
    if (!owed) break;

    try {
      // **The caller's deadline, when it has one** (SONNY-425). This loop makes one provider call
      // per identity, so the adapter's own per-request bound is not a bound on the drain — N
      // identities buy N of them. `DELETE /v1/account` runs this inside §12's deadline and threads
      // the signal here so the ceiling is the route's rather than the adapter's times N. Nothing
      // else passes one, and a drain without one behaves exactly as it did.
      await provider.signOutAllForUser(owed.supabase_user_id, options.signal);
    } catch (error) {
      if (!(error instanceof ProviderRejected)) {
        // Transient, or unknown, which is treated as transient. `provider_session_revoked_at` stays
        // NULL, so the row is still owed and the next drain finds it.
        //
        // **The lease is released, and that distinction matters.** A lease says "somebody is calling
        // the provider about this right now"; a failure that has already returned is not that. Left
        // set, an operator who fixed the provider and re-ran the drain would be told there was
        // nothing to do for the next five minutes, which is the same class of wrong answer F2 was
        // about. Back-off is a different concern and this ticket does not need one.
        //
        // **It releases every row naming this id, including ones another drain holds a live lease
        // on, and 0014 made that set larger** (PR #164 review, F8). The statement is `main`'s and is
        // unchanged; what changed underneath it is the table, which now holds one row per
        // `(identity, id)` **ever observed** rather than one per identity currently naming it. The
        // harm is bounded to a duplicate provider call, which this function's own docstring already
        // concedes for any call outliving its lease, and narrowing it would mean carrying the
        // claimed row's identity through the failure path to buy nothing the lease does not already
        // give. Written down rather than changed.
        await client.query(
          "UPDATE sonny.identity_provider_user SET revocation_claimed_at = NULL WHERE supabase_user_id = $1 AND provider_session_revoked_at IS NULL",
          [owed.supabase_user_id],
        );
        // This run still excludes it, so one dead user cannot spin the loop.
        failures.push({
          supabaseUserId: owed.supabase_user_id,
          reason: (error as Error)?.name || "Error",
        });
        continue;
      }
      // The provider has no such session. That is the state we wanted, so it is recorded as done.
    }

    // **Every row the claim snapshotted**, not just the one that was claimed: one
    // `signOutAllForUser` revokes all of that user's sessions, so marking one row would leave the
    // others owed forever and every drain would call the provider again for nothing.
    //
    // **And only in the episode the claim saw them in** (SONNY-365, migration 0016). This used to
    // be `WHERE pu.supabase_user_id = $1`, which asks whether a row is owed **now** and never
    // whether this provider call covers the obligation that exists **now**. Those come apart
    // whenever an obligation is created between the call and this statement: the account is
    // reopened, the user refreshes, the account is closed again, and 0015 correctly clears the
    // stamp for the new obligation — which this statement then wrote straight back, discharging it
    // with a call that predates it and leaving the reopen's sessions live on an account owed
    // nothing. `revocation_episode` is incremented by each of the three events that start an
    // episode, so a row whose obligation has moved on simply does not match and stays owed. The
    // next iteration claims it again and calls the provider again, which is the point: a new
    // obligation gets its own revocation rather than inheriting an older one's discharge.
    //
    // **Owed rows only, and the restriction is load-bearing.** A row naming this same user id that
    // is *current* on a *live* account is not owed anything; stamping it would mean that when that
    // account is later closed, the drain would consider its debt already paid — for sessions minted
    // after this call returned. Same fragment as the claim, so the two cannot drift. It is kept
    // beside the episode check rather than replaced by it: they refuse different things — this one
    // a row that stopped being owed, the episode one a row that is owed for a newer reason — and
    // `supersession.db.test.ts`'s sign-in-during-the-call test rests on this one.
    //
    // **`$1` is the `now` captured before the loop, and that is informational.** Nothing reads this
    // column's value; every predicate in this file reads only whether it is NULL. Which obligation
    // a stamp discharged is `revocation_episode`, not the timestamp.
    await client.query(
      `UPDATE sonny.identity_provider_user pu
          SET provider_session_revoked_at = $1
         FROM unnest($2::uuid[], $3::bigint[]) AS claimed(row_id, episode)
        WHERE pu.id = claimed.row_id
          AND pu.revocation_episode = claimed.episode
          AND pu.provider_session_revoked_at IS NULL
          AND EXISTS (SELECT 1 FROM sonny.identity i
                       WHERE i.id = pu.identity_id ${OWED_PREDICATE})`,
      [now, claimed.map((row) => row.row_id), claimed.map((row) => row.revocation_episode)],
    );
    revoked += 1;
  }

  return { revoked, failed: failures.length, failures };
}

/**
 * How many revocations are still owed, for the health of a deployment rather than for a request.
 *
 * **`DISTINCT pu.supabase_user_id`, because that is the unit of the work** (PR #164 review, F3).
 * One `signOutAllForUser` clears every row naming one provider-side user, so a raw row count told an
 * operator an account owed 2 while one drain call cleared it and `RevocationOutcome.revoked`
 * reported 1 — three figures sharing a noun and not a unit. Two identities naming one Supabase user
 * is not a hypothetical shape; `attribution.ts`'s header says it is what the whole account/identity
 * separation exists to allow.
 */
export async function owedRevocationCount(client: pg.Client): Promise<number> {
  const { rows } = await client.query<{ n: number }>(
    `SELECT count(DISTINCT pu.supabase_user_id)::int AS n
       FROM sonny.identity_provider_user pu
       JOIN sonny.identity i ON i.id = pu.identity_id
      WHERE pu.provider_session_revoked_at IS NULL
        ${OWED_PREDICATE}`,
  );
  return rows[0]?.n ?? 0;
}

/**
 * How many of those are owed **because the id was superseded rather than because an account closed**
 * — SONNY-196's divergence, counted.
 *
 * This is the number that was unrepresentable before: a live account whose provider-side user was
 * re-keyed underneath it. It is reported separately by `npm run revocations` because it means
 * something different to an operator — a closed account's debt is expected and drains away, while a
 * growing supersession count on live accounts says Supabase is re-keying users under this
 * deployment, which is either the unconfirmed-identity pruning SONNY-196 is about or something
 * nobody has explained yet.
 */
export async function supersededProviderUserCount(client: pg.Client): Promise<number> {
  const { rows } = await client.query<{ n: number }>(
    `SELECT count(DISTINCT supabase_user_id)::int AS n
       FROM sonny.identity_provider_user
      WHERE superseded_at IS NOT NULL AND provider_session_revoked_at IS NULL`,
  );
  return rows[0]?.n ?? 0;
}
