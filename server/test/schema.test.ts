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

/**
 * **A file reaches the helper when it CALLS something the helper gave it, not when it mentions one**
 * (PR #172, F5). This was `/support\/schema\.js|rebuildSchema|dropSchema/` — a mention — which an
 * unused import satisfies, and an unused import is exactly what a half-finished new file has. It is
 * the same defect as F1 one file over: a pattern that saw one spelling of a thing rather than the
 * thing.
 *
 * So the import clause is parsed for the names it actually binds, `as` aliases included, and at
 * least one of those *local* names has to appear as a call. An alias therefore has to be called
 * under its alias, which is the only way a scan can follow one.
 */
function callsSomethingFromTheHelper(code: string): boolean {
  // `[^;]` rather than `[\s\S]`: a lazy any-character clause starts matching at the file's FIRST
  // `import` keyword and runs to this module's `from`, so it hands back every import above this one
  // glued together, and the greedy brace extraction then reads names out of the wrong statement.
  // That bug was in this function's first version and it is why the negative control for it did not
  // fire — a file with the helper imported and its call deleted still passed, because `pg` and
  // vitest's own bindings had been swept into the name list. A statement cannot contain a `;`, so
  // excluding one is what keeps a clause inside its own statement. The identical bug was in
  // `backstop.test.ts`'s vitest clause parser and is fixed there too.
  const clauses = [...code.matchAll(/import\s+([^;]*?)\s+from\s+["']\.\/support\/schema\.js["']/g)]
    .map((match) => match[1]!);
  const callables = clauses.flatMap((clause) => {
    // A namespace import binds every export under one name, so the call to look for is `ns.<name>(`.
    const namespace = /\*\s*as\s+([A-Za-z_$][A-Za-z0-9_$]*)/.exec(clause);
    if (namespace) return [`${namespace[1]!}\\.[A-Za-z_$][A-Za-z0-9_$]*`];
    const named = /\{([^}]*)\}/.exec(clause);
    return (named?.[1] ?? "").split(",")
      .map((specifier) => specifier.trim().split(/\s+as\s+/).pop()?.trim())
      .filter((name): name is string => name !== undefined && name.length > 0);
  });
  return callables.some((name) => new RegExp(`(?<![A-Za-z0-9_$.])${name}\\s*\\(`).test(code));
}

const REACHES_THE_HELPER = { test: callsSomethingFromTheHelper };

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

  it("counts a CALL rather than a mention, so an unused import does not satisfy it", () => {
    // The pattern is the guard, so the pattern is what gets tested — the same rule
    // `backstop.test.ts` carries. Every "reaches" sample below imports the helper and calls
    // something it bound; every "does not" mentions it and calls nothing.
    const importLine = 'import { rebuildSchema } from "./support/schema.js";';
    const aliased = 'import { rebuildSchema as build } from "./support/schema.js";';
    const reaches = [
      `${importLine}\nawait rebuildSchema(client);`,
      `${importLine}\n  await rebuildSchema (client);`,
      `${aliased}\nawait build(client);`,
      'import { dropSchema, rebuildSchema } from "./support/schema.js";\nawait dropSchema(client);',
    ];
    const doesNot = [
      importLine,                                                    // imported and never called
      `${importLine}\nconst held = rebuildSchema;`,                  // referenced, never called
      `${aliased}\nawait rebuildSchema(client);`,                    // aliased, called under the old name
      'await rebuildSchema(client);',                                // called with no import of it
      'const x = myRebuildSchema(client);',                          // a longer identifier
      'await up(client);',
      // The parser bug this arm exists to catch, in the shape every real file has: names belonging
      // to a statement ABOVE this module's import must not be read as this one's, so an unused
      // helper import beside a used `pg` is still an unused helper import.
      `import pg from "pg";\n${importLine}\nnew pg.Client({});`,
    ];
    // A namespace import binds every export under one name, and calling through it is still calling.
    const throughANamespace =
      'import * as schema from "./support/schema.js";\nawait schema.rebuildSchema(client);';
    expect(REACHES_THE_HELPER.test(throughANamespace)).toBe(true);
    expect(reaches.filter((sample) => !REACHES_THE_HELPER.test(sample))).toEqual([]);
    expect(doesNot.filter((sample) => REACHES_THE_HELPER.test(sample))).toEqual([]);
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
