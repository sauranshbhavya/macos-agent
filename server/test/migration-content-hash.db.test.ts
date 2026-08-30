import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { MigrationDriftError, down, loadMigrations, runCommand, up } from "../src/db/migrate.js";
import { migrationContentHash } from "../src/db/migration-hash.js";

/**
 * SONNY-364's selftest: apply a migration, alter its file, run again, and watch the runner refuse.
 *
 * This repository's rule is that a guard counts only once it has been shown to flag the thing it
 * names, and the pure half (`migration-content-hash.test.ts`) can only show that a hash moves. That
 * a *moved hash stops a migration run* is a property of the runner against a real ledger, so it is
 * pinned here — along with the direction that matters just as much and is easier to lose: a
 * comment-only edit must still be waved through, or this guard quietly ends the practice of
 * annotating migrations that this repository relies on.
 *
 * **Everything here works in a throwaway directory of its own, under ids that sort before `0001`.**
 * The `*.db.test.ts` files share one database and run serially (`vitest.config.ts`), and
 * `migrate.db.test.ts` reaches for `ORDER BY id DESC LIMIT 1` to find "the newest migration" — so a
 * probe row of ours sorting after the real ones would become that, and this file would break a
 * neighbour it never touched. `0000_` cannot, and `afterAll` removes the rows regardless.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

/** Ids the probe migrations use. `0000_` so they can never be the newest applied row. */
const PROBE = "0000_probe_content_hash";
const NEXT = "0000_probe_content_hash_b";

const upSql = (column: string): string => `CREATE TABLE public.sonny_hash_probe (${column});`;
const downSql = "DROP TABLE IF EXISTS public.sonny_hash_probe;";
const file = (up: string, down = downSql): string => `${up}\n-- @rollback\n${down}`;

