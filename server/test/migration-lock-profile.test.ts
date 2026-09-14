import { describe, expect, it } from "vitest";
import { loadMigrations } from "../src/db/migrate.js";
import {
  declaredLockProfile,
  formatLockProfile,
  LockDeclarationError,
  sameLockProfile,
} from "../src/db/lock-profile.js";

/**
 * The declaration half of SONNY-370, which needs no database and so runs on every `npm test`.
 *
 * What it guarantees: every shipped migration states, in both halves, which relations it blocks and
 * which tables it scans, in a form that parses — so a new migration cannot arrive with no profile at
 * all, which is how PR #171's first 0017 arrived. Whether each statement is TRUE is
 * `migration-lock-profile.db.test.ts`'s, and it is the half that measures.
 */
describe("a migration's declared lock profile", () => {
  const where = "0099_x up";

  it("reads `none` on both lines as a migration that blocks and scans nothing", () => {
    expect(declaredLockProfile("-- @locks none\n-- @scans none\nSELECT 1;", where)).toEqual({ locks: [], scans: [] });
  });

  it("reads every blocking mode, including the one whose name starts with another's", () => {
    const profile = declaredLockProfile(
      "-- @locks SHARE ROW EXCLUSIVE sonny.b, ACCESS EXCLUSIVE sonny.a, SHARE sonny.c, EXCLUSIVE sonny.d\n" +
        "-- @scans sonny.c, sonny.a",
      where,
    );
    expect(profile).toEqual({
      locks: [
        { relation: "sonny.a", mode: "ACCESS EXCLUSIVE" },
        { relation: "sonny.b", mode: "SHARE ROW EXCLUSIVE" },
        { relation: "sonny.c", mode: "SHARE" },
        { relation: "sonny.d", mode: "EXCLUSIVE" },
      ],
      scans: ["sonny.a", "sonny.c"],
    });
  });

  it("answers undefined only when the half declares nothing at all", () => {
    expect(declaredLockProfile("CREATE TABLE t (id int);", where)).toBeUndefined();
  });

  it("round-trips through the lines a failure tells the author to write", () => {
    const profile = { locks: [{ relation: "sonny.identity", mode: "SHARE" as const }], scans: ["sonny.identity"] };
    const text = formatLockProfile(profile);
    expect(text).toBe("-- @locks SHARE sonny.identity\n-- @scans sonny.identity");
    const parsed = declaredLockProfile(text, where);
    expect(parsed).toEqual(profile);
    expect(sameLockProfile(parsed!, profile)).toBe(true);
    expect(sameLockProfile(parsed!, { locks: profile.locks, scans: [] })).toBe(false);
  });

  // Every refusal is a declaration that is PRESENT and unreadable. None of them may read as
  // "undeclared", or a typo would switch the check off for that migration.
  it.each([
    ["only the locks line", "-- @locks none"],
    ["only the scans line", "-- @scans none"],
    ["a line twice", "-- @locks none\n-- @locks none\n-- @scans none"],
    ["an empty line", "-- @locks\n-- @scans none"],
    ["a mode Postgres does not have", "-- @locks ROW EXCLUSIVE sonny.a\n-- @scans none"],
    ["a mode that blocks nothing", "-- @locks SHARE UPDATE EXCLUSIVE sonny.a\n-- @scans none"],
    ["an unqualified relation", "-- @locks ACCESS EXCLUSIVE identity\n-- @scans none"],
    ["an unqualified scan", "-- @locks none\n-- @scans identity"],
    ["none mixed with a name", "-- @locks none, SHARE sonny.a\n-- @scans none"],
    ["a relation locked twice", "-- @locks SHARE sonny.a, ACCESS EXCLUSIVE sonny.a\n-- @scans none"],
    ["a table scanned twice", "-- @locks none\n-- @scans sonny.a, sonny.a"],
  ])("refuses %s", (_name, text) => {
    expect(() => declaredLockProfile(text, where)).toThrow(LockDeclarationError);
    expect(() => declaredLockProfile(text, where)).toThrow(/^0099_x up: /);
  });

  it("is carried by both halves of every migration that ships", async () => {
    const shipped = await loadMigrations();
    // The walk reached something, so an empty directory cannot read as a clean one.
    expect(shipped.length).toBeGreaterThan(20);
    const undeclared = shipped.flatMap((migration) => [
      ...(declaredLockProfile(migration.up, `${migration.id} up`) === undefined ? [`${migration.id} up`] : []),
      ...(declaredLockProfile(migration.down, `${migration.id} down`) === undefined ? [`${migration.id} down`] : []),
    ]);
    expect(undeclared).toEqual([]);
  });
});
