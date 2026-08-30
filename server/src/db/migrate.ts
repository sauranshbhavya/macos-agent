import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import pg from "pg";
import { migrationContentHash } from "./migration-hash.js";

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
 *
 * **Every applied migration is recorded with a hash of its executable SQL, and a later run refuses
 * to proceed past a file that has changed** (SONNY-364). The ledger used to hold the id alone, so
 * "0014 applied" was true and said nothing about *which* 0014 — two deployments could report the
 * same ids and hold different schemas, with `status` calling them identical. What the hash covers
 * and, more to the point, what it deliberately ignores, is in `migration-hash.ts`: comments and
 * layout are stripped so that annotating an applied migration stays legal, which is a practice this
 * repository relies on.
 */

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "migrations");
const ROLLBACK_MARKER = "-- @rollback";

export interface Migration {
  readonly id: string;
  readonly up: string;
  readonly down: string;
  /** Over both halves' executable SQL. Computed at load so no caller can forget to record it. */
  readonly contentHash: string;
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
    const up = text.slice(0, marker).trim();
    const down = text.slice(marker + ROLLBACK_MARKER.length).trim();
    migrations.push({
      id: file.replace(/\.sql$/, ""),
      up,
      down,
      contentHash: migrationContentHash(up, down),
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
    id           text PRIMARY KEY,
    applied_at   timestamptz NOT NULL DEFAULT now(),
    content_hash text
  );
  ALTER TABLE sonny_meta.schema_migration ADD COLUMN IF NOT EXISTS content_hash text`;

/**
 * Every applied id, mapped to the content hash recorded when it was applied — or `null`.
 *
 * **`null` means "unknown", and it is never treated as a match** (SONNY-364). The column is nullable
 * and the `ALTER` above is what an existing database gets, so every row written before this landed
 * carries no hash. Backfilling those from today's files was the alternative and it is a lie about
 * when the measurement was taken: it would write the current text's hash against a row recording an
 * apply that happened months earlier, and the guard would then report a match on a comparison it
 * never made. That is precisely the shape this repository keeps recording — a check that reports
 * success about a question nobody asked — so an absent hash is carried as unknown, reported as
 * unverified by `status`, and compared against nothing.
 *
 * A row clears itself out of that state the next time its migration is rolled back and re-applied,
 * which is a real operation with real cost and is the honest price. No `adopt` command exists to
 * stamp a hash onto an existing row on an operator's say-so: an adopted hash and an observed one
 * would be indistinguishable in the ledger, which puts the guard back where it started.
 */
async function applied(client: pg.Client): Promise<Map<string, string | null>> {
  await client.query(LEDGER);
  const { rows } = await client.query<{ id: string; content_hash: string | null }>(
    "SELECT id, content_hash FROM sonny_meta.schema_migration",
  );
  return new Map(rows.map((row) => [row.id, row.content_hash]));
}

/** An applied migration whose file no longer produces the SQL that was recorded against it. */
export interface MigrationDrift {
  readonly id: string;
  /** The hash recorded when this environment applied the migration. */
  readonly recorded: string;
  /** What the file on disk hashes to now. */
  readonly found: string;
}

/**
 * Every applied migration whose file disagrees with what was recorded, in file order.
 *
 * Only the intersection is compared, and both exclusions matter. A migration with **no ledger row**
 * is pending, and pending is what `up` is for. A migration with **no file** cannot be hashed, so
 * there is nothing to compare it against — that is a real second hazard and deliberately not this
 * one; it is recorded on SONNY-364 rather than half-built here. The exclusion is also what lets a
 * caller run `up(client, someOtherDir)` against a database holding the real migrations, which is how
 * three existing tests apply throwaway migrations.
 */
export function driftedMigrations(
  recorded: ReadonlyMap<string, string | null>,
  migrations: readonly Migration[],
): readonly MigrationDrift[] {
  const drift: MigrationDrift[] = [];
  for (const migration of migrations) {
    if (!recorded.has(migration.id)) continue;
    const was = recorded.get(migration.id);
    if (was === null || was === undefined) continue;
    if (was !== migration.contentHash) {
      drift.push({ id: migration.id, recorded: was, found: migration.contentHash });
    }
  }
  return drift;
}

/**
 * What `up` and `down` throw when the files disagree with the ledger.
 *
 * A named type rather than a bare `Error` for one reason: the CLI below catches it and prints the
 * message alone. Everything else this runner throws is a fault — a migration that failed, a database
 * that would not answer — and a stack trace is the right output for those. This one is not a fault,
 * it is a finding, addressed to a person who now has to decide what to do about a database that does
 * not match its files. Left uncaught it arrived as a Node crash dump with the source line echoed
 * above the message and four stack frames below it, which buries the one paragraph worth reading.
 */
export class MigrationDriftError extends Error {
  readonly drift: readonly MigrationDrift[];
  constructor(drift: readonly MigrationDrift[]) {
    const one = drift.length === 1;
    const each = drift
      .map((d) => `  ${d.id}: applied ${d.recorded.slice(0, 12)}…, file now ${d.found.slice(0, 12)}…`)
      .join("\n");
    super(
      `${drift.length} applied migration${one ? "" : "s"} no longer ${one ? "matches" : "match"} ` +
        `the file${one ? "" : "s"} that applied ${one ? "it" : "them"}:\n${each}\n` +
        `This database was built by SQL ${one ? "that file no longer describes" : "those files no longer describe"}, ` +
        `so nothing further is applied or rolled back. Restore the file to the revision this ` +
        `environment ran (git), or — if the change is intended — ship it as a NEW migration, which ` +
        `is the only way every environment gets it. Comments and layout are not hashed, so this is ` +
        `a change to the executable SQL.`,
    );
    this.name = "MigrationDriftError";
    this.drift = drift;
  }
}

/**
 * Refuses rather than reports, and refuses **before** anything is applied or rolled back.
 *
 * The database in front of this runner was built by SQL the files no longer describe. Applying the
 * next migration on top of it would build a schema no other environment has, and rolling one back
 * would run a `down` that was never paired with the `up` that ran here — so both doors are shut and
 * the way out is to restore the file, which `git` can do and this runner cannot.
 */
function refuseOnDrift(drift: readonly MigrationDrift[]): void {
  if (drift.length === 0) return;
  throw new MigrationDriftError(drift);
}

/** Applies every migration not yet recorded, oldest first. Returns the ids it applied. */
export async function up(client: pg.Client, dir?: string): Promise<readonly string[]> {
  const recorded = await applied(client);
  const migrations = await loadMigrations(dir);
  // Before anything is applied: a schema built by SQL that no longer exists is not a base to build
  // the next migration on.
  refuseOnDrift(driftedMigrations(recorded, migrations));
  const pending = migrations.filter((m) => !recorded.has(m.id));
  const ran: string[] = [];
  for (const migration of pending) {
    // One transaction per migration: a failure leaves the ledger and the schema agreeing, rather
    // than half a migration applied and unrecorded.
    await client.query("BEGIN");
    try {
      await client.query(migration.up);
      // The hash goes in inside the same transaction as the SQL it describes, so a ledger row can
      // never exist without one, nor name a different text than the one that just ran.
      await client.query(
        "INSERT INTO sonny_meta.schema_migration (id, content_hash) VALUES ($1, $2)",
        [migration.id, migration.contentHash],
      );
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
  const recorded = await applied(client);
  const migrations = await loadMigrations(dir);
  // A rollback is the half most likely to be edited after the fact, and running a `down` that was
  // never paired with the `up` this database ran is how a rehearsal stops being one.
  refuseOnDrift(driftedMigrations(recorded, migrations));
  const last = [...migrations].reverse().find((m) => recorded.has(m.id));
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

/**
 * `EX_DATAERR` from sysexits, and the same code from all three commands so a caller can act on it
 * without knowing which one it ran. The input data — the ledger and the migration files together —
 * is incorrect: they describe different databases. It is deliberately not `EX_CONFIG` (78, which
 * this runner already uses for a missing `DATABASE_URL`) and not `2`, which means the command line
 * was wrong.
 */
const DATA_ERROR = 65;

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
    try {
    if (command === "up") {
      const ran = await up(client);
      process.stdout.write(ran.length ? `applied: ${ran.join(", ")}\n` : "nothing to apply\n");
    } else if (command === "down") {
      const rolled = await down(client);
      process.stdout.write(rolled ? `rolled back: ${rolled}\n` : "nothing to roll back\n");
    } else if (command === "status") {
      // **`status` reports and never refuses**, which is the opposite of `up` and `down` on purpose:
      // it is the diagnostic an operator reaches for once one of those has refused, and a diagnostic
      // that throws instead of describing the state is no use at the moment it is needed.
      const recorded = await applied(client);
      const migrations = await loadMigrations();
      const drifted = new Set(driftedMigrations(recorded, migrations).map((d) => d.id));
      let changed = 0;
      let unverified = 0;
      for (const migration of migrations) {
        const state = !recorded.has(migration.id)
          ? "pending"
          : drifted.has(migration.id)
            ? "CHANGED"
            : recorded.get(migration.id) === null
              ? "unverified"
              : "applied";
        if (state === "CHANGED") changed += 1;
        if (state === "unverified") unverified += 1;
        process.stdout.write(`${state.padEnd(10)}  ${migration.id}\n`);
      }
      if (changed > 0) {
        process.stderr.write(
          `\n${changed} applied migration${changed === 1 ? " has" : "s have"} changed since ` +
            `${changed === 1 ? "it was" : "they were"} applied. This database was built by SQL its ` +
            `files no longer describe; \`up\` and \`down\` both refuse until the files are restored ` +
            `(git) or the change ships as a new migration.\n`,
        );
        // A status that printed CHANGED and exited 0 is the clean zero this repository keeps
        // recording: a check whose reassuring answer is indistinguishable from a real one.
        process.exitCode = DATA_ERROR;
      }
      if (unverified > 0) {
        process.stderr.write(
          "\nSome migrations show `unverified`: they were applied before this runner recorded a " +
            "content hash, so there is nothing to compare their files against. They are NOT known " +
            "to match — no hash is invented for them, because a backfilled one would claim a " +
            "comparison that never happened. A migration leaves that state the next time it is " +
            "rolled back and re-applied.\n",
        );
      }
    } else {
      process.stderr.write(`unknown command "${command}" -- expected up, down or status\n`);
      process.exit(2);
    }
    } catch (error) {
      // The finding, not the fault: message alone, no stack. Anything else rethrows and keeps the
      // trace, because a migration that failed mid-statement is a fault and the frames are the
      // point.
      if (!(error instanceof MigrationDriftError)) throw error;
      process.stderr.write(`${error.message}\n`);
      process.exitCode = DATA_ERROR;
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
