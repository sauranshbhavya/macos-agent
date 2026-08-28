import { it } from "vitest";

/**
 * The deadline a server-suite test waits under when the thing it is waiting for is owned by
 * something else — another pooled connection, Postgres, three requests in flight at once — and the
 * rule that decides what reaching that deadline MEANS (SONNY-335, SONNY-241).
 *
 * **What was wrong.** `auth.db.test.ts`'s two sign-in concurrency tests were governed by vitest's
 * default `testTimeout` of 5000 ms, which nobody chose for them. Under mutation-battery load they
 * met it: SONNY-241 records a sighting at 5014 ms in PR #104's review and a second inside a
 * 17-mutant battery over SONNY-203's branch, and SONNY-335 a third in PR #148's cycle-2 battery,
 * where the two were counted as killing a mutant in `src/content/hook.ts` that their request path
 * cannot reach. That is the shape `scripts/mutate --help` names: a flaky test reads as a kill, and
 * it fails in the reassuring direction, recording a guard that does not exist.
 *
 * Two things were wrong with that deadline and only one of them is its length. Five seconds is a
 * default, not a bound anyone derived. And vitest's message for it — `Test timed out in 5000ms.` —
 * is shared by every test in this repository, so it cannot be declared in
 * `scripts/mutate-untrusted-failures` without excusing every timeout everywhere, genuine mutation
 * kills included. A construct with its own wording is what makes the declaration narrow enough to
 * be safe.
 *
 * **The Swift half's answer does not transfer, and that was measured rather than assumed.**
 * `HangBackstop` (SONNY-302) refuses to call a timeout a deadlock until the wait has evaluated its
 * condition 500 times, because in that test process thirty seconds of wall clock buys two looks —
 * so the count separates "the code never finished" from "this process never got a turn" where the
 * clock cannot. The same instrument was tried here and it separates nothing. Measured on this
 * repository's server suite against a Postgres in Docker, with a 5 ms probe interval, at four load
 * levels: idle-ish (1-minute load average 42), 24 shell spinners (49), 60-client `pgbench` (79),
 * and 40 CPU-bound `node` processes (155, rising to 194) — the probe ticked at **178, 178, 167 and
 * 171 per second** against a nominal 200, with worst single gaps of **12, 12, 14 and 46 ms**. In
 * the run at 171/s the first of the two tests took **2527 ms**, ten times its unloaded cost and
 * half the old budget. So the event loop stays healthy while the work gets ten times slower: an
 * observation floor set anywhere below the healthy population would have classified that run as a
 * deadlock, which is the manufactured kill this construct exists to stop. Node is not the Swift
 * main actor — the wait here is IO, not a poll queued behind hundreds of `@MainActor` jobs — and
 * the two populations the Swift floor separates simply are not two populations here.
 *
 * **So what is left is time, and the honest use of it is a bound rather than a threshold.** A
 * genuine hang never finishes; a slow machine finishes late. Nothing but waiting longer tells them
 * apart. ``HANG_BACKSTOP_MS`` is set far outside anything measured — sixty seconds against a worst
 * measured 2527 ms and against the ~5000 ms the reported failures met — so a run that reaches it is
 * one that never finished, and the wording says so. It is declared in
 * `scripts/mutate-untrusted-failures` all the same, for the reason that file's header gives: what
 * belongs there is "anything whose failure is a statement about the machine", and a wall clock on
 * work another process owns is exactly that however wide the margin. Understating coverage is the
 * safe direction; manufacturing it is not.
 *
 * **What that costs, stated rather than implied.** A mutant that genuinely hangs one of these two
 * tests, and breaks nothing else, comes back `UNATTRIBUTED` rather than `KILLED` — the battery says
 * it cannot tell, which is true. What it does not cost is a mutant that makes one of them *wrong*:
 * ``underHangBackstop`` rethrows whatever the body threw, untouched, so an assertion failure stays
 * an assertion failure and carries none of this wording. That direction is the one that matters and
 * `backstop.test.ts` holds it.
 *
 * **Both failure modes still fail, and neither hangs.** The wait is bounded by its own deadline,
 * and vitest's ceiling above it is bounded too.
 */

/**
 * Sixty seconds: the point past which work this suite waits on has not finished rather than being
 * slow.
 *
 * Chosen from measurement rather than feel — 24× the worst this suite has been observed to take
 * under deliberate load, and 12× the ~5000 ms the reported failures met — and it is the number two
 * tests in `auth.db.test.ts` and one in `races.db.test.ts` already carry by hand for the same
 * reason. It is not a timing assertion and nothing asserts a run stays under it.
 */
export const HANG_BACKSTOP_MS = 60_000;

/**
 * What vitest is told, and it must stay strictly greater than ``HANG_BACKSTOP_MS``.
 *
 * If vitest's own ceiling were the lower of the two it would speak first, with the generic message
 * this whole construct exists to replace — and that message is undeclared, so a load-caused failure
 * would go straight back to being counted as a mutation kill. `backstop.test.ts` pins the
 * inequality, and ``itUnderHangBackstop`` is the only door, so the two cannot be set apart by
 * anyone declaring a test.
 */
