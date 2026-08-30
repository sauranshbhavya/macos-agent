import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const testTree = dirname(fileURLToPath(import.meta.url));

/**
 * The scan that keeps a twelfth database test file from arriving without a schema rebuild
 * (SONNY-366).
 *
 * **What it is guarding against is a file that looks finished.** `up(client)` in a `beforeAll` reads
 * like setup, runs without error, and leaves the file measuring whatever schema the last invocation
 * of the suite left behind — the whole of `test/support/schema.ts`'s header. Nine of the twelve
 * `.db.test.ts` files had exactly that shape, and the ninth arrived that way because the other eight
 * did; PR #167 fixed one of them by hand, which is how the tenth would arrive too.
 *
 * **A scan over text, and it is worth saying so.** `CLAUDE.md` records that a grep count is evidence
 * about text and never about behaviour. What this file establishes is that every `.db.test.ts` file
 * names the shared helper and that nothing else reaches the migration runner. That the helper then
 * genuinely replaces a schema is a different claim, and it is `schema.db.test.ts`'s — the two are
 * only worth anything together.
 */

/** Every `.ts` file under `server/test/`, at any depth. */
function everyTestSource(directory: string = testTree): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return everyTestSource(path);
    return entry.isFile() && path.endsWith(".ts") ? [path] : [];
  });
}

/**
 * Comment-prefixed lines dropped, matching `backstop.test.ts`'s `codeOf` and
 * `TestSourceTree.typeScriptCommentPrefixes` exactly. A scan a doc comment can satisfy holds
 * nothing, and this tree is written in JSDoc throughout — this very file names
 * `src/db/migrate.js` in prose twice.
 */
function codeOf(path: string): string {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => {
      const trimmed = line.trim();
      return !trimmed.startsWith("//") && !trimmed.startsWith("/*") && !trimmed.startsWith("*");
    })
    .join("\n");
}

const named = (paths: string[]): string[] => paths.map((path) => relative(testTree, path)).sort();

const databaseTestFiles = (): string[] =>
  everyTestSource().filter((path) => path.endsWith(".db.test.ts"));

/** Any mention of the shared helper module — an import, a call, an alias. */
const REACHES_THE_HELPER = /support\/schema\.js|rebuildSchema|dropSchema/;

/** Any mention of the migration runner module, which is the door the helper exists to be. */
const REACHES_THE_MIGRATION_RUNNER = /src\/db\/migrate\.js/;

/**
 * The one database test file that needs no schema, and the reason is checked below rather than
 * trusted: `pool.db.test.ts` leases connections and runs `SELECT 1`, so it names no table.
 */
const NEEDS_NO_SCHEMA = new Set(["pool.db.test.ts"]);

/**
 * Who may name the migration runner directly. `migrate.db.test.ts`, `migrate.load.test.ts` and
 * `schema.db.test.ts` are tests OF the runner, so importing it is their subject rather than a
 * bypass — the last of those exists to call `up()` against a full ledger and show it applying
 * nothing, which is a claim nobody can make without the import. `support/schema.ts` is the helper,
 * which has to call `up` to be a helper at all.
 *
 * The list is short and each entry is a file whose *name* says it is about migrations. That is the
 * property to protect when it grows: an entry for a file called `content.db.test.ts` would be this
 * guard being switched off one line at a time.
 */
const MAY_REACH_THE_MIGRATION_RUNNER = new Set([
  "migrate.db.test.ts", "migrate.load.test.ts", "schema.db.test.ts", "support/schema.ts",
]);

describe("the shared schema rebuild", () => {
  it("is reached by every database test file that needs a schema", () => {
    const missing = named(
      databaseTestFiles()
        .filter((path) => !NEEDS_NO_SCHEMA.has(relative(testTree, path)))
        .filter((path) => !REACHES_THE_HELPER.test(codeOf(path))),
    );
    // Named rather than counted, so a failure says which file to fix.
    expect(missing).toEqual([]);
  });

  it("exempts only files that genuinely name no table, so the exemption is earned", () => {
    // An exemption list is the thing that rots (`test/support/database.ts` says so about a different
    // one), so each entry is re-derived here instead of believed. A file that starts querying
    // `sonny.<table>` fails this the day it does, whatever the list says.
    const unearned = named(
      databaseTestFiles()
        .filter((path) => NEEDS_NO_SCHEMA.has(relative(testTree, path)))
        .filter((path) => /sonny(_meta)?\./.test(codeOf(path))),
    );
    expect(unearned).toEqual([]);
    // And every entry names a file that is really there: an exemption for a deleted file is a hole
    // waiting for something to be created into it.
    const present = named(
      databaseTestFiles().filter((path) => NEEDS_NO_SCHEMA.has(relative(testTree, path))),
    );
    expect(present).toEqual([...NEEDS_NO_SCHEMA].sort());
  });

  it("is the only door to the migration runner, so `up(client)` cannot come back as setup", () => {
    const bypassing = named(
      everyTestSource()
        .filter((path) => !MAY_REACH_THE_MIGRATION_RUNNER.has(relative(testTree, path)))
        .filter((path) => REACHES_THE_MIGRATION_RUNNER.test(codeOf(path))),
    );
    expect(bypassing).toEqual([]);
  });

  it("finds what it is looking for, so an empty answer above means something", () => {
    // **The zero this file has to refuse on its own terms.** Every assertion above is satisfied by a
    // scan that enumerates nothing — a moved directory, a changed suffix, a `codeOf` that strips the
    // whole file. `CLAUDE.md`: a search whose engine cannot see the bytes you mean answers a clean
    // zero, and a clean zero is the one answer that looks like good news. So the population is
    // asserted against a floor of its own rather than against a list that could move with it.
    const files = databaseTestFiles();
    expect(files.length).toBeGreaterThanOrEqual(1);

    // A positive control on each pattern: both must be able to produce a hit, or their absence
    // elsewhere is not a measurement.
    const reachingTheHelper = named(databaseTestFiles().filter((path) => REACHES_THE_HELPER.test(codeOf(path))));
    expect(reachingTheHelper.length).toBeGreaterThanOrEqual(1);
    const reachingTheRunner = named(
      everyTestSource().filter((path) => REACHES_THE_MIGRATION_RUNNER.test(codeOf(path))),
    );
    expect(reachingTheRunner).toEqual([...MAY_REACH_THE_MIGRATION_RUNNER].sort());
  });
});
