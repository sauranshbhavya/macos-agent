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
  )`;

/**
 * Whether the ledger already carries the hash column — asked before the `ALTER` rather than left to
 * `ADD COLUMN IF NOT EXISTS`, because that form is not free when it does nothing (SONNY-364 review).
 *
 * `ALTER TABLE` takes `ACCESS EXCLUSIVE` on the table to evaluate its own `IF NOT EXISTS`, so on
 * every run after the first it queued behind any open ledger writer and then released without
 * changing anything. Re-measured here rather than carried from the review, against one writer
 * holding a ten-second transaction, each runner timed on the same database: read-only `status`
 * takes **0.15 s** with this check, **8.17 s** with the unconditional `ALTER`, and **0.13 s** on the
 * pre-SONNY-364 ledger SQL — so the check restores what the ledger cost before this ticket. With no
 * lock holder at all the three are 0.15 s, 0.13 s and 0.12 s, which is what says the 8.17 s is the
 * lock and not the work. `status` is the command an operator runs to find out what is happening, so
 * it is the last one that should block for eight seconds behind a writer. This catalog read takes
 * `ACCESS SHARE` and conflicts with nothing that matters.
 *
 * The `IF NOT EXISTS` stays on the `ALTER` below even though this check makes it redundant: two
 * runners starting at once can both read "absent", and the second one's bare `ADD COLUMN` would
 * fail. The check removes the lock from the common path; the clause covers the race on the rare one.
 */
const HAS_CONTENT_HASH = `
  SELECT 1 FROM information_schema.columns
   WHERE table_schema = 'sonny_meta' AND table_name = 'schema_migration'
     AND column_name = 'content_hash'`;

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
  // First, and before any lock is taken: if this connection would not lex strings the way the
  // hashes were computed, every comparison below is meaningless and the honest thing is to stop.
  const { rows: settings } = await client.query<{ standard_conforming_strings: string }>(
    "SHOW standard_conforming_strings",
  );
  const setting = settings[0]?.standard_conforming_strings;
  if (setting !== "on") throw new UnsafeStringLexingError(setting ?? "unreadable");
  await client.query(LEDGER);
  const { rowCount } = await client.query(HAS_CONTENT_HASH);
  if (rowCount === 0) {
    await client.query(
      "ALTER TABLE sonny_meta.schema_migration ADD COLUMN IF NOT EXISTS content_hash text",
    );
  }
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
 * The base for every refusal this runner raises about the state it found, as opposed to a fault.
 *
 * The CLI catches this and prints the message alone; anything else keeps its stack, because a
 * migration that failed mid-statement is a fault and the frames are the point.
 */
export abstract class MigrationRefusal extends Error {}

/**
 * Thrown when the connection would not lex a migration's strings the way this runner hashes them.
 *
 * **A detected precondition rather than a written assumption** (SONNY-364 cycle 2). With
 * `standard_conforming_strings = off`, a backslash escapes inside a **plain** `'…'` too — so `\'`
 * does not end the literal, and the lexer, which correctly does not honour backslashes there, stops
 * early exactly as it did for `E'…'` before cycle 1. That is F1 returning through the branch the
 * lexer treats as safe: two `INSERT`s storing different rows collapse to one hash, which is the
 * defect this whole ticket exists to close.
 *
 * **It needs detecting because `DATABASE_URL` alone falsifies it**, with no file this repository
 * controls changed: `?options=-c%20standard_conforming_strings%3Doff` turns it off for the session.
 * The setting has been on by default since Postgres 9.1 and nothing under `server/` sets it, and
 * that is a likelihood argument — which this design refuses everywhere else it matters. The check
 * is one `SHOW` in a function that already runs three queries, and it takes no lock.
 *
 * `EX_CONFIG` rather than `EX_DATAERR`: nothing is wrong with the ledger or the files. The
 * connection is configured in a way this runner cannot work over, and the fix is in the connection.
 */
