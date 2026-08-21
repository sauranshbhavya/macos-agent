import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

  it("rolls the last migration back, undoing its schema change and its ledger row", async () => {
    // Rolls back whatever is newest rather than naming a migration: this test outlives every
    // migration added after it, and hardcoding one made it fail the moment 0002 landed.
    const applied = await client.query<{ id: string }>(
      "SELECT id FROM sonny_meta.schema_migration ORDER BY id DESC LIMIT 1",
    );
    const newest = applied.rows[0]!.id;
    const rolled = await down(client);
    expect(rolled).toBe(newest);
    // **Assert the schema actually changed, not only the ledger** (PR #87 R17). Generalising this
    // test past a single migration dropped its schema assertion, leaving it checking that a row
    // disappeared from a table the runner itself writes -- which happens whether or not the
    // rollback SQL ran at all. 0004's trigger is the observable thing its rollback removes.
    const { rows: triggers } = await client.query(
      "SELECT tgname FROM pg_trigger WHERE tgname = 'account_close_marks_identities' AND NOT tgisinternal",
    );
    expect(triggers).toHaveLength(0);
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

  it("keeps its ledger outside public, where Supabase would expose it over HTTP", async () => {
    await up(client);
    const { rows } = await client.query(
      "SELECT schemaname FROM pg_tables WHERE tablename = 'schema_migration'",
    );
    expect(rows.map((r: { schemaname: string }) => r.schemaname)).toEqual(["sonny_meta"]);
  });
});
