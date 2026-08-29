import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { FALLBACK_DATABASE_URL, testDatabaseUrl } from "./support/database.js";

/**
 * **The guard on SONNY-352's defect: a test file naming the port the runner exists to choose.**
 *
 * `npm run test:db` sets `DATABASE_URL` and falls back to one documented container. Two files
 * ignored it and wrote that port as a literal, so the variable was configurable for most of the
 * suite and inert for those two — which stays invisible until two lanes run at once, and then reads
 * as a suite-wide failure with nothing in the output naming the cause. `support/database.ts` is now
 * the single place that port is written, and this is what keeps it single.
 *
 * **Narrow by design.** Four other files name a connection string for good reasons — port 1 to
 * prove a pool does not connect, port 5432 as config shape, one planted inside a fake error to prove
 * it is redacted — so a blanket ban would need an exemption list, and an exemption list rots into a
 * guard that exempts the defect.
 */
const TEST_DIR = new URL(".", import.meta.url).pathname;

/** The port the runner is supposed to decide. Derived, so changing the fallback moves the guard. */
const RUNNER_PORT = new URL(FALLBACK_DATABASE_URL).port;

/** The one file allowed to write it. Asserted to exist and to contain it, so a stale name shows. */
const OWNER = join("support", "database.ts");

function testSources(dir: string, prefix = ""): { path: string; text: string }[] {
  const found: { path: string; text: string }[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = join(prefix, entry.name);
    if (entry.isDirectory()) found.push(...testSources(join(dir, entry.name), rel));
    else if (entry.name.endsWith(".ts")) found.push({ path: rel, text: readFileSync(join(dir, entry.name), "utf8") });
  }
  return found;
}

/** A connection string naming the runner's port, in any of the two schemes `pg` accepts. */
function namesRunnerPort(text: string): boolean {
  return new RegExp(String.raw`postgres(ql)?://[^\s"']*:${RUNNER_PORT}\b`).test(text);
}

describe("one knob sets the test database's port", () => {
  it("finds test sources at all, so a clean result is a result and not an empty scan", () => {
    // **Refused on its own terms, not by comparison** (CLAUDE.md, SONNY-334). A scan that enumerates
    // nothing satisfies every assertion below by finding nothing, which is the defect this guard was
    // written for reached through the one door it would not watch.
    const sources = testSources(TEST_DIR);
    expect(sources.length).toBeGreaterThan(0);
    expect(sources.map((s) => s.path)).toContain(OWNER);
  });

  it("detects a connection string naming the runner's port, so a pass means it looked", () => {
    // The positive control. A matcher that cannot produce a hit has not been tested and its zero is
    // not a measurement — the false-zero rule, applied to this guard's own regex.
    expect(namesRunnerPort(`DATABASE_URL: "postgres://postgres:postgres@localhost:${RUNNER_PORT}/postgres"`)).toBe(true);
    // No credentials in this one: `check:secrets` allowlists exactly `postgres://postgres:postgres@`
    // and reads any other user:password pair before an @ as a real DSN, this comment included —
    // which it did, on the sentence that used to spell one out. The scheme is what is under test here.
    expect(namesRunnerPort(`postgresql://localhost:${RUNNER_PORT}/x`)).toBe(true);
    // ...and does not fire on the connection strings that are legitimately here.
    expect(namesRunnerPort("postgres://postgres:postgres@localhost:1/db")).toBe(false);
    expect(namesRunnerPort("postgres://postgres:postgres@localhost:5432/sonny")).toBe(false);
  });

  it("is written in exactly one file, which is the one that owns the fallback", () => {
    const offenders = testSources(TEST_DIR)
      .filter((source) => source.path !== OWNER && namesRunnerPort(source.text))
      .map((source) => source.path);
    expect(offenders).toEqual([]);
    // And the owner really does carry it, so renaming or emptying that file cannot pass silently.
    const owner = testSources(TEST_DIR).find((source) => source.path === OWNER)!;
    expect(namesRunnerPort(owner.text)).toBe(true);
  });

  it("hands back DATABASE_URL when the runner set one, and the documented container when it did not", () => {
    const before = process.env["DATABASE_URL"];
    try {
      process.env["DATABASE_URL"] = "postgres://postgres:postgres@elsewhere:5599/db";
      expect(testDatabaseUrl()).toBe("postgres://postgres:postgres@elsewhere:5599/db");
      delete process.env["DATABASE_URL"];
      expect(testDatabaseUrl()).toBe(FALLBACK_DATABASE_URL);
    } finally {
      if (before === undefined) delete process.env["DATABASE_URL"];
      else process.env["DATABASE_URL"] = before;
    }
  });
});
