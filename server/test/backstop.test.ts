import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import vitestConfig from "../vitest.config.js";
import {
  HANG_BACKSTOP_DECLARED_FRAGMENT, HANG_BACKSTOP_MS, VITEST_TIMEOUT_MS,
  hangBackstopMessage, underHangBackstop,
} from "./support/backstop.js";

const testTree = dirname(fileURLToPath(import.meta.url));

/**
 * Every `.ts` file under `server/test/`, at any depth — the same population
 * `TestSourceTree.serverTestFiles()` enumerates on the Swift side, and for the same reason: a scan
 * that stops covering the files a refactor moved is a scan that has stopped existing.
 */
function everyTestSource(directory: string = testTree): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return everyTestSource(path);
    return entry.isFile() && path.endsWith(".ts") ? [path] : [];
  });
}

/**
 * Comment-prefixed lines dropped, matching `TestSourceTree.typeScriptCommentPrefixes` exactly. A
 * scan a comment can satisfy holds nothing, and this tree is written in JSDoc throughout.
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

/**
 * **No assertion in this file may put the declared wording into its own failure — on EITHER side.**
 *
 * `scripts/mutate` matches a signature against the text a failure recorded, so a guard whose own
 * failure carries a declaration is a guard the declaration file switches off (PR #112 review, F1).
 * The first version of this file closed the *expected* side — a boolean computed beforehand rather
 * than `toContain(FRAGMENT)` — and opened the *received* side one line later: `expect(message)
 * .toContain("work that never finishes")` prints `message`, and `message` **is** the backstop
 * wording. PR #156's review reproduced it: the fragment arrived as the received value and
 * `classify_failures` returned `U` for a real failure. So every expectation here takes a value that
 * cannot carry the wording — a boolean, a number, a list of paths — and never a string derived from
 * `hangBackstopMessage` or from `backstop.ts`'s own source.
 *
 * It was never live: no plan in this repository mutates `server/test/`, so an ordinary battery over
 * `server/src` cannot make one of these tests red. It is erosion of the guard on the declaration's
 * wording rather than a wrong answer, and the direction was the safe one — a kill understated to
 * `UNATTRIBUTED` rather than manufactured.
 */
/**
 * Any mention of the raw helper by name — a call, an aliased import, a bare reference.
 *
 * Not a call pattern: see the population test below for what that cost. `itUnderHangBackstop` does
 * not match it, because the `U` there is capitalised and this is case-sensitive by construction.
 */
const REACHES_THE_RAW_HELPER = /(?<![A-Za-z])underHangBackstop(?![A-Za-z])/;

/** The two files allowed to reach it: the module itself, and this one, which tests the module. */
const ALLOWED_TO_REACH_THE_RAW_HELPER = new Set(["backstop.test.ts", "support/backstop.ts"]);