describeDb("an applied migration cannot change silently", () => {
  let client: pg.Client;
  let dir: string;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    dir = await mkdtemp(join(tmpdir(), "sonny-hash-probe-"));
    // Bootstraps the ledger against a database that may be brand new: `up` is what creates
    // `sonny_meta.schema_migration`, and an empty directory makes it create that and apply nothing.
    // Without this the first `reset()` below queries a table that does not exist yet, and every
    // assertion after it is reasoning about a state the run never reached.
    await up(client, await mkdtemp(join(tmpdir(), "sonny-hash-bootstrap-")));
  });

  afterAll(async () => {
    // Leaves the shared database as it was found. A probe row surviving this file would sit in the
    // ledger naming a migration no directory contains, which is a state nothing else here expects.
    await client.query("DELETE FROM sonny_meta.schema_migration WHERE id LIKE '0000_probe%'");
    await client.query("DROP TABLE IF EXISTS public.sonny_hash_probe");
    await client.query("DROP TABLE IF EXISTS public.sonny_hash_probe_b");
    await client.query("DROP FUNCTION IF EXISTS public.sonny_hash_probe_fn()");
    await client.end();
  });

  /** Rewrites the probe migration's file and returns what the runner should now hash it to. */
  const writeProbe = async (up: string, down = downSql): Promise<string> => {
    await writeFile(join(dir, `${PROBE}.sql`), file(up, down));
    return migrationContentHash(up, down);
  };

  const ledgerHash = async (id = PROBE): Promise<string | null | undefined> => {
    const { rows } = await client.query<{ content_hash: string | null }>(
      "SELECT content_hash FROM sonny_meta.schema_migration WHERE id = $1",
      [id],
    );
    return rows[0]?.content_hash;
  };

  /**
   * Removes everything this file can create, so no test here depends on the one before it having
   * finished. **A mutation battery aborts tests mid-run by design**, and the first version of this
   * left a function behind when it did: the next baseline then failed with `function
   * "sonny_hash_probe_fn" already exists`, which reads as a defect in the branch and was leftover
   * state from a killed mutant.
   */
  const reset = async (): Promise<void> => {
    await client.query("DELETE FROM sonny_meta.schema_migration WHERE id LIKE '0000_probe%'");
    await client.query("DROP TABLE IF EXISTS public.sonny_hash_probe");
    await client.query("DROP TABLE IF EXISTS public.sonny_hash_probe_b");
    await client.query("DROP FUNCTION IF EXISTS public.sonny_hash_probe_fn()");
  };

  it("records the content hash in the same transaction as the SQL it describes", async () => {
    await reset();
    const expected = await writeProbe(upSql("id int"));
    expect(await up(client, dir)).toEqual([PROBE]);
    expect(await ledgerHash()).toBe(expected);
    expect(await ledgerHash()).toMatch(/^[0-9a-f]{64}$/);
  });

  it("refuses to apply anything once an applied migration's SQL has changed", async () => {
    // **The selftest arm.** Applied above; now the file changes behaviourally, and a second run must
    // stop rather than build the next migration on a schema no other environment has.
    await writeProbe(upSql("id uuid"));
    // A genuinely pending migration sits beside it, so this also pins WHERE the refusal happens:
    // before anything is applied, not after the run has half-finished.
    await writeFile(join(dir, `${NEXT}.sql`), file("CREATE TABLE public.sonny_hash_probe_b (id int);",
      "DROP TABLE IF EXISTS public.sonny_hash_probe_b;"));

    // The type rather than the wording: this assertion was written against the message and the
    // sentence was later reworded for grammar, which broke the test without changing the behaviour.
    // The id has to be in the message — an operator has to know WHICH file — so that much is pinned.
    await expect(up(client, dir)).rejects.toThrow(MigrationDriftError);
    await expect(up(client, dir)).rejects.toThrow(new RegExp(PROBE));

    const { rows } = await client.query(
      "SELECT id FROM sonny_meta.schema_migration WHERE id = $1", [NEXT]);
    expect(rows).toHaveLength(0);
    const { rows: tables } = await client.query(
      "SELECT tablename FROM pg_tables WHERE tablename = 'sonny_hash_probe_b'");
    expect(tables).toHaveLength(0);
  });

  it("refuses to roll back over the same drift, because the rollback is edited text too", async () => {
    // `down` is the half a later edit is most likely to touch, and running a `down` that was never
    // paired with the `up` this database ran is how the README's staging rehearsal stops being one.
    await expect(down(client, dir)).rejects.toThrow(MigrationDriftError);
    // ...and it really did not roll back: the ledger row and the table are both still there.
    expect(await ledgerHash()).toMatch(/^[0-9a-f]{64}$/);
    const { rows } = await client.query(
      "SELECT tablename FROM pg_tables WHERE tablename = 'sonny_hash_probe'");
    expect(rows).toHaveLength(1);
  });

  it("proceeds again once the file is restored, which is the only way out it offers", async () => {
    // The refusal names restoring the file (git) as the remedy. If restoring it did not clear the
    // refusal, the remedy would be wrong and the runner would be a dead end.
    await writeProbe(upSql("id int"));
    expect(await up(client, dir)).toEqual([NEXT]);
  });

  it("refuses on a changed ROLLBACK half alone, with the up half untouched", async () => {
    await writeProbe(upSql("id int"), "DROP TABLE public.sonny_hash_probe;");
    await expect(up(client, dir)).rejects.toThrow(MigrationDriftError);
    await writeProbe(upSql("id int"));
    expect(await up(client, dir)).toEqual([]);
  });

  it("waves through a comment-only edit — the decision the whole design rests on", async () => {
    // PR #167 edited an already-applied 0014 to record that 0015 changed what its column may imply.
    // That edit was deliberate and correct. A whole-file hash would have turned it into a hard
    // failure on every environment that had already run 0014, and this is the arm that says it does
    // not: same executable SQL, three paragraphs of new prose, and a run that simply proceeds.
    await writeProbe(
      "-- **A later note.** Why this column means what it means, recorded after the fact.\n" +
        "--\n-- A second paragraph, because this repository annotates its migrations on purpose.\n" +
        upSql("id int") +
        " -- and a trailing note",
      `-- The rollback gets prose too.\n${downSql}`,
    );
    expect(await up(client, dir)).toEqual([]);
    expect(await down(client, dir)).toBe(NEXT);
    expect(await up(client, dir)).toEqual([NEXT]);
  });

  it("treats an absent recorded hash as unknown and compares it against nothing", async () => {
    // What a database applied before this runner existed carries. Backfilling those rows from
    // today's files was the alternative and would be a lie about when the hash was taken — so the
    // honest state is "unknown", and unknown must neither match nor refuse. Here the file has
    // genuinely changed and the run still proceeds, which is the whole of that decision.
    await client.query(
      "UPDATE sonny_meta.schema_migration SET content_hash = NULL WHERE id = $1", [PROBE]);
    await writeProbe(upSql("id bigint"));
    expect(await up(client, dir)).toEqual([]);
    expect(await ledgerHash()).toBeNull();
    // And it stays unknown: nothing invents a hash for it on the way past.
    await writeProbe(upSql("id int"));
    expect(await up(client, dir)).toEqual([]);
    expect(await ledgerHash()).toBeNull();
  });

  it("re-applying is what clears the unknown state, and it is the only thing that does", async () => {
    expect(await down(client, dir)).toBe(NEXT);
    expect(await down(client, dir)).toBe(PROBE);
    const expected = await writeProbe(upSql("id int"));
    await up(client, dir);
    expect(await ledgerHash()).toBe(expected);
  });

  it("compares only migrations whose file is present, so a foreign directory still runs", async () => {
    // `up(client, someOtherDir)` is how three existing tests apply throwaway migrations against a
    // database that also holds the real ones. A guard that refused on every applied id it could not
    // find a file for would break all of them — and would be refusing on the different hazard of a
    // DELETED migration, which is deliberately not this ticket's.
    const shipped = await loadMigrations();
    expect(shipped.length).toBeGreaterThan(0);
    const empty = await mkdtemp(join(tmpdir(), "sonny-hash-empty-"));
    expect(await up(client, empty)).toEqual([]);
  });

  it("does not refuse over a PENDING migration whose file changed, because pending is what up is for", async () => {
    await reset();
    await writeProbe(upSql("id int"));
    await writeProbe(upSql("id uuid"));
    expect(await up(client, dir)).toContain(PROBE);
    await reset();
  });

  // ---- The exit codes, which `server/README.md`'s command table promises (SONNY-364 review) ----

  const runs = async (command: string): Promise<{ code: number; out: string; err: string }> => {
    let out = "";
    let err = "";
    const code = await runCommand(
      command,
      client,
      { out: (t) => (out += t), err: (t) => (err += t) },
      dir,
    );
    return { code, out, err };
  };

  it("exits 65 from up, down and status when an applied migration's file has changed", async () => {
    // The documented contract, and until `runCommand` was split out of `main` nothing in the suite
    // could reach it — `main` is only callable by spawning the compiled runner.
    await reset();
    await writeProbe(upSql("id int"));
    expect((await runs("up")).code).toBe(0);
    await writeProbe(upSql("id uuid"));
    for (const command of ["up", "down", "status"]) {
      const run = await runs(command);
      expect(run.code, `${command} should exit 65 on a changed applied migration`).toBe(65);
    }
  });

  it("says which migration changed on stderr, not on stdout", async () => {
    // The listing goes to stdout and the summary to stderr, and BOTH name the migration: an
    // operator who has redirected stdout, or is reading a CI log's stderr, would otherwise be told
    // only that "1 migration" changed and not which.
    const run = await runs("status");
    expect(run.err).toContain(PROBE);
    expect(run.out).toContain(`CHANGED     ${PROBE}`);
    expect(run.out).not.toContain("no longer describe");
  });

  it("does not claim the change was outside a string literal, because it may not have been", async () => {
    // F2: the refusal used to end "Comments and layout are not hashed, so this is a change to the
    // executable SQL", which is false when the edit is one line of prose inside a `$$ … $$` body —
    // that text IS hashed, correctly, because Postgres stores it in pg_proc.prosrc. The refusal was
    // right and the sentence sent the reader hunting for a schema change that was not there.
    const fn = (note: string) =>
      `CREATE FUNCTION public.sonny_hash_probe_fn() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n  -- ${note}\n  RETURN 1;\nEND $$;`;
    await reset();
    await writeProbe(fn("first"), "DROP FUNCTION IF EXISTS public.sonny_hash_probe_fn();");
    expect((await runs("up")).code).toBe(0);
    // One line of prose inside the body is the entire diff.
    await writeProbe(fn("second"), "DROP FUNCTION IF EXISTS public.sonny_hash_probe_fn();");
    const run = await runs("up");
    expect(run.code).toBe(65);
    expect(run.err).not.toContain("Comments and layout are not hashed");
    expect(run.err).toContain("pg_proc.prosrc");
    await reset();
  });

  it("exits 0 from status when nothing has changed, and 2 on an unknown command", async () => {
    await writeProbe(upSql("id int"));
    expect((await runs("up")).code).toBe(0);
    const clean = await runs("status");
    expect(clean.code).toBe(0);
    expect(clean.out).toContain("applied");
    const unknown = await runs("sideways");
    expect(unknown.code).toBe(2);
    expect(unknown.err).toContain("expected up, down or status");
    await reset();
  });

  it("issues no ALTER on the ledger once the hash column is there", async () => {
    // The lock regression (SONNY-364 review). `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` takes
    // ACCESS EXCLUSIVE to evaluate its own IF NOT EXISTS, so on every run after the first it queued
    // behind any open ledger writer: read-only `status` measured 8.17 s behind a ten-second writer
    // against 0.13 s for the pre-ticket ledger SQL, and 0.15 s with the catalog check in front.
    // A timing test would be flaky, so the mechanism is pinned instead: no ALTER is issued at all.
    const issued: string[] = [];
    const spy = {
      query: (text: unknown, values?: unknown) => {
        if (typeof text === "string") issued.push(text);
        return (client as unknown as { query: (t: unknown, v?: unknown) => unknown }).query(text, values);
      },
    } as unknown as pg.Client;
    await up(spy, dir);
    expect(issued.some((q) => q.includes("ALTER TABLE sonny_meta.schema_migration"))).toBe(false);
    // ...and the check that replaced it really did run, so this is not passing because nothing did.
    expect(issued.some((q) => q.includes("information_schema.columns"))).toBe(true);
    await reset();
  });

  it("carries the hash column on a ledger created before this runner recorded one", async () => {
    // The `CREATE TABLE IF NOT EXISTS` in `LEDGER` does nothing to a table that already exists, so
    // an existing database gets the column from the `ALTER … ADD COLUMN IF NOT EXISTS` beside it and
    // from nothing else. Dropping the column is the only way to exercise that path, so the rows'
    // hashes are saved and put back — this file shares its database with every other `*.db.test.ts`.
    const { rows: saved } = await client.query<{ id: string; content_hash: string | null }>(
      "SELECT id, content_hash FROM sonny_meta.schema_migration");
    await client.query("ALTER TABLE sonny_meta.schema_migration DROP COLUMN content_hash");
    try {
      const empty = await mkdtemp(join(tmpdir(), "sonny-hash-alter-"));
      expect(await up(client, empty)).toEqual([]);
      const { rows: column } = await client.query<{ is_nullable: string; data_type: string }>(
        `SELECT is_nullable, data_type FROM information_schema.columns
          WHERE table_schema = 'sonny_meta' AND table_name = 'schema_migration'
            AND column_name = 'content_hash'`);
      expect(column).toHaveLength(1);
      // Nullable, because "applied before hashes were recorded" has to be expressible. A NOT NULL
      // column would have forced a backfilled value onto every existing row — the lie this design
      // refused to tell.
      expect(column[0]!.is_nullable).toBe("YES");
      const { rows: after } = await client.query<{ id: string; content_hash: string | null }>(
        "SELECT id, content_hash FROM sonny_meta.schema_migration");
      expect(after.map((r) => r.id).sort()).toEqual(saved.map((r) => r.id).sort());
      expect(after.every((r) => r.content_hash === null)).toBe(true);
    } finally {
      for (const row of saved) {
        await client.query(
          "UPDATE sonny_meta.schema_migration SET content_hash = $2 WHERE id = $1",
          [row.id, row.content_hash]);
      }
    }
  });
  // An explicit deadline for the file. Every test here applies at most two one-statement migrations
  // against a local Postgres, so the work is milliseconds; what this is bounding is the shared
  // database being busy, not the code under test. vitest's unchosen 5000 ms default is the number
  // SONNY-354 is about, and nothing here is racing a wall clock for its result.
}, 60_000);
