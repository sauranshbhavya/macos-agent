import pg from "pg";
import { up } from "../../src/db/migrate.js";

/**
 * Where a database test gets its schema, and the reason it may not get one any other way
 * (SONNY-366).
 *
 * **`up()` is a no-op against a database that already has a schema, so a file that only calls it
 * measures the wrong tree.** It applies *pending* migrations — ids absent from
 * `sonny_meta.schema_migration` — and a migration whose text changed in the working tree keeps its
 * id. So a file whose `beforeAll` calls `up(client)` and nothing else runs against whatever schema
 * the previous invocation of the suite left behind, which on a long-lived container is a schema
 * built from migration text that may be weeks old.
 *
 * That is the default workflow rather than a corner case. `npx vitest list --filesOnly` puts
 * `auth.db.test.ts` first of the `.db.test.ts` files and the rebuilders after it, so with one
 * container and repeated `npm run test:db` the first file never once saw a current migration.
 *
 * **Proved with a mutant rather than argued** (PR #167 review, F1): the same test with 0015's
 * `CREATE TRIGGER` deleted reported `1 failed` on a dropped database and `1 passed` on a reused
 * one, with `pg_trigger` showing the real trigger still installed under the mutant. A test that
 * green-lights a schema nobody asked for is the false measurement `CLAUDE.md`'s Claims-and-evidence
 * section is about, and it silently weakened that branch's battery too — R1 came back "KILLED by 3
 * tests" and none of the three was the test the mutant was written for.
 *
 * PR #167 closed it in `auth.db.test.ts` alone. This module is the general form, and it is a module
 * rather than a copied pair of statements because eight copies of a setup is how the ninth arrives
 * without it — which is literally what happened: three files carried the two `DROP SCHEMA` lines and
 * the other nine did not.
 *
 * **The cost was the open question and it is small.** SONNY-366's own comment sized a rebuild at
 * "about 18 s to about 57 s" for the first file and warned that ten of them would push the suite
 * into SONNY-354's timeouts. Measured here instead, three consecutive rebuilds against this
 * repository's 16 migrations on an idle local Postgres in Docker (a throwaway probe calling the two
 * statements and then `up`, at `f55e4ed`): **drop 51/28/21 ms, up 115/100/89 ms** — about 130 ms a
 * rebuild, against a `no-op up` of 3 ms. Ten of those is a little over a second on a suite that runs
 * in 22 s. The 57 s figure is described on the ticket as uncontrolled and does not reproduce:
 * `auth.db.test.ts`, the file that already rebuilds, runs alone in 4.52 s.
 *
 * So no memoisation, no once-per-process fixture, no shared-schema cleverness. Every file rebuilds,
 * every file is independent of what ran before it, and the whole of what that buys costs about a
 * second. A per-process cache would have to know when `migrate.db.test.ts` had left the schema
 * rolled back, which is exactly the sort of implicit ordering coupling this ticket exists to remove.
 */

/**
 * Both schemas gone, so the next `up()` really applies every migration.
 *
 * Two of them, and dropping only `sonny` would be worse than dropping neither: the ledger lives in
 * `sonny_meta` by design (`migrate.ts` says why), so a run that dropped the tables and kept the
 * ledger would have `up()` report nothing pending against a database with no schema at all.
 */
export async function dropSchema(client: pg.Client): Promise<void> {
  await client.query("DROP SCHEMA IF EXISTS sonny CASCADE");
  await client.query("DROP SCHEMA IF EXISTS sonny_meta CASCADE");
}

/**
 * The schema every `.db.test.ts` file starts from: built here, in this process, from the migration
 * text in the working tree.
 *
 * `migrate.db.test.ts` is the one file that calls ``dropSchema`` alone instead — its first test
 * asserts what `up()` applies, which needs an empty database to be a question at all.
 */
export async function rebuildSchema(client: pg.Client): Promise<void> {
  await dropSchema(client);
  await up(client);
}
