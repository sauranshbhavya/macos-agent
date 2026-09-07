import pg from "pg";
import { describe, expect } from "vitest";
import { creditBalance } from "../src/credit/balance.js";
import { postgresCreditStore } from "../src/credit/store.js";
import {
  claimTopUpAttempt,
  readOutstandingTopUp,
  recordTopUpOrder,
  settleTopUpAttempt,
} from "../src/credit/topup.js";
import { readLastTopUpCharge } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { catalogueOf } from "./support/credit.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * The two things a fake cannot say anything about a top-up (SONNY-215).
 *
 * `topup.test.ts` proves every refusal, the mapping and the routes, all without a database. This
 * file proves what only a real Postgres can answer:
 *
 * 1. **The per-period bound is exact under concurrency.** Two attempts racing compute the same
 *    `attempt_no` and one of them must lose on the unique index — which is the whole reason the
 *    claim is an `INSERT … HAVING` rather than a `count(*)` check followed by an insert. A fake that
 *    returned `undefined` on the fourth call would model the bound and prove nothing about the race.
 * 2. **A granted row raises the next read's allowance**, through the same `factsFor` the route uses
 *    — so the sum, the period filter and the outcome filter are all exercised by the query that
 *    ships rather than by one written for the test.
 *
 * **Every period here is reached by writing a `period_start`, never by waiting**, which is
 * `credit.db.test.ts`'s rule and `CLAUDE.md`'s: a test that slept to cross a boundary would be
 * betting on a wall clock it shares with the rest of the suite.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "9b1c2d3e-4f50-4a61-8b72-3c4d5e6f7a80";
const PROVIDER = "test-provider";
const AT = new Date("2026-08-15T12:00:00Z");
const PERIOD = periodStart(AT);
const CONSENTED = new Date("2026-08-02T09:30:00Z");

/** The claim's arguments, with the pieces a test varies pulled out. */
function claimOf(overrides: { readonly maxPerPeriod?: number; readonly periodStart?: Date } = {}) {
  return {
    accountId: ACCOUNT,
    provider: PROVIDER,
    periodStart: overrides.periodStart ?? PERIOD,
    consentedAt: CONSENTED,
    runsLeftAtTrigger: 0,
    creditsRemainingAtTrigger: 4,
    maxPerPeriod: overrides.maxPerPeriod ?? 3,
  };
}

/**
 * Two claims that both number themselves the SAME `attempt_no`, with the contention **built rather
 * than hoped for** (SONNY-431).
 *
 * `claimTopUpAttempt` numbers its row `coalesce(max(attempt_no), 0) + 1` over its own snapshot, so
 * two claims contend only while neither snapshot holds the other's row. Dispatching both at once
 * and awaiting them -- which is what the arm below used to do -- leaves that to the scheduler.
 * Under three concurrent database suites the two Postgres backends sometimes serialise instead: one
 * commits before the other's snapshot is taken, the second numbers itself the *next* slot rather
 * than the same one, both succeed, and a test asserting that one of them must lose fails on a run
 * where nothing at all is wrong. Measured at 8 in 3400 races, every one of the eight two rows
 * holding slots 1 and 2 -- never one slot taken twice.
 *
 * So the contender's snapshot is pinned here, in a `REPEATABLE READ` transaction opened before the
 * holder's row exists. That is the same state READ COMMITTED concurrency produces -- a statement
 * numbering itself from a snapshot that does not contain a row already in the index -- and it
 * produces it every time, with nothing waiting on a clock and nothing polled: 300 of 300 for each
 * of the two callers below, against 100 of 100 two-claim outcomes once the unique index is dropped.
 *
 * **The contender's transaction is committed and never rolled back, and that is not tidiness.** A
 * rolled-back contender leaves no row behind, so a schema carrying no unique index at all reads
 * back as one correct row and every assertion below still passes -- the control stops firing, which
 * is the one thing these two tests exist for. It was measured in that shape first, and the
 * index-dropped run reported `rows=1 attempt_nos=[1]`: correct-looking, and about nothing.
 */
