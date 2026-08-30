import { afterAll, afterEach, beforeAll, beforeEach, it } from "vitest";

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
 * clock cannot. The same instrument was tried here and it separates nothing. Measured with a
 * throwaway 5 ms interval probe against a Postgres in Docker, at four load levels: the machine as
 * found (1-minute load average 42), 24 shell spinners (49), 60-client `pgbench` (79), and 40
 * CPU-bound `node` processes (155, rising to 194) — the probe ticked at **178, 178, 167 and 171 per
 * second** against a nominal 200, with worst single gaps of **12, 12, 14 and 46 ms**. In the run at
 * 171/s the first of the two tests took **2527 ms**, ten times its unloaded cost and half the old
 * budget. So the event loop stays healthy while the work gets ten times slower: an observation
 * floor set anywhere below the healthy population would have classified that run as a deadlock,
 * which is the manufactured kill this construct exists to stop. Node is not the Swift main actor —
 * the wait here is IO, not a poll queued behind hundreds of `@MainActor` jobs — and the two
 * populations the Swift floor separates simply are not two populations here.
 *
 * **Half of that measurement has been reproduced independently and half has not** (PR #172's
 * review, recorded rather than fixed). The tick-rate half held: three probes at one-minute load
 * averages of 18, 20 and 33 came back **168.4, 177.1 and 173.7 ticks per second** against a nominal
 * 200, which is the load-independence the rejection above turns on and is squarely inside the
 * 167-178 measured here. The **query-slowdown** half did not: on that machine mean query time did
 * not move under `pgbench` plus 40 spinners (**40.8 ms → 39.0 ms**), because Docker Desktop holds
 * its own vCPUs there and the load never reached Postgres. So the 2527 ms figure below, and the
 * "ten times its unloaded cost" it is quoted for, rest on one machine's measurement and should be
 * read that way. The rejection does not depend on them — it depends on the event loop staying
 * healthy, which is the half that reproduced — but a number nobody else has been able to see should
 * say so where it is used.
 *
 * **Nothing runs while the work runs, and that is the second thing this construct owes these two
 * tests.** The first version kept the probe at run time and printed its count in the message as
 * evidence for a reader. It was removed, because a periodic timer is the one part of a deadline
 * that can perturb what the deadline is guarding, and these two tests measure a race between three
 * database transactions. Measured over the same mutant — R1, the per-address advisory lock deleted
 * from `src/auth/codes.ts` — by running `scripts/mutate <plan> --only R1` repeatedly and counting
 * the runs whose report named the plus-tag test as a killer. Three arms:
 *
 * - **5 of 9** with the probe in place;
 * - **8 of 10** with it removed;
 * - **8 of 9** valid runs on `main`'s own copy of `auth.db.test.ts` grafted onto this branch — a
 *   tenth is excluded there because its baseline went red, and that run is the flake this branch
 *   fixes, reproduced.
 *
 * Not a decisive difference at that sample size, and the wrong side of an undecidable question to
 * be on for a diagnostic whose number was already measured as unable to support a verdict. What is
 * left in the wait is one `setTimeout` that does nothing until it fires. (This paragraph said
 * "6 of 10 ... against 8 of 9 on the copy without it" until PR #156's review, F1: a pair that was
 * never measured, reassigning `main`'s arm to the without-probe one and putting the two arms one
 * run apart rather than three — in the file a session comes to when deciding whether to put the
 * probe back.)
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
 * under deliberate load (see the caveat above on which half of that reproduced), and 12× the
 * ~5000 ms the reported failures met. It is the number five tests across `auth.db.test.ts`,
 * `entitlement.db.test.ts`, `races.db.test.ts` and `migrate.db.test.ts` had already reached for by
 * hand for the same reason, each writing it as a raw `{ timeout: 60_000 }` that set vitest's
 * ceiling and left its message generic; SONNY-354 folded all five in. It is not a timing assertion
 * and nothing asserts a run stays under it.
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

/**
 * The wording, on two rendered lines, with the declared fragment whole on the second.
 *
 * Whole on one line because `scripts/mutate` matches a signature as a substring of the block it
 * reassembles from the log, and a fragment split across two lines carries a newline the declaration
 * does not. No line here opens on `FAIL`, on `Test ` or on `Suite `, each of which is a boundary in
 * one of the two log readers that harness carries.
 */
