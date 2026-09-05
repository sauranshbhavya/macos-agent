import pg from "pg";
import { describe, expect } from "vitest";
import { callerOriginatedLatestCode, consumeLatest, recordIssue } from "../src/auth/codes.js";
import { normalizeEmail, resolve } from "../src/auth/identity.js";
import { ProviderRejected, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import { drainOwedRevocations } from "../src/auth/revocation.js";
import { down, up } from "../src/db/migrate.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { testDatabaseUrl } from "./support/database.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * What migrations 0016 and 0017 do to a database that already holds rows — applied, rolled back and
 * applied again (SONNY-365, SONNY-353).
 *
 * **This file exists because of what its two tests need rather than because of what they are about.**
 * They were written inside `instance-identity.db.test.ts`, whose other ten tests are about the
 * episode counter and the code ordering those migrations create. These two are different in kind:
 * the schema transition is their **subject**, not their setup. The round trip asserts that both
 * migrations survive a database holding rows in every state they touch, and the ordering test can
 * only make a row that predates `issue_seq` by rolling 0017 back and writing one while the column
 * does not exist. Neither claim can be made without `down()` and `up()`.
 *
 * **So this file names the migration runner, and `schema.test.ts` gates that.** Its exemption list
 * asks that every entry be a file whose *name* says it is about migrations, and warns that an entry
 * for a file named for something else would be the guard switched off one line at a time —
 * `instance-identity.db.test.ts` is exactly such a name, which is why these two moved here instead
 * of buying that file an entry it could not honestly earn. The helper's `dropSchema`, which is the
 * door PR #169 found and needed no exemption for, cannot serve here: it drops a schema, and what
 * these tests need is a *migration* rolled back and forward with rows surviving across it.
 *
 * `rebuildSchema` still supplies the starting schema, so this file makes no claim about what the
 * previous invocation of the suite left behind.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const FIRST = "bbbbbbbb-0000-4000-8000-000000000001";
const SECOND = "bbbbbbbb-0000-4000-8000-000000000002";

/**
 * A provider that records and never fails.
 *
 * Deliberately smaller than `instance-identity.db.test.ts`'s: that one carries a `once` hook so a
 * write can land in the middle of a provider call, which is the interleaving those tests are about.
 * Nothing here interleaves — the drain is used to put rows into the stamped state the round trip
 * then carries across a rollback — so a copy of the larger fixture would be borrowed complexity.
 */
class SucceedingProvider implements AuthProvider {
  revokedUsers: string[] = [];
  async sendEmailCode(_email: string) { return { providerRequestId: undefined }; }
  async verifyEmailCode(_e: string, _c: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async refresh(_t: string): Promise<VerifiedSession> {
    throw new ProviderRejected("not used here");
  }
  async signOut(_t: string) {}
  async signOutAllForUser(id: string) { this.revokedUsers.push(id); }
  async userFromAccessToken(_t: string): Promise<string> {
    throw new ProviderRejected("not on this path");
  }
  async deleteUser(_id: string) {}
}

describeDb("migrations 0016 and 0017 over a database that already holds rows", () => {
  let client: pg.Client;
  let provider: SucceedingProvider;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => { await client.end(); });
  beforeEachUnderHangBackstop(async () => {
    // **The schema is rebuilt per test, not just per file, and here that is load-bearing.** Both
    // tests below roll migrations back and leave the ledger somewhere the next one must not
    // inherit; a file-level rebuild would make the second test depend on how the first finished,
    // which a mutation battery aborting mid-run turns into a failure that reads as a defect.
    await rebuildSchema(client);
    provider = new SucceedingProvider();
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

  describe("the migrations round-trip against a database that already holds rows", () => {
    itUnderHangBackstop("rolls 0017 and 0016 back and forward over rows in every state they touch", async () => {
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
      const seeded = await client.query<{ id: string }>(
        `INSERT INTO sonny.sign_in_code_issue (mailbox_key, issued_at, expires_at, source_hash, consumed_at)
         VALUES ('m@example.com', $1, $2, 'h', NULL),
                ('m@example.com', $1, $2, 'h', $1),
                ('m@example.com', $1, $1, 'h', NULL)
         RETURNING id`,
        [past, future]);
      const seededIds = seeded.rows.map((r) => r.id);
      const before = await client.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM sonny.identity_provider_user");

      // Down to 0016. `down()` rolls back the last applied migration each time, so this walks the
      // ledger from the head — **which means every migration added after this file was written adds
      // a step here**, and the failure it produces when one is forgotten is legible: the assertion
      // says the head was some other file. 0018 is SONNY-211's and is rolled back only to get past
      // it; nothing below is about it.
      expect(await down(client)).toBe("0020_a_screenshot_can_be_deleted_without_the_task");
      expect(await down(client)).toBe("0019_topping_up_happens_only_if_you_asked");
      expect(await down(client)).toBe("0018_a_subscription_reaches_the_entitlement");
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
        "0018_a_subscription_reaches_the_entitlement",
        "0019_topping_up_happens_only_if_you_asked",
        "0020_a_screenshot_can_be_deleted_without_the_task",
      ]);
      // **Pin the MAPPING, not the set** (PR #171 review, F2). This asserted
      // `toEqual([1, 2, 3])` over the whole column, which checks that three numbers came out dense
      // and ordered and never **which row got which number** — it passed under the shipped
      // ordering, under the uuid ordering this branch rejected, and under `ORDER BY random()`. The
      // subject of SONNY-353 is which row is newest, so every assertion here names a row.
      const seqOf = async (id: string) => {
        const { rows } = await client.query<{ issue_seq: string }>(
          "SELECT issue_seq::text AS issue_seq FROM sonny.sign_in_code_issue WHERE id = $1", [id]);
        return Number(rows[0]!.issue_seq);
      };

      // Every pre-existing row reads the sentinel. 0 is what `NOT NULL DEFAULT 0` gave them without
      // touching a row, and the identity starts at 1, so no later row can collide with it.
      expect(await Promise.all(seededIds.map(seqOf))).toEqual([0, 0, 0]);

      // Rows written after the migration carry real insertion order, by id and in order.
      const one = await recordIssue(client, "m@example.com", "h-one", past);
      const two = await recordIssue(client, "m@example.com", "h-two", past);
      expect(await seqOf(one.id)).toBe(1);
      expect(await seqOf(two.id)).toBe(2);

      // And the ordering that follows from it, across the boundary the sentinel creates. All five
      // rows at this mailbox share one `issued_at`, so `issued_at` can separate none of them: the
      // last code issued wins over the one issued before it AND over the live pre-migration row,
      // which is correct because every post-migration row is newer than every pre-migration one.
      expect(await consumeLatest(client, "m@example.com", past)).toBe(true);
      const { rows: consumed } = await client.query<{ id: string }>(
        `SELECT id FROM sonny.sign_in_code_issue
          WHERE mailbox_key = 'm@example.com' AND consumed_at IS NOT NULL AND id <> $1`,
        [seededIds[1]]);   // the seeded row that was already consumed is not evidence of anything
      expect(consumed.map((r) => r.id)).toEqual([two.id]);
      // Every provider-side user row comes back at episode 1, which is the honest answer: the
      // counter records obligations since the column existed, and the ones before it are unknown.
      const episodes = await client.query<{ n: string }>(
        "SELECT DISTINCT revocation_episode::text AS n FROM sonny.identity_provider_user");
      expect(episodes.rows.map((r) => Number(r.n))).toEqual([1]);
    });

    itUnderHangBackstop("orders the rows it INHERITS by issued_at, which the sentinel alone would have reversed", async () => {
      // **PR #171 cycle 2, F1 — the regression the sentinel introduced into this ticket's own
      // subject.** Every pre-migration row carries `issue_seq = 0`, so ordering on the sequence
      // alone collapses that whole population into one tie — and a tie is not what those rows had.
      // `ORDER BY issued_at DESC` was undefined only for rows sharing an exact instant and correct
      // for every other pair, which is the ordinary case. So the sequence alone made
      // `latestIssuance` WORSE for exactly the population 0017 exists to fix, on the query that
      // reads `source_hash` for the disclosure gate. `issued_at DESC` behind the sentinel recovers
      // it.
      //
      // The rows have to predate the column, so this rolls 0017 back, writes them, and rolls
      // forward — the same door a deployment goes through, and the reason `issue_seq` is absent
      // from the INSERT below.
      expect(await down(client)).toBe("0020_a_screenshot_can_be_deleted_without_the_task");
      expect(await down(client)).toBe("0019_topping_up_happens_only_if_you_asked");
      expect(await down(client)).toBe("0018_a_subscription_reaches_the_entitlement");
      expect(await down(client)).toBe("0017_the_latest_sign_in_code_is_the_last_one_issued");
      const at = (hhmm: string) => new Date(`2026-08-30T${hhmm}:00.000Z`);
      const inherited = await client.query<{ id: string }>(
        `INSERT INTO sonny.sign_in_code_issue (mailbox_key, issued_at, expires_at, source_hash)
         VALUES ('inherited@example.com', $1, $4, 'hash-oldest'),
                ('inherited@example.com', $2, $4, 'hash-middle'),
                ('inherited@example.com', $3, $4, 'hash-newest')
         RETURNING id`,
        [at("12:00"), at("12:05"), at("12:09"), new Date("2099-01-01T00:00:00.000Z")]);
      const newestId = inherited.rows[2]!.id;
      expect(await up(client)).toEqual([
        "0017_the_latest_sign_in_code_is_the_last_one_issued",
        "0018_a_subscription_reaches_the_entitlement",
        "0019_topping_up_happens_only_if_you_asked",
        "0020_a_screenshot_can_be_deleted_without_the_task",
      ]);

      // All three carry the sentinel, so `issue_seq` separates none of them and only the second key
      // can answer. Without it the query returns the OLDEST of the three.
      const seqs = await client.query<{ n: string }>(
        "SELECT DISTINCT issue_seq::text AS n FROM sonny.sign_in_code_issue WHERE mailbox_key = 'inherited@example.com'");
      expect(seqs.rows.map((r) => Number(r.n))).toEqual([0]);

      const now = at("12:10");
      // `latestIssuance`, through the disclosure gate that reads its `source_hash`.
      expect(await callerOriginatedLatestCode(client, "inherited@example.com", now, "hash-newest")).toBe(true);
      expect(await callerOriginatedLatestCode(client, "inherited@example.com", now, "hash-oldest")).toBe(false);
      // And `consumeLatest`, which redeems by the same ordering.
      expect(await consumeLatest(client, "inherited@example.com", now)).toBe(true);
      const { rows: taken } = await client.query<{ id: string }>(
        "SELECT id FROM sonny.sign_in_code_issue WHERE consumed_at IS NOT NULL");
      expect(taken.map((r) => r.id)).toEqual([newestId]);

      // A post-migration row still beats all three even with an EARLIER `issued_at`, so the second
      // key has not displaced the first. 12:08 rather than something further back on purpose: the
      // gate below also refuses anything older than `FAILURE_DISCLOSURE_SECONDS`, and a row back-
      // dated past that answers false for a reason that has nothing to do with ordering — which is
      // how the first draft of this assertion failed while the clause under test was working.
      const fresh = await recordIssue(client, "inherited@example.com", "hash-fresh", at("12:08"));
      expect(await callerOriginatedLatestCode(client, "inherited@example.com", now, "hash-fresh")).toBe(true);
      const { rows: freshSeq } = await client.query<{ n: string }>(
        "SELECT issue_seq::text AS n FROM sonny.sign_in_code_issue WHERE id = $1", [fresh.id]);
      expect(Number(freshSeq[0]!.n)).toBe(1);
    });
  });
});