async function twoClaimsForOneSlot(
  holder: pg.Client,
  maxPerPeriod: number,
  slotsAlreadyTaken: number,
) {
  const contender = new pg.Client({ connectionString: url });
  await contender.connect();
  try {
    await contender.query("BEGIN ISOLATION LEVEL REPEATABLE READ");
    // The snapshot the contender will number itself from, asserted rather than assumed: one that
    // already held the holder's row would have the two claims computing different slots, and there
    // would be no contention left for the caller to make an assertion about.
    const pinned = await contender.query<{ n: number }>(
      `SELECT count(*)::int AS n
         FROM sonny.credit_topup
        WHERE account_id = $1 AND period_start = $2`,
      [ACCOUNT, PERIOD],
    );
    expect(pinned.rows[0]?.n).toBe(slotsAlreadyTaken);

    const held = await claimTopUpAttempt(holder, claimOf({ maxPerPeriod }));
    const contended = await claimTopUpAttempt(contender, claimOf({ maxPerPeriod }));
    await contender.query("COMMIT");
    return { held, contended };
  } finally {
    await contender.end();
  }
}

/** Every attempt this account holds for `PERIOD`, in slot order. */
async function slotsHeld(holder: pg.Client): Promise<readonly number[]> {
  const { rows } = await holder.query<{ attempt_no: number }>(
    `SELECT attempt_no
       FROM sonny.credit_topup
      WHERE account_id = $1 AND period_start = $2
      ORDER BY attempt_no`,
    [ACCOUNT, PERIOD],
  );
  return rows.map((row) => row.attempt_no);
}

