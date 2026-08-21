import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { down, loadMigrations, up } from "../src/db/migrate.js";

/**
 * Migration tests need a real Postgres, because what they check — a transaction per migration, a
 * ledger that stays in step with the schema — is Postgres behaviour rather than TypeScript
 * behaviour. A mock would prove nothing.
 *
 * They skip when DATABASE_URL is unset so `npm test` stays dependency-free by default, and
 * `npm run test:db` (README) supplies one. **Skipping is reported, not silent**: a suite that
 * quietly runs zero tests looks exactly like a suite that passed.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

if (!url) {
  console.warn(
    "\n  migrate.test.ts SKIPPED — DATABASE_URL unset. These are the only tests that touch a" +
      "\n  database; see server/README.md for the one-line container that runs them.\n",
  );
}

describeDb("migrations against a real Postgres", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    // Start from nothing so the run is repeatable rather than dependent on what ran before it.
    await client.query("DROP SCHEMA IF EXISTS sonny CASCADE");
    await client.query("DROP TABLE IF EXISTS schema_migration");
  });

  afterAll(async () => {
    await client.end();
  });

  it("refuses a migration that has no rollback half", async () => {
    // The property that makes "applied and rolled back" a guarantee rather than a coincidence.
    const { mkdtemp, writeFile } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = await mkdtemp(join(tmpdir(), "sonny-mig-"));
    await writeFile(join(dir, "0001_no_rollback.sql"), "CREATE TABLE t (id int);");
    await expect(loadMigrations(dir)).rejects.toThrow(/@rollback/);
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
    const rolled = await down(client);
    expect(rolled).toBe("0001_schema_baseline");
    const { rows: schemas } = await client.query(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'sonny'",
    );
    expect(schemas).toHaveLength(0);
    const { rows: ledger } = await client.query("SELECT id FROM schema_migration");
    expect(ledger).toHaveLength(0);
  });

  it("re-applies cleanly after a rollback, which is what makes staging a rehearsal", async () => {
    // The whole reason staging exists per the ticket: a migration is verified there before it
    // touches production. That is only a verification if apply → roll back → apply lands in the
    // same place, so it is asserted rather than assumed.
    const ran = await up(client);
    expect(ran).toContain("0001_schema_baseline");
    const { rows } = await client.query(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'sonny'",
    );
    expect(rows).toHaveLength(1);
  });

  it("reports nothing to roll back once the ledger is empty", async () => {
    await down(client);
    expect(await down(client)).toBeUndefined();
  });
});
