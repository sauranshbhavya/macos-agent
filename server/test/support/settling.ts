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
 * **What this does.** `track` runs a body and remembers it. `settle` aborts whatever is tracked and
 * does not resolve until it has actually stopped. Called from an `afterEach`, which vitest runs
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
   * Aborts anything tracked and resolves once it has stopped, whether it stopped by finishing or by
   * throwing. Never rejects: a body abandoned by a deadline has already failed its test, and its
   * rejection belongs to nobody by the time this runs. Resolves immediately when nothing is tracked.
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
  let controller: AbortController | undefined;
  let stopped: Promise<void> = Promise.resolve();

  return {
    track(work) {
      controller = new AbortController();
      const running = work(controller.signal);
      // Two references to one promise, deliberately. The caller gets `running` and sees its
      // rejection; `stopped` is the same promise with both outcomes flattened, so `settle` can wait
      // for it without adopting a failure that is not its to report — and so an abandoned body's
      // rejection is handled here rather than surfacing as an unhandled rejection inside whatever
      // test happens to be running by then.
      stopped = running.then(() => {}, () => {});
      return running;
    },
    async settle() {
      controller?.abort(new Error(ABANDONED));
      await stopped;
      controller = undefined;
      stopped = Promise.resolve();
    },
  };
}
