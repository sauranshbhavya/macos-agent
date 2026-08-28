import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
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
