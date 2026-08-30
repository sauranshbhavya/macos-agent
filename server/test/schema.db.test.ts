import pg from "pg";
import { afterAll, beforeAll, describe, expect } from "vitest";
import { up } from "../src/db/migrate.js";
import { testDatabaseUrl } from "./support/database.js";
import { dropSchema, rebuildSchema } from "./support/schema.js";
import { itUnderHangBackstop } from "./support/backstop.js";

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

/**
 * What `test/support/schema.ts` actually does to a database, and the defect it exists for, both
 * demonstrated rather than described (SONNY-366).
 *
 * `schema.test.ts` scans the tree and establishes that every database test file names the helper.
 * That is a statement about text and is worth nothing on its own: a helper that had quietly become
 * `await up(client)` again would satisfy every arm of it. This file is the other half — it plants
 * the exact divergence the ticket is about, a schema that disagrees with a full ledger, and shows
 * the helper resolving it and `up()` alone failing to.
 *
 * The second of those is the positive control and the more important one. Without it a reader has no
 * way to tell a helper that rebuilds from a helper that happens to be running against a database
 * that was already correct.
 *
 * **This is one of the four files allowed to import `up` directly**, and it is the same reason
 * `migrate.db.test.ts` is: the runner's behaviour is this file's subject rather than its setup.
 * Asserting `up()` is a no-op without calling `up()` would be a claim about the ledger dressed up as
 * a claim about the runner, and the exemption is what buys the difference.
 */
describeDb("the shared schema rebuild, against a real Postgres", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    await rebuildSchema(client);
  });

  afterAll(async () => {
    // Left whole rather than as this file found it: every `.db.test.ts` file rebuilds in its own
    // `beforeAll` now, so what follows does not depend on this — but a file that ends by deleting a
    // schema is a file somebody will one day debug for an hour.
    await rebuildSchema(client);
    await client.end();
  });

  /** How many of the shipped migrations the ledger claims. */
  const ledgerCount = async (): Promise<number> => {
    const { rows } = await client.query<{ n: string }>(
      "SELECT count(*)::text AS n FROM sonny_meta.schema_migration",
    );
    return Number(rows[0]!.n);
  };

  const identityTableExists = async (): Promise<boolean> => {
    const { rows } = await client.query(
      "SELECT 1 FROM information_schema.tables WHERE table_schema = 'sonny' AND table_name = 'identity'",
    );
    return rows.length === 1;
  };

  itUnderHangBackstop("leaves neither schema behind when it drops", async () => {
    await dropSchema(client);
    const { rows } = await client.query<{ nspname: string }>(
      "SELECT nspname FROM pg_namespace WHERE nspname IN ('sonny', 'sonny_meta') ORDER BY nspname",
    );
    expect(rows.map((r) => r.nspname)).toEqual([]);
    await rebuildSchema(client);
  });

  itUnderHangBackstop("rebuilds a schema that disagrees with a full ledger, which `up()` alone cannot", async () => {
    // The divergence, planted exactly as the defect produces it: the ledger still lists every
    // migration, and the schema no longer matches the text those ids were written from. On a real
    // machine this arrives by editing a migration file rather than by dropping a table, but the
    // state `up()` meets is the same one — every id already recorded.
    const shipped = await ledgerCount();
    expect(shipped).toBeGreaterThan(0);
    await client.query("DROP TABLE sonny.identity CASCADE");
    expect(await identityTableExists()).toBe(false);
    // The ledger is untouched, which is the whole trap: `up()` has nothing pending to apply.
    expect(await ledgerCount()).toBe(shipped);

    // **The positive control, and the defect itself.** `up()` applies only ids the ledger does not
    // already hold, so against this state it applies nothing and reports nothing — and the table it
    // was supposed to guarantee is still gone. That is the whole of SONNY-366 in three lines, and it
    // is what every `beforeAll` in this tree used to do and call setup.
    const appliedByUpAlone = await up(client);
    expect(appliedByUpAlone).toEqual([]);
    expect(await identityTableExists()).toBe(false);
    expect(await ledgerCount()).toBe(shipped);

    await rebuildSchema(client);
    expect(await identityTableExists()).toBe(true);
    expect(await ledgerCount()).toBe(shipped);
  });
});