describeDb("the bound on how many charges a period can carry", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.credit_topup");
    await client.query("TRUNCATE sonny.auto_topup_consent");
    await client.query("TRUNCATE sonny.entitlement");
    await client.query("TRUNCATE sonny.metering_event");
  });

  itUnderHangBackstop("numbers each attempt and refuses once the period is full", async () => {
    const first = await claimTopUpAttempt(client, claimOf());
    const second = await claimTopUpAttempt(client, claimOf());
    const third = await claimTopUpAttempt(client, claimOf());
    const fourth = await claimTopUpAttempt(client, claimOf());

    expect(first).toBeDefined();
    expect(second).toBeDefined();
    expect(third).toBeDefined();
    // The bound, and the assertion is on `undefined` rather than on a throw: a full period is an
    // ordinary answer the route turns into a refusal, not a fault.
    expect(fourth).toBeUndefined();

    const { rows } = await client.query<{ attempt_no: number; outcome: string }>(
      "SELECT attempt_no, outcome FROM sonny.credit_topup WHERE account_id = $1 ORDER BY attempt_no",
      [ACCOUNT],
    );
    expect(rows.map((row) => row.attempt_no)).toEqual([1, 2, 3]);
    // **Every claimed row reads `attempted` until it is settled**, which is what makes a crashed
    // charge path consume its slot rather than loop.
    expect(new Set(rows.map((row) => row.outcome))).toEqual(new Set(["attempted"]));
  });

  itUnderHangBackstop("lets exactly one of two racing claims win the same slot", async () => {
    // **The property the `INSERT ... HAVING` shape exists for.** Both statements see the same
    // `count(*)`, so a check-then-insert would let both through and the period would carry
    // `maxPerPeriod + 1` charges. What refuses the second is the unique index on
    // `(account_id, period_start, attempt_no)`, and `claimTopUpAttempt` reads that violation as a
    // full period rather than letting it escape as a 500. `twoClaimsForOneSlot` is where the two
    // are made to contend, and why the shape that used to stand here could not (SONNY-431).
    const { held, contended } = await twoClaimsForOneSlot(client, 10, 0);

    expect(held).toBeDefined();
    // `undefined`, not a throw: from the caller's side the loser of the race and a full period are
    // the same fact, and neither is a fault.
    expect(contended).toBeUndefined();

    // The load-bearing read, and it is a value rather than a shape: one row, holding the one slot
    // both claims computed. A second row here -- whatever number it carried -- would be a charge
    // the bound never authorised.
    expect(await slotsHeld(client)).toEqual([1]);
  });

  itUnderHangBackstop("holds the bound when two claims contend for a period's last slot", async () => {
    // **The money half, and the arm above cannot stand in for it** (SONNY-431). That one runs at
    // `maxPerPeriod: 10`, where two winners take slots 1 and 2 and cost nobody anything. Here the
    // period is one short of full, so the two contend for the *last* slot and a second winner is a
    // charge past the bound the user consented to. `count(*) < $7` cannot refuse it -- both
    // snapshots see `maxPerPeriod - 1` and both pass the `HAVING` -- so at the boundary the unique
    // index is what holds the bound rather than merely what numbers the rows. Measured with that
    // index dropped: 100 of 100 periods end up carrying `maxPerPeriod + 1` charges, at slots
    // [1, 2, 3, 3].
    const maxPerPeriod = 3;
    for (let taken = 0; taken < maxPerPeriod - 1; taken += 1) {
      expect(await claimTopUpAttempt(client, claimOf({ maxPerPeriod }))).toBeDefined();
    }

    const { held, contended } = await twoClaimsForOneSlot(client, maxPerPeriod, maxPerPeriod - 1);

    expect(held).toBeDefined();
    expect(contended).toBeUndefined();
    expect(await slotsHeld(client)).toEqual([1, 2, 3]);
  });

  itUnderHangBackstop("counts a period's attempts and not another period's", async () => {
    // Three in July does not stop a top-up in August. `attempt_no` restarts, because the whole
    // uniqueness is keyed on the period.
    const july = new Date("2026-07-01T00:00:00Z");
    for (let i = 0; i < 3; i += 1) {
      expect(await claimTopUpAttempt(client, claimOf({ periodStart: july }))).toBeDefined();
    }
    expect(await claimTopUpAttempt(client, claimOf({ periodStart: july }))).toBeUndefined();

    const august = await claimTopUpAttempt(client, claimOf());
    expect(august).toBeDefined();
    const { rows } = await client.query<{ attempt_no: number }>(
      "SELECT attempt_no FROM sonny.credit_topup WHERE account_id = $1 AND period_start = $2",
      [ACCOUNT, PERIOD],
    );
    expect(rows.map((row) => row.attempt_no)).toEqual([1]);
  });

  itUnderHangBackstop("refuses to record a charge that granted nothing as a grant", async () => {
    // 0019's `credit_topup_granted_is_exactly_the_credited`, in both directions. These are the two
    // ways this table could lie about money, and neither is reachable.
    const attempt = await claimTopUpAttempt(client, claimOf());
    const topUpId = attempt?.topUpId;
    expect(topUpId).toBeDefined();

    await expect(
      client.query(
        "UPDATE sonny.credit_topup SET outcome = 'granted', credits = 0 WHERE topup_id = $1",
        [topUpId],
      ),
    ).rejects.toThrow(/credit_topup_granted_is_exactly_the_credited/);
    await expect(
      client.query(
        "UPDATE sonny.credit_topup SET outcome = 'declined', credits = 500 WHERE topup_id = $1",
        [topUpId],
      ),
    ).rejects.toThrow(/credit_topup_granted_is_exactly_the_credited/);
  });

  itUnderHangBackstop("cannot record a charge with no consent behind it", async () => {
    // **The schema half of the ticket's hard requirement.** `consented_at` is NOT NULL, so a charge
    // authorised by nothing has nowhere to be written — and the claim happens before the provider is
    // called, so an unrecordable charge is an unmade one.
    await expect(
      client.query(
        `INSERT INTO sonny.credit_topup
                (account_id, provider, period_start, attempt_no, outcome, credits, consented_at,
                 runs_left_at_trigger, credits_remaining_at_trigger)
         VALUES ($1, $2, $3, 1, 'granted', 500, NULL, 0, 0)`,
        [ACCOUNT, PROVIDER, PERIOD],
      ),
    ).rejects.toThrow(/consented_at/);
  });

  itUnderHangBackstop("charges one provider order once", async () => {
    // The draft's id is written before the charge, so a settle replayed for one order cannot mint a
    // second grant.
    const first = await claimTopUpAttempt(client, claimOf());
    const second = await claimTopUpAttempt(client, claimOf());
    await settleTopUpAttempt(client, {
      topUpId: first!.topUpId,
      outcome: "granted",
      credits: 500,
      providerOrderId: "order-1",
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: AT,
    });

    await expect(
      settleTopUpAttempt(client, {
        topUpId: second!.topUpId,
        outcome: "granted",
        credits: 500,
        providerOrderId: "order-1",
        chargedAmount: undefined,
        chargedCurrency: undefined,
        settledAt: AT,
      }),
    ).rejects.toThrow(/credit_topup_provider_order_idx/);
  });
});

