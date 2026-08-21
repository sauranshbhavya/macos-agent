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
      "0001_x.sql": "CREATE TABLE t (id int);\n-- @rollback\nDROP TABLE t;",
    });
    const [migration] = await loadMigrations(dir);
    expect(migration?.id).toBe("0001_x");
    expect(migration?.up).toBe("CREATE TABLE t (id int);");
    expect(migration?.down).toBe("DROP TABLE t;");
  });

  it("puts no part of the rollback into the up half, which would drop what it just created", async () => {
    // The failure this pins is silent and total: an `up` that carried its own `DROP` would apply,
    // record itself as applied, and leave the schema unchanged.
    const dir = await withFiles({
      "0001_x.sql": "CREATE SCHEMA s;\n-- @rollback\nDROP SCHEMA s CASCADE;",
    });
    const [migration] = await loadMigrations(dir);
    expect(migration?.up).not.toContain("DROP");
    expect(migration?.down).not.toContain("CREATE");
  });

  it("orders migrations by filename, which is what makes numbering meaningful", async () => {
    const dir = await withFiles({
      "0002_b.sql": "SELECT 2;\n-- @rollback\nSELECT 2;",
      "0001_a.sql": "SELECT 1;\n-- @rollback\nSELECT 1;",
      "0010_c.sql": "SELECT 3;\n-- @rollback\nSELECT 3;",
    });
    expect((await loadMigrations(dir)).map((m) => m.id)).toEqual(["0001_a", "0002_b", "0010_c"]);
  });

  it("ignores non-SQL files rather than trying to run them", async () => {
    const dir = await withFiles({
      "0001_a.sql": "SELECT 1;\n-- @rollback\nSELECT 1;",
      "README.md": "notes",
    });
    expect((await loadMigrations(dir)).map((m) => m.id)).toEqual(["0001_a"]);
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
