import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadMigrations } from "../src/db/migrate.js";

/**
 * The runner's file-level guarantees, which need **no database at all** and therefore run in the
 * default `npm test`.
 *
 * They were previously inside the database-gated suite, so the runner's core promise — that a
 * migration without a rollback is refused — was skipped on every run of the documented command.
 * A guarantee only checked when someone remembers to start a container is not a guarantee.
 */
describe("loadMigrations", () => {
  const withFiles = async (files: Record<string, string>): Promise<string> => {
    const dir = await mkdtemp(join(tmpdir(), "sonny-mig-"));
    for (const [name, body] of Object.entries(files)) await writeFile(join(dir, name), body);
    return dir;
  };

  /**
   * A half that states it blocks and scans nothing, which every half must now carry (SONNY-370). The
   * fixtures below that are not about the declaration carry it so that each one still reaches the
   * behaviour its name is about, rather than being refused at load for a reason it never mentions.
   */
  const declared = (sql: string): string => `-- @locks none\n-- @scans none\n${sql}`;
  const migration = (up: string, down: string): string => `${declared(up)}\n-- @rollback\n${declared(down)}`;

  it("refuses a migration that has no rollback half", async () => {
    const dir = await withFiles({ "0001_no_rollback.sql": "CREATE TABLE t (id int);" });
    await expect(loadMigrations(dir)).rejects.toThrow(/@rollback/);
  });

  it("names the offending file, so the refusal is actionable", async () => {
    const dir = await withFiles({ "0007_bad.sql": "CREATE TABLE t (id int);" });
    await expect(loadMigrations(dir)).rejects.toThrow(/0007_bad\.sql/);
  });

  it("splits a migration into its up and down halves at the marker", async () => {
    const dir = await withFiles({
      "0001_x.sql": migration("CREATE TABLE t (id int);", "DROP TABLE t;"),
    });
    const [loaded] = await loadMigrations(dir);
    expect(loaded?.id).toBe("0001_x");
    expect(loaded?.up).toBe(declared("CREATE TABLE t (id int);"));
    expect(loaded?.down).toBe(declared("DROP TABLE t;"));
  });

  it("puts no part of the rollback into the up half, which would drop what it just created", async () => {
    // The failure this pins is silent and total: an `up` that carried its own `DROP` would apply,
    // record itself as applied, and leave the schema unchanged.
    const dir = await withFiles({
      "0001_x.sql": migration("CREATE SCHEMA s;", "DROP SCHEMA s CASCADE;"),
    });
    const [loaded] = await loadMigrations(dir);
    expect(loaded?.up).not.toContain("DROP");
    expect(loaded?.down).not.toContain("CREATE");
  });

  it("orders migrations by filename, which is what makes numbering meaningful", async () => {
    const dir = await withFiles({
      "0002_b.sql": migration("SELECT 2;", "SELECT 2;"),
      "0001_a.sql": migration("SELECT 1;", "SELECT 1;"),
      "0010_c.sql": migration("SELECT 3;", "SELECT 3;"),
    });
    expect((await loadMigrations(dir)).map((m) => m.id)).toEqual(["0001_a", "0002_b", "0010_c"]);
  });

  it("ignores non-SQL files rather than trying to run them", async () => {
    const dir = await withFiles({
      "0001_a.sql": migration("SELECT 1;", "SELECT 1;"),
      "README.md": "notes",
    });
    expect((await loadMigrations(dir)).map((m) => m.id)).toEqual(["0001_a"]);
  });

  // SONNY-370, founders' option B: a half that does not state its lock profile is refused at load,
  // the way a file with no rollback half is. Each refused case carries every declaration line except
  // the one its name says is missing, so the refusal can only be about that line — and the message
  // it is matched against names the half, not just the file.
  it("loads a migration whose two halves each carry both declaration lines", async () => {
    const dir = await withFiles({
      "0001_x.sql":
        "-- @locks ACCESS EXCLUSIVE sonny.t\n-- @scans sonny.t\nALTER TABLE sonny.t ADD COLUMN c int;\n" +
        "-- @rollback\n-- @locks ACCESS EXCLUSIVE sonny.t\n-- @scans none\nALTER TABLE sonny.t DROP COLUMN c;",
    });
    expect((await loadMigrations(dir)).map((m) => m.id)).toEqual(["0001_x"]);
  });

  it.each([
    ["a missing @locks line", "-- @scans none\nSELECT 1;\n-- @rollback\n-- @locks none\n-- @scans none\nSELECT 1;", /0003_bad\.sql up half/],
    ["a missing @scans line", "-- @locks none\n-- @scans none\nSELECT 1;\n-- @rollback\n-- @locks none\nSELECT 1;", /0003_bad\.sql down half/],
    ["an up half that declares nothing", "SELECT 1;\n-- @rollback\n-- @locks none\n-- @scans none\nSELECT 1;", /0003_bad\.sql's up half declares no lock profile/],
    ["a down half that declares nothing", "-- @locks none\n-- @scans none\nSELECT 1;\n-- @rollback\nSELECT 1;", /0003_bad\.sql's down half declares no lock profile/],
  ])("refuses a migration with %s, naming the file and the half", async (_name, body, message) => {
    const dir = await withFiles({ "0003_bad.sql": body });
    await expect(loadMigrations(dir)).rejects.toThrow(message);
  });

  // PR #250 review, R2: the two lines are read only at the head of a half — its leading blank and
  // comment lines — because below the first statement a line can sit inside a `$$` body or a string,
  // where Postgres stores it and the hash covers it. A marker line down there is refused, not ignored.
  const body = "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n";
  const bodyEnd = "  RETURN 1;\nEND $$;";
  it.each([
    ["only inside a function body", `${body}-- @locks none\n-- @scans none\n${bodyEnd}\n-- @rollback\n${declared("SELECT 1;")}`],
    ["at the head and again inside a function body", `${declared(body)}-- @locks none\n${bodyEnd}\n-- @rollback\n${declared("SELECT 1;")}`],
    ["below a first statement, outside any body", `SELECT 1;\n-- @locks none\n-- @scans none\n-- @rollback\n${declared("SELECT 1;")}`],
  ])("refuses a declaration %s, naming the file and the half", async (_name, text) => {
    const dir = await withFiles({ "0005_buried.sql": text });
    await expect(loadMigrations(dir)).rejects.toThrow(/0005_buried\.sql up half: "-- @locks none" sits below the half's first statement/);
  });

  it("reads a declaration among the head's other comments, above a function body that has comments of its own", async () => {
    const dir = await withFiles({
      "0006_headed.sql":
        "-- 0006 — a title line\n--\n-- @locks none\n\n-- prose between the two\n-- @scans none\n" +
        `${body}  -- a comment inside the body\n${bodyEnd}\n-- @rollback\n${declared("SELECT 1;")}`,
    });
    const [loaded] = await loadMigrations(dir);
    expect(loaded?.id).toBe("0006_headed");
  });

  it("loads the migrations that actually ship", async () => {
    // No directory argument: exercises the default path resolution, which is what `npm run
    // migrate` uses in both the local checkout and the container image.
    const shipped = await loadMigrations();
    expect(shipped.map((m) => m.id)).toContain("0001_schema_baseline");
    for (const migration of shipped) {
      expect(migration.up.length).toBeGreaterThan(0);
      expect(migration.down.length).toBeGreaterThan(0);
    }
  });
});