describeDb("an order this gateway made and did not resolve (PR #196's F1)", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.credit_topup");
  });

  const claim = async (periodStart?: Date) => {
    const attempt = await claimTopUpAttempt(
      client,
      periodStart === undefined ? claimOf({ maxPerPeriod: 10 }) : claimOf({ maxPerPeriod: 10, periodStart }),
    );
    if (attempt === undefined) throw new Error("the fixture's claim was refused");
    return attempt.topUpId;
  };
  const outstanding = (provider: string = PROVIDER) =>
    readOutstandingTopUp(client, { accountId: ACCOUNT, provider, periodStart: PERIOD });

  itUnderHangBackstop("is not outstanding until an order id is on it", async () => {
    // **The distinction the whole recovery rests on.** A claimed row with no order id is a process
    // that died *before* the charge and cost nobody anything; there is nothing at the provider to
    // ask about, so resolving it would create an order rather than find one.
    await claim();

    expect(await outstanding()).toBeUndefined();
  });

  itUnderHangBackstop("is outstanding the moment the order id is recorded, before any charge", async () => {
    const topUpId = await claim();
    await recordTopUpOrder(client, { topUpId, providerOrderId: "order-1" });

    expect(await outstanding()).toEqual({ topUpId, orderId: "order-1" });
  });

  itUnderHangBackstop("stays outstanding while its answer could not be read", async () => {
    // `unconfirmed` is the steady-state unresolved marker: the charge was attempted and nothing
    // could be read back, so the account's next attempt asks the provider rather than buying.
    const topUpId = await claim();
    await recordTopUpOrder(client, { topUpId, providerOrderId: "order-2" });
    await settleTopUpAttempt(client, {
      topUpId,
      outcome: "unconfirmed",
      credits: 0,
      providerOrderId: "order-2",
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: AT,
    });

    expect(await outstanding()).toEqual({ topUpId, orderId: "order-2" });
  });

  itUnderHangBackstop("stops being outstanding once something says what happened to the money", async () => {
    // The two closed outcomes, both directions. A granted row is resolved and a declined one is
    // refused — resolving either again would charge a second time or refuse a paid order.
    for (const outcome of ["granted", "declined"] as const) {
      await client.query("TRUNCATE sonny.credit_topup");
      const topUpId = await claim();
      await recordTopUpOrder(client, { topUpId, providerOrderId: `order-${outcome}` });
      await settleTopUpAttempt(client, {
        topUpId,
        outcome,
        credits: outcome === "granted" ? 500 : 0,
        providerOrderId: `order-${outcome}`,
        chargedAmount: outcome === "granted" ? 500 : undefined,
        chargedCurrency: outcome === "granted" ? "usd" : undefined,
        settledAt: AT,
      });

      expect(await outstanding()).toBeUndefined();
    }
  });

  itUnderHangBackstop("does not reach across a period boundary", async () => {
    const topUpId = await claim(new Date("2026-07-01T00:00:00Z"));
    await recordTopUpOrder(client, { topUpId, providerOrderId: "order-july" });

    expect(await outstanding()).toBeUndefined();
  });

  itUnderHangBackstop("does not reach across a provider boundary either", async () => {
    // **PR #196's G4.** `finalizeTopUpOrder` takes an order id and nothing else, so an order created
    // at one provider would be finalized against another's API on a deployment that changed
    // `BILLING_PROVIDER` mid-period. The column has always been written by `claim`; nothing read it.
    const topUpId = await claim();
    await recordTopUpOrder(client, { topUpId, providerOrderId: "order-1" });

    expect(await outstanding("some-other-provider")).toBeUndefined();
    // The control: the same row is found under the provider that really created it, so the
    // `undefined` above is a scoping and not a query that finds nothing.
    expect(await outstanding()).toEqual({ topUpId, orderId: "order-1" });
  });

  itUnderHangBackstop("refuses to write an order id onto a row that already carries one", async () => {
    // **PR #196's G3.** The line this guards is called the whole of F1, and it now says so by
    // failing rather than by passing silently: a statement that matched nothing would leave the row
    // with no order id while the caller charged anyway, which is the state F1 was.
    const topUpId = await claim();
    await recordTopUpOrder(client, { topUpId, providerOrderId: "order-first" });

    await expect(
      recordTopUpOrder(client, { topUpId, providerOrderId: "order-second" }),
    ).rejects.toThrow(/did not take its provider order id \(matched 0 rows\)/);
    // And the first id is still there — the throw is a refusal to overwrite, not a failed write.
    expect(await outstanding()).toEqual({ topUpId, orderId: "order-first" });
  });

  itUnderHangBackstop("refuses to write an order id onto a row that does not exist", async () => {
    await expect(
      recordTopUpOrder(client, {
        topUpId: "00000000-0000-4000-8000-000000000000",
        providerOrderId: "order-nowhere",
      }),
    ).rejects.toThrow(/matched 0 rows/);
  });

  itUnderHangBackstop("refuses to record a charge on a row that granted nothing", async () => {
    // 0019's `credit_topup_only_a_grant_was_charged` (SONNY-215's F6). A declined row carrying an
    // amount would put a payment that never happened on the surface that shows a user what they were
    // last charged.
    const topUpId = await claim();
    await expect(
      client.query(
        "UPDATE sonny.credit_topup SET outcome = 'declined', charged_amount = 500, charged_currency = 'usd' WHERE topup_id = $1",
        [topUpId],
      ),
    ).rejects.toThrow(/credit_topup_only_a_grant_was_charged/);
  });

  itUnderHangBackstop("refuses an amount with no currency, and a currency with no amount", async () => {
    const topUpId = await claim();
    for (const set of ["charged_amount = 500", "charged_currency = 'usd'"]) {
      await expect(
        client.query(
          `UPDATE sonny.credit_topup SET outcome = 'granted', credits = 500, ${set} WHERE topup_id = $1`,
          [topUpId],
        ),
      ).rejects.toThrow(/credit_topup_charge_is_whole/);
    }
  });
});

