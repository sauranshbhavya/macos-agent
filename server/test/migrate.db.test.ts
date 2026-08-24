import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rateLimitEmailKey } from "../src/auth/identity.js";
import { down, loadMigrations, up } from "../src/db/migrate.js";

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

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    // Start from nothing so the run is repeatable rather than dependent on what ran before it.
    await client.query("DROP SCHEMA IF EXISTS sonny CASCADE");
    await client.query("DROP SCHEMA IF EXISTS sonny_meta CASCADE");
  });

  afterAll(async () => {
    await client.end();
  });

  it("applies pending migrations and records them", async () => {
    const ran = await up(client);
    expect(ran).toContain("0001_schema_baseline");
    const { rows } = await client.query(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'sonny'",
    );
    expect(rows).toHaveLength(1);
  });

  it("is idempotent — a second run applies nothing", async () => {
    const ran = await up(client);
    expect(ran).toEqual([]);
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

  it("rolls the last migration back, undoing its schema change and its ledger row", async () => {
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


  it("re-applies cleanly after a rollback, which is what makes staging a rehearsal", async () => {
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

  it("reports nothing to roll back once the ledger is empty", async () => {
    // Rolls back every applied migration rather than assuming there is one. The bound is the
    // migration count plus slack, so a runner that returned a rolled-back id forever would fail
    // here rather than spin.
    const total = (await loadMigrations()).length;
    for (let i = 0; i < total + 2; i += 1) {
      if ((await down(client)) === undefined) break;
    }
    expect(await down(client)).toBeUndefined();
  });

  it("rolls a failing migration back entirely, leaving neither schema nor ledger row", async () => {
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

  it("0007 folds pre-existing plus-tag rows, which a fresh database can never exercise", async () => {
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
  });

  it("keeps its ledger outside public, where Supabase would expose it over HTTP", async () => {
    await up(client);
    const { rows } = await client.query(
      "SELECT schemaname FROM pg_tables WHERE tablename = 'schema_migration'",
    );
    expect(rows.map((r: { schemaname: string }) => r.schemaname)).toEqual(["sonny_meta"]);
  });
});
