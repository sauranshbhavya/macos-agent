import pg from "pg";
import { describe, expect } from "vitest";
import { pooledConnections } from "../src/db/pool.js";
import { leasingUnderTotalDeadline, underTotalDeadline } from "../src/model/routing.js";
import { ProviderTimedOut } from "../src/model/upstream.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * The account routes' lease against a real Postgres and a real `pg.Pool` (SONNY-434, PR #235's fresh
 * review, F1 and F3).
 *
 * `account-deadline.test.ts` holds the arithmetic over a fake that honours `statement_timeout`; what
 * a fake cannot say is what Postgres does with the number it is handed, or what a real pool does with
 * a wait. Two things are measured here and nowhere else: that a statement blocked on another
 * connection's lock is cut at **whichever of the pool's bound and the budget's remainder comes
 * first**, in both directions; and that a wait for a pooled connection ends at the budget while the
 * pool still has nothing, with the connection the pool hands over afterwards going straight back.
 *
 * **The bounds are shortened, for `statement-timeout.db.test.ts`'s reason**: the production numbers
 * are ten and fifteen seconds, and the unit file pins that the wiring's default ceiling is the pool's
 * `STATEMENT_TIMEOUT_MS`; what this file trades away by passing a small `perStatementMs` is ten
 * seconds of waiting per direction, not anything it asserts.
 *
 * Skips without `DATABASE_URL`, like every other `*.db.test.ts`; the run announces that once,
 * loudly, from `global-setup.ts`.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

/** `SHOW statement_timeout` renders with a unit; this reads it back as milliseconds. */
function millisecondsShown(shown: string): number {
  const match = /^(\d+)(ms|s|min)?$/.exec(shown.trim());
  if (match === null) throw new Error(`not a statement_timeout reading: ${shown}`);
  const scale = match[2] === "s" ? 1_000 : match[2] === "min" ? 60_000 : 1;
  return Number(match[1]) * scale;
}