export function hangBackstopMessage(description: string, elapsedMs: number): string {
  const seconds = (elapsedMs / 1000).toFixed(1);
  return [
    `waited ${seconds}s for: ${description}, and it never finished.`,
    `${HANG_BACKSTOP_DECLARED_FRAGMENT} — this deadline is far outside anything this suite has`
      + ` been measured at, so reaching it means the work never finished rather than that it was`
      + ` slow, and on a machine loaded past that margin it means neither. It is not read as a`
      + ` mutation kill for that reason. Re-run it alone on a quieter machine; if it happens there`
      + ` too, look for what is not completing rather than for what is slow.`,
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
  let timer: NodeJS.Timeout | undefined;
  try {
    const running = work();
    // The abandoned promise is still pending when the deadline wins, and a rejection arriving after
    // that is nobody's to handle — swallow it here rather than let it surface as an unhandled
    // rejection in whatever test happens to be running by then.
    running.catch(() => {});
    const deadline = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        reject(new Error(hangBackstopMessage(description, Date.now() - startedAt)));
      }, deadlineMs);
      // Never the reason the process stays alive: a pending deadline that outlived its wait would
      // hold vitest's worker open after the suite had finished.
      timer.unref();
    });
    return await Promise.race([running, deadline]);
  } finally {
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

/**
 * The four hooks a database file uses, each under the same deadline and the same declared wording
 * as `itUnderHangBackstop` (PR #172 cycle 2, F4).
 *
 * **A chosen hook deadline was still an undeclared one, and this branch is what made that
 * reachable.** Cycle 1's F4 replaced vitest's inherited 10 s `hookTimeout` with 90 s, which fixed
 * the number and not the message: a hook that reaches it fails with `Hook timed out in 90000ms.`,
 * a wording every hook in this repository shares, so `scripts/mutate-untrusted-failures` cannot
 * declare it without excusing a genuine mutant-induced hang in any hook anywhere — and undeclared
 * means a battery counts it as a kill. That is SONNY-224's manufactured kill arriving through the
 * hook path, and the path is one SONNY-366 widened by putting a ~230 ms schema rebuild into every
 * `beforeAll` where seven files had a 4 ms no-op. The argument is the same one already made for the
 * test population; the conclusion has to be too.
 *
 * So the hook body runs under ``underHangBackstop``, whose wording IS declared, and vitest's own
 * ceiling is set above it exactly as it is for a test — the backstop speaks first, and the generic
 * message is unreachable rather than merely unlikely. Measured by dropping ``HANG_BACKSTOP_MS`` to
 * one second and hanging a `beforeAll`: the run carried `waited 1.0s for: a beforeAll hook` and the
 * declared fragment, and `Hook timed out in` appeared nowhere in it.
 *
 * **What this drops, stated rather than discovered later:** vitest lets a `beforeAll`/`beforeEach`
 * body return a cleanup function, which it calls afterwards. These wrappers return `void`, so that
 * feature is not available through them. Nothing in this suite uses it; a file that needs it needs
 * a wrapper that forwards it, not a raw hook.
 *
 * `aroundAll` and `aroundEach` are the two hooks vitest exports that have no wrapper here. They are
 * unused, and `backstop.test.ts` refuses them in a database file for that reason — fail-closed, so
 * the first file that wants one has to add a wrapper rather than quietly reopen this.
 */
export function beforeAllUnderHangBackstop(body: () => Promise<void>): void {
  beforeAll(async () => { await underHangBackstop("a beforeAll hook", body); }, VITEST_TIMEOUT_MS);
}

export function beforeEachUnderHangBackstop(body: () => Promise<void>): void {
  beforeEach(async () => { await underHangBackstop("a beforeEach hook", body); }, VITEST_TIMEOUT_MS);
}

export function afterAllUnderHangBackstop(body: () => Promise<void>): void {
  afterAll(async () => { await underHangBackstop("an afterAll hook", body); }, VITEST_TIMEOUT_MS);
}

export function afterEachUnderHangBackstop(body: () => Promise<void>): void {
  afterEach(async () => { await underHangBackstop("an afterEach hook", body); }, VITEST_TIMEOUT_MS);
}