describeDb("what a granted top-up does to the number a user reads", () => {
  let client: pg.Client;
  const catalogue = catalogueOf({ runCredits: 10, monthlyCredits: [1000] });

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.credit_topup");
    await client.query("TRUNCATE sonny.auto_topup_consent");
    await client.query("TRUNCATE sonny.entitlement");
    await client.query("TRUNCATE sonny.metering_event");
  });

  /** The real store over this suite's one connection. */
  const store = () => postgresCreditStore(async (work) => work(client));

  const grant = async (credits: number, when: Date = PERIOD): Promise<void> => {
    const attempt = await claimTopUpAttempt(client, claimOf({ periodStart: when }));
    await settleTopUpAttempt(client, {
      topUpId: attempt!.topUpId,
      outcome: "granted",
      credits,
      providerOrderId: `order-${Math.random().toString(36).slice(2)}`,
      // A real grant records what it cost, which is what the last-charge surface reads.
      chargedAmount: 500,
      chargedCurrency: "usd",
      settledAt: AT,
    });
  };

  itUnderHangBackstop("raises this period's allowance and leaves the draw alone", async () => {
    const before = await store().factsFor(ACCOUNT, AT);
    expect(before.toppedUpCredits).toBe(0);
    expect(before.topUpAttemptsThisPeriod).toBe(0);

    await grant(500);

    const after = await store().factsFor(ACCOUNT, AT);
    expect(after.toppedUpCredits).toBe(500);
    expect(after.topUpAttemptsThisPeriod).toBe(1);
    // Through the arithmetic the route uses: a thousand-credit tier that bought five hundred more is
    // a hundred and fifty runs, and the draw is untouched.
    const balance = creditBalance({
      catalogue,
      planKey: undefined,
      draw: after.draw,
      toppedUpCredits: after.toppedUpCredits,
      now: AT,
    });
    expect(balance.credits.allowance).toBe(1500);
    expect(balance.credits.toppedUp).toBe(500);
    expect(balance.runsIncluded).toBe(150);
    expect(balance.credits.drawn).toBe(0);
  });

  itUnderHangBackstop("counts only granted rows, so a decline buys nothing", async () => {
    const attempt = await claimTopUpAttempt(client, claimOf());
    await settleTopUpAttempt(client, {
      topUpId: attempt!.topUpId,
      outcome: "declined",
      credits: 0,
      providerOrderId: undefined,
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: AT,
    });

    const facts = await store().factsFor(ACCOUNT, AT);
    expect(facts.toppedUpCredits).toBe(0);
    // And it still consumed its attempt, which is 0019's decision: a run of declines is a reason to
    // stop trying, not a reason to keep going for free.
    expect(facts.topUpAttemptsThisPeriod).toBe(1);
  });

  itUnderHangBackstop("reports the last charge, and never an attempt that took no money", async () => {
    // **The gap the round's battery found (S20).** Dropping the query's `outcome = 'granted'` filter
    // survived, because every existing case had one row: a declined attempt carries no amount, so a
    // single-row fixture answers the same either way. What separates them is a *later* attempt that
    // failed — under the mutant the newest row wins, carries no amount, and the surface that tells a
    // user what they were last charged shows **nothing at all** for an account that really was
    // charged.
    await grant(500);
    // **The grant is back-dated and the decline keeps `now()`, so the decline really is newer.**
    // The first version of this test back-dated the *decline* instead, which put it in the past and
    // left the query answering the same either way — the mutant survived a second battery because
    // of it. `CLAUDE.md`'s rule about moving a stored date a measurable distance, in the direction
    // the assertion needs, applies to the row you are *not* asserting on as much as to the one you
    // are.
    await client.query("UPDATE sonny.credit_topup SET attempted_at = $1", [
      new Date("2026-08-02T00:00:00Z"),
    ]);
    const later = await claimTopUpAttempt(client, claimOf());
    await settleTopUpAttempt(client, {
      topUpId: later!.topUpId,
      outcome: "declined",
      credits: 0,
      providerOrderId: "order-declined",
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: AT,
    });
    // Proved rather than assumed: the row this test is about is the older of the two.
    const { rows } = await client.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM sonny.credit_topup a
        WHERE a.topup_id = $1
          AND a.attempted_at > (SELECT b.attempted_at FROM sonny.credit_topup b WHERE b.outcome = 'granted')`,
      [later!.topUpId],
    );
    expect(rows[0]!.n).toBe("1");

    const charge = await readLastTopUpCharge(client, ACCOUNT);
    expect(charge?.amount).toBe(500);
    expect(charge?.currency).toBe("usd");
  });

  itUnderHangBackstop("reports nothing for an account that has only ever been declined", async () => {
    const only = await claimTopUpAttempt(client, claimOf());
    await settleTopUpAttempt(client, {
      topUpId: only!.topUpId,
      outcome: "declined",
      credits: 0,
      providerOrderId: "order-only",
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: AT,
    });

    expect(await readLastTopUpCharge(client, ACCOUNT)).toBeUndefined();
  });

  itUnderHangBackstop("reports the newest charge when there is more than one", async () => {
    await grant(500);
    await client.query("UPDATE sonny.credit_topup SET attempted_at = $1", [
      new Date("2026-08-02T00:00:00Z"),
    ]);
    const second = await claimTopUpAttempt(client, claimOf());
    await settleTopUpAttempt(client, {
      topUpId: second!.topUpId,
      outcome: "granted",
      credits: 500,
      providerOrderId: "order-newer",
      chargedAmount: 700,
      chargedCurrency: "eur",
      settledAt: AT,
    });

    const charge = await readLastTopUpCharge(client, ACCOUNT);
    expect(charge?.amount).toBe(700);
    expect(charge?.currency).toBe("eur");
  });

  itUnderHangBackstop("does not carry a previous period's top-up forward", async () => {
    // The consequence of having no ledger, asserted rather than argued: a pack is spent against the
    // period it was bought in. `balance.ts` carries why carrying it forward would need one.
    await grant(500, new Date("2026-07-01T00:00:00Z"));

    const facts = await store().factsFor(ACCOUNT, AT);
    expect(facts.toppedUpCredits).toBe(0);
    expect(facts.topUpAttemptsThisPeriod).toBe(0);
  });
});

describeDb("the consent a charge is authorised by", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.auto_topup_consent");
  });

  const store = () => postgresCreditStore(async (work) => work(client));

  itUnderHangBackstop("is off for an account with no row at all", async () => {
    // **Off by default as a property of the schema.** Nothing has been written, and the answer is
    // the same one an explicit opt-out produces.
    const facts = await store().factsFor(ACCOUNT, AT);
    expect(facts.autoTopUpOptedInAt).toBeNull();
  });

  itUnderHangBackstop("records when the user said yes, and keeps that instant across a second yes", async () => {
    // The instant is what a charge cites as its own authorisation, so it has to be when they agreed
    // rather than the last time they looked at the setting.
    const first = new Date("2026-08-03T10:00:00Z");
    const second = new Date("2026-08-09T18:00:00Z");
    expect(await store().setAutoTopUp(ACCOUNT, true, first)).toEqual(first);
    expect(await store().setAutoTopUp(ACCOUNT, true, second)).toEqual(first);
    expect((await store().factsFor(ACCOUNT, AT)).autoTopUpOptedInAt).toEqual(first);
  });

  itUnderHangBackstop("clears the instant on an opt-out and keeps the row", async () => {
    const yes = new Date("2026-08-03T10:00:00Z");
    const no = new Date("2026-08-11T08:00:00Z");
    await store().setAutoTopUp(ACCOUNT, true, yes);
    expect(await store().setAutoTopUp(ACCOUNT, false, no)).toBeNull();

    const { rows } = await client.query<{ opted_in_at: Date | null; updated_at: Date }>(
      "SELECT opted_in_at, updated_at FROM sonny.auto_topup_consent WHERE account_id = $1",
      [ACCOUNT],
    );
    // The row survives, so "they turned it off on the 11th" stays answerable — which deleting it
    // would lose.
    expect(rows).toHaveLength(1);
    expect(rows[0]?.opted_in_at).toBeNull();
    expect(rows[0]?.updated_at).toEqual(no);
  });

  itUnderHangBackstop("starts again from a new instant when a user opts back in", async () => {
    const first = new Date("2026-08-03T10:00:00Z");
    const off = new Date("2026-08-11T08:00:00Z");
    const again = new Date("2026-08-20T14:00:00Z");
    await store().setAutoTopUp(ACCOUNT, true, first);
    await store().setAutoTopUp(ACCOUNT, false, off);
    // **Not the original instant.** They withdrew consent and gave it again, and a charge made after
    // the 20th is authorised by the 20th rather than by an agreement they had already revoked.
    expect(await store().setAutoTopUp(ACCOUNT, true, again)).toEqual(again);
  });
});