export const VITEST_TIMEOUT_MS = HANG_BACKSTOP_MS + 30_000;

/**
 * How often the scheduling probe looks, in milliseconds.
 *
 * Its count is **evidence for a reader and never a verdict** — see this file's header for the
 * measurement that rules the verdict out. It costs 6000 no-op callbacks across a full sixty-second
 * wait and about 24 across an ordinary one.
 */
const PROBE_INTERVAL_MS = 10;

/**
 * The literal `scripts/mutate-untrusted-failures` declares, so that a battery reads this failure as
 * the non-evidence it is.
 *
 * Exported and interpolated rather than written twice: the declaration's `sites 1` is asserted by
 * `UntrustedFailureDeclarationTests`, which since SONNY-334 counts across this tree as well as
 * `Tests/`, and a second literal copy would make that count wrong the day it landed. Nothing that
 * asserts on this value may quote it — a failing assertion prints its expected value, and a guard
 * whose own failure matches a declaration is a guard the declaration file switches off (PR #112
 * review, F1).
 */
export const HANG_BACKSTOP_DECLARED_FRAGMENT =
  "This is a server-suite hang backstop, not a timing assertion";

/** What the scheduling probe saw while a wait was outstanding. Evidence, not a verdict. */
export interface Scheduling {
  readonly observations: number;
  readonly nominal: number;
  readonly worstGapMs: number;
}

/**
 * The wording, on two rendered lines, with the declared fragment whole on the second.
 *
 * Whole on one line because `scripts/mutate` matches a signature as a substring of the block it
 * reassembles from the log, and a fragment split across two lines carries a newline the declaration
 * does not. No line here opens on `FAIL`, on `Test ` or on `Suite `, each of which is a boundary in
 * one of the two log readers that harness carries.
 */
export function hangBackstopMessage(
  description: string,
  elapsedMs: number,
  scheduling: Scheduling,
): string {
  const seconds = (elapsedMs / 1000).toFixed(1);
  return [
    `waited ${seconds}s for: ${description}, and it never finished.`,
    `${HANG_BACKSTOP_DECLARED_FRAGMENT} — this deadline is far outside anything this suite has`
      + ` been measured at, so reaching it means the work never finished rather than that it was`
      + ` slow, and on a machine loaded past that margin it means neither. It is not read as a`
      + ` mutation kill for that reason. While it waited this process was scheduled`
      + ` ${scheduling.observations} times against a nominal ${scheduling.nominal}, the longest`
      + ` single gap being ${scheduling.worstGapMs}ms; gaps of seconds there are the machine, and`
      + ` gaps like these are not.`,
  ].join("\n");
}

/**
 * Run `work` under the backstop, returning what it returned.
 *
 * Rethrows whatever `work` threw, untouched — an assertion failure inside a backstopped test is
 * evidence about a mutant and must keep looking like one.
 *
 * Exported for `backstop.test.ts`, which is the only file allowed to call it directly; every other
 * caller goes through ``itUnderHangBackstop`` so that the vitest timeout and this deadline cannot
 * be set apart. `backstop.test.ts` scans this tree for the exceptions.
 */
export async function underHangBackstop<T>(
  description: string,
  work: () => Promise<T>,
  deadlineMs: number = HANG_BACKSTOP_MS,
): Promise<T> {
  const startedAt = Date.now();
  let observations = 0;
  let worstGapMs = 0;
  let lastTickAt = startedAt;
  const probe = setInterval(() => {
    const now = Date.now();
    observations += 1;
    worstGapMs = Math.max(worstGapMs, now - lastTickAt);
    lastTickAt = now;
  }, PROBE_INTERVAL_MS);
  // Never the reason the process stays alive: a probe that outlived its wait would hold vitest's
  // worker open after the suite had finished.
  probe.unref();

  let timer: NodeJS.Timeout | undefined;
  try {
    const running = work();
    // The abandoned promise is still pending when the deadline wins, and a rejection arriving after
    // that is nobody's to handle — swallow it here rather than let it surface as an unhandled
    // rejection in whatever test happens to be running by then.
    running.catch(() => {});
    const deadline = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        const elapsedMs = Date.now() - startedAt;
        reject(new Error(hangBackstopMessage(description, elapsedMs, {
          observations,
          nominal: Math.round(elapsedMs / PROBE_INTERVAL_MS),
          worstGapMs,
        })));
      }, deadlineMs);
      timer.unref();
    });
    return await Promise.race([running, deadline]);
  } finally {
    clearInterval(probe);
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * Declare a test whose whole body runs under the backstop.
 *
 * One call sets both bounds, which is the point: a test declared this way cannot be given vitest's
 * default five seconds by accident, and the backstop cannot be reached by a test vitest would kill
 * first. The whole body rather than one awaited expression, because everything in these tests —
 * building the app, the requests, the queries after them, `app.close()` — waits on the same
 * database and slows together.
 */
export function itUnderHangBackstop(name: string, body: () => Promise<void>): void {
  it(name, { timeout: VITEST_TIMEOUT_MS }, async () => {
    await underHangBackstop(name, body);
  });
}
