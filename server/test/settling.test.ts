import { describe, expect, it } from "vitest";
import { ABANDONED, settling } from "./support/settling.js";

/**
 * The barrier `migrate.db.test.ts` rests on, proved on its own (SONNY-357).
 *
 * **Nothing here waits on a clock, and that is the point.** The defect this construct fixes is a
 * test that lost a race, so a test of the fix that could itself lose one would be the same mistake a
 * level up — `CLAUDE.md`'s rule about never sleeping and then asserting on something another task is
 * racing you to. Every arm below drives the work with promises it resolves itself and asserts on a
 * recorded sequence of events, so the assertions hold at any speed.
 */
describe("the settling barrier", () => {
  /** A promise with its resolve and reject handles, so a test decides when work finishes. */
  function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void; reject: (e: unknown) => void } {
    let resolve!: (v: T) => void;
    let reject!: (e: unknown) => void;
    const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
    return { promise, resolve, reject };
  }

  it("returns what the work returned", async () => {
    const barrier = settling();
    expect(await barrier.track(async () => 42)).toBe(42);
    await barrier.settle();
  });

  it("rejects with the work's own failure, so an assertion failure stays one", async () => {
    const barrier = settling();
    const thrown = new Error("expected 3 to be 4");
    let caught: unknown;
    try {
      await barrier.track(async () => { throw thrown; });
    } catch (error) {
      caught = error;
    }
    // The identical object rather than an equal message: anything that wrapped it could attach this
    // construct's own wording, and a mutant that makes a test WRONG would then read as one that made
    // it slow.
    expect(caught === thrown).toBe(true);
    await barrier.settle();
  });

  it("resolves at once when nothing was ever tracked", async () => {
    const barrier = settling();
    let settled = false;
    await barrier.settle().then(() => { settled = true; });
    expect(settled).toBe(true);
  });

  it("does not resolve until abandoned work has actually stopped, which is the whole property", async () => {
    // The shape of an abandoned test, exactly: the body is still inside a step when the test ends.
    // `settle` must both tell it to stop AND wait for the step in flight, because the step is a
    // query on the client the next test is about to use.
    const barrier = settling();
    const events: string[] = [];
    const stepInFlight = deferred<void>();
    const sawTheSignal = deferred<void>();

    const abandoned = barrier.track(async (signal) => {
      for (let i = 0; i < 100; i += 1) {
        signal.throwIfAborted();
        events.push(`step ${i}`);
        // The first step never returns until this test lets it, which is what makes "a step in
        // flight" a state rather than a moment.
        if (i === 0) { sawTheSignal.resolve(); await stepInFlight.promise; }
      }
    });
    abandoned.catch(() => {});
    await sawTheSignal.promise;

    let settleResolved = false;
    const settling_ = barrier.settle().then(() => { settleResolved = true; events.push("settled"); });

    // The step is still in flight, so `settle` cannot have resolved. Asserted after draining the
    // microtask queue rather than after a delay: if `settle` were going to resolve without waiting,
    // it would have done so by now, and nothing here depends on how fast the machine is.
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
    expect(settleResolved).toBe(false);

    // Now let the step finish. The loop's next `throwIfAborted` ends it, and `settle` follows.
    stepInFlight.resolve();
    await settling_;
    expect(settleResolved).toBe(true);
    // One step ran and no more: the loop stopped at the abort rather than running its other 99.
    expect(events).toEqual(["step 0", "settled"]);
  });

  /**
   * Two bodies tracked before either finishes, released in a caller-chosen order, with `settle`
   * asserted not to resolve until the last of them has stopped.
   *
   * **Run in both orders, and that is not symmetry for its own sake.** A first version released the
   * second body first and passed against a deliberately broken barrier that tracked only the
   * *first* — because the body it was still waiting on happened to be the one that mutant kept.
   * One ordering can only ever exercise one slot; the mutants that survived it are recorded on the
   * two arms below.
   */
  async function settleWaitsForWhicheverFinishesLast(releaseFirstBodyFirst: boolean): Promise<string[]> {
    const barrier = settling();
    const events: string[] = [];
    const one = deferred<void>();
    const two = deferred<void>();
    const bothStarted = deferred<void>();
    let started = 0;
    const reachedStart = (): void => { started += 1; if (started === 2) bothStarted.resolve(); };

    const bodyOne = barrier.track(async (signal) => {
      reachedStart();
      await one.promise;
      events.push(signal.aborted ? "one saw the abort" : "one did not see an abort");
    });
    const bodyTwo = barrier.track(async (signal) => {
      reachedStart();
      await two.promise;
      events.push(signal.aborted ? "two saw the abort" : "two did not see an abort");
    });
    bodyOne.catch(() => {}); bodyTwo.catch(() => {});
    await bothStarted.promise;

    let settled = false;
    const settling_ = barrier.settle().then(() => { settled = true; events.push("settled"); });

    // **Draining the queues rather than waiting a while, and `setImmediate` rather than a handful
    // of `Promise.resolve()`s.** Node exhausts the microtask queue before it runs a macrotask, so
    // one turn through `setImmediate` flushes any finite promise chain — where three microtask hops
    // flush only three, which is fewer than the `.then().finally()` chain inside the barrier needs
    // to resolve. That is not a subtle distinction here: a shallow drain made this test pass
    // against two barriers that resolved a tick early, and it is what let the single-slot mutants
    // survive the first version of it. Two turns, so a body released on the first still lands on
    // the second. Nothing here depends on how fast the machine is.
    const drain = async (): Promise<void> => {
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));
    };
    await drain();
    events.push(settled ? "RESOLVED with both running" : "still waiting, both running");

    const [firstReleased, lastReleased] = releaseFirstBodyFirst ? [one, two] : [two, one];
    firstReleased.resolve();
    await drain();
    events.push(settled ? "RESOLVED with one still running" : "still waiting, one running");

    lastReleased.resolve();
    await settling_;
    return events;
  }

  it("waits for EVERY outstanding body, releasing the first-tracked one first", async () => {
    // **PR #172's F3.** The first version kept one controller and one promise, so a second `track`
    // overwrote both — the first body was never aborted and never waited for, and `settle` resolved
    // while it was still running. `settle` returning IS the guarantee, so a hole here is silent by
    // construction: the caller reads a resolved promise as "nothing is outstanding".
    //
    // **This ordering is the one that catches a barrier keeping only the first body.** A mutant
    // doing exactly that (`if (outstanding.size === 0) outstanding.add(stopped)`) SURVIVED the
    // single-ordering version of this test and is killed here.
    const events = await settleWaitsForWhicheverFinishesLast(true);
    expect(events).toEqual([
      "still waiting, both running",
      "one saw the abort",
      "still waiting, one running",
      "two saw the abort",
      "settled",
    ]);
  });

  it("waits for EVERY outstanding body, releasing the second-tracked one first", async () => {
    // The other slot: a barrier keeping only the most recent body — which is the defect as it
    // actually shipped — is killed here and not by the arm above.
    const events = await settleWaitsForWhicheverFinishesLast(false);
    expect(events).toEqual([
      "still waiting, both running",
      "two saw the abort",
      "still waiting, one running",
      "one saw the abort",
      "settled",
    ]);
  });

  it("stops an abandoned body with a message that says what happened", async () => {
    const barrier = settling();
    let message = "";
    const abandoned = barrier.track(async (signal) => {
      await Promise.resolve();
      signal.throwIfAborted();
    });
    abandoned.catch((error: unknown) => { message = (error as Error).message; });
    await barrier.settle();
    await abandoned.catch(() => {});
    expect(message).toBe(ABANDONED);
  });

  it("swallows a rejection that arrives after abandonment rather than letting it escape", async () => {
    // A body that rejects with something other than the abort — a query erroring because the schema
    // moved under it, which is exactly what an abandoned rollback produces. Nobody is left to catch
    // it, so `settle` has to, or it surfaces as an unhandled rejection inside a later test and reads
    // as that test's failure.
    const barrier = settling();
    const unhandled: unknown[] = [];
    const record = (reason: unknown): void => { unhandled.push(reason); };
    process.on("unhandledRejection", record);
    try {
      const late = deferred<void>();
      barrier.track(async () => { await late.promise; });
      const settled = barrier.settle();
      late.reject(new Error("relation \"sonny.identity\" does not exist"));
      await settled;
      // Two turns of the loop is where Node reports an unhandled rejection if it is going to.
      await new Promise((resolve) => setImmediate(resolve));
      await new Promise((resolve) => setImmediate(resolve));
    } finally {
      process.off("unhandledRejection", record);
    }
    expect(unhandled).toEqual([]);
  });
});
