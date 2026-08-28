import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  ACCOUNT_REQUESTS,
  CODE_REQUEST_PER_ADDRESS,
  CODE_REQUEST_PER_SOURCE,
  CODE_VERIFY_PER_ADDRESS,
  CODE_VERIFY_PER_SOURCE,
  bucketKey,
  staleWindowsBefore,
  sweep as sweepRateLimitWindows,
} from "../src/auth/ratelimit.js";
import { up } from "../src/db/migrate.js";
import { periodStart } from "../src/entitlement/period.js";
import {
  admitRequest,
  readEntitlement,
  readPeriodUsage,
  reserve,
  settle,
  sweepExpiredReservations,
  unitsForMeteredCall,
} from "../src/entitlement/store.js";
import { grant, setRevoked } from "../src/entitlements.js";

/**
 * The spend cap against a real Postgres, under interleavings that are **forced rather than hoped
 * for** (SONNY-135).
 *
 * **This file is where the ticket's hardest requirement is actually met.** `entitlement.test.ts`
 * proves what each refusal tells a client, against a fake; a fake cannot prove a race, and a fake
 * that appeared to enforce a cap would be how this suite came to believe it had tested one. The
 * mechanism is a property of Postgres — an `UPDATE` under READ COMMITTED re-evaluating its own
 * `WHERE` against a row a concurrent transaction has just committed — so the only place it can be
 * demonstrated is against Postgres.
 *
 * **Why it is written this way, which `races.db.test.ts` already argued and this file inherits.** A
 * randomized battery in this codebase reaches whatever ordering the timing happens to favour, and a
 * clean result is evidence about the states it reached and silent about the states it did not — the
 * two being indistinguishable in its output. So the ordering that matters is **forced**, with a
 * transaction held open; the forced case asserts that the interleaving actually happened (the other
 * participant's promise is still pending) before asserting any outcome; and the outcome asserted is
 * one that **cannot hold under the other ordering**, which the rollback case beside it demonstrates
 * by producing the opposite result from the same setup.
 *
 * **And the control is committed beside it**, for the reason `docs/sonny-row-12-host-decision.md`
 * §9.4 gives in as many words: *a race test with no control passes whether or not the property
 * holds*. `theNaiveReadThenWriteOverspends` runs the same race against a read-then-write
 * implementation and reproduces the over-spend rather than arguing about it.
 *
 * Opt-in like the other `*.db.test.ts` files: `npm test` skips it, `npm run test:db` runs it.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";
const OTHER = "9b2e1d9f-2d6b-4b0a-8a72-3c7a6a3b88bc";
const SALT = "a-salt-that-is-not-a-real-one";
const NOW = new Date("2026-08-28T09:00:00Z");

describeDb("the per-user spend cap, against a real Postgres", () => {
  let client: pg.Client;
  const opened: pg.Client[] = [];

  const connect = async (): Promise<pg.Client> => {
    const extra = new pg.Client({ connectionString: url });
    await extra.connect();
    opened.push(extra);
    return extra;
  };

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await up(client);
  });

  afterAll(async () => {
    for (const extra of opened) await extra.end();
    await client.end();
  });

  beforeEach(async () => {
    await client.query(
      "TRUNCATE sonny.usage_reservation, sonny.usage_period, sonny.entitlement, sonny.auth_rate_limit",
    );
  });

  /**
   * Wait until some backend is actually blocked on another's lock, and answer which.
   *
   * **A real signal rather than a sleep.** `CLAUDE.md` records what a wall-clock bet costs — a test
   * that sleeps and then asserts is a bet on a machine's load, and the one in this repository that
   * made it manufactured a mutation kill. What "the interleaving happened" really means here is that
   * Postgres has one backend waiting on another's row lock, and `pg_blocking_pids` is Postgres saying
   * exactly that. Polling it turns the assertion from *probably by now* into *observed*.
   *
   * The bound is a hang backstop rather than a threshold the test races: it can only be reached by a
   * genuine failure to block, which is the case the test is about.
   */
  const waitUntilBlocked = async (): Promise<void> => {
    const deadline = Date.now() + 4000;
    for (;;) {
      const blocked = await client.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM pg_stat_activity
          WHERE datname = current_database() AND cardinality(pg_blocking_pids(pid)) > 0`,
      );
      if ((blocked.rows[0]?.n ?? 0) > 0) return;
      if (Date.now() > deadline) throw new Error("no backend ever blocked: the race did not happen");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  };

  /** Open a period at a chosen cap, the way the first reserve of a period would. */
  const openPeriod = async (accountId: string, capUnits: number): Promise<void> => {
    await client.query(
      "INSERT INTO sonny.usage_period (account_id, period_start, cap_units) VALUES ($1, $2, $3)",
      [accountId, periodStart(NOW), capUnits],
    );
  };

  const period = async (accountId = ACCOUNT) => {
    const usage = await readPeriodUsage(client, accountId, NOW);
    if (usage === undefined) throw new Error("no period row");
    return usage;
  };

  const reserveOne = (on: pg.Client, accountId = ACCOUNT, capUnits = 1) =>
    reserve(on, { accountId, capUnits, amount: unitsForMeteredCall(), now: NOW });

  describe("two requests racing the cap", () => {
    it("refuses the second when only one fits — the ordering forced, not hoped for", async () => {
      await openPeriod(ACCOUNT, 1);

      // The first racer, standing in for a reserve that has run its `UPDATE` and not yet committed.
      // Written as the statement rather than as a `reserve()` call because the point is to hold the
      // row lock open across the second racer's whole attempt, which a function that commits cannot
      // do. Its effect on the row is exactly `reserve`'s.
      const first = await connect();
      await first.query("BEGIN");
      const held = await first.query(
        `UPDATE sonny.usage_period SET reserved = reserved + 1
          WHERE account_id = $1 AND period_start = $2
            AND spent + reserved + 1 <= cap_units
        RETURNING reserved`,
        [ACCOUNT, periodStart(NOW)],
      );
      expect(held.rows).toHaveLength(1);

      // The second racer, running the real code, on its own connection.
      const second = await connect();
      let settledOutcome: unknown;
      const racing = reserveOne(second).then((outcome) => (settledOutcome = outcome));

      // **The interleaving actually happened**, which is the assertion that makes the rest mean
      // something: the second racer is blocked on the first's row lock rather than having already
      // read a stale snapshot and decided. Without this, a test that ran the two in sequence would
      // pass identically.
      await waitUntilBlocked();
      expect(settledOutcome).toBeUndefined();

      await first.query("COMMIT");
      const outcome = await racing;

      // Re-evaluated against the committed row rather than against its own start snapshot.
      expect(outcome).toEqual({ kind: "over_cap", capUnits: 1 });
      const usage = await period();
      expect(usage.reserved).toBe(1);
      expect(usage.spent).toBe(0);
      // One hold exists, not two: the refused racer wrote no reservation row.
      const holds = await client.query("SELECT count(*)::int AS n FROM sonny.usage_reservation");
      expect(holds.rows[0].n).toBe(0);
    });

    it("admits the second when the first rolls back — the outcome the other ordering cannot give", async () => {
      // The same setup and the same forced block, differing in one thing: the first racer's
      // transaction ends in ROLLBACK. If the second racer were deciding from its own start snapshot
      // it would answer the same either way; it does not, which is what the pair proves.
      await openPeriod(ACCOUNT, 1);
      const first = await connect();
      await first.query("BEGIN");
      await first.query(
        `UPDATE sonny.usage_period SET reserved = reserved + 1
          WHERE account_id = $1 AND period_start = $2 AND spent + reserved + 1 <= cap_units`,
        [ACCOUNT, periodStart(NOW)],
      );

      const second = await connect();
      let settledOutcome: unknown;
      const racing = reserveOne(second).then((outcome) => (settledOutcome = outcome));
      await waitUntilBlocked();
      expect(settledOutcome).toBeUndefined();

      await first.query("ROLLBACK");
      const outcome = await racing;

      expect(outcome).toMatchObject({ kind: "reserved", units: 1 });
      expect((await period()).reserved).toBe(1);
    });
  });

  describe("many requests racing the cap", () => {
    // **The timeout is a hang backstop and not a threshold this test races.** Fifty connections and
    // fifty transactions serializing on one row take a few seconds on a laptop's container, which is
    // comfortably inside this and comfortably outside vitest's 5-second default. Nothing here
    // asserts an elapsed time; the only way to reach this bound is for the race never to finish,
    // which `CLAUDE.md` calls the one wall-clock construct that is safe.
    it("lets exactly as many through as fit, and lands on the cap", { timeout: 60_000 }, async () => {
      // Fifty concurrent reservations against a cap of ten. Every one of them runs the real
      // `reserve` on its own connection, which is what a burst of real requests is.
      const CONCURRENCY = 50;
      const CAP = 10;
      await openPeriod(ACCOUNT, CAP);
      const clients = await Promise.all(
        Array.from({ length: CONCURRENCY }, () => connect()),
      );

      const outcomes = await Promise.all(clients.map((on) => reserveOne(on, ACCOUNT, CAP)));

      const reserved = outcomes.filter((outcome) => outcome.kind === "reserved");
      const refused = outcomes.filter((outcome) => outcome.kind === "over_cap");
      expect(reserved).toHaveLength(CAP);
      expect(refused).toHaveLength(CONCURRENCY - CAP);
      // Landed exactly on the cap: not under it, and — the direction that costs money — not over it.
      const usage = await period();
      expect(usage.reserved).toBe(CAP);
      expect(usage.spent + usage.reserved).toBe(usage.capUnits);
      // One reservation row per winner, so every unit held is one something can settle or sweep.
      const holds = await client.query("SELECT count(*)::int AS n FROM sonny.usage_reservation");
      expect(holds.rows[0].n).toBe(CAP);
      // Each reservation id is distinct — fifty racers cannot share one hold.
      expect(new Set(reserved.map((outcome) => (outcome as { reservationId: string }).reservationId)).size)
        .toBe(CAP);
    });

    it("theNaiveReadThenWriteOverspends — the control, without which this proves nothing", async () => {
      // §9.4: "a race test with no control passes whether or not the property holds." This is the
      // implementation the single statement replaced — read the counter, decide, write it back — run
      // as the same race against the same cap, on a table with no CHECK so the over-spend is
      // *reproduced* rather than converted into a constraint violation.
      await client.query(
        `CREATE TEMP TABLE naive (account_id uuid PRIMARY KEY, cap_units bigint, reserved bigint)`,
      );
      await client.query("INSERT INTO naive VALUES ($1, 10, 0)", [ACCOUNT]);

      const naiveReserve = async (on: pg.Client): Promise<boolean> => {
        const read = await on.query<{ reserved: string; cap_units: string }>(
          "SELECT reserved, cap_units FROM naive WHERE account_id = $1",
          [ACCOUNT],
        );
        const row = read.rows[0]!;
        if (Number(row.reserved) + 1 > Number(row.cap_units)) return false;
        await on.query("UPDATE naive SET reserved = reserved + 1 WHERE account_id = $1", [ACCOUNT]);
        return true;
      };

      // The temp table lives on `client`'s session, so the racers are this one connection — which is
      // the *friendliest* possible conditions for the naive version and it still overshoots.
      const results = await Promise.all(Array.from({ length: 50 }, () => naiveReserve(client)));
      const admitted = results.filter(Boolean).length;
      const final = await client.query<{ reserved: string }>(
        "SELECT reserved FROM naive WHERE account_id = $1",
        [ACCOUNT],
      );

      expect(admitted).toBeGreaterThan(10);
      expect(Number(final.rows[0]!.reserved)).toBeGreaterThan(10);
      await client.query("DROP TABLE naive");
    });

    it("keeps the CHECK as a backstop that makes an over-spend structurally impossible", async () => {
      // §9.4's other half: the constraint is a real backstop and a bad interface. It is kept so that
      // a reserve rewritten badly cannot exceed the cap, and it is never what a caller meets —
      // `reserve` refuses cleanly before this can fire.
      await openPeriod(ACCOUNT, 1);
      await expect(
        client.query(
          "UPDATE sonny.usage_period SET reserved = 5 WHERE account_id = $1 AND period_start = $2",
          [ACCOUNT, periodStart(NOW)],
        ),
      ).rejects.toThrow(/usage_period_never_over_cap/);
    });
  });

  describe("settling a hold", () => {
    it("moves a charged hold into spent, and leaves the total untouched", async () => {
      await openPeriod(ACCOUNT, 10);
      const held = await reserveOne(client, ACCOUNT, 10);
      expect(held.kind).toBe("reserved");
      const before = await period();
      expect([before.spent, before.reserved]).toEqual([0, 1]);

      const outcome = await settle(client, (held as { reservationId: string }).reservationId, true);

      expect(outcome).toBe("charged");
      const after = await period();
      expect([after.spent, after.reserved]).toEqual([1, 0]);
    });

    it("gives a released hold back, spending nothing", async () => {
      await openPeriod(ACCOUNT, 10);
      const held = await reserveOne(client, ACCOUNT, 10);
      await settle(client, (held as { reservationId: string }).reservationId, false);
      const after = await period();
      expect([after.spent, after.reserved]).toEqual([0, 0]);
    });

    it("charges once when a settle is retried, which the response path can do", async () => {
      await openPeriod(ACCOUNT, 10);
      const held = await reserveOne(client, ACCOUNT, 10);
      const id = (held as { reservationId: string }).reservationId;

      expect(await settle(client, id, true)).toBe("charged");
      expect(await settle(client, id, true)).toBe("already_settled");

      const after = await period();
      expect([after.spent, after.reserved]).toEqual([1, 0]);
    });

    it("cannot be pushed over the cap by a settle, in either direction", async () => {
      // A charge moves a unit from `reserved` to `spent` and leaves the sum alone; a release lowers
      // `reserved`. Neither can trip the backstop, which is why `settle` needs no cap check.
      await openPeriod(ACCOUNT, 2);
      const first = await reserveOne(client, ACCOUNT, 2);
      const second = await reserveOne(client, ACCOUNT, 2);
      expect((await period()).reserved).toBe(2);
      await settle(client, (first as { reservationId: string }).reservationId, true);
      await settle(client, (second as { reservationId: string }).reservationId, true);
      const after = await period();
      expect([after.spent, after.reserved]).toEqual([2, 0]);
      // And the cap now genuinely refuses, because `spent` counts against it exactly as `reserved`.
      expect(await reserveOne(client, ACCOUNT, 2)).toEqual({ kind: "over_cap", capUnits: 2 });
    });
  });

  describe("the sweep that reclaims orphaned holds", () => {
    it("reclaims EVERY expired hold across several accounts, not one per period", async () => {
      // **The multi-orphan shape deliberately**, because the single-orphan version it replaced passed
      // against the broken sweep. `UPDATE … FROM` is a join: without the per-period aggregation,
      // Postgres applies one source row per target row and discards the rest, marking every hold
      // settled while reclaiming one — so the remainder becomes permanently unusable cap with no row
      // left to reclaim it from. Three holds for one account and one for another is the shape that
      // tells the two implementations apart (SONNY-125, PR #82 cycle 1, F2).
      await openPeriod(ACCOUNT, 10);
      await openPeriod(OTHER, 10);
      const expired = new Date(NOW.getTime() - 10 * 60 * 1000);
      for (const [account, count] of [[ACCOUNT, 3], [OTHER, 1]] as const) {
        for (let index = 0; index < count; index += 1) {
          await reserve(client, {
            accountId: account,
            capUnits: 10,
            amount: unitsForMeteredCall(),
            now: expired,
          });
        }
      }
      // The period the expired reserves opened is the one `expired` falls in, which is the same
      // month here; both accounts now hold what they reserved.
      expect((await period(ACCOUNT)).reserved).toBe(3);
      expect((await period(OTHER)).reserved).toBe(1);

      const reclaimed = await sweepExpiredReservations(client, NOW);

      // **Four holds, not two periods.** The broken version's return value counted `usage_period`
      // rows and called them holds, so it answered a plausible number that agreed with the bug.
      expect(reclaimed).toBe(4);
      expect((await period(ACCOUNT)).reserved).toBe(0);
      expect((await period(OTHER)).reserved).toBe(0);
      // And the reclaimed capacity is genuinely usable again, which is the property that was lost:
      // both accounts can now reserve their whole cap.
      for (let index = 0; index < 10; index += 1) {
        expect((await reserveOne(client, ACCOUNT, 10)).kind).toBe("reserved");
      }
      expect((await period(ACCOUNT)).reserved).toBe(10);
    });

    it("leaves a hold that has not expired alone, so a running request keeps its reservation", async () => {
      await openPeriod(ACCOUNT, 10);
      await reserveOne(client, ACCOUNT, 10);
      expect(await sweepExpiredReservations(client, NOW)).toBe(0);
      expect((await period()).reserved).toBe(1);
    });

    it("does not reclaim a hold twice", async () => {
      await openPeriod(ACCOUNT, 10);
      await reserve(client, {
        accountId: ACCOUNT,
        capUnits: 10,
        amount: unitsForMeteredCall(),
        now: new Date(NOW.getTime() - 10 * 60 * 1000),
      });
      expect(await sweepExpiredReservations(client, NOW)).toBe(1);
      expect(await sweepExpiredReservations(client, NOW)).toBe(0);
      expect((await period()).reserved).toBe(0);
    });
  });

  describe("the sweep an operator schedules", () => {
    it("clears stale rate-limit windows as well as expired holds, from one command", async () => {
      // **F4's answer, asserted rather than described.** The rate-limit table's sweep had no caller
      // outside a test, and this branch multiplied what it holds — a row per account per minute
      // rather than one per sign-in attempt. Both sweeps run from `npm run entitlements -- sweep`,
      // so an operator has one thing to schedule.
      await openPeriod(ACCOUNT, 10);
      await reserve(client, {
        accountId: ACCOUNT,
        capUnits: 10,
        amount: unitsForMeteredCall(),
        now: new Date(NOW.getTime() - 10 * 60 * 1000),
      });
      const stale = new Date(NOW.getTime() - 48 * 60 * 60 * 1000);
      const live = new Date(Math.floor(NOW.getTime() / 60000) * 60000);
      await client.query(
        `INSERT INTO sonny.auth_rate_limit (bucket, window_start, count)
              VALUES ($1, $2, 3), ($1, $3, 1)`,
        [bucketKey("acct", ACCOUNT, SALT), stale, live],
      );

      const reclaimed = await sweepExpiredReservations(client, NOW);
      const windows = await sweepRateLimitWindows(client, staleWindowsBefore(NOW));

      expect(reclaimed).toBe(1);
      expect(windows).toBe(1);
      // **The live window survives**, which is the direction that matters: deleting one something is
      // still counting against would hand a caller a fresh allowance.
      const left = await client.query<{ window_start: Date }>(
        "SELECT window_start FROM sonny.auth_rate_limit ORDER BY window_start",
      );
      expect(left.rows).toHaveLength(1);
      expect(left.rows[0]!.window_start.getTime()).toBe(live.getTime());
    });

    it("never deletes a window inside the longest limit's own span", () => {
      // **Written out by name rather than read off `ALL_LIMITS`** (cycle 3's N3). The first version
      // computed the expected value from the same array the implementation reads, so both sides
      // moved together and a limit missing from the array was invisible — and the direction that
      // failure takes is the one the test above calls the one that matters: a sweep deleting a
      // window something is still counting against hands a caller a fresh allowance. The population
      // itself is held by `theSweepsCutOffCoversEveryDeclaredLimit` below.
      const longest = Math.max(
        CODE_REQUEST_PER_ADDRESS.windowSeconds,
        CODE_REQUEST_PER_SOURCE.windowSeconds,
        CODE_VERIFY_PER_ADDRESS.windowSeconds,
        CODE_VERIFY_PER_SOURCE.windowSeconds,
        ACCOUNT_REQUESTS.windowSeconds,
      );
      expect(staleWindowsBefore(NOW).getTime()).toBe(NOW.getTime() - longest * 1000);
      expect(longest).toBeGreaterThanOrEqual(ACCOUNT_REQUESTS.windowSeconds);
    });
  });

  describe("the cap a period was opened with", () => {
    it("is copied at the first reserve and not re-read when the account's cap changes", async () => {
      // A cap that changed mid-period would retroactively re-decide every refusal already issued: a
      // user told at the ceiling that they were out would, after an operator raised it, have been
      // silently not-out at the time they were told.
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: [], capUnits: 1 });
      const first = await reserve(client, {
        accountId: ACCOUNT,
        capUnits: 1,
        amount: unitsForMeteredCall(),
        now: NOW,
      });
      expect(first.kind).toBe("reserved");

      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: [], capUnits: 100 });
      const second = await reserve(client, {
        accountId: ACCOUNT,
        capUnits: 100,
        amount: unitsForMeteredCall(),
        now: NOW,
      });

      expect(second).toEqual({ kind: "over_cap", capUnits: 1 });
      // The refusal reports the cap that actually decided it, not the one the caller passed in.
      expect((await period()).capUnits).toBe(1);
    });

    it("opens the next period at the new cap, which is what a period boundary is for", async () => {
      await openPeriod(ACCOUNT, 1);
      await reserveOne(client, ACCOUNT, 1);
      const nextMonth = new Date("2026-09-01T00:00:01Z");
      const outcome = await reserve(client, {
        accountId: ACCOUNT,
        capUnits: 100,
        amount: unitsForMeteredCall(),
        now: nextMonth,
      });
      expect(outcome.kind).toBe("reserved");
      const next = await readPeriodUsage(client, ACCOUNT, nextMonth);
      expect(next).toMatchObject({ capUnits: 100, spent: 0, reserved: 1 });
    });

    // The same hang backstop, and the same reason, as the fifty-way race above: two connections and
    // two transactions contending for one row are well inside this and can exceed vitest's
    // five-second default under the load a mutation battery puts on the machine — measured, in a
    // battery where this timeout was read as a mutant being caught. Nothing here asserts an elapsed
    // time.
    it("opens a period safely when two requests reach it at once", { timeout: 60_000 }, async () => {
      // Two racers, no period row, one cap. The `INSERT … ON CONFLICT DO NOTHING` is idempotent and
      // decides nothing; the conditional `UPDATE` beside it decides everything, and it runs as its
      // own statement so it takes a fresh snapshot in which the winner's row is committed.
      const [a, b] = await Promise.all([connect(), connect()]);
      const outcomes = await Promise.all([
        reserveOne(a, ACCOUNT, 1),
        reserveOne(b, ACCOUNT, 1),
      ]);
      expect(outcomes.filter((outcome) => outcome.kind === "reserved")).toHaveLength(1);
      expect(outcomes.filter((outcome) => outcome.kind === "over_cap")).toHaveLength(1);
      expect((await period()).reserved).toBe(1);
    });
  });

  describe("what an account is allowed", () => {
    it("reads an absent row as no plan, no capabilities and the deployment's cap", async () => {
      const record = await readEntitlement(client, ACCOUNT);
      expect(record).toEqual({
        accountId: ACCOUNT,
        plan: "none",
        capabilities: [],
        capUnits: null,
        revokedAt: null,
      });
    });

    it("round-trips a grant, and a revoke strips the capabilities a claim would carry", async () => {
      await grant(client, {
        accountId: ACCOUNT,
        plan: "test-plan",
        capabilities: ["cap.a", "cap.b"],
        capUnits: 25,
      });
      const granted = await readEntitlement(client, ACCOUNT);
      expect(granted).toMatchObject({
        plan: "test-plan",
        capabilities: ["cap.a", "cap.b"],
        capUnits: 25,
        revokedAt: null,
      });

      expect(await setRevoked(client, ACCOUNT, true)).toBe(true);
      const revoked = await readEntitlement(client, ACCOUNT);
      expect(revoked.revokedAt).toBeInstanceOf(Date);
      // The row and its plan key survive; what a claim would carry does not.
      expect(revoked.plan).toBe("test-plan");
      expect(revoked.capabilities).toEqual(["cap.a", "cap.b"]);

      // A fresh grant clears the revocation, so an operator writing a plan onto a cancelled account
      // does not leave it minting capability-less claims.
      await grant(client, { accountId: ACCOUNT, plan: "test-plan", capabilities: ["cap.a"], capUnits: null });
      expect((await readEntitlement(client, ACCOUNT)).revokedAt).toBeNull();
    });

    it("reports a revoke against an account with no row rather than reporting success", async () => {
      expect(await setRevoked(client, OTHER, true)).toBe(false);
    });
  });

  describe("admission, in the order the checks run", () => {
    const admit = (overrides: Partial<Parameters<typeof admitRequest>[1]> = {}) =>
      admitRequest(client, {
        accountId: ACCOUNT,
        requiredCapability: undefined,
        metered: true,
        defaultCapUnits: 10,
        rateLimitSalt: SALT,
        now: NOW,
        ...overrides,
      });

    it("admits a metered request with a hold, using the deployment cap when the account names none", async () => {
      const outcome = await admit();
      expect(outcome.kind).toBe("admitted");
      expect((outcome as { reservationId: string }).reservationId).toBeDefined();
      expect((await period()).capUnits).toBe(10);
    });

    it("prefers the account's own cap over the deployment's", async () => {
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: [], capUnits: 3 });
      await admit();
      expect((await period()).capUnits).toBe(3);
    });

    it("honours an account capped at zero, which is an answer and not an absence", async () => {
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: [], capUnits: 0 });
      expect(await admit()).toEqual({ kind: "over_cap", capUnits: 0 });
    });

    it("refuses a gated capability the account does not hold, and takes no hold doing it", async () => {
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: ["cap.other"], capUnits: 10 });
      const outcome = await admit({ requiredCapability: "cap.gated" });
      expect(outcome).toEqual({ kind: "not_entitled", capability: "cap.gated" });
      // Nothing was spent on a request that was refused: no period opened, no hold taken.
      expect(await readPeriodUsage(client, ACCOUNT, NOW)).toBeUndefined();
    });

    it("admits a gated capability the account does hold", async () => {
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: ["cap.gated"], capUnits: 10 });
      expect((await admit({ requiredCapability: "cap.gated" })).kind).toBe("admitted");
    });

    it("refuses a revoked account's gated capability, which is how a cancellation takes effect", async () => {
      await grant(client, { accountId: ACCOUNT, plan: "p", capabilities: ["cap.gated"], capUnits: 10 });
      await setRevoked(client, ACCOUNT, true);
      expect(await admit({ requiredCapability: "cap.gated" }))
        .toEqual({ kind: "not_entitled", capability: "cap.gated" });
    });

    it("stops at the rate limit before it reads an entitlement or takes a hold", async () => {
      // The order is policy: the cheapest refusal first, and the one that bounds how fast everything
      // below it can be driven. Asserted by exhausting the limit and then checking that the request
      // after it neither opened a period nor took a hold.
      const bucket = bucketKey("acct", ACCOUNT, SALT);
      await client.query(
        "INSERT INTO sonny.auth_rate_limit (bucket, window_start, count) VALUES ($1, $2, 120)",
        [bucket, new Date(Math.floor(NOW.getTime() / 60000) * 60000)],
      );

      const outcome = await admit();

      expect(outcome.kind).toBe("rate_limited");
      expect((outcome as { retryAfterSeconds: number }).retryAfterSeconds).toBeGreaterThan(0);
      expect(await readPeriodUsage(client, ACCOUNT, NOW)).toBeUndefined();
    });

    it("does not read an entitlement row for a route that gates on nothing and spends nothing", async () => {
      // Every authenticated route is rate limited; only some are worth a second query. Asserted by
      // the absence of a period row and by the admission carrying no hold.
      const outcome = await admit({ metered: false, requiredCapability: undefined });
      expect(outcome).toEqual({ kind: "admitted", reservationId: undefined });
      expect(await readPeriodUsage(client, ACCOUNT, NOW)).toBeUndefined();
    });

    it("counts each admission against the rate limit exactly once", async () => {
      for (let index = 0; index < 3; index += 1) await admit({ metered: false });
      const counted = await client.query<{ count: number }>(
        "SELECT count FROM sonny.auth_rate_limit WHERE bucket = $1",
        [bucketKey("acct", ACCOUNT, SALT)],
      );
      expect(counted.rows[0]!.count).toBe(3);
    });

    it("keeps one account's rate limit and cap away from another's", async () => {
      await admit();
      await admitRequest(client, {
        accountId: OTHER,
        requiredCapability: undefined,
        metered: true,
        defaultCapUnits: 10,
        rateLimitSalt: SALT,
        now: NOW,
      });
      expect((await period(ACCOUNT)).reserved).toBe(1);
      expect((await period(OTHER)).reserved).toBe(1);
    });
  });
});
