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
    await expect(underHangBackstop("work that never finishes", () => never, 50)).rejects.toThrow(Error);
  });

  it("says so in the wording a mutation battery is told not to read as a kill", async () => {
    const never = new Promise<void>(() => {});
    let message = "";
    try {
      await underHangBackstop("work that never finishes", () => never, 50);
    } catch (error) {
      message = (error as Error).message;
    }
    // Computed beforehand and asserted as a boolean, never `toContain`: a failing `toContain` prints
    // its expected value, which would put a declared signature into the log this guard's own
    // failure produces — and a guard whose failure matches a declaration is one the declaration
    // file switches off (PR #112 review, F1).
    const carriesTheDeclaredFragment = message.includes(HANG_BACKSTOP_DECLARED_FRAGMENT);
    expect(carriesTheDeclaredFragment).toBe(true);
    expect(message).toContain("work that never finishes");
    expect(message).toMatch(/scheduled \d+ times against a nominal \d+/);
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
    expect(caught).toBe(thrown);
    const dressedUpAsAHang = (caught as Error).message.includes(HANG_BACKSTOP_DECLARED_FRAGMENT);
    expect(dressedUpAsAHang).toBe(false);
  });

  it("keeps the declared fragment whole on one line, and opens no line a log reader would misread", () => {
    const lines = hangBackstopMessage("some work", 60_000, {
      observations: 5983, nominal: 6000, worstGapMs: 34,
    }).split("\n");
    const linesCarryingIt = lines.filter((line) => line.includes(HANG_BACKSTOP_DECLARED_FRAGMENT));
    // One line, because `scripts/mutate` matches a signature as a substring of the block it
    // reassembles out of the log, and a fragment split across two lines carries a newline the
    // declaration does not.
    expect(linesCarryingIt).toHaveLength(1);
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

  it("gives vitest a ceiling strictly above its own deadline", () => {
    // The other way round, vitest speaks first — with `Test timed out in Nms.`, a message every
    // test in this repository shares, which cannot be declared without excusing every timeout
    // everywhere. That is the failure this whole construct exists to replace.
    expect(VITEST_TIMEOUT_MS).toBeGreaterThan(HANG_BACKSTOP_MS);
  });

  it("is reached through itUnderHangBackstop everywhere else, so the two bounds cannot drift", () => {
    const allowed = new Set(["backstop.test.ts", "support/backstop.ts"]);
    const direct = everyTestSource()
      .filter((path) => !allowed.has(relative(testTree, path)))
      .filter((path) => /(?<![A-Za-z])underHangBackstop\s*\(/.test(codeOf(path)))
      .map((path) => relative(testTree, path));
    // A direct call inside a plain `it` gets vitest's default five seconds, so the backstop never
    // speaks and the generic timeout comes back — the defect, reintroduced silently.
    expect(direct).toEqual([]);
    // And the scan has to be able to find something, or its empty answer means nothing: the two
    // exempt files are where the call really does live.
    const exempt = everyTestSource()
      .filter((path) => allowed.has(relative(testTree, path)))
      .filter((path) => /(?<![A-Za-z])underHangBackstop\s*\(/.test(codeOf(path)))
      .map((path) => relative(testTree, path));
    expect(exempt.sort()).toEqual(["backstop.test.ts", "support/backstop.ts"]);
  });
});