export class UnsafeStringLexingError extends MigrationRefusal {
  constructor(setting: string) {
    super(
      `this connection has standard_conforming_strings = ${setting}, and every migration hash ` +
        `assumes "on".\n` +
        `With it off a backslash escapes inside an ordinary '…' string, so two migrations that ` +
        `store different rows can hash the same and a changed migration would be applied in ` +
        `silence — the exact failure the hash exists to catch.\n` +
        `Nothing under server/ sets it, so look at DATABASE_URL: a connection string may carry ` +
        `?options=-c%20standard_conforming_strings%3Doff. Remove it and re-run.`,
    );
    this.name = "UnsafeStringLexingError";
  }
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
export class MigrationDriftError extends MigrationRefusal {
  /**
   * **Every clause of this message has to be true in every case that reaches it** (SONNY-364 review,
   * F2). It used to end "Comments and layout are not hashed, so this is a change to the executable
   * SQL", which is false for the one edit most likely to produce a surprising refusal: a line of
   * prose inside a `$$ … $$` function body IS hashed, correctly, because Postgres stores it in
   * `pg_proc.prosrc`. The refusal was right and the sentence beneath it sent the reader hunting for
   * a schema change that was not there. This message is read exactly once, under pressure, by
   * somebody whose deploy has just stopped.
   */
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
        `is the only way every environment gets it. Comments and layout OUTSIDE string literals are ` +
        `not hashed, so what moved is text Postgres keeps — a statement, or the body of a function, ` +
        `where a comment line is stored in pg_proc.prosrc and counts as a change like any other.`,
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

/** What `status` says about one migration. `CHANGED` is upper-case because it is the one that acts. */
export type MigrationState = "applied" | "pending" | "CHANGED" | "unverified";

/**
 * What `status` reports, as data rather than as writes to stdout.
 *
 * Split out of the CLI so the classification can be tested at all: `main` is only reachable by
 * spawning a built `dist/db/migrate.js`, and a suite that runs from source cannot do that without
 * making itself depend on a prior `npm run build`. The one line this leaves untestable is the
 * `process.exitCode` assignment, which is why the count comes back rather than a boolean — a
 * `changed` of zero on a drifted ledger is the failure worth catching, and it is catchable here.
 */
export function migrationStates(
  recorded: ReadonlyMap<string, string | null>,
  migrations: readonly Migration[],
): readonly { readonly id: string; readonly state: MigrationState }[] {
  const drifted = new Set(driftedMigrations(recorded, migrations).map((d) => d.id));
  return migrations.map((migration) => ({
    id: migration.id,
    state: !recorded.has(migration.id)
      ? "pending"
      : drifted.has(migration.id)
        ? "CHANGED"
        : recorded.get(migration.id) === null
          ? "unverified"
          : "applied",
  }));
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

/**
 * `EX_CONFIG` from sysexits, already what this runner exits when `DATABASE_URL` is missing. It is
 * also what an unsafe `standard_conforming_strings` exits with, and for the same reason: the
 * problem is in how the process was pointed at its database, not in the database's contents.
 */
const CONFIG_ERROR = 78;

/**
 * Where a command's writes go. Injected so the whole dispatch can be exercised from the suite — the
 * alternative is spawning a built `dist/db/migrate.js`, which couples the tests to a prior
 * `npm run build`.
 */
export interface CommandOutput {
  readonly out: (text: string) => void;
  readonly err: (text: string) => void;
}

/**
 * Runs one command and returns the exit code, writing nothing to the process directly.
 *
 * **The exit codes are a documented contract** — `server/README.md`'s command table promises that
 * all three exit 65 when an applied migration's file has changed — and until this was split out of
 * `main` nothing in the suite could reach them: `main` is only callable by spawning the compiled
 * runner. 55 lines of dispatch, including every one of those codes, were covered by a session
 * running the command by hand and by nothing else (SONNY-364 review). What is left in `main` below
 * is argv, the environment and the connection.
 *
 * `dir` exists for the same reason `up` and `down` already take one — a test needs a throwaway
 * directory of its own — and the CLI never passes it, so the shipped path resolves migrations
 * exactly as before.
 */
export async function runCommand(
  command: string,
  client: pg.Client,
  io: CommandOutput,
  dir?: string,
): Promise<number> {
  try {
    if (command === "up") {
      const ran = await up(client, dir);
      io.out(ran.length ? `applied: ${ran.join(", ")}\n` : "nothing to apply\n");
      return 0;
    }
    if (command === "down") {
      const rolled = await down(client, dir);
      io.out(rolled ? `rolled back: ${rolled}\n` : "nothing to roll back\n");
      return 0;
    }
    if (command === "status") {
      // **`status` reports and never refuses**, which is the opposite of `up` and `down` on purpose:
      // it is the diagnostic an operator reaches for once one of those has refused, and a diagnostic
      // that throws instead of describing the state is no use at the moment it is needed.
      const states = migrationStates(await applied(client), await loadMigrations(dir));
      const changed = states.filter((s) => s.state === "CHANGED").length;
      const unverified = states.filter((s) => s.state === "unverified").length;
      for (const { id, state } of states) io.out(`${state.padEnd(10)}  ${id}\n`);
      if (changed > 0) {
        // Names them, so the summary stands on its own the way `up`'s and `down`'s refusal does.
        // The ids are in the listing on stdout too, and an operator who has redirected stdout — or
        // is reading a CI log's stderr — would otherwise be told only that "1 migration" changed.
        const names = states.filter((s) => s.state === "CHANGED").map((s) => s.id).join(", ");
        io.err(
          `\n${changed} applied migration${changed === 1 ? " has" : "s have"} changed since ` +
            `${changed === 1 ? "it was" : "they were"} applied: ${names}. This database was built ` +
            `by SQL its files no longer describe; \`up\` and \`down\` both refuse until the files ` +
            `are restored (git) or the change ships as a new migration.\n`,
        );
      }
      if (unverified > 0) {
        io.err(
          "\nSome migrations show `unverified`: they were applied before this runner recorded a " +
            "content hash, so there is nothing to compare their files against. They are NOT known " +
            "to match — no hash is invented for them, because a backfilled one would claim a " +
            "comparison that never happened. A migration leaves that state the next time it is " +
            "rolled back and re-applied.\n",
        );
      }
      // A status that printed CHANGED and exited 0 is the clean zero this repository keeps
      // recording: a check whose reassuring answer is indistinguishable from a real one.
      return changed > 0 ? DATA_ERROR : 0;
    }
    io.err(`unknown command "${command}" -- expected up, down or status\n`);
    return 2;
  } catch (error) {
    // The finding, not the fault: message alone, no stack. Anything else rethrows and keeps the
    // trace, because a migration that failed mid-statement is a fault and the frames are the point.
    if (!(error instanceof MigrationRefusal)) throw error;
    io.err(`${error.message}\n`);
    return error instanceof UnsafeStringLexingError ? CONFIG_ERROR : DATA_ERROR;
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
    process.exitCode = await runCommand(command, client, {
      out: (text) => process.stdout.write(text),
      err: (text) => process.stderr.write(text),
    });
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
