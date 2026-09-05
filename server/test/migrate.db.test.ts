import pg from "pg";
import { describe, expect } from "vitest";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rateLimitEmailKey } from "../src/auth/identity.js";
import { down, loadMigrations, up } from "../src/db/migrate.js";
import { dropSchema } from "./support/schema.js";
import { afterAllUnderHangBackstop, afterEachUnderHangBackstop, beforeAllUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";
import { settling } from "./support/settling.js";

/**
 * Migration tests need a real Postgres, because what they check — a transaction per migration, a
 * ledger that stays in step with the schema — is Postgres behaviour rather than TypeScript
 * behaviour. A mock would prove nothing.
 *
 * They skip when DATABASE_URL is unset so `npm test` stays dependency-free by default, and
 * `npm run test:db` (README) supplies one. **The skip is announced by `test/global-setup.ts`**,
 * which writes before the reporter owns the terminal -- a `console.warn` at module scope in an
 * all-skipped file is swallowed, which is how three documents came to claim a loudness the run
 * did not have.
 *
 * Everything here needs a database. The runner's file-level guarantees -- the rollback-or-refuse
 * rule above all -- live in `migrate.load.test.ts` and run unconditionally, because a guarantee
 * that only runs when someone starts a container is not a guarantee.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

describeDb("migrations against a real Postgres", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    // Start from nothing so the run is repeatable rather than dependent on what ran before it.
    await dropSchema(client);
  });

  /**
   * **Every test's work is tracked, and this hook is what makes that mean something** (SONNY-357).
   *
   * The two rollback loops below walk the whole migration chain a migration at a time. When a
   * deadline fires — vitest's, or the hang backstop's — the test is failed and the runner moves on,
   * and nothing stops the loop: it keeps issuing `down()` against the `client` every test in this
   * file shares, so the next test's `up()` races a rollback still in flight and reports a schema
   * error describing a state the tree never had. One slow test then produces one failure plus an
   * unpredictable set of downstream ones, none of whose messages point at the cause.
   *
   * vitest runs and awaits `afterEach` after a timed-out test, so aborting and draining here is the
   * one place that guarantee can be made. `test/support/settling.ts` holds the mechanism, the reason
   * a private connection was considered and rejected, and what is left over.
   *
   * The deadline is `afterEachUnderHangBackstop`'s, which is the one every hook and every test in
   * this file waits under. Reaching it means Postgres stopped answering a single-statement
   * rollback, which is a broken database rather than a slow test — and it fails loudly here,
   * naming this file and in wording a battery is told not to read as a kill, instead of quietly
   * downstream. It was a hand-written `VITEST_TIMEOUT_MS` on this one hook until PR #172's cycle 2
   * (F4), which chose the number and left the message vitest's own.
   */
  const inFlight = settling();
  afterEachUnderHangBackstop(async () => {
    await inFlight.settle();
  });

  afterAllUnderHangBackstop(async () => {
    await client.end();
  });

  itUnderHangBackstop("applies pending migrations and records them", async () => {
    await inFlight.track(async () => {
      const ran = await up(client);
      expect(ran).toContain("0001_schema_baseline");
      const { rows } = await client.query(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'sonny'",
      );
      expect(rows).toHaveLength(1);
    });
  });

  itUnderHangBackstop("is idempotent — a second run applies nothing", async () => {
    await inFlight.track(async () => {
      const ran = await up(client);
      expect(ran).toEqual([]);
    });
  });

  /**
   * Everything the `sonny` schema is made of, as one comparable string.
   *
   * **Naming one migration's observable is what kept going stale** (PR #87 second round). R17 was
   * right that asserting only on the ledger is vacuous — that row disappears whether or not the
   * rollback SQL ran — and fixed it by naming 0004's trigger, which then broke the moment 0005
   * landed and became the newest. A fingerprint asserts the same property without knowing which
   * migration is last: roll back the newest and the schema must *differ*. Triggers, columns and
   * function bodies are all in it, so a migration whose only effect is a `CREATE OR REPLACE
   * FUNCTION` still registers.
   */
  /**
   * Triggers, columns, indexes, functions **and CHECK constraints**.
   *
   * **The last of those was added by SONNY-404, because a migration that moves only a constraint was
   * invisible here.** `0021_a_wipe_leaves_the_account_open` widens one CHECK and adds no column,
   * index, trigger or function, so rolling it back left this fingerprint byte-identical and the
   * assertion below — that a rollback actually changes the schema — failed against a rollback that
   * had worked perfectly. The direction that matters is the other one, though: without this arm a
   * rollback that silently *kept* a constraint reads exactly like one that removed it, and a CHECK
   * is the kind of schema change whose absence stays invisible until a row that should have been
   * refused lands. `0020` moved a CHECK too and passed only because it added columns beside it.
   *
   * `contype = 'c'` is real CHECKs; NOT NULL is not a `pg_constraint` row on this server version, so
   * this adds no noise that would make every column change register twice.
   */
  const schemaFingerprint = async (): Promise<string> => {
    const { rows } = await client.query<{ line: string }>(
      `SELECT line FROM (
         SELECT 'trigger:' || c.relname || '.' || t.tgname AS line
           FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'sonny' AND NOT t.tgisinternal
         UNION ALL
         SELECT 'column:' || table_name || '.' || column_name || ':' || data_type
           FROM information_schema.columns WHERE table_schema = 'sonny'
         UNION ALL
         SELECT 'index:' || indexname || ':' || indexdef
           FROM pg_indexes WHERE schemaname = 'sonny'
         UNION ALL
         SELECT 'function:' || p.proname || ':' || md5(p.prosrc)
           FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'sonny'
         UNION ALL
         SELECT 'check:' || c.conrelid::regclass::text || '.' || c.conname || ':'
                || pg_get_constraintdef(c.oid)
           FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
          WHERE n.nspname = 'sonny' AND c.contype = 'c'
       ) parts ORDER BY line`,
    );
    return rows.map((r) => r.line).join("\n");
  };

  /**
   * The whole-schema fingerprint taken before this file's rollback, so the re-apply test two below
   * can assert the schema came back to **exactly** where it was rather than merely to something
   * that still has a `sonny` schema in it.
   */
  let beforeRollback = "";

  itUnderHangBackstop("rolls the last migration back, undoing its schema change and its ledger row", async () => {
    await inFlight.track(async () => {
      // Rolls back whatever is newest rather than naming a migration: this test outlives every
      // migration added after it, and hardcoding one made it fail the moment 0002 landed.
      const applied = await client.query<{ id: string }>(
        "SELECT id FROM sonny_meta.schema_migration ORDER BY id DESC LIMIT 1",
      );
      const newest = applied.rows[0]!.id;
      const before = await schemaFingerprint();
      beforeRollback = before;
      const rolled = await down(client);
      expect(rolled).toBe(newest);
      // **Assert the schema actually changed, not only the ledger** (PR #87 R17).
      expect(await schemaFingerprint()).not.toBe(before);
      const { rows: ledger } = await client.query(
        "SELECT id FROM sonny_meta.schema_migration WHERE id = $1", [newest],
      );
      expect(ledger).toHaveLength(0);
    });
  });


  itUnderHangBackstop("re-applies cleanly after a rollback, which is what makes staging a rehearsal", async () => {
    await inFlight.track(async () => {
      // The whole reason staging exists per the ticket: a migration is verified there before it
      // touches production. That is only a verification if apply → roll back → apply lands in the
      // same place, so it is asserted rather than assumed.
      // Re-applies whatever the previous test rolled back, and asserts the schema is whole again --
      // named by property rather than by migration id, so this survives every migration added later.
      const ran = await up(client);
      expect(ran.length).toBeGreaterThan(0);
      const { rows } = await client.query(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'sonny'",
      );
      expect(rows).toHaveLength(1);
      // **"Lands in the same place" asserted as an equality** (PR #87 second round). The sentence
      // above is the reason this test exists and "the schema still exists" was all it checked -- a
      // rollback that dropped a trigger and an `up` that forgot to recreate it would both pass. The
      // fingerprint compares every trigger, column, index and function body against the state before
      // the rollback.
      expect(await schemaFingerprint()).toBe(beforeRollback);
    });
  });

  itUnderHangBackstop("reports nothing to roll back once the ledger is empty", async () => {
    await inFlight.track(async (signal) => {
      // Rolls back every applied migration rather than assuming there is one. The bound is the
      // migration count plus slack, so a runner that returned a rolled-back id forever would fail
      // here rather than spin.
      const total = (await loadMigrations()).length;
      for (let i = 0; i < total + 2; i += 1) {
        // The boundary the barrier needs: if this test has ended, stop here rather than keep
        // rolling migrations back against a client the next test is about to use.
        signal.throwIfAborted();
        if ((await down(client)) === undefined) break;
      }
      expect(await down(client)).toBeUndefined();
    });
  });

  itUnderHangBackstop("rolls a failing migration back entirely, leaving neither schema nor ledger row", async () => {
    await inFlight.track(async () => {
      // The per-migration transaction, pinned. A migration whose second statement fails must leave
      // nothing behind from its first -- otherwise a retry meets objects it believes it has not
      // created yet, and the ledger and the schema disagree permanently.
      const dir = await mkdtemp(join(tmpdir(), "sonny-mig-fail-"));
      await writeFile(
        join(dir, "0001_half_fails.sql"),
        "CREATE TABLE public.mig_probe (id int);\nSELECT this_function_does_not_exist();\n" +
          "-- @rollback\nDROP TABLE IF EXISTS public.mig_probe;",
      );
      await expect(up(client, dir)).rejects.toThrow(/0001_half_fails/);

      const { rows: tables } = await client.query(
        "SELECT tablename FROM pg_tables WHERE tablename = 'mig_probe'",
      );
      expect(tables).toHaveLength(0);
      const { rows: ledger } = await client.query(
        "SELECT id FROM sonny_meta.schema_migration WHERE id = '0001_half_fails'",
      );
      expect(ledger).toHaveLength(0);
    });
  });

  itUnderHangBackstop("0007 folds pre-existing plus-tag rows, which a fresh database can never exercise", async () => {
    await inFlight.track(async (signal) => {
      // **PR #87 sixth round — the one real coverage gap the migration-mutant sweep found.** 0007's
      // `UPDATE` rewrites plus-tagged issuance rows onto the folded mailbox key and consumes the
      // losers. It runs on exactly one occasion: the first deployment that already has rows. Every
      // test in this suite starts from an empty database, so the statement was a no-op everywhere and
      // **deleting it outright left the suite at 162/162 green.** It was verified once by hand,
      // against deliberately colliding rows, and that verification existed as prose rather than as a
      // command anyone could re-run.
      //
      // This is that verification, committed. It rolls back to before 0007, seeds the rows a real
      // deployment would have, and applies the migration — which is the only way to reach the
      // statement at all.
      // **Anchored rather than assumed.** This file's tests share one database and run in order, and
      // the one before this leaves the ledger empty — so `down()` here would return `undefined` on its
      // first call and the loop below would be reasoning about a state that is not there.
      await up(client);
      const shipped = (await loadMigrations()).map((m) => m.id);
      const target = shipped[shipped.indexOf("0007_code_liveness_is_keyed_on_the_mailbox") - 1]!;
      for (let i = 0; i < shipped.length; i += 1) {
        // Same boundary as the loop above, and this is the loop SONNY-357 was filed for: it is the
        // long one, and the test it is in is the one whose margin shrinks with every migration.
        signal.throwIfAborted();
        const applied = await client.query<{ id: string }>(
          "SELECT id FROM sonny_meta.schema_migration ORDER BY id DESC LIMIT 1");
        if (applied.rows[0]?.id === target) break;
        expect(await down(client)).toBeDefined();
      }
      // Under 0006 the column still carries its old name, which is itself part of what 0007 changes.
      const seed = async (key: string, minutesAgo: number, consumed = false) => {
        await client.query(
          `INSERT INTO sonny.sign_in_code_issue (email_norm, issued_at, expires_at, source_hash, consumed_at)
           VALUES ($1, now() - make_interval(mins => $2), now() + interval '10 minutes', 'h', $3)`,
          [key, minutesAgo, consumed ? new Date() : null]);
      };
      await client.query("TRUNCATE sonny.sign_in_code_issue");
      await seed("victim@x.com", 3);
      await seed("victim+1@x.com", 2);
      await seed("victim+2@x.com", 1);          // newest of the three — the one that must survive
      await seed("victim+old@x.com", 9, true);  // already consumed, must stay consumed
      await seed("other@x.com", 1);             // a different mailbox, must be untouched
      await seed("+onlytag@x.com", 1);          // empty local part folds to "@x.com", as the fn does
      await seed("weird@b+c.com", 1);           // the plus is in the DOMAIN and must NOT fold

      expect(await up(client)).toContain("0007_code_liveness_is_keyed_on_the_mailbox");

      const { rows } = await client.query<{ mailbox_key: string; live: number; total: number }>(
        `SELECT mailbox_key,
                count(*) FILTER (WHERE consumed_at IS NULL)::int AS live,
                count(*)::int AS total
           FROM sonny.sign_in_code_issue GROUP BY mailbox_key ORDER BY mailbox_key`);
      const byKey = new Map(rows.map((r) => [r.mailbox_key, r]));

      // The three variants plus the already-consumed one collapsed to ONE key, with exactly one live.
      expect(byKey.get("victim@x.com")).toEqual({ mailbox_key: "victim@x.com", live: 1, total: 4 });
      // ...and the survivor is the NEWEST, which is the rule the fold has to preserve.
      const survivor = await client.query<{ issued_at: Date }>(
        `SELECT issued_at FROM sonny.sign_in_code_issue
          WHERE mailbox_key = 'victim@x.com' AND consumed_at IS NULL`);
      const newest = await client.query<{ issued_at: Date }>(
        `SELECT issued_at FROM sonny.sign_in_code_issue
          WHERE mailbox_key = 'victim@x.com' ORDER BY issued_at DESC LIMIT 1`);
      expect(survivor.rows[0]!.issued_at).toEqual(newest.rows[0]!.issued_at);

      // Untouched neighbours: a different mailbox, and a plus that is in the domain rather than the
      // local part — `rateLimitEmailKey` does not fold that one and neither may the migration.
      expect(byKey.get("other@x.com")).toEqual({ mailbox_key: "other@x.com", live: 1, total: 1 });
      expect(byKey.get("weird@b+c.com")).toEqual({ mailbox_key: "weird@b+c.com", live: 1, total: 1 });
      // An empty local part folds to the bare domain, exactly as `rateLimitEmailKey` does.
      expect(byKey.get("@x.com")).toEqual({ mailbox_key: "@x.com", live: 1, total: 1 });

      // **The fold agrees with the function it is reproducing**, which is the property that keeps the
      // two from drifting: the migration is SQL and `rateLimitEmailKey` is TypeScript.
      for (const key of ["victim+1@x.com", "victim+2@x.com", "+onlytag@x.com", "weird@b+c.com", "other@x.com"]) {
        expect(byKey.has(rateLimitEmailKey(key))).toBe(true);
      }
      await client.query("TRUNCATE sonny.sign_in_code_issue");
      // **The most expensive test in this file, and the one both of its deadline tickets were
      // filed from.** It rolls every migration above 0006 back one at a time and re-applies them, so
      // its cost is a function of the migration count: **2483 ms of vitest's 5000 ms default at 14
      // migrations**, measured alone against an idle local Postgres
      // (`npx vitest run test/migrate.db.test.ts --reporter=verbose`, SONNY-196/230's branch). A 2x
      // margin that halves every fourteen migrations is not a number to leave implicit, and it is
      // the thinnest margin measured anywhere in the database population — which is the measurement
      // SONNY-354 drew its line from. The deadline is `itUnderHangBackstop`'s now, sixty seconds
      // with a message a battery is told not to read as a kill; it was a hand-written
      // `{ timeout: 60_000 }` before that, which set vitest's ceiling and left its message generic.
      //
      // **What a wider deadline does not fix is what SONNY-357 was filed for**, and it is why the
      // body of this test is inside `inFlight.track`. A deadline that fires fails the test and moves
      // on; it does not cancel the loop above, which keeps issuing `down()` on the `client` this
      // file shares with every test below. So the next `up()` raced a rollback still in flight and
      // reported a schema error describing a state the tree never had — a wrong answer that reads
      // like a real one, which is the class `CLAUDE.md`'s Claims-and-evidence section is about. The
      // `afterEach` at the top of this suite is what ends that: it aborts the loop and waits for the
      // step in flight before the next test starts.
      //
      // **Not attributed to a run that was observed to do this.** One run on SONNY-196/230's branch
      // did show a timeout here followed by two impossible schema errors below, and the cause of
      // that run was another lane's suite writing to the same database (SONNY-352), not the
      // duration. The numbers above are the reason for these changes; that run is not.
    });
  });

  itUnderHangBackstop("indexes supabase_user_id, which the auth gate reads on every protected request", async () => {
    await inFlight.track(async () => {
      // **0010, and the reason it is this branch's rather than a later one's** (PR #104's adversarial
      // review, F4). `accountForSupabaseUser` filters on `i.supabase_user_id`, and SONNY-203 moved
      // that read from `POST /v1/auth/refresh` — about once an hour per user — to every request to
      // every protected route. Unindexed, that was a sequential scan of `sonny.identity` before any
      // handler started.
      //
      // Measured on this branch at 20,000 identities, with `EXPLAIN (ANALYZE, BUFFERS)` over the exact
      // query: **without** the index, `Seq Scan on identity`, `Rows Removed by Filter: 19999`,
      // `Execution Time: 5.889 ms`, 200 executions averaging 2.532 ms; **with** it, `Index Scan using
      // identity_supabase_user_idx`, `Buffers: shared hit=6`, `Execution Time: 0.023 ms`. The
      // migration was applied, rolled back and re-applied, and the plan flipped both ways with it.
      //
      // Existence rather than the plan is asserted here on purpose: a plan test needs tens of
      // thousands of seeded rows to be meaningful, because Postgres correctly sequential-scans a small
      // table whatever indexes exist — so it would either be slow or vacuous. This fails if anyone
      // drops the index, which is the regression worth catching.
      const { rows } = await client.query<{ indexdef: string }>(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        ["sonny", "identity_supabase_user_idx"],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]!.indexdef).toContain("supabase_user_id");
      // NOT unique: the identity model deliberately lets several identities name one Supabase user,
      // which is what makes two `auth.users` rows resolve to one account. A unique index here would
      // refuse the writes the model exists to allow.
      expect(rows[0]!.indexdef).not.toContain("UNIQUE");
    });
  });

  itUnderHangBackstop("keeps its ledger outside public, where Supabase would expose it over HTTP", async () => {
    await inFlight.track(async () => {
      await up(client);
      const { rows } = await client.query(
        "SELECT schemaname FROM pg_tables WHERE tablename = 'schema_migration'",
      );
      expect(rows.map((r: { schemaname: string }) => r.schemaname)).toEqual(["sonny_meta"]);
    });
  });
});
