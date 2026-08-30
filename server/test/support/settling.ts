/**
 * The barrier that keeps an abandoned test's database work from reaching the test after it
 * (SONNY-357).
 *
 * **What goes wrong without one.** `migrate.db.test.ts` rolls the whole migration chain back a
 * migration at a time inside a `for` loop. When a deadline fires — vitest's, or the hang backstop's
 * — the test is failed and the runner moves on, and **nothing stops the loop**. It keeps issuing
 * `down()` against the client the rest of the file shares, so the next test's `up()` races a
 * rollback still in flight and reports a schema error describing a state the tree never had. One
 * slow test therefore produces one failure plus an unpredictable set of downstream ones, none of
 * whose messages point at the cause — and under a mutation battery that is SONNY-224's manufactured
 * kill reached through a timeout, a mutant recorded as caught by a test that only lost a race.
 *
 * **What this does.** `track` runs a body and remembers it. `settle` aborts everything tracked and
 * does not resolve until all of it has actually stopped. Called from an `afterEach`, which vitest runs
 * after a timed-out test and awaits, that makes "no work is outstanding when the next test starts" a
 * property of the file rather than a hope. The body cooperates by calling `signal.throwIfAborted()`
 * at each step of a loop; a step already in flight is waited for rather than interrupted, which is
 * the whole of what `settle` promises.
 *
 * **What it does not do, and why the alternative was rejected.** SONNY-357 also asks whether the
 * chain tests should hold their own connection so a slow teardown cannot reach their neighbours. It
 * would remove one hazard and not the one that matters. A `pg.Client` serialises its own queue, so
 * the neighbour's danger is not an interleaved statement — it is landing inside the abandoned
 * transaction, which a private connection does fix, and the schema changing underneath it, which a
 * private connection does not fix at all, because both connections address the same database. The
 * barrier closes both, and a second connection under it would be depth against the case where the
 * barrier itself times out. That case is a Postgres that has stopped answering a single-statement
 * rollback, which is a broken database rather than a slow test, and it announces itself as a failing
 * hook naming the file instead of as a wrong answer somewhere downstream.
 */

export interface Settling {
  /**
   * Runs `work` and tracks it. Returns exactly what `work` returned, and rejects with exactly what
   * it threw — an assertion failure inside a tracked body has to stay an assertion failure, or a
   * mutant that makes a test WRONG would be dressed up as one that made it slow.
   */
  track<T>(work: (signal: AbortSignal) => Promise<T>): Promise<T>;
  /**
   * Aborts **everything** tracked and resolves once all of it has stopped, whether each stopped by
   * finishing or by throwing. Never rejects: a body abandoned by a deadline has already failed its
   * test, and its rejection belongs to nobody by the time this runs. Resolves immediately when
   * nothing is tracked.
   */
  settle(): Promise<void>;
}

/**
 * The message an abandoned body throws with, so a log that carries it says what happened rather than
 * showing a loop that stopped for no stated reason.
 *
 * Deliberately **not** declared in `scripts/mutate-untrusted-failures`. It can only appear on a test
 * that has already failed some other way — a deadline fired — so it is never the only red a mutant
 * has against it, and declaring it would be declaring a consequence rather than a cause.
 */
export const ABANDONED =
  "abandoned: the test that started this work ended before it finished, so it was stopped here " +
  "rather than left running against a client the next test uses";

export function settling(): Settling {
  /**
   * **Every outstanding body, not the most recent one** (PR #172, F3). The first version kept a
   * single controller and a single `stopped` promise, so a second `track` overwrote both: the first
   * body's controller was dropped, so `settle` never aborted it, and its promise was dropped, so
   * `settle` resolved while it was still running. That is a hole in the middle of the one construct
   * whose entire job is to guarantee nothing is still running — and it is silent, because `settle`
   * returning is what the caller reads as the guarantee being met.
   *
   * A set closes it without needing a rule about how many times a test may call `track`, which is
   * the right shape: the barrier should be correct under any usage rather than correct under the
   * usage it happens to have today.
   */
  const live = new Set<AbortController>();
  const outstanding = new Set<Promise<void>>();

  return {
    track(work) {
      const controller = new AbortController();
      live.add(controller);
      const running = work(controller.signal);
      // Two references to one promise, deliberately. The caller gets `running` and sees its
      // rejection; the set holds the same promise with both outcomes flattened, so `settle` can
      // wait for it without adopting a failure that is not its to report — and so an abandoned
      // body's rejection is handled here rather than surfacing as an unhandled rejection inside
      // whatever test happens to be running by then.
      const stopped: Promise<void> = running.then(() => {}, () => {}).finally(() => {
        outstanding.delete(stopped);
        live.delete(controller);
      });
      outstanding.add(stopped);
      return running;
    },
    async settle() {
      // A loop rather than one pass: a body that starts another body while this is waiting would
      // otherwise be left live and un-awaited, which is the defect this method was just fixed for,
      // one level in. Each awaited promise removes itself, so the set empties and this terminates
      // for any body that does not spawn work forever — and one that does is a runaway test, which
      // reaches the hook's own deadline and says so rather than being silently half-waited-for.
      while (outstanding.size > 0) {
        for (const controller of live) controller.abort(new Error(ABANDONED));
        await Promise.all([...outstanding]);
      }
      // **Clears nothing, today, and that is recorded rather than chased** (PR #172 cycle 2, F3).
      // Every entry in `live` is removed by its own body's `.finally()`, and the loop above does
      // not exit until every one of those has run — so deleting this line is an EQUIVALENT mutant
      // and was confirmed as one by deleting it and watching all 9 tests pass. It stays as the
      // statement that `live` is empty when this returns, which is a property a reader otherwise
      // has to re-derive from two `.finally()` bodies twenty lines up.
      live.clear();
    },
  };
}
