import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import pg from "pg";

/**
 * Plain-SQL migrations with a forward and a rollback half, applied in one transaction each and
 * recorded in a table this runner owns.
 *
 * **Why plain SQL rather than an ORM's migration DSL.** The schema this row is actually going to
 * build already exists as raw SQL — SONNY-125's spend-cap mechanism turns on `UPDATE … FROM`
 * applying one source row per target row, and on READ COMMITTED re-evaluating a `WHERE` against a
 * concurrently-updated row. Neither is expressible in a DSL, and a generated migration that
 * *looked* equivalent would silently lose the property the whole mechanism rests on. So the
 * migrations are the SQL, reviewable as the SQL.
 *
 * **Every migration must supply a rollback.** The file is split on the `-- @rollback` marker; a
 * file without one is refused at load rather than at 2am. That is what makes the ticket's
 * "applied and rolled back" requirement a property of the system rather than of a lucky migration.
 */

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "migrations");
const ROLLBACK_MARKER = "-- @rollback";

export interface Migration {
  readonly id: string;
  readonly up: string;
  readonly down: string;
}

export async function loadMigrations(dir: string = migrationsDir): Promise<readonly Migration[]> {
  const files = (await readdir(dir)).filter((name) => name.endsWith(".sql")).sort();
  const migrations: Migration[] = [];
  for (const file of files) {
    const text = await readFile(join(dir, file), "utf8");
    const marker = text.indexOf(ROLLBACK_MARKER);
    if (marker === -1) {
      throw new Error(
        `${file} has no "${ROLLBACK_MARKER}" section. Every migration needs a rollback; add one, ` +
          `even if it is a comment explaining why the change cannot be undone.`,
      );
    }
    migrations.push({
      id: file.replace(/\.sql$/, ""),
      up: text.slice(0, marker).trim(),
      down: text.slice(marker + ROLLBACK_MARKER.length).trim(),
    });
  }
  return migrations;
}

/**
 * The ledger's own schema, and it is deliberately neither `public` nor `sonny`.
 *
 * **Not `public`:** Postgres defaults an unqualified `CREATE TABLE` there, and on Supabase `public`
 * is the schema PostgREST exposes over HTTP. A table created there with no row-level security is
 * readable by anyone holding the anon key -- which is a publishable, client-side key. The ledger is
 * not secret in the sense a credential is, but it is an inventory of every schema change and its
 * timing, and it has no reason to be on the internet. 0001's own header already argues against
 * putting this row's tables in `public`; the ledger was the one table that ignored it.
 *
 * **Not `sonny` either:** that schema's rollback is `DROP SCHEMA sonny CASCADE`, so a ledger living
 * inside it would be destroyed by the very rollback whose completion it has to record. Rolling back
 * the baseline would take the record of the baseline with it, and the next `up` would replay a
 * migration it had already partly applied.
 */
const LEDGER = `
  CREATE SCHEMA IF NOT EXISTS sonny_meta;
  CREATE TABLE IF NOT EXISTS sonny_meta.schema_migration (
    id          text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
  )`;

async function applied(client: pg.Client): Promise<Set<string>> {
  await client.query(LEDGER);
  const { rows } = await client.query<{ id: string }>("SELECT id FROM sonny_meta.schema_migration");
  return new Set(rows.map((row) => row.id));
}

/** Applies every migration not yet recorded, oldest first. Returns the ids it applied. */
export async function up(client: pg.Client, dir?: string): Promise<readonly string[]> {
  const done = await applied(client);
  const pending = (await loadMigrations(dir)).filter((m) => !done.has(m.id));
  const ran: string[] = [];
  for (const migration of pending) {
    // One transaction per migration: a failure leaves the ledger and the schema agreeing, rather
    // than half a migration applied and unrecorded.
    await client.query("BEGIN");
    try {
      await client.query(migration.up);
      await client.query("INSERT INTO sonny_meta.schema_migration (id) VALUES ($1)", [migration.id]);
      await client.query("COMMIT");
      ran.push(migration.id);
    } catch (error) {
      await client.query("ROLLBACK");
      throw new Error(`migration ${migration.id} failed and was rolled back: ${String(error)}`);
    }
  }
  return ran;
}

/** Rolls back the most recently applied migration. Returns its id, or undefined if none. */
export async function down(client: pg.Client, dir?: string): Promise<string | undefined> {
  const done = await applied(client);
  const migrations = await loadMigrations(dir);
  const last = [...migrations].reverse().find((m) => done.has(m.id));
  if (!last) return undefined;
  await client.query("BEGIN");
  try {
    await client.query(last.down);
    await client.query("DELETE FROM sonny_meta.schema_migration WHERE id = $1", [last.id]);
    await client.query("COMMIT");
    return last.id;
  } catch (error) {
    await client.query("ROLLBACK");
    throw new Error(`rollback of ${last.id} failed and was itself rolled back: ${String(error)}`);
  }
}

async function main(): Promise<void> {
  const command = process.argv[2] ?? "up";
  const url = process.env["DATABASE_URL"];
  if (!url) {
    process.stderr.write("DATABASE_URL is not set\n");
    process.exit(78);
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    if (command === "up") {
      const ran = await up(client);
      process.stdout.write(ran.length ? `applied: ${ran.join(", ")}\n` : "nothing to apply\n");
    } else if (command === "down") {
      const rolled = await down(client);
      process.stdout.write(rolled ? `rolled back: ${rolled}\n` : "nothing to roll back\n");
    } else if (command === "status") {
      const done = await applied(client);
      for (const migration of await loadMigrations()) {
        process.stdout.write(`${done.has(migration.id) ? "applied" : "pending"}  ${migration.id}\n`);
      }
    } else {
      process.stderr.write(`unknown command "${command}" -- expected up, down or status\n`);
      process.exit(2);
    }
  } finally {
    await client.end();
  }
}

// Only run as a CLI, never on import -- the tests import `up` and `down` directly.
//
// **`pathToFileURL` rather than a template string, and the difference is a silent no-op.**
// `file://${process.argv[1]}` leaves the path unencoded, while `import.meta.url` percent-encodes
// it. Any character that differs between the two forms -- a space is the common one, and this
// repository's own checkouts live under paths containing them -- makes the comparison false, so
// `npm run migrate` would exit 0 having done nothing at all. A migration tool that reports success
// without migrating is the worst shape a failure can take here.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
