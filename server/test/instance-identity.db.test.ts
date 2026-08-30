import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  callerOriginatedLatestCode,
  consumeLatest,
  recordIssue,
} from "../src/auth/codes.js";
import { normalizeEmail, resolve } from "../src/auth/identity.js";
import { ProviderRejected, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import { drainOwedRevocations, owedRevocationCount } from "../src/auth/revocation.js";
import { down, up } from "../src/db/migrate.js";
import { testDatabaseUrl } from "./support/database.js";

/**
 * One shape twice: an operation that cannot tell which instance of a thing it is acting on
 * (SONNY-365, SONNY-353).
 *
 * **SONNY-365** — a drain's mark-done discharged "the obligation for this provider-side user"
 * rather than "the obligation this drain claimed". Those differ whenever an obligation is created
 * between the provider call and the stamp, and the result is sessions that were never revoked on an
 * account the books say is clean. Migration 0016 gives each row a `revocation_episode` that every
 * obligation-creating event increments; the drain records it at claim time and stamps only rows
 * still carrying it.
 *
 * **SONNY-353** — `consumeLatest` and `latestIssuance` picked "the newest code" with
 * `ORDER BY issued_at DESC` and no tie-break, so two codes sharing an instant had no defined
 * newest. Migration 0017 adds `issue_seq`, an identity column, and both queries order by it.
 *
 * **Against a real Postgres in both halves, because both mechanisms are the database's.** The
 * episode is maintained by three trigger arms and read by a predicate; the ordering is a query plan's
 * choice. A fake would prove nothing about either.
 *
 * **This file drops the schema before it migrates** (PR #167's F1). `up()` applies only *pending*
 * migrations, so on a database another file already built it is a no-op — and a file that skips the
 * drop measures the previous invocation's schema, which is how a mutant that deleted a whole
 * `CREATE TRIGGER` was measured passing.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const FIRST = "bbbbbbbb-0000-4000-8000-000000000001";
const SECOND = "bbbbbbbb-0000-4000-8000-000000000002";

/** Records what it was asked to revoke, and can run one write in the middle of the call. */
class RecordingProvider implements AuthProvider {
  revokedUsers: string[] = [];
  /**
   * Runs **inside** `signOutAllForUser`, before the call is recorded, and clears itself so it fires
   * exactly once.
   *
   * One-shot on purpose. A refused stamp leaves the row owed with its claim cleared, so the drain's
   * next iteration claims it again — and an interleave that fired on every call would re-create the
   * obligation every time and spin the loop to its `limit`, which measures the harness rather than
   * the property.
   */
  once: undefined | (() => Promise<void>);
  async sendEmailCode(_email: string) { return { providerRequestId: undefined }; }
  async verifyEmailCode(_e: string, _c: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async refresh(_t: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async signOut(_t: string) {}
  async signOutAllForUser(id: string) {
    const hook = this.once;
    if (hook) { this.once = undefined; await hook(); }
    this.revokedUsers.push(id);
  }
  async userFromAccessToken(_t: string): Promise<string> {
    throw new ProviderRejected("not on this path");
  }
  async deleteUser(_id: string) {}
}

describeDb("an auth operation knows which instance it is acting on", () => {
  let client: pg.Client;
  /** A second connection: the interleaved write has to commit while the drain is inside its call. */
  let other: pg.Client;
  let provider: RecordingProvider;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    other = new pg.Client({ connectionString: testDatabaseUrl() });
    await other.connect();
    await client.query("DROP SCHEMA IF EXISTS sonny CASCADE");
    await client.query("DROP SCHEMA IF EXISTS sonny_meta CASCADE");
    await up(client);
  });
  afterAll(async () => { await client.end(); await other.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.identity, sonny.account RESTART IDENTITY CASCADE");
    await client.query("TRUNCATE sonny.sign_in_code_issue");
    provider = new RecordingProvider();
  });

  const assertion = (address: string, supabaseUserId: string) => ({
    provider: "email" as const,
    subject: normalizeEmail(address),
    email: address,
    emailVerified: true,
    supabaseUserId,
  });

  const close = (c: pg.Client, accountId: string) =>
    c.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [accountId]);
  const reopen = (c: pg.Client, accountId: string) =>
    c.query("UPDATE sonny.account SET deleted_at = NULL WHERE id = $1", [accountId]);

  const episodesFor = async (supabaseUserId: string) => {
    const { rows } = await client.query<{ n: string }>(
      "SELECT revocation_episode::text AS n FROM sonny.identity_provider_user WHERE supabase_user_id = $1 ORDER BY id",
      [supabaseUserId]);
    return rows.map((r) => Number(r.n));
  };
  const stampedRows = async (supabaseUserId: string) => {
    const { rows } = await client.query<{ n: string }>(
      "SELECT count(*)::text AS n FROM sonny.identity_provider_user WHERE supabase_user_id = $1 AND provider_session_revoked_at IS NOT NULL",
      [supabaseUserId]);
    return Number(rows[0]!.n);
  };

  describe("SONNY-365 — a drain discharges the obligation it claimed and no other", () => {
    it("does NOT discharge an obligation created while its own provider call was in flight", async () => {
      // **PR #167's reproduction, as the headline.** The account is closed and owes a revocation.
      // A drain claims it and calls the provider. While that call is in flight the account is
      // reopened and closed again — door B of 0015's enumeration, the one that needs no request at
      // all — and 0015 correctly clears the stamp for the fresh obligation. The drain then returns.
      //
      // `limit: 1` so this measures the stamp rather than the loop: one claim, one provider call,
      // one mark-done, and then the assertion. Before 0016 the mark-done wrote the stamp back and
      // this ended `owed = 0` with the reopen's sessions never revoked.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(client, accountId);
      expect(await owedRevocationCount(client)).toBe(1);

      provider.once = async () => {
        await reopen(other, accountId);
        await close(other, accountId);
      };
      const outcome = await drainOwedRevocations(client, provider, { limit: 1 });

      expect(provider.revokedUsers).toEqual([FIRST]);
      // The call was made and is counted; the obligation it was made for no longer exists, and the
      // one that does exist was created after it.
      expect(outcome.revoked).toBe(1);
      expect(await stampedRows(FIRST)).toBe(0);
      expect(await owedRevocationCount(client)).toBe(1);
    });

    it("services the new obligation with its own provider call in the same run", async () => {
      // The other half, and the reason a refused stamp needs no new outcome field: the row is still
      // owed and its claim was cleared by the close, so the drain's next iteration picks it up and
      // asks the provider again. Two calls, and the second one is the one that covers the sessions
      // minted during the reopen.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(client, accountId);
      provider.once = async () => {
        await reopen(other, accountId);
        await close(other, accountId);
      };

      await drainOwedRevocations(client, provider);

      expect(provider.revokedUsers).toEqual([FIRST, FIRST]);
      expect(await owedRevocationCount(client)).toBe(0);
      expect(await stampedRows(FIRST)).toBe(1);
    });

    it("does NOT discharge an obligation created by a SUPERSESSION during the call", async () => {
      // The second configuration. Here the interleaved event is the id being superseded rather than
      // the account closing, which is `OWED_PREDICATE`'s other disjunct — and it matters that the
      // mark-done's own `EXISTS (… OWED_PREDICATE)` cannot catch this one: a superseded row IS
      // owed, so that clause says yes and only the episode says no.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(client, accountId);

      provider.once = async () => {
        await reopen(other, accountId);
        // The user comes back as somebody else: FIRST is superseded, which creates its obligation.
        await resolve(other, assertion("a@example.com", SECOND));
      };
      await drainOwedRevocations(client, provider, { limit: 1 });

      expect(provider.revokedUsers).toEqual([FIRST]);
      expect(await stampedRows(FIRST)).toBe(0);
      expect(await owedRevocationCount(client)).toBe(1);
    });

    it("does NOT discharge a SIBLING row's fresh obligation, which no claim ever covered", async () => {
      // **The case that decided the design, and the one the close trigger's third `AND` used to
      // hide.** A discharge fans out to every owed row naming the provider-side user, because one
      // `signOutAllForUser` ends every session of that user — so rows the drain never claimed are
      // stamped too. Those rows carry no claim, which is why a claim token could not have been the
      // episode identity, and under 0015's guard their close wrote nothing at all: no stamp and no
      // claim to clear meant the trigger skipped them, and the drain stamped a fresh obligation.
      //
      // Two accounts, one provider-side user. `sonny.identity` is written directly for the second:
      // the trigger that records a provider-side user fires on any writer of that column, which is
      // 0014's whole design, and `resolve()` would attach one address to one account.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      const { rows: made } = await client.query<{ id: string }>(
        "INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      const sibling = made[0]!.id;
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
                                     supabase_user_id, link_method)
         VALUES ($1, 'email', $2, 'b@example.com', true, $3, 'primary')`,
        [sibling, normalizeEmail("b@example.com"), FIRST]);
      await close(client, accountId);
      await close(client, sibling);
      // Two rows, one provider-side user, and `owedRevocationCount` counts the user.
      expect(await episodesFor(FIRST)).toHaveLength(2);
      expect(await owedRevocationCount(client)).toBe(1);

      provider.once = async () => {
        await reopen(other, sibling);
        await close(other, sibling);
      };
      await drainOwedRevocations(client, provider, { limit: 1 });

      // The claimed row's obligation is discharged; the sibling's fresh one is not.
      expect(await stampedRows(FIRST)).toBe(1);
      expect(await owedRevocationCount(client)).toBe(1);
    });

    it("increments the episode on each of the three events that start one, and never otherwise", async () => {
      // The mechanism itself, so a reader can see what the tests above rest on. Also the guard on
      // the close trigger's removed `AND`: a close bumps a row carrying neither a stamp nor a claim,
      // which is exactly what that guard used to skip.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      expect(await episodesFor(FIRST)).toEqual([1]);

      // 1. The identity observes the id again.
      await resolve(client, assertion("a@example.com", FIRST));
      expect(await episodesFor(FIRST)).toEqual([2]);

      // 2. The account closes — on a row with no stamp and no claim.
      await close(client, accountId);
      expect(await episodesFor(FIRST)).toEqual([3]);

      // A write to the closed identity that is not a close changes nothing: the trigger is keyed on
      // the transition, not on the state.
      await client.query("UPDATE sonny.identity SET email_hint = 'x@example.com' WHERE account_id = $1",
        [accountId]);
      expect(await episodesFor(FIRST)).toEqual([3]);

      // 3. The id is superseded.
      await reopen(client, accountId);
      await resolve(client, assertion("a@example.com", SECOND));
      expect(await episodesFor(FIRST)).toEqual([4]);
      expect(await episodesFor(SECOND)).toEqual([1]);
    });

    it("still discharges normally when nothing interleaves", async () => {
      // The negative control. An episode check that refused everything would pass every test above.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await close(client, accountId);
      const outcome = await drainOwedRevocations(client, provider);
      expect(outcome).toEqual({ revoked: 1, failed: 0, failures: [] });
      expect(await stampedRows(FIRST)).toBe(1);
      expect(await owedRevocationCount(client)).toBe(0);
    });
  });

  describe("SONNY-353 — the latest code at a mailbox is the last one issued", () => {
    const mailbox = "codes@example.com";
    /** One frozen instant, which is what makes every row's `issued_at` equal. */
    const frozen = new Date("2026-08-30T12:00:00.000Z");

    const consumedIds = async () => {
      const { rows } = await client.query<{ id: string }>(
        "SELECT id FROM sonny.sign_in_code_issue WHERE consumed_at IS NOT NULL");
      return rows.map((r) => r.id);
    };

    it("consumes the LAST of several issuances that share one instant", async () => {
      // Five rows, one `issued_at`. Under `ORDER BY issued_at DESC` with no tie-break the winner is
      // whatever the plan returns first, which is neither defined nor the newest; under `issue_seq`
      // it is the last one written. Five rather than two so a plan that happens to reverse cannot
      // pass by coincidence.
      const ids: string[] = [];
      for (let i = 0; i < 5; i += 1) {
        ids.push((await recordIssue(client, mailbox, `hash-${i}`, frozen)).id);
      }
      const sameInstant = await client.query<{ n: string }>(
        "SELECT count(DISTINCT issued_at)::text AS n FROM sonny.sign_in_code_issue");
      expect(Number(sameInstant.rows[0]!.n)).toBe(1);

      expect(await consumeLatest(client, mailbox, frozen)).toBe(true);
      expect(await consumedIds()).toEqual([ids[4]]);
    });

    it("discloses the failure of the LAST issuance when two share an instant", async () => {
      // The other query, and the one whose ambiguity is not merely a wrong row. `latestIssuance`
      // feeds the disclosure gate, so the undefined ordering could hand it the other issuance's
      // `source_hash` — telling the caller who really did originate the live code that theirs is
      // `auth.code_invalid`, and telling somebody else about a mailbox they have no claim on.
      await recordIssue(client, mailbox, "hash-older", frozen);
      await recordIssue(client, mailbox, "hash-newer", frozen);

      expect(await callerOriginatedLatestCode(client, mailbox, frozen, "hash-newer")).toBe(true);
      expect(await callerOriginatedLatestCode(client, mailbox, frozen, "hash-older")).toBe(false);
    });

    it("orders by issuance even when the clock goes backwards", async () => {
      // `issue_seq` is not a proxy for `issued_at` and does not defer to it. A test harness that
      // rewinds its clock still gets the code it issued last, which is the one a user is holding —
      // and `issueCode` has already invalidated the live ones before it.
      const older = new Date("2026-08-30T12:00:00.000Z");
      const newer = new Date("2026-08-30T11:00:00.000Z");
      await recordIssue(client, mailbox, "hash-first", older);
      const second = await recordIssue(client, mailbox, "hash-second", newer);

      expect(await consumeLatest(client, mailbox, newer)).toBe(true);
      expect(await consumedIds()).toEqual([second.id]);
    });

    it("refuses an issue_seq written by application code", async () => {
      // `GENERATED ALWAYS`, so the ordering cannot be forged or back-dated by a caller. 428C9 is
      // Postgres's `generated_always`.
      await expect(
        client.query(
          `INSERT INTO sonny.sign_in_code_issue (mailbox_key, issued_at, expires_at, source_hash, issue_seq)
           VALUES ($1, $2, $2, 'h', 99)`,
          [mailbox, frozen]),
      ).rejects.toMatchObject({ code: "428C9" });
    });
  });

  describe("the migrations round-trip against a database that already holds rows", () => {
    it("rolls 0017 and 0016 back and forward over rows in every state they touch", async () => {
      // **An empty database is the case that always works.** So this plants a row in every state
      // both migrations care about first: a provider-side user that is current, one that is
      // superseded, one that is stamped, one that is claimed, and a mailbox holding a live code, a
      // consumed one and an expired one — then rolls both migrations back and forward again.
      const { accountId } = await resolve(client, assertion("a@example.com", FIRST));
      await resolve(client, assertion("a@example.com", SECOND));  // supersedes FIRST
      await close(client, accountId);
      await drainOwedRevocations(client, provider);               // stamps what is owed
      const { accountId: live } = await resolve(client, assertion("c@example.com", "bbbbbbbb-0000-4000-8000-000000000003"));
      await client.query(
        "UPDATE sonny.identity_provider_user SET revocation_claimed_at = now() WHERE identity_id IN (SELECT id FROM sonny.identity WHERE account_id = $1)",
        [live]);
      const past = new Date("2026-08-30T11:00:00.000Z");
      const future = new Date("2099-01-01T00:00:00.000Z");
      await client.query(
        `INSERT INTO sonny.sign_in_code_issue (mailbox_key, issued_at, expires_at, source_hash, consumed_at)
         VALUES ('m@example.com', $1, $2, 'h', NULL),
                ('m@example.com', $1, $2, 'h', $1),
                ('m@example.com', $1, $1, 'h', NULL)`,
        [past, future]);
      const before = await client.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM sonny.identity_provider_user");

      // Down twice: 0017 then 0016. `down()` rolls back the last applied migration each time.
      expect(await down(client)).toBe("0017_the_latest_sign_in_code_is_the_last_one_issued");
      expect(await down(client)).toBe("0016_a_drain_discharges_the_obligation_it_claimed");
      const gone = await client.query<{ column_name: string }>(
        `SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'sonny'
            AND ((table_name = 'sign_in_code_issue' AND column_name = 'issue_seq')
              OR (table_name = 'identity_provider_user' AND column_name = 'revocation_episode'))`);
      expect(gone.rows).toEqual([]);
      // The rows survive the rollback — nothing is corrupted and nothing is repaired.
      const after = await client.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM sonny.identity_provider_user");
      expect(after.rows[0]!.n).toBe(before.rows[0]!.n);

      // And forward again, over exactly those rows, which is the direction a deployment takes.
      expect(await up(client)).toEqual([
        "0016_a_drain_discharges_the_obligation_it_claimed",
        "0017_the_latest_sign_in_code_is_the_last_one_issued",
      ]);
      // The backfill is dense and ordered, and the sequence continues past it rather than colliding.
      const seqs = await client.query<{ issue_seq: string }>(
        "SELECT issue_seq::text AS issue_seq FROM sonny.sign_in_code_issue ORDER BY issue_seq");
      expect(seqs.rows.map((r) => Number(r.issue_seq))).toEqual([1, 2, 3]);
      const fresh = await recordIssue(client, "m@example.com", "h", past);
      const { rows: next } = await client.query<{ issue_seq: string }>(
        "SELECT issue_seq::text AS issue_seq FROM sonny.sign_in_code_issue WHERE id = $1", [fresh.id]);
      expect(Number(next[0]!.issue_seq)).toBe(4);
      // Every provider-side user row comes back at episode 1, which is the honest answer: the
      // counter records obligations since the column existed, and the ones before it are unknown.
      const episodes = await client.query<{ n: string }>(
        "SELECT DISTINCT revocation_episode::text AS n FROM sonny.identity_provider_user");
      expect(episodes.rows.map((r) => Number(r.n))).toEqual([1]);
    });
  });
});