describeDb("the account routes' lease against a real Postgres (SONNY-434)", () => {
  let setup: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    setup = new pg.Client({ connectionString: url });
    await setup.connect();
    await rebuildSchema(setup);
  });
  afterAllUnderHangBackstop(async () => {
    await setup.end();
  });

  /**
   * One lease against a locked table, under a budget and a ceiling of the test's choosing: what
   * Postgres was handed for the statement (read back with `SHOW` through the same bounded client,
   * which sets the bound before the `SHOW` exactly as before any statement), how the lease ended,
   * and how long it took.
   */
  async function leaseAgainstTheLock(input: { budgetMs: number; ceilingMs: number }) {
    const wiring = pooledConnections(url!, { max: 1, statementTimeoutMillis: input.ceilingMs });
    const lease = leasingUnderTotalDeadline(wiring.withConnection, { perStatementMs: input.ceilingMs });
    const holder = new pg.Client({ connectionString: url });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("LOCK TABLE sonny.entitlement IN ACCESS EXCLUSIVE MODE");
      let handed = "";
      const started = Date.now();
      const outcome = await underTotalDeadline({ total: input.budgetMs }, () =>
        lease(async (client) => {
          const shown = await client.query<{ statement_timeout: string }>("SHOW statement_timeout");
          handed = shown.rows[0]!.statement_timeout;
          await client.query("SELECT count(*) FROM sonny.entitlement");
        }),
      ).then(
        () => "completed" as const,
        (error: unknown) => error,
      );
      const elapsedMs = Date.now() - started;
      // Still held: the wait ended because the statement was cancelled, not because the lock lifted.
      const { rows } = await setup.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM pg_locks WHERE relation = 'sonny.entitlement'::regclass AND mode = 'AccessExclusiveLock' AND granted",
      );
      expect(rows[0]!.n).toBe("1");
      // And the connection went back at the pool's own value, not at the lease's.
      const afterwards = await wiring.withConnection(async (client) => {
        const shown = await client.query<{ statement_timeout: string }>("SHOW statement_timeout");
        return shown.rows[0]!.statement_timeout;
      });
      return { outcome, handedMs: millisecondsShown(handed), elapsedMs, afterwardsMs: millisecondsShown(afterwards) };
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
      await holder.end();
      await wiring.close();
    }
  }

  itUnderHangBackstop("underABudgetWiderThanThePoolsBoundAStatementIsCutAtThePoolsBound", async () => {
    // F1's direction: ten seconds of budget, a half-second ceiling. The statement is handed the
    // ceiling, not the remainder, and is cancelled there — the review's eleven-second statement
    // completing inside the budget is exactly this reading coming back as the remainder.
    const reading = await leaseAgainstTheLock({ budgetMs: 10_000, ceilingMs: 500 });

    expect(reading.outcome).toBeInstanceOf(ProviderTimedOut);
    expect(reading.handedMs).toBe(500);
    // Cut at the ceiling, not at the budget: a generous bound on wall time, ten times the ceiling
    // and half the budget, so a machine has to be very slow indeed to fail this for the wrong reason
    // and the failure it guards against — a ten-second wait — clears it by a factor of two.
    expect(reading.elapsedMs).toBeLessThan(5_000);
    expect(reading.afterwardsMs).toBe(500);
  });

  itUnderHangBackstop("underABudgetNarrowerThanThePoolsBoundAStatementIsCutAtTheBudget", async () => {
    // The other direction: a five-second ceiling, three hundred milliseconds of budget. The
    // statement is handed what is left of the budget — at most three hundred — and is cancelled
    // there, well before the ceiling could have.
    const reading = await leaseAgainstTheLock({ budgetMs: 300, ceilingMs: 5_000 });

    expect(reading.outcome).toBeInstanceOf(ProviderTimedOut);
    expect(reading.handedMs).toBeGreaterThan(0);
    expect(reading.handedMs).toBeLessThanOrEqual(300);
    expect(reading.elapsedMs).toBeLessThan(2_500);
    expect(reading.afterwardsMs).toBe(5_000);
  });

  /**
   * The pool's only connection, held by a lease that sleeps, with the moment it took the connection
   * signalled rather than guessed at: the pool is warmed first so the holder reuses an open socket
   * and `held` resolves the instant the holder has it, which is what makes "the second lease was
   * answered while the holder still held" a state check and not a clock.
   */
  async function holdTheOnlyConnection(
    wiring: ReturnType<typeof pooledConnections>,
    sleepSeconds: number,
  ): Promise<{ readonly done: Promise<void>; readonly stillHolding: () => boolean }> {
    await wiring.withConnection(async (client) => client.query("SELECT 1"));
    let holding = false;
    let signal!: () => void;
    const held = new Promise<void>((resolve) => {
      signal = resolve;
    });
    const done = wiring.withConnection(async (client) => {
      holding = true;
      signal();
      await client.query(`SELECT pg_sleep(${sleepSeconds})`);
      holding = false;
    });
    await held;
    return { done, stillHolding: () => holding };
  }

  itUnderHangBackstop("aWaitForAPooledConnectionThatOutlastsTheBudgetEndsAtTheBudgetAndRunsNothingOnTheConnectionItIsHanded", async () => {
    // F3, in the reviewer's shape against a real pool: one connection, held by a lease that sleeps
    // for longer than the budget; a second lease under that budget.
    const wiring = pooledConnections(url!, { max: 1 });
    const lease = leasingUnderTotalDeadline(wiring.withConnection);
    let ran = 0;
    try {
      const holder = await holdTheOnlyConnection(wiring, 1.5);

      const late = await underTotalDeadline({ total: 300 }, () =>
        lease(async (client) => {
          ran += 1;
          await client.query("SELECT 1");
        }),
      ).then(
        () => "completed" as const,
        (error: unknown) => error,
      );

      expect(late).toBeInstanceOf(ProviderTimedOut);
      expect(holder.stillHolding()).toBe(true);
      expect(ran).toBe(0);

      await holder.done;
      // The abandoned lease's connection went back without running its work, and the pool is whole:
      // a third lease is served.
      const answer = await wiring.withConnection(async (client) => (await client.query("SELECT 2::int AS n")).rows[0]);
      expect(answer).toEqual({ n: 2 });
      expect(ran).toBe(0);
    } finally {
      await wiring.close();
    }
  });

  itUnderHangBackstop("thePoolsOwnConnectTimeoutInsideABudgetIsAnsweredAsATimeout", async () => {
    // The pool giving up before the budget does — the review's B4, where the answer was a `500`.
    // `connectionTimeoutMillis` is the real library's, so the wording `leasingUnderTotalDeadline`
    // matches is the wording `pg-pool` really emits for a wait in its queue; two seconds rather than
    // the review's default five keeps the test short, and the holder outlasts it.
    const wiring = pooledConnections(url!, { max: 1, connectionTimeoutMillis: 2_000 });
    const lease = leasingUnderTotalDeadline(wiring.withConnection);
    try {
      const holder = await holdTheOnlyConnection(wiring, 3);

      const late = await underTotalDeadline({ total: 10_000 }, () =>
        lease(async (client) => client.query("SELECT 1")),
      ).then(
        () => "completed" as const,
        (error: unknown) => error,
      );

      expect(late).toBeInstanceOf(ProviderTimedOut);
      expect(holder.stillHolding()).toBe(true);
      await holder.done;
      const answer = await wiring.withConnection(async (client) => (await client.query("SELECT 3::int AS n")).rows[0]);
      expect(answer).toEqual({ n: 3 });
    } finally {
      await wiring.close();
    }
  });
});
