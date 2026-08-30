import pg from "pg";
import { describe, expect } from "vitest";
import { accountForSupabaseUser } from "../src/auth/attribution.js";
import { normalizeEmail, resolve } from "../src/auth/identity.js";
import {
  ProviderRejected,
  ProviderUnavailable,
  type AuthProvider,
  type VerifiedSession,
} from "../src/auth/provider.js";
import {
  drainOwedRevocations,
  owedRevocationCount,
  supersededProviderUserCount,
} from "../src/auth/revocation.js";
import { owedByAccount } from "../src/revocations.js";
import { rebuildSchema } from "./support/schema.js";
import { afterAllUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";

/**
 * The identity lifecycle's provider-side half: what happens to a `supabase_user_id` that stops being
 * the one an identity names (SONNY-230), and what that supersession tells us about Supabase having
 * removed the identity underneath us (SONNY-196).
 *
 * **Against a real Postgres, because the mechanism is a trigger.** The record of a supersession is
 * made by `sonny.record_provider_side_user()` firing on an `UPDATE OF supabase_user_id`, deliberately
 * rather than by `resolve()` remembering to write a second statement — so a fake would prove nothing
 * about the property, which is that *any* writer of that column is recorded, not that one function
 * calls one query.
 *
 * **What every test here is protecting, in one sentence:** a provider-side user id this gateway has
 * stopped naming must not keep working, and must not stop being owed a revocation.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

/** Two provider-side user ids for one subject. That is the whole scenario. */
const FIRST = "aaaaaaaa-0000-4000-8000-000000000001";
const SECOND = "aaaaaaaa-0000-4000-8000-000000000002";
const THIRD = "aaaaaaaa-0000-4000-8000-000000000003";

/** Records what it was asked to revoke; fails for whatever the test names. */
class RecordingProvider implements AuthProvider {
  revokedUsers: string[] = [];
  failFor = new Set<string>();
  rejectFor = new Set<string>();
  /**
   * Runs **inside** `signOutAllForUser`, before the call is recorded.
   *
   * The only way to land another connection's write in the middle of a provider call, which is what
   * the interleaving test needs: `drainOwedRevocations` deliberately holds no transaction across
   * that call, so the window is real rather than simulated.
   */
  beforeRevoke: undefined | (() => Promise<void>);
  async sendEmailCode(_email: string) { return { providerRequestId: undefined }; }
  async verifyEmailCode(_email: string, _code: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async refresh(_token: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async signOut(_accessToken: string) {}
  async signOutAllForUser(id: string) {
    if (this.beforeRevoke) await this.beforeRevoke();
    if (this.failFor.has(id)) throw new ProviderUnavailable("admin API timed out");
    if (this.rejectFor.has(id)) throw new ProviderRejected("no such user");
    this.revokedUsers.push(id);
  }
  async userFromAccessToken(_accessToken: string): Promise<string> {
    throw new ProviderRejected("the gate verifies locally; this seam is not on the request path");
  }
  async deleteUser(_id: string) {}
}

describeDb("a superseded provider-side user is recorded, revocable, and cannot keep working", () => {
  let client: pg.Client;
  /**
   * A second connection, for the one test that needs a sign-in to land *during* a drain's provider
   * call. Everything else runs on `client`; a shared connection could not express the interleaving
   * at all, because the two writes would serialise on one session.
   */
  let other: pg.Client;
  let provider: RecordingProvider;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    other = new pg.Client({ connectionString: url });
    await other.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => { await client.end(); await other.end(); });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.identity, sonny.account RESTART IDENTITY CASCADE");
    provider = new RecordingProvider();
  });

  const assertion = (address: string, supabaseUserId: string) => ({
    provider: "email" as const,
    subject: normalizeEmail(address),
    email: address,
    emailVerified: true,
    supabaseUserId,
  });

  /** Every provider-side user id recorded for one account, with its state. */
  const historyFor = async (accountId: string) => {
    const { rows } = await client.query<{
      supabase_user_id: string;
      superseded: boolean;
      revoked: boolean;
    }>(
      `SELECT pu.supabase_user_id,
              (pu.superseded_at IS NOT NULL) AS superseded,
              (pu.provider_session_revoked_at IS NOT NULL) AS revoked
         FROM sonny.identity_provider_user pu
         JOIN sonny.identity i ON i.id = pu.identity_id
        WHERE i.account_id = $1
        ORDER BY pu.supabase_user_id`,
      [accountId],
    );
    return rows;
  };

  const close = async (accountId: string) =>
    client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [accountId]);

  describe("SONNY-230 — the id that was overwritten", () => {
    itUnderHangBackstop("keeps the first provider-side user id when the second one arrives", async () => {
      // **The defect, from the reviewer's own reproduction.** `resolve()`'s rule 1 refreshes with
      // `supabase_user_id = COALESCE($5, supabase_user_id)`, which overwrites — so before 0014 the
      // first id existed nowhere at all the instant the second one landed.
      const first = await resolve(client, assertion("a@example.com", FIRST));
      const second = await resolve(client, assertion("a@example.com", SECOND));
      expect(second.accountId).toBe(first.accountId);

      expect(await historyFor(first.accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: false },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
      // And the identity itself names the current one, which is what attribution reads.
      const { rows } = await client.query<{ supabase_user_id: string }>(
        "SELECT supabase_user_id FROM sonny.identity WHERE account_id = $1", [first.accountId]);
      expect(rows[0]!.supabase_user_id).toBe(SECOND);
    });

    itUnderHangBackstop("owes a revocation for the superseded id on a LIVE account, without waiting for a close", async () => {
      // **The widening, and the security answer.** A superseded provider-side user may still hold
      // live sessions at Supabase. Before 0014 nothing was owed until the account closed — and the
      // superseded id would not have been in that set either, because it had been overwritten. So
      // the debt could never be reported and never be paid.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));

      const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [accountId]);
      expect(rows[0].deleted_at).toBeNull();

      expect(await owedRevocationCount(client)).toBe(1);
      expect(await supersededProviderUserCount(client)).toBe(1);
      expect(await owedByAccount(client)).toEqual([
        { accountId, providerUsers: 1, superseded: 1 },
      ]);
    });

    itUnderHangBackstop("drains the superseded id, and the drain asks the provider about THAT id", async () => {
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));

      const outcome = await drainOwedRevocations(client, provider);
      expect(outcome).toEqual({ revoked: 1, failed: 0, failures: [] });
      // The id the provider was asked about is the superseded one, not the current one. Asserting
      // the count alone would pass on a drain that revoked the wrong user.
      expect(provider.revokedUsers).toEqual([FIRST]);
      expect(await owedRevocationCount(client)).toBe(0);
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: true },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
    });

    itUnderHangBackstop("revokes BOTH ids when the account is closed — the reviewer's reproduction, inverted", async () => {
      // Verbatim from SONNY-230: "resolve twice for one subject with two different provider user
      // ids, close the account, drain — only the newer id is revoked, and the older one appears in
      // no owed query, because the column that named it is gone."
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      await close(accountId);

      expect(await owedRevocationCount(client)).toBe(2);
      const outcome = await drainOwedRevocations(client, provider);
      expect(outcome.revoked).toBe(2);
      expect([...provider.revokedUsers].sort()).toEqual([FIRST, SECOND]);
      expect(await owedRevocationCount(client)).toBe(0);
    });

    itUnderHangBackstop("keeps every id in a chain of three, not just the last two", async () => {
      // A supersession is not a single-slot memory. Two supersessions in a row have to leave two
      // superseded rows, or the mechanism is a rename of the defect.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      await resolve(client, assertion("a@example.com", THIRD));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: false },
        { supabase_user_id: SECOND, superseded: true, revoked: false },
        { supabase_user_id: THIRD, superseded: false, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(2);
    });
  });

  describe("the id that stops being named must stop working", () => {
    itUnderHangBackstop("does not attribute a superseded provider-side user to the account", async () => {
      // **This is the property both tickets protect**, and it is the one an access token minted for
      // the old provider-side user would exercise: `auth/gate.ts` attributes every protected request
      // through `accountForSupabaseUser`, so an id that resolves to no live identity is a 401.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));

      expect(await accountForSupabaseUser(client, SECOND)).toEqual({ accountId });
      // Both directions, deliberately: a test that only asserted the refusal would pass against an
      // attribution query that refused everything.
      expect(await accountForSupabaseUser(client, FIRST)).toEqual({ ambiguous: false });
    });

    itUnderHangBackstop("still attributes an id that is superseded on one identity and current on another", async () => {
      // One Supabase user can legitimately be named by two identities — that separation is the
      // whole reason `sonny.account` is not `auth.users`. So "superseded" is a fact about one
      // identity's history, never a global ban on the id, and a fix that denylisted the value would
      // sign a live user out of an account they are currently using.
      const shared = await resolve(client, assertion("shared@example.com", FIRST));
      // **Inserted rather than resolved.** `resolve()` cannot put a second identity on an existing
      // account any more: rule 2 flags a verified-email match instead of linking (founder decision,
      // 2026-08-22), so a second `resolve()` would create a second account and this test would be
      // asserting about two accounts while reading as though it had one. `linkExplicitly` is the
      // real path and needs a proven identity id; the state is what matters here, not how it was
      // reached, so the row is written directly — the same thing `auth.db.test.ts` does to build a
      // multi-identity account.
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, supabase_user_id, link_method)
         VALUES ($1,'google','google-sub-1','shared@example.com',true,false,$2,'explicit')`,
        [shared.accountId, FIRST],
      );
      // The email identity moves on; the google one still names FIRST.
      await resolve(client, assertion("shared@example.com", SECOND));

      expect(await accountForSupabaseUser(client, FIRST)).toEqual({ accountId: shared.accountId });
      expect(await accountForSupabaseUser(client, SECOND)).toEqual({ accountId: shared.accountId });
    });
  });

  describe("SONNY-196 — what a supersession says about Supabase", () => {
    itUnderHangBackstop("reports superseded ids separately from a closed account's debt", async () => {
      // The two are owed for different reasons and mean different things to an operator: a closed
      // account's debt is expected and drains away, while a supersession on a live account is
      // Supabase re-keying a subject underneath this deployment — which is what removing an
      // unconfirmed identity looks like from here. Before 0014 the second was unrepresentable.
      const live = await resolve(client, assertion("live@example.com", FIRST));
      await resolve(client, assertion("live@example.com", SECOND));
      const closed = await resolve(client, assertion("closed@example.com", THIRD));
      await close(closed.accountId);

      expect(await owedRevocationCount(client)).toBe(2);
      expect(await supersededProviderUserCount(client)).toBe(1);
      const rows = await owedByAccount(client);
      expect(rows.find((r) => r.accountId === live.accountId))
        .toEqual({ accountId: live.accountId, providerUsers: 1, superseded: 1 });
      expect(rows.find((r) => r.accountId === closed.accountId))
        .toEqual({ accountId: closed.accountId, providerUsers: 1, superseded: 0 });
    });

    itUnderHangBackstop("records nothing new when the same id is presented again", async () => {
      // The ordinary case, and the one that must stay silent: a subject signing in repeatedly with
      // the same Supabase user has not diverged from anything. A trigger that recorded a
      // supersession on every refresh would turn every sign-in into an owed revocation, which is a
      // false alarm indistinguishable from the real one.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", FIRST));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: false, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(0);
      expect(await supersededProviderUserCount(client)).toBe(0);
    });

    itUnderHangBackstop("makes an id current again when the provider hands it back", async () => {
      // Supabase re-keying a subject twice, ending where it started. The returned id is what the
      // subject signs in as now, so it is no longer owed a revocation *for being superseded* — and
      // the one it displaced is.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      await resolve(client, assertion("a@example.com", FIRST));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: false, revoked: false },
        { supabase_user_id: SECOND, superseded: true, revoked: false },
      ]);
      expect(await accountForSupabaseUser(client, FIRST)).toEqual({ accountId });
      expect(await accountForSupabaseUser(client, SECOND)).toEqual({ ambiguous: false });
      expect(await supersededProviderUserCount(client)).toBe(1);
    });

    itUnderHangBackstop("records a supersession written by something that is not resolve()", async () => {
      // **Why the record is a trigger and not two statements in `resolve()`.** The event is the
      // column changing; anything that changes it — a backfill, a support script, a future link
      // path — has to be recorded, or the mechanism is only as good as the next writer's memory.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await client.query(
        "UPDATE sonny.identity SET supabase_user_id = $2 WHERE account_id = $1",
        [accountId, SECOND],
      );
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: false },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
    });

    itUnderHangBackstop("records the first id an identity acquires after having none", async () => {
      // `supabase_user_id` is nullable — 0002 says an identity can exist before its Supabase user
      // does, and until it has one there is nothing to remember. This is the INSERT branch of the
      // trigger, reached with no supersession to consider.
      const { accountId } = await resolve(client, {
        provider: "email", subject: "none@example.com", email: "none@example.com",
        emailVerified: true, supabaseUserId: undefined,
      });
      expect(await historyFor(accountId)).toEqual([]);
      await resolve(client, assertion("none@example.com", FIRST));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: false, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(0);
    });

    itUnderHangBackstop("supersedes an id that is CLEARED rather than replaced", async () => {
      // **This test exists because a mutant survived and the comment explaining the line was
      // wrong.** The trigger's supersession branch reads `OLD.supabase_user_id IS DISTINCT FROM
      // NEW.supabase_user_id`, and both that migration's comment and the test above claimed `<>`
      // would break the *first-id* case — which goes through the INSERT branch and never reaches
      // that line. So replacing `IS DISTINCT FROM` with `<>` changed nothing any test could see,
      // and the battery reported SURVIVED.
      //
      // The case the operator actually buys is a writer that **clears** the column: `'x' <> NULL`
      // is NULL rather than true, so under `<>` the cleared id would stay in the history marked
      // current — attributing nothing, because the identity no longer names it, and owed nothing,
      // because nothing marked it superseded. That is precisely SONNY-230's unrevocable-and-
      // unrecorded state, reached through a different door. `resolve()` cannot produce it (its
      // `COALESCE` never writes a NULL), which is exactly why it needs a test rather than being
      // left to the one caller that happens to be safe.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await client.query(
        "UPDATE sonny.identity SET supabase_user_id = NULL WHERE account_id = $1", [accountId]);
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(1);
      expect(await supersededProviderUserCount(client)).toBe(1);
      // And it cannot sign anyone in, which is the property that makes the record worth having.
      expect(await accountForSupabaseUser(client, FIRST)).toEqual({ ambiguous: false });
    });
  });

  describe("a revocation is spent when the id is observed again (PR #164 review, F1)", () => {
    // **The root cause both tests below reach through different doors.**
    // `provider_session_revoked_at` is read by `OWED_PREDICATE` as "this id has no outstanding
    // revocation", and it was being written as "this id has been revoked at least once". Under the
    // second reading one stamp makes an id un-owed forever, so every close after it revokes
    // nothing. The trigger now clears the stamp whenever the identity observes the id again,
    // because that starts a new episode whose sessions nothing has revoked.

    itUnderHangBackstop("owes a fresh revocation after a revoked id comes back and the account is closed", async () => {
      // Route one, which this branch introduced: the `ON CONFLICT … SET superseded_at = NULL` arm
      // un-supersedes an id and used to leave the revocation stamp behind.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);

      // Supabase hands FIRST back. The user signs in as FIRST and gets NEW sessions — which is why
      // the revocation recorded a moment ago says nothing about the ones they hold now.
      await resolve(client, assertion("a@example.com", FIRST));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: false, revoked: false },
        { supabase_user_id: SECOND, superseded: true, revoked: false },
      ]);

      await close(accountId);
      expect(await owedRevocationCount(client)).toBe(2);
      provider.revokedUsers = [];
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(2);
      // **FIRST is asked about again.** Before the fix it was asked about once, ever, and the
      // account then hard-deleted cleanly with those sessions live.
      expect([...provider.revokedUsers].sort()).toEqual([FIRST, SECOND]);
    });

    itUnderHangBackstop("owes a fresh revocation after a close, a drain, a reopen and a second close", async () => {
      // **Route two, and it needs no supersession at all — it predates this branch** (SONNY-358,
      // authorised by the founder to be fixed here rather than split across two branches, because
      // it is one root cause). The reviewer measured this same sequence against `main` at `def8c3a`
      // and got `owed = 1` after the first close and `owed = 0` after the reopen and the second.
      //
      // Reopening is `UPDATE sonny.account SET deleted_at = NULL`, which 0005's
      // `mark_identities_closed` un-flags the identities for — `linking.db.test.ts` calls it "the
      // only way an account is ever reopened". The user then signs in again, and rule 1's refresh
      // names `supabase_user_id`, which is what lands in the trigger's `ON CONFLICT` arm.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(await owedRevocationCount(client)).toBe(0);

      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);
      await resolve(client, assertion("a@example.com", FIRST));
      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: false }]);

      await close(accountId);
      expect(await owedRevocationCount(client)).toBe(1);
      // And the guard refuses to destroy the record, which it could not have done before: the
      // reviewer's reproduction ended with the account hard-deleting cleanly.
      await expect(client.query("DELETE FROM sonny.account WHERE id = $1", [accountId]))
        .rejects.toThrow(/still owes 1 provider-side revocation/);

      provider.revokedUsers = [];
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
    });

    itUnderHangBackstop("does not un-spend a revocation the identity never observed again", async () => {
      // **What this test does and does not establish, corrected** (PR #164 cycle 2, C-F2). The fix
      // round called it "the direction that must not clear" and said it stopped the fix being
      // "clear it always". **It cannot.** Nothing fires the trigger after the drain stamps here, so
      // the state it asserts is never disturbed — by an over-clearing mutant or by anything else.
      // It is a true assertion about a sequence that does not exercise the clearing at all, and
      // the reviewer's mutant that cleared every row of the identity SURVIVED a 60-test run beside
      // it. The test below it is the one that pins that direction.
      //
      // What this one does establish is still worth having: a superseded id revoked and never
      // observed again stays revoked, so a drain does not re-ask the provider about an episode
      // that ended.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);

      await close(accountId);
      // Only SECOND is owed — FIRST's episode ended and no later one began.
      expect(await owedRevocationCount(client)).toBe(1);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([SECOND]);
    });

    itUnderHangBackstop("does not un-spend a superseded id when an ordinary repeat sign-in names the current one", async () => {
      // **The reviewer's test, taken verbatim in substance** (PR #164 cycle 2, C-F2), and the gap it
      // fills was found by a **surviving mutant** rather than by reading the test above and
      // believing its description. That is the sentence worth keeping: a test whose stated
      // guarantee it cannot deliver reads exactly like one that can, and the only thing that told
      // the two apart was a mutant that lived.
      //
      // The scenario nothing covered: an ordinary repeat sign-in, naming the id the identity
      // **already holds**, after a supersession has been drained. The trigger fires — rule 1's
      // refresh names `supabase_user_id` every time — so an `ON CONFLICT` arm that cleared more
      // than the conflicting row would un-spend the superseded id here. The drain would then call
      // the provider about an episode that ended, every later sign-in would re-owe it, and
      // `npm run revocations` would report a debt that never drains.
      //
      // The shipped arm is scoped to the conflicting row by construction, so this passes as
      // written; the reviewer proved it fails against the over-clearing mutant, and the same mutant
      // is now killed by it in this repository's own battery.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: true },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);

      // The repeat sign-in. Same id the identity already names, so no supersession — but the
      // trigger runs, which is the whole point.
      await resolve(client, assertion("a@example.com", SECOND));
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: true },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(0);

      // And FIRST is not re-asked on a later close: its episode ended and no later one began.
      await close(accountId);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([SECOND]);
    });

    itUnderHangBackstop("leaves a row un-stamped rather than wrongly stamped when a sign-in lands DURING the provider call", async () => {
      // **The reviewer's test, taken as offered** (PR #164 cycle 2, C-F4). It is what turns the
      // ordering argument recorded at the `ON CONFLICT` arm from a trace into a property the suite
      // holds: the fix clears a stamp on re-observation and the drain writes one, so the question
      // "what if those two interleave?" is the obvious objection to the whole design.
      //
      // The window is real rather than simulated. `drainOwedRevocations` deliberately holds no
      // transaction across `signOutAllForUser` — that is the lease's whole reason — so a sign-in on
      // another connection can commit while the drain is inside the provider call.
      //
      // **The answer is the conservative one, and it is the mark-done's `EXISTS (… OWED_PREDICATE)`
      // that makes it so**: the row is re-checked at stamping time, finds the id current on a live
      // account, and is left alone. Not stamped is the safe direction — a wrongly stamped row is a
      // revocation nobody will ever owe again, which is exactly cycle 1's F1.
      //
      // **The assertions follow the reviewer's measured TRACE rather than the assertions in their
      // probe file, and the difference is worth recording.** That file's copy asserts
      // `revoked === 1` and `revokedUsers === [FIRST]`; the same review's trace of the same
      // scenario prints `outcome {"revoked":2} asked: [0001, 0002]`, and its own log for that file
      // reads `1 passed | 1 skipped` — this test was **skipped** in both directions of the C-F2
      // proof, so its assertions were never executed. Transcribed literally it fails, which is how
      // this was found. Two is right and is the better behaviour: the drain re-reads the owed set
      // each iteration, so the id this interleaving newly superseded is picked up in the **same
      // run** rather than waiting for another — which is what the review body praises in prose one
      // line above the number that contradicts it.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      // While the drain is inside `signOutAllForUser(FIRST)`, the provider hands FIRST back and the
      // user signs in on another connection.
      provider.beforeRevoke = async () => { await resolve(other, assertion("a@example.com", FIRST)); };

      const outcome = await drainOwedRevocations(client, provider);
      // Two: FIRST, which was owed when the loop claimed it, and then SECOND, which this
      // interleaving superseded while that call was in flight.
      expect(outcome.revoked).toBe(2);
      expect(provider.revokedUsers).toEqual([FIRST, SECOND]);

      // **FIRST is current again on a live account: not owed, and NOT stamped** — the assertion the
      // whole test exists for. The provider was asked about it, and the mark-done still declined to
      // record a revocation against an episode that had already restarted.
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: false, revoked: false },
        { supabase_user_id: SECOND, superseded: true, revoked: true },
      ]);
      expect(await owedRevocationCount(client)).toBe(0);

      // And a later close owes FIRST afresh, which is the property the whole round is about: the
      // un-stamped row is still owed the moment an owed condition arrives.
      await close(accountId);
      expect(await owedRevocationCount(client)).toBe(1);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([FIRST]);
    });

    itUnderHangBackstop("clears a dead drain's lease when the id comes back", async () => {
      // The review's F8 note, closed by the same two lines: a row superseded, claimed by a drain
      // that then died, un-superseded and superseded again used to be invisible to the claim query
      // for up to `sonny.revocation_lease_seconds()`. A lease belongs to an episode too.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      await client.query(
        "UPDATE sonny.identity_provider_user SET revocation_claimed_at = now() WHERE supabase_user_id = $1",
        [FIRST]);
      // A live lease hides it, which is the mechanism working.
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(0);

      await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      const { rows } = await client.query<{ claimed: boolean }>(
        `SELECT (revocation_claimed_at IS NOT NULL) AS claimed
           FROM sonny.identity_provider_user WHERE supabase_user_id = $1`, [FIRST]);
      expect(rows[0]!.claimed).toBe(false);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(2);
    });
  });

  describe("a close owes its own revocation, however the user did or did not come back (SONNY-358)", () => {
    // **What these tests are about, and why they are not more tests of the block above.**
    //
    // 0014 ends a revocation episode when the identity **observes** the id again, which closes every
    // route where the user comes back through `resolve()`. It rests on a premise nobody had written
    // down: that a user whose sessions were revoked can only come back by signing in. Three routes
    // falsify it, and all three were measured against this tree before 0015 was written — the first
    // is the one SONNY-358 was filed for and lives on its own route, in `auth.db.test.ts`:
    //
    //   A. they come back by **refreshing** — `POST /v1/auth/refresh` never calls `resolve()`;
    //   B. they do not come back **at all** — reopen and re-close with nothing in between;
    //   C. they come back as **somebody else** — the next sign-in presents a different id, so the
    //      stamped one is superseded rather than observed.
    //
    // 0015's answer is that a recorded revocation implies only that the provider was already asked,
    // never that it complied — `ProviderRejected` is recorded as done on any 4xx but 429 — so the
    // stamp is cleared by the two events that CREATE an obligation (`OWED_PREDICATE`'s own two
    // disjuncts) rather than by the user turning up. The migration's header has the decision in
    // full.

    itUnderHangBackstop("owes a fresh revocation after a reopen and a second close with NO sign-in and no refresh at all", async () => {
      // **Route B, and it is the one no route-level fix could have closed**: there is no request to
      // hang one on. Measured before 0015 on this same sequence, the last assertion read 0.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(await owedRevocationCount(client)).toBe(0);

      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);
      // Nothing at all happens in between. The stamp survives the reopen — reopening creates no
      // obligation — and the close is what clears it.
      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: true }]);

      await close(accountId);
      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: false }]);
      expect(await owedRevocationCount(client)).toBe(1);
      await expect(client.query("DELETE FROM sonny.account WHERE id = $1", [accountId]))
        .rejects.toThrow(/still owes 1 provider-side revocation/);

      provider.revokedUsers = [];
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
    });

    itUnderHangBackstop("owes a fresh revocation for a stamped id that a later sign-in SUPERSEDES", async () => {
      // **Route C.** The user comes back as a different provider-side user, so the stamped id is
      // superseded rather than observed and 0014's `ON CONFLICT` arm never touches it. Before 0015
      // the history here read `{FIRST, superseded: true, revoked: true}` and the account owed 0 — an
      // id whose sessions may still be live, superseded, on a live account, owed nothing by anybody.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);

      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);
      await resolve(client, assertion("a@example.com", SECOND));

      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: false },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
      // Owed on a LIVE account, which is what the supersession disjunct is for.
      expect(await owedRevocationCount(client)).toBe(1);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([FIRST]);
    });

    itUnderHangBackstop("hands a stamped row back to the drain even while a dead lease is on it", async () => {
      // The lease belongs to the episode too — 0014 settled that for the come-back arm and this is
      // the same rule on the close. A drain that claimed a row and died leaves
      // `revocation_claimed_at` set; without clearing it here, the revocation the second close owes
      // would be invisible to the claim query for a whole `sonny.revocation_lease_seconds()`.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);
      await client.query(
        "UPDATE sonny.identity_provider_user SET revocation_claimed_at = now() WHERE supabase_user_id = $1",
        [FIRST]);

      await close(accountId);
      const { rows } = await client.query<{ claimed: boolean }>(
        `SELECT (revocation_claimed_at IS NOT NULL) AS claimed
           FROM sonny.identity_provider_user WHERE supabase_user_id = $1`, [FIRST]);
      expect(rows[0]!.claimed).toBe(false);
      provider.revokedUsers = [];
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
    });

    itUnderHangBackstop("does NOT re-owe anything when an already-closed account is closed again", async () => {
      // The counterweight to route B, and the direction that says the trigger fires on the
      // TRANSITION rather than on the state. `sonny.mark_identities_closed` (0005) updates only
      // identities that are `NOT account_closed`, so a repeated close touches no identity row and
      // this trigger never runs — but a trigger keyed on `NEW.account_closed` alone would fire on
      // every later write to a closed identity and re-owe an episode that genuinely ended, calling
      // the provider again on every one.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);

      await close(accountId);
      await close(accountId);
      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: true }]);
      expect(await owedRevocationCount(client)).toBe(0);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([]);
    });

    itUnderHangBackstop("does NOT re-owe when a CLOSED identity's row is written for some other reason", async () => {
      // **The test the one above cannot be** (PR #167 review, F2), and the reason is worth the
      // paragraph, because the branch shipped a changelog sentence claiming otherwise.
      //
      // The trigger is keyed on the TRANSITION — `WHEN (NEW.account_closed AND NOT
      // OLD.account_closed)` — and the obvious mutant is to key it on the state instead,
      // `WHEN (NEW.account_closed)`, which would re-owe a genuinely spent revocation on every later
      // write to a closed identity. The re-close test above cannot separate the two: 0005's
      // `mark_identities_closed` filters `AND NOT account_closed`, so a repeated close updates **no
      // identity row at all** and NEITHER version fires. It passes under both, which is exactly the
      // shape 0014's own `IS DISTINCT FROM` lesson is about — a correct line whose test guards
      // nothing — and the reviewer's battery proved it by watching that mutant SURVIVE the whole
      // suite.
      //
      // So this writes the closed identity for an ordinary reason instead. Nothing in application
      // code does that today — `resolve()` and `linkExplicitly` both exclude closed identities, and
      // `mark_identities_closed` filters in both directions — which is why there is no live defect
      // and why the case has to be written by hand to exist at all. A support script or a future
      // backfill touching a closed row is what it stands for.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: true }]);

      // An ordinary write to a row that is already closed. `account_closed` does not change, so no
      // new obligation exists and the spent revocation must stay spent.
      const written = await client.query(
        "UPDATE sonny.identity SET email_hint = 'renamed@example.com' WHERE account_id = $1",
        [accountId]);
      // The write really happened — otherwise this test would pass for the same empty reason the
      // re-close one does, which is the whole defect it was written to avoid.
      expect(written.rowCount).toBe(1);

      expect(await historyFor(accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: true }]);
      expect(await owedRevocationCount(client)).toBe(0);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([]);
    });

    itUnderHangBackstop("does NOT re-owe a superseded id that was already drained when the account later closes", async () => {
      // The counterweight to route C, and the reason the close's clear is scoped to
      // `superseded_at IS NULL`. A close creates an obligation for the id the identity is CURRENTLY
      // naming; an id it stopped naming had its obligation created once, by the supersession, and
      // the close says nothing new about it — no session for a superseded id can have been minted
      // through this gateway since, because `accountForSupabaseUser` refuses to attribute one.
      //
      // Without the scoping this passes every other test in this file and re-owes every id in a
      // closed account's history on every close, for ever.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);

      await close(accountId);
      expect(await historyFor(accountId)).toEqual([
        { supabase_user_id: FIRST, superseded: true, revoked: true },
        { supabase_user_id: SECOND, superseded: false, revoked: false },
      ]);
      expect(await owedRevocationCount(client)).toBe(1);
      provider.revokedUsers = [];
      await drainOwedRevocations(client, provider);
      expect(provider.revokedUsers).toEqual([SECOND]);
    });

    itUnderHangBackstop("owes a revocation for an identity MOVED onto a closed account, which names no column at all", async () => {
      // **The `UPDATE OF` trap, from the other side** (0005's third statement, and 0014's F5). The
      // close trigger compares OLD to NEW rather than keying on a SET list, because
      // `sonny.derive_identity_closed` is a BEFORE trigger that writes `NEW.account_closed` on an
      // `UPDATE … SET account_id`, a statement that never mentions the column. An `AFTER UPDATE OF
      // account_closed` trigger would not fire here at all, and the move would carry a spent stamp
      // onto a closed account with nothing owed.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(accountId);
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      await client.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);

      const dead = await client.query<{ id: string }>(
        "INSERT INTO sonny.account (deleted_at) VALUES (now()) RETURNING id");
      await client.query("UPDATE sonny.identity SET account_id = $1 WHERE account_id = $2",
        [dead.rows[0]!.id, accountId]);

      expect(await historyFor(dead.rows[0]!.id))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: false }]);
      expect(await owedRevocationCount(client)).toBe(1);
    });
  });

  describe("the counts are per provider-side user, which is the unit of the work", () => {
    itUnderHangBackstop("counts one provider-side user named by two identities once", async () => {
      // **PR #164 review, F3.** `owedByAccount` counted rows and printed them under the noun
      // "provider-side user(s)", so an operator was told an account owed 2 while one drain call
      // cleared it and `RevocationOutcome.revoked` said 1 — three figures sharing a word and not a
      // unit. Two identities naming one Supabase user is the shape `attribution.ts`'s header says
      // the whole account/identity separation exists to allow.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, supabase_user_id, link_method)
         VALUES ($1,'google','google-sub-3','a@example.com',true,false,$2,'explicit')`,
        [accountId, FIRST]);
      await close(accountId);

      expect(await owedRevocationCount(client)).toBe(1);
      expect(await owedByAccount(client)).toEqual([
        { accountId, providerUsers: 1, superseded: 0 },
      ]);
      const outcome = await drainOwedRevocations(client, provider);
      // One call, one revocation, one owed — the three figures now agree.
      expect(outcome.revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
      expect(await owedRevocationCount(client)).toBe(0);
    });
  });

  describe("the drain and the delete guard agree about the same set", () => {
    itUnderHangBackstop("refuses to hard-delete a live account that still owes a superseded revocation", async () => {
      // 0009's rule — the guard counts what the drain counts — applied to the set the drain now
      // reads. Deleting here would destroy the only record that the superseded user's sessions are
      // owed a revocation, which is the exact failure SONNY-230 describes.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      await expect(client.query("DELETE FROM sonny.account WHERE id = $1", [accountId]))
        .rejects.toThrow(/still owes 1 provider-side revocation/);

      // Drained, it deletes — a guard that refused everything would pass the line above and be
      // useless.
      await drainOwedRevocations(client, provider);
      await client.query("DELETE FROM sonny.account WHERE id = $1", [accountId]);
      expect((await client.query("SELECT count(*)::int AS n FROM sonny.account")).rows[0].n).toBe(0);
    });

    itUnderHangBackstop("leaves a superseded id owed when the provider call fails transiently", async () => {
      // `ProviderRejected` is the only answer that counts as done. A timeout leaves the row owed,
      // releases the lease, and the next drain finds it — the same contract the closed-account case
      // has had since PR #87's third round, now reaching supersessions too.
      await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));
      provider.failFor.add(FIRST);

      const outcome = await drainOwedRevocations(client, provider);
      expect(outcome.revoked).toBe(0);
      // **`"Error"`, not `"ProviderUnavailable"`, and that is a fact about the seam rather than a
      // slack assertion.** `revocation.ts` records `(error as Error)?.name`, and
      // `class ProviderUnavailable extends Error {}` sets no `name`, so every non-rejection failure
      // reports the base class's. Asserted as it is because the alternative is a test that pins a
      // value nothing produces; naming the two error classes is `provider.ts`'s to change and is
      // outside both these tickets.
      expect(outcome.failures).toEqual([{ supabaseUserId: FIRST, reason: "Error" }]);
      expect(await owedRevocationCount(client)).toBe(1);

      provider.failFor.clear();
      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(await owedRevocationCount(client)).toBe(0);
    });

    itUnderHangBackstop("does not stamp a live account's CURRENT id while revoking that same id elsewhere", async () => {
      // One `signOutAllForUser` revokes every session of one provider-side user, so the drain fans
      // its stamp out across every row naming it. **Every OWED row, and no other.** A row that is
      // current on a live account is not owed anything, and stamping it would mean that when that
      // account is later closed the drain would consider its debt already paid — for sessions minted
      // after this call returned. Silent, and a session nobody can revoke.
      const closed = await resolve(client, assertion("closed@example.com", FIRST));
      await close(closed.accountId);
      const live = await resolve(client, {
        provider: "google", subject: "google-sub-2", email: "live@example.com",
        emailVerified: true, supabaseUserId: FIRST,
      });

      expect((await drainOwedRevocations(client, provider)).revoked).toBe(1);
      expect(provider.revokedUsers).toEqual([FIRST]);
      expect(await historyFor(live.accountId))
        .toEqual([{ supabase_user_id: FIRST, superseded: false, revoked: false }]);

      // And closing that account now genuinely owes one, rather than reading as already paid.
      await close(live.accountId);
      expect(await owedRevocationCount(client)).toBe(1);
    });
  });
});