describe("the server suite's hang backstop", () => {
  /**
   * A deadline nothing can reach, so the only thing that can end this wait is the work finishing.
   * The lesson SONNY-302 paid for in its own tests: a small deadline chosen for speed is a bet on
   * the machine, and it reads as an efficiency rather than as a bet.
   */
  const NOTHING_CAN_REACH_IT = 60 * 60 * 1000;

  it("returns what the work returned", async () => {
    const value = await underHangBackstop("work that finishes", async () => 42, NOTHING_CAN_REACH_IT);
    expect(value).toBe(42);
  });

  it("fails, bounded, when the work never finishes", async () => {
    // The work is a promise nothing resolves, so the state being asserted cannot expire on its own
    // and the deadline is the only thing that can end this. That the call returns at all is the
    // whole of the boundedness claim: were it unbounded, vitest's own ceiling would end this test
    // instead and this assertion would never run.
    const never = new Promise<void>(() => {});
    let rejectedWithAnError = false;
    try {
      await underHangBackstop("work that never finishes", () => never, 50);
    } catch (error) {
      rejectedWithAnError = error instanceof Error;
    }
    expect(rejectedWithAnError).toBe(true);
  });

  it("says so in the wording a mutation battery is told not to read as a kill", async () => {
    const never = new Promise<void>(() => {});
    let message = "";
    try {
      await underHangBackstop("work that never finishes", () => never, 50);
    } catch (error) {
      message = (error as Error).message;
    }
    // Booleans on both sides, per this file's header rule: an expectation over `message` prints
    // `message` when it fails, and `message` is the declared wording.
    const carriesTheDeclaredFragment = message.includes(HANG_BACKSTOP_DECLARED_FRAGMENT);
    expect(carriesTheDeclaredFragment).toBe(true);
    const namesWhatItWaitedFor = message.includes("work that never finishes");
    expect(namesWhatItWaitedFor).toBe(true);
    const opensWithHowLongItWaited = /^waited \d+\.\ds for: /.test(message);
    expect(opensWithHowLongItWaited).toBe(true);
  });

  it("rethrows the work's own failure untouched, so a real kill stays a real kill", async () => {
    const thrown = new Error("expected 3 to be 4");
    let caught: unknown;
    try {
      await underHangBackstop("work that fails", async () => { throw thrown; }, NOTHING_CAN_REACH_IT);
    } catch (error) {
      caught = error;
    }
    // The identical object, not merely an equal message: anything that wrapped or re-created it
    // could quietly attach this construct's wording, and a mutant that makes one of these tests
    // WRONG would then be excused as one that made it slow. That is the direction that matters.
    const rethrownUnchanged = caught === thrown;
    expect(rethrownUnchanged).toBe(true);
    const dressedUpAsAHang = (caught as Error).message.includes(HANG_BACKSTOP_DECLARED_FRAGMENT);
    expect(dressedUpAsAHang).toBe(false);
  });

  it("keeps the declared fragment whole on one line, and opens no line a log reader would misread", () => {
    const lines = hangBackstopMessage("some work", 60_000).split("\n");
    const linesCarryingIt = lines.filter((line) => line.includes(HANG_BACKSTOP_DECLARED_FRAGMENT));
    // One line, because `scripts/mutate` matches a signature as a substring of the block it
    // reassembles out of the log, and a fragment split across two lines carries a newline the
    // declaration does not.
    expect(linesCarryingIt.length).toBe(1);
    // `FAIL` opens a vitest entry, `Test ` and `Suite ` close a swift-testing issue block, and the
    // rule closes a vitest one. A message line shaped like any of them is read as an event.
    for (const line of lines) {
      expect(line.startsWith("FAIL")).toBe(false);
      expect(line.trimStart().startsWith("FAIL ")).toBe(false);
      expect(line.startsWith("Test ")).toBe(false);
      expect(line.startsWith("Suite ")).toBe(false);
      expect(line.startsWith("⎯")).toBe(false);
    }
  });

  it("starts no repeating timer of its own, so it cannot perturb what it is guarding", () => {
    // The whole reason the first version's scheduling probe was taken out (SONNY-241). The two
    // tests this construct guards measure a race between three database transactions, and a
    // periodic timer is the one part of a deadline that runs *while* the work does. Measured over
    // mutant R1 — the per-address advisory lock deleted from `src/auth/codes.ts` — by running
    // `scripts/mutate <plan> --only R1` repeatedly and counting the runs whose report named the
    // plus-tag test: 5 of 9 with the probe in place, 8 of 10 with it removed, and 8 of 9 valid runs
    // on `main`'s own copy of `auth.db.test.ts` grafted onto this branch (a tenth is excluded there
    // — its baseline went red, which is the flake this branch fixes, reproduced). Not a decisive
    // difference at that sample size, and the wrong side of an undecidable question to be on for a
    // diagnostic whose number was already measured as unable to support a verdict.
    //
    // A source scan rather than an observation, because "nothing repeating is scheduled" is a
    // property of the code and any runtime measurement of it would be a bet on the machine — which
    // is the class of mistake this whole file exists to end. Booleans, per the header rule: the
    // source being scanned is `backstop.ts`, which carries the declared wording.
    const source = codeOf(join(testTree, "support/backstop.ts"));
    const startsARepeatingTimer = source.includes("setInterval");
    expect(startsARepeatingTimer).toBe(false);
    // And the scan can find what it is looking for, so its absence means something: the one timer
    // the construct does own is a non-repeating one.
    const ownsANonRepeatingTimer = source.includes("setTimeout");
    expect(ownsANonRepeatingTimer).toBe(true);
  });

  it("gives vitest a ceiling strictly above its own deadline", () => {
    // The other way round, vitest speaks first — with `Test timed out in Nms.`, a message every
    // test in this repository shares, which cannot be declared without excusing every timeout
    // everywhere. That is the failure this whole construct exists to replace.
    expect(VITEST_TIMEOUT_MS).toBeGreaterThan(HANG_BACKSTOP_MS);
  });

  it("names every form that reaches the raw helper, and no form that does not", () => {
    // **The pattern is the guard, so the pattern is what gets tested** (PR #156 review, F2). It was
    // `/(?<![A-Za-z])underHangBackstop\s*\(/` — a match on the CALL — and `underHangBackstop` is
    // generic, so `underHangBackstop<void>(…)` is ordinary TypeScript, type-checks, and walks past
    // it. The reviewer proved it end to end: that shape inside a plain `it`, wrapping a
    // seven-second wait, produced `Test timed out in 5000ms.` — which `classify_failures` returns
    // `T` for, so it counts as a mutation kill. SONNY-335's defect, reintroduced with every guard
    // in this file green.
    //
    // It matches the REFERENCE now rather than the call, so an alias and an explicit type argument
    // are both caught, and so is a bare `import { underHangBackstop }` in a file with no exemption
    // — which is the loud direction and the right one, since importing it is what precedes calling
    // it. The population below is the point of this test: a scan whose own inputs are never
    // enumerated is a scan nobody has watched fail.
    const reaches = [
      'await underHangBackstop("x", body);',
      'await underHangBackstop<void>("x", body);',
      'await underHangBackstop  ("x", body);',
      'await bs.underHangBackstop("x", body);',
      'import { underHangBackstop } from "./support/backstop.js";',
      'import { underHangBackstop as guard } from "./support/backstop.js";',
      'const held = underHangBackstop;',
    ];
    const doesNot = [
      'itUnderHangBackstop("x", body);',
      'import { itUnderHangBackstop } from "./support/backstop.js";',
      'await underHangBackstopped("x", body);',
      'await myunderHangBackstop("x", body);',
    ];
    // Reported as the failing samples rather than as a bare boolean, so a failure says which shape
    // moved. None of these carries the declared wording, so printing them is safe.
    expect(reaches.filter((sample) => !REACHES_THE_RAW_HELPER.test(sample))).toEqual([]);
    expect(doesNot.filter((sample) => REACHES_THE_RAW_HELPER.test(sample))).toEqual([]);
  });

  /**
   * **The two names vitest binds a test declarator to, read off its own types rather than guessed**
   * (PR #172, F1). `@vitest/runner` declares exactly two — `declare const test: TestAPI` and
   * `declare const it: TestAPI` — and `vitest` re-exports both. Everything else about a declaration
   * is a property chain hanging off one of those two.
   *
   * The chain is `ChainableTestAPI & ExtendedAPI & { extend }`, which in that same file is
   * `"concurrent" | "sequential" | "only" | "skip" | "todo" | "fails"` plus `each` and `for` (chained
   * as properties), plus `skipIf(cond)` and `runIf(cond)` (chained as *calls* that return the
   * chainable again), plus `extend`, which returns a whole new `TestAPI` **under a name of the
   * caller's choosing**. So the population is not a list of spellings and cannot be scanned for as
   * one, which is what the arm this replaces tried to do: it counted `/^\s*it\(/` and required zero,
   * so `test(`, `it.each(`, `it.skip(` and every other member of that surface walked straight past
   * it, and a hanging `test(` came back as `Test timed out in 5000ms.` — the undeclared,
   * repository-wide message this whole construct exists to replace.
   */
  const RAW_TEST_DECLARATORS = ["it", "test"];

  /**
   * A declaration-shaped *call*: one of those two names, as its own identifier, followed by any
   * property chain — including one whose segments are themselves calls, which is what `skipIf` and
   * `runIf` are — and then an opening `(` or a backtick, since ``it.each`table`(…)`` is a template
   * tag rather than a call.
   *
   * The leading lookbehind is what keeps `itUnderHangBackstop(`, `testDatabaseUrl(` and
   * `pattern.test(` out; measured against this whole tree, it matches **0** lines in any
   * `.db.test.ts` file and finds `it(` in every file that legitimately declares one, which is the
   * pair of facts that makes a zero here mean something.
   */
  const DECLARES_A_TEST_DIRECTLY =
    /(?<![A-Za-z0-9_$.])(it|test)\s*(\.\s*[A-Za-z_$][A-Za-z0-9_$]*\s*(\([^)]*\)\s*)?)*[(`]/;

  /**
   * Every `import … from "vitest"` clause in a file, as its raw text between `import` and `from`.
   *
   * **`[^;]` rather than `[\s\S]`, and the difference is a parser that reads the wrong statement.**
   * A lazy `[\s\S]*?` starts matching at the file's FIRST `import` keyword and runs to the vitest
   * `from`, so the clause it hands back is every import above the vitest one glued to part of it —
   * and the brace extraction below, being greedy, then pulls names out of whichever of those
   * happened to be there. Caught by watching a negative control not fire on the sibling scan in
   * `schema.test.ts`, which had the identical bug. A statement cannot contain a `;`, so excluding
   * one is what keeps a clause inside its own statement.
   */
  function vitestImportClauses(code: string): string[] {
    return [...code.matchAll(/import\s+([^;]*?)\s+from\s+["']vitest["']/g)].map((m) => m[1]!);
  }

  /**
   * How a file reaches a raw declarator, named rather than counted.
   *
   * **The import is the arm that actually closes this**, and the reason is one line up in
   * `vitest.config.ts`: `globals` is not enabled, so a declarator has to be imported before it can
   * be called, and every route into the file goes through a clause this reads. It matches the
   * *imported* name rather than the local one, so `import { it as t }` is caught; and a namespace
   * import is refused outright, because `import * as v from "vitest"` brings the whole surface in
   * under one name no specifier list can see and nothing in this suite needs it.
   */
  function reachesARawDeclarator(code: string): string[] {
    const found: string[] = [];
    for (const clause of vitestImportClauses(code)) {
      const namespace = /\*\s*as\s+([A-Za-z_$][A-Za-z0-9_$]*)/.exec(clause);
      if (namespace) { found.push(`namespace import \`* as ${namespace[1]}\``); continue; }
      const named = /\{([^}]*)\}/.exec(clause);
      for (const specifier of (named?.[1] ?? "").split(",")) {
        const imported = specifier.trim().split(/\s+as\s+/)[0]?.trim();
        if (imported !== undefined && RAW_TEST_DECLARATORS.includes(imported)) {
          found.push(`imports \`${specifier.trim()}\``);
        }
      }
    }
    if (DECLARES_A_TEST_DIRECTLY.test(code)) found.push("calls a raw declarator");
    return found;
  }

  it("knows every shape vitest accepts as a test declaration, and no shape it does not", () => {
    // **The pattern is the guard, so the pattern is what gets tested** — the same rule the raw-helper
    // scan below already carries (PR #156 review, F2), applied to a surface with far more spellings
    // in it. Every entry here is a real member of `TestAPI` as its own types declare it.
    const declares = [
      'it("x", body);',
      'test("x", body);',
      'it.skip("x", body);',
      'it.only("x", body);',
      'it.todo("x");',
      'it.fails("x", body);',
      'it.concurrent("x", body);',
      'it.sequential("x", body);',
      'test.each([1, 2])("x %i", body);',
      'it.for([1, 2])("x %i", body);',
      'it.skip.each([1])("x", body);',
      'it.skipIf(cond)("x", body);',
      'test.runIf(cond)("x", body);',
      'it.each`\n a \n`("x", body);',
      'it ("x", body);',
      '} else it("x", body);',
    ];
    const doesNot = [
      'itUnderHangBackstop("x", body);',
      'const url = testDatabaseUrl();',
      'expect(PATTERN.test(sample)).toBe(true);',
      'const latest = rows[0];',
      'describe("x", body);',
      'const t = myTest("x", body);',
    ];
    // Reported as the failing samples rather than as a bare boolean, so a failure says which shape
    // moved. None carries the declared wording, so printing them is safe under this file's header.
    expect(declares.filter((sample) => !DECLARES_A_TEST_DIRECTLY.test(sample))).toEqual([]);
    expect(doesNot.filter((sample) => DECLARES_A_TEST_DIRECTLY.test(sample))).toEqual([]);
  });

  it("sees a raw declarator arriving through any import shape, aliased or namespaced", () => {
    const reaches = [
      'import { it } from "vitest";',
      'import { test } from "vitest";',
      'import { it as t } from "vitest";',
      'import { afterAll, beforeAll, it, describe } from "vitest";',
      'import {\n  describe,\n  test as check,\n} from "vitest";',
      'import * as v from "vitest";',
      "import { test } from 'vitest';",
      // A vitest import that is not the file's first import, which is every real file's shape and
      // the case the clause parser used to get wrong.
      'import pg from "pg";\nimport { describe, it } from "vitest";',
    ];
    const doesNot = [
      'import { afterAll, beforeAll, describe, expect } from "vitest";',
      'import { itUnderHangBackstop } from "./support/backstop.js";',
      'import { testDatabaseUrl } from "./support/database.js";',
      'import { latest } from "./support/x.js";',
      // The other direction of the same parser bug: names belonging to a DIFFERENT statement must
      // not be read as this one's. Under the old any-character clause the `it` below was.
      'import { it } from "./support/mine.js";\nimport { describe, expect } from "vitest";',
    ];
    expect(reaches.filter((sample) => reachesARawDeclarator(sample).length === 0)).toEqual([]);
    expect(doesNot.filter((sample) => reachesARawDeclarator(sample).length > 0)).toEqual([]);
  });

  it("puts every database test under the backstop, because that is the whole population that waits on Postgres", () => {
    // **The rule, stated once: a test that waits on the database waits under the backstop; a test
    // that does not keeps vitest's default** (SONNY-354). It is drawn from measurement rather than
    // taste. A `.db.test.ts` test waits on work in another process whose cost this one does not
    // control, and the thinnest margin measured in that population was `migrate.db.test.ts`'s
    // rollback chain at 2483 ms of the 5000 ms default — a factor of two. Every other file in this
    // tree runs in-process: the whole non-database suite is 33 files under 300 ms each, so the
    // slowest single test in it has something like a 500x margin, against a worst measured
    // load-induced slowdown of 10x (`support/backstop.ts` has that measurement, and the caveat on
    // which half of it another machine could reproduce).
    //
    // So the line is drawn at the file suffix and there are no exceptions. Four tests in these
    // files are synchronous and touch no database; they are wrapped too, because an exemption list
    // is the thing that rots and one `async` keyword is cheaper than maintaining one.
    //
    // What this costs is stated in `support/backstop.ts` and is now owed by the whole database
    // population rather than by 2 tests: a mutant that makes one of them HANG and breaks nothing
    // else comes back UNATTRIBUTED rather than KILLED, which exits 2 like a survivor and is
    // reported rather than swallowed. What it does not cost is a mutant that makes one of them
    // WRONG — `underHangBackstop` rethrows the body's own error untouched, which the test above
    // pins on object identity.
    const offenders = everyTestSource()
      .filter((path) => path.endsWith(".db.test.ts"))
      .map((path) => ({ file: relative(testTree, path), how: reachesARawDeclarator(codeOf(path)) }))
      .filter((entry) => entry.how.length > 0);
    // Named with how, rather than as a bare boolean: a failure should say which file and which shape.
    expect(offenders).toEqual([]);
  });

  it("rests on globals being off, which is what makes the import arm exhaustive", () => {
    // Without `globals`, `it` and `test` are not in scope until a file imports them, so a clause
    // scan sees every route to one. Turn `globals` on and that stops being true — the call arm still
    // catches a direct call, but an alias assigned from a global would walk past both. This arm
    // exists so that flipping the config fails here, with a reason, instead of quietly widening what
    // the scan cannot see.
    expect(vitestConfig.test?.globals ?? false).toBe(false);
  });

  it("gives hooks and in-process tests deadlines this suite chose, not vitest's defaults", () => {
    // PR #172's F4. `beforeAll` ran on vitest's unchosen 10 s while SONNY-366 was putting a ~230 ms
    // schema rebuild inside one, in files that previously had a 4 ms no-op there. The headroom was
    // never the complaint; an inherited number was. Pinned against the constant rather than against
    // a literal, so the config and the construct cannot drift.
    expect(vitestConfig.test?.hookTimeout).toBe(VITEST_TIMEOUT_MS);
    // And the in-process population's deadline is written down at the value it already had, so a
    // future change to it is a decision somebody made rather than a default that moved.
    expect(vitestConfig.test?.testTimeout).toBe(5_000);
  });

  it("finds database tests to check at all, so the arms above are not passing on an empty tree", () => {
    // **The zero these arms have to refuse on their own terms.** `offenders` is empty whenever the
    // scan enumerates nothing — a renamed suffix, a moved directory, a `codeOf` that strips the
    // file. `CLAUDE.md`: a search whose engine cannot see the bytes you mean answers a clean zero,
    // and a clean zero is the one answer that looks like good news. So the population is asserted
    // against a floor of its own rather than against anything that could move with it.
    const files = everyTestSource().filter((path) => path.endsWith(".db.test.ts"));
    expect(files.length).toBeGreaterThanOrEqual(1);
    const declared = files.reduce(
      (total, path) => total + (codeOf(path).match(/^\s*itUnderHangBackstop\(/gm) ?? []).length, 0);
    expect(declared).toBeGreaterThanOrEqual(1);
    // And both halves of the offender check can produce a hit against real files, or their empty
    // answer above is not a measurement: the non-database files both import and call a raw
    // declarator, which is exactly what they are supposed to do.
    const elsewhere = everyTestSource()
      .filter((path) => !path.endsWith(".db.test.ts"))
      .filter((path) => reachesARawDeclarator(codeOf(path)).length > 0);
    expect(elsewhere.length).toBeGreaterThanOrEqual(1);
    const callsOneSomewhere = everyTestSource()
      .some((path) => DECLARES_A_TEST_DIRECTLY.test(codeOf(path)));
    expect(callsOneSomewhere).toBe(true);
  });

  it("is reached through itUnderHangBackstop everywhere else, so the two bounds cannot drift", () => {
    const direct = everyTestSource()
      .filter((path) => !ALLOWED_TO_REACH_THE_RAW_HELPER.has(relative(testTree, path)))
      .filter((path) => REACHES_THE_RAW_HELPER.test(codeOf(path)))
      .map((path) => relative(testTree, path));
    // A direct call inside a plain `it` gets vitest's default five seconds, so the backstop never
    // speaks and the generic timeout comes back — the defect, reintroduced silently.
    expect(direct).toEqual([]);
    // And the scan has to be able to find something, or its empty answer means nothing: the two
    // exempt files are where the reference really does live.
    const exempt = everyTestSource()
      .filter((path) => ALLOWED_TO_REACH_THE_RAW_HELPER.has(relative(testTree, path)))
      .filter((path) => REACHES_THE_RAW_HELPER.test(codeOf(path)))
      .map((path) => relative(testTree, path));
    expect(exempt.sort()).toEqual(["backstop.test.ts", "support/backstop.ts"]);
  });
});
