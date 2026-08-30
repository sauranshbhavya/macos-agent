import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect } from "vitest";
import { LinkError, linkExplicitly, normalizeEmail, resolve } from "../src/auth/identity.js";
import { rebuildSchema } from "./support/schema.js";
import { itUnderHangBackstop } from "./support/backstop.js";

/**
 * The concurrency invariants of the account/identity model, under interleavings that are **forced
 * rather than hoped for**.
 *
 * **Why this file exists at all** (PR #87 third round, F7). The previous round's closing comment and
 * changelog entry quoted figures for a 50-round randomized race battery — its result, its own
 * self-critique, and its fix — for a script that existed nowhere in the tree or in git history. It
 * was run ad hoc in a scratch directory and thrown away. Three reviewers independently went looking
 * for it. That is this repository's own rule failing on the number the round leaned on most: a
 * counted number carries the command that produced it, and there was no command left to run.
 *
 * **Why it is written this way, which is the more useful half.** That ad-hoc battery passed 50/50 —
 * and then passed 50/50 again against a tree with the defect it had been written to catch
 * deliberately reintroduced. Every path it drove linked *onto* the closing account, which the
 * account lock correctly refuses, so it re-proved a guarantee that already held and never once
 * reached the state it was aimed at. A reviewer then reconstructed the same race independently and
 * measured the same thing from the other side: **30 iterations under natural timing landed the same
 * lock-acquisition ordering 30 times out of 30**, for a structural round-trip-asymmetry reason, and
 * never exercised the other branch without an explicitly pre-acquired lock.
 *
 * The lesson generalises past this branch: **a randomized battery in this codebase reaches whatever
 * ordering the timing happens to favour, and a clean result is evidence about the states it reached
 * and silent about the states it did not — and the two are indistinguishable in its output.** So:
 *
 * - Every ordering that matters is **forced**, with a held transaction, and each forced case asserts
 *   that the interleaving actually happened (the other participant's promise is still pending) before
 *   asserting any outcome. An ordering that failed to occur fails the test rather than passing it.
 * - Each forced case asserts an outcome that **cannot hold under the other ordering**, so the two
 *   cannot be swapped without a failure.
 * - The randomized pass alternates who starts first **by construction** rather than by luck, and
 *   asserts that both outcome classes were actually observed — so it cannot become one-sided
 *   silently, which is exactly how the ad-hoc version became worthless.
 *
 * Opt-in like the other `*.db.test.ts` files: `npm test` skips it, `npm run test:db` runs it.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

describeDb("concurrency invariants, under forced interleavings", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAll(async () => { await client.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.identity, sonny.account RESTART IDENTITY CASCADE");
  });

  const emailAssertion = (address: string) => ({
    provider: "email" as const,
    subject: normalizeEmail(address),
    email: address,
    emailVerified: true,
    supabaseUserId: undefined,
  });

  /** A connection of its own, for a participant that has to hold a transaction open. */
  const connect = async (): Promise<pg.Client> => {
    const c = new pg.Client({ connectionString: url });
    await c.connect();
    return c;
  };

  /**
   * The four things that must be true of the whole table after any interleaving.
   *
   * Stated as a query over everything rather than as assertions about the rows a test happens to
   * know about: a race that corrupts a row nobody thought to look at is exactly the failure mode
   * these are for.
   */
  const assertInvariants = async (): Promise<void> => {
    const stranded = await client.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM sonny.identity i JOIN sonny.account a ON a.id = i.account_id
        WHERE a.deleted_at IS NOT NULL AND NOT i.account_closed`);
    expect(stranded.rows[0]!.n).toBe(0);          // no identity live on a closed account

    const skew = await client.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM sonny.identity i JOIN sonny.account a ON a.id = i.account_id
        WHERE i.account_closed <> (a.deleted_at IS NOT NULL)`);
    expect(skew.rows[0]!.n).toBe(0);              // the flag never disagrees with its account

    const duplicates = await client.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM (
         SELECT provider, subject FROM sonny.identity WHERE NOT account_closed
          GROUP BY provider, subject HAVING count(*) > 1) d`);
    expect(duplicates.rows[0]!.n).toBe(0);        // one live identity per (provider, subject)

    const orphans = await client.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM sonny.identity i
        LEFT JOIN sonny.account a ON a.id = i.account_id WHERE a.id IS NULL`);
    expect(orphans.rows[0]!.n).toBe(0);           // no identity pointing at nothing
  };

  describe("forced ordering A — the close reaches the row first", () => {
    itUnderHangBackstop("makes the resolver block, then land on a NEW account rather than the closing one", async () => {
      const victim = await resolve(client, emailAssertion("orderA@example.com"));
      const closer = await connect();
      const racer = await connect();
      try {
        await closer.query("BEGIN");
        // Marks every identity on the account at statement end, taking their row locks and holding
        // them until this transaction ends.
        await closer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [victim.accountId]);

        let settled = false;
        const racing = resolve(racer, emailAssertion("orderA@example.com"))
          .then((value) => { settled = true; return value; });
        await new Promise((r) => setTimeout(r, 200));

        // **The ordering proof.** Rule 1 found the identity — the close is uncommitted, so it is
        // still visible — and its `UPDATE … WHERE NOT account_closed` is blocked on the trigger's
        // row lock. If this were false the test below would be asserting the outcome of an
        // interleaving that never happened, which is the failure this whole file is built against.
        expect(settled).toBe(false);

        await closer.query("COMMIT");
        const result = await racing;

        // **Only reachable under THIS ordering.** The resolver woke, found its row marked, restarted
        // and got its own account. Under ordering B it would have landed on the original.
        expect(result.created).toBe(true);
        expect(result.accountId).not.toBe(victim.accountId);
      } finally {
        await closer.end();
        await racer.end();
      }
      await assertInvariants();
    });
  });

  describe("forced ordering B — a writer holds the account before the close reaches it", () => {
    itUnderHangBackstop("makes the CLOSE block, and the identity it gains is still marked", async () => {
      // `linkExplicitly` takes `SELECT … FOR SHARE` on its target account, which conflicts with the
      // `FOR NO KEY UPDATE` a close takes. This is the mirror of ordering A: the same two statements,
      // the other one first, and an outcome that ordering A cannot produce.
      const home = await resolve(client, emailAssertion("orderB-home@example.com"));
      const moving = await resolve(client, emailAssertion("orderB-moving@example.com"));

      const linker = await connect();
      const closer = await connect();
      try {
        await linker.query("BEGIN");
        await linker.query(
          "SELECT 1 FROM sonny.account WHERE id = $1 AND deleted_at IS NULL FOR SHARE",
          [home.accountId],
        );

        let closeSettled = false;
        const closing = closer
          .query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [home.accountId])
          .then(() => { closeSettled = true; });
        await new Promise((r) => setTimeout(r, 200));

        // **The ordering proof, from the other side.** The close is waiting on the linker's share
        // lock. In ordering A nothing was holding one and the close never waited.
        expect(closeSettled).toBe(false);

        // The linker completes its move while the close waits, then releases.
        await linker.query(
          `UPDATE sonny.identity i SET account_id = $2, link_method = 'explicit', linked_at = now()
            WHERE i.id = $1 AND NOT i.account_closed`,
          [moving.identityId, home.accountId],
        );
        await linker.query("COMMIT");
        await closing;

        // **Only reachable under THIS ordering.** The identity joined the account *before* the close
        // took effect, so the close's trigger marks it along with the rest. Under ordering A the
        // move would have been refused outright, because the target was already closed.
        const { rows } = await client.query(
          "SELECT account_id, account_closed FROM sonny.identity WHERE id = $1", [moving.identityId],
        );
        expect(rows[0].account_id).toBe(home.accountId);
        expect(rows[0].account_closed).toBe(true);
      } finally {
        await linker.end();
        await closer.end();
      }
      await assertInvariants();
    });
  });

  describe("linkExplicitly's own account lock, called as a function", () => {
    itUnderHangBackstop("BLOCKS on a concurrent close rather than moving onto a closing account", async () => {
      // **PR #87 fifth round, F5.** Deleting `resolve()`'s `FOR SHARE` was justified — and proved
      // correct by instrumentation — on the grounds that "the same lock, for the same reason, is
      // still taken by `linkExplicitly`". That concentrated the guarantee into one call site, and
      // removing `FOR SHARE` from that site left the suite green: the round's own justification was
      // unguarded against a one-word edit.
      //
      // **"Forced ordering B" below is the test people assume covers this, and it does not** — it
      // hand-rolls the same SQL on a raw connection and never calls the function, so it tests
      // Postgres' lock behaviour, which is not the thing that can regress. This one calls
      // `linkExplicitly` itself.
      const home = await resolve(client, emailAssertion("f5-home@example.com"));
      const moving = await resolve(client, emailAssertion("f5-moving@example.com"));

      const closer = await connect();
      const linker = await connect();
      try {
        await closer.query("BEGIN");
        // Takes FOR NO KEY UPDATE on the target account and holds it.
        await closer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [home.accountId]);

        let settled = false;
        const linking = linkExplicitly(
          linker, moving.identityId, home.accountId, home.accountId, moving.identityId,
        ).then(() => { settled = true; }, (error: unknown) => { settled = true; return error; });

        await new Promise((r) => setTimeout(r, 200));
        // **The assertion the guarantee rests on.** Without the `FOR SHARE`, `linkExplicitly`'s
        // existence check reads the pre-close snapshot, sees a live account, and proceeds straight
        // to the move — it does not wait, and it lands an identity on an account that is closing.
        expect(settled).toBe(false);

        await closer.query("COMMIT");
        const outcome = await linking;

        // It woke, re-read, and refused: a deleted account must never gain identities.
        expect(outcome).toBeInstanceOf(LinkError);
        const { rows } = await client.query(
          "SELECT account_id FROM sonny.identity WHERE id = $1", [moving.identityId]);
        expect(rows[0].account_id).toBe(moving.accountId);   // did not move
      } finally {
        await closer.end();
        await linker.end();
      }
      await assertInvariants();
    });
  });

  describe("forced ordering C — an identity moves OFF a closed account", () => {
    itUnderHangBackstop("recomputes the flag, which the ad-hoc battery never once reached", async () => {
      // **This is the state the previous round's battery could not produce.** Every path it drove
      // linked onto the *closing* account, and the account lock refuses those — so it re-proved the
      // lock and never touched the trigger this case is about. The direction that matters is a row
      // leaving a closed account, and no lock is involved: it is the derive trigger or nothing.
      const live = await resolve(client, emailAssertion("orderC-live@example.com"));
      const doomed = await resolve(client, emailAssertion("orderC-doomed@example.com"));
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [doomed.accountId]);
      expect((await client.query(
        "SELECT account_closed FROM sonny.identity WHERE id = $1", [doomed.identityId],
      )).rows[0].account_closed).toBe(true);

      // Raw SQL, because `linkExplicitly` refuses this outright now — the trigger is the guard being
      // exercised here, and it has to hold for statements that never go through that function.
      await client.query("UPDATE sonny.identity SET account_id = $2 WHERE id = $1",
        [doomed.identityId, live.accountId]);

      const { rows } = await client.query(
        "SELECT account_closed FROM sonny.identity WHERE id = $1", [doomed.identityId]);
      expect(rows[0].account_closed).toBe(false);
      await assertInvariants();
    });
  });

  describe("the randomized pass, which alternates by construction rather than by luck", () => {
    // **A chosen deadline, and connections opened once rather than per round.** The first version
    // opened two connections inside the loop and ran just under Vitest's 5s default — which is a
    // flaky test, and a flaky race test is worse than no race test: it teaches everyone to re-run.
    // Connection setup dominated the round; the interleaving is what costs milliseconds. The
    // deadline was a hand-written `{ timeout: 60_000 }` until SONNY-354; it is the backstop's now,
    // which is the same sixty seconds with a message a battery is told not to read as a kill.
    itUnderHangBackstop("holds every invariant across both orderings, and OBSERVES both", async () => {
      // The ad-hoc version left this to timing and got one ordering every time. Here the round
      // number decides who starts first, so both are reached by construction — and the assertion at
      // the end proves they were, which is what stops this becoming one-sided without anyone
      // noticing. The jitter varies the interleaving *within* each side; it is not what provides
      // coverage.
      const ROUNDS = 24;
      const observed = new Set<string>();
      const closer = await connect();
      const racer = await connect();
      try {

      for (let round = 0; round < ROUNDS; round += 1) {
        const address = `fuzz${round}@example.com`;
        const seed = await resolve(client, emailAssertion(address));
        {
          // Deterministic alternation, jittered delay. `round % 7` rather than a random number so a
          // failure is reproducible from its round index alone.
          const closeFirst = round % 2 === 0;
          const jitter = (round % 7) * 5;

          const close = async (): Promise<void> => {
            await new Promise((r) => setTimeout(r, closeFirst ? 0 : jitter + 20));
            await closer.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [seed.accountId]);
          };
          const sign = async (): Promise<string> => {
            await new Promise((r) => setTimeout(r, closeFirst ? jitter + 20 : 0));
            const result = await resolve(racer, emailAssertion(address));
            return result.created ? "new-account" : "same-account";
          };

          const [, outcome] = await Promise.all([close(), sign()]);
          observed.add(outcome);
        }
        await assertInvariants();

        // The address is usable afterwards, exactly once, whichever way the round went.
        await resolve(client, emailAssertion(address));
        const live = await client.query<{ n: number }>(
          "SELECT count(*)::int AS n FROM sonny.identity WHERE subject = $1 AND NOT account_closed",
          [normalizeEmail(address)]);
        expect(live.rows[0]!.n).toBe(1);
      }

      } finally {
        await closer.end();
        await racer.end();
      }

      // **The vacuity assertion.** A pass that only ever produced one outcome tells you nothing
      // about the other branch, and reads identically to one that covered both. If this ever fails,
      // the battery has stopped exercising what its name claims and the fix is the interleaving,
      // never the assertion.
      expect([...observed].sort()).toEqual(["new-account", "same-account"]);
    });
  });

  // **A marker test used to sit here and it asserted `expect(true).toBe(true)`** (PR #87 fifth
  // round, F10). It was honestly labelled as documentation, and it was still a passing test counted
  // in this suite's total — in a file whose entire subject is that a green result can mean nothing.
  // The note it carried belongs in prose, so here it is, and the count is one smaller:
  //
  // **Proving these tests can fail is not executable from inside them.** The forced-ordering cases
  // are killed by mutating the migrations, which cannot be done by the suite that applies them —
  // and doing it by hand needs a *fresh* database, because `up()` skips a migration already in the
  // ledger, so a mutant left in the file never runs and the suite passes for the wrong reason. That
  // is a real trap and it caught this round once. `docs/sonny-v1-implementation-changelog.md`
  // carries which mutant killed which test, at the SHA it was run.
});
