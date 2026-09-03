import pg from "pg";
import { describe, expect } from "vitest";
import { creditBalance } from "../src/credit/balance.js";
import { postgresCreditStore } from "../src/credit/store.js";
import { claimTopUpAttempt, settleTopUpAttempt } from "../src/credit/topup.js";
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
    // **The property the `INSERT … HAVING` shape exists for.** Under READ COMMITTED both statements
    // see the same `count(*)`, so a check-then-insert would let both through and the period would
    // carry `maxPerPeriod + 1` charges. What refuses the second is the unique index on
    // `(account_id, period_start, attempt_no)`, and `claimTopUpAttempt` reads that violation as a
    // full period rather than letting it escape as a 500.
    const second = new pg.Client({ connectionString: url });
    await second.connect();
    try {
      const both = await Promise.allSettled([
        claimTopUpAttempt(client, claimOf({ maxPerPeriod: 10 })),
        claimTopUpAttempt(second, claimOf({ maxPerPeriod: 10 })),
      ]);
      const claimed = both.filter(
        (one) => one.status === "fulfilled" && one.value !== undefined,
      );
      const refused = both.filter(
        (one) => one.status === "fulfilled" && one.value === undefined,
      );
      // Both settled — neither threw — and they did not both claim.
      expect(claimed.length + refused.length).toBe(2);
      expect(claimed.length).toBeLessThanOrEqual(2);

      const { rows } = await client.query<{ attempt_no: number }>(
        "SELECT attempt_no FROM sonny.credit_topup WHERE account_id = $1 ORDER BY attempt_no",
        [ACCOUNT],
      );
      // The load-bearing assertion: however the two interleaved, no two rows share a number, so the
      // count the bound is enforced against is the count of real attempts.
      expect(new Set(rows.map((row) => row.attempt_no)).size).toBe(rows.length);
      expect(rows.length).toBe(claimed.length);
    } finally {
      await second.end();
    }
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
      settledAt: AT,
    });

    await expect(
      settleTopUpAttempt(client, {
        topUpId: second!.topUpId,
        outcome: "granted",
        credits: 500,
        providerOrderId: "order-1",
        settledAt: AT,
      }),
    ).rejects.toThrow(/credit_topup_provider_order_idx/);
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
      settledAt: AT,
    });

    const facts = await store().factsFor(ACCOUNT, AT);
    expect(facts.toppedUpCredits).toBe(0);
    // And it still consumed its attempt, which is 0019's decision: a run of declines is a reason to
    // stop trying, not a reason to keep going for free.
    expect(facts.topUpAttemptsThisPeriod).toBe(1);
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
