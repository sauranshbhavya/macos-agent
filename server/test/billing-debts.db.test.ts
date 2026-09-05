import pg from "pg";
import { describe, expect } from "vitest";
import {
  reachOfSelfHeal,
  readBillingDebts,
  readUnaccountedDeliveries,
  readUnresolvedTopUps,
  reportBillingDebts,
  strandedByPeriodRollover,
} from "../src/billing-debts.js";
import {
  claimTopUpAttempt,
  readOutstandingTopUp,
  recordTopUpOrder,
  settleTopUpAttempt,
} from "../src/credit/topup.js";
import { periodStart } from "../src/entitlement/period.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * Which rows are debt, against a real Postgres (SONNY-408).
 *
 * **A fake proves nothing about either query here.** What is under test is exactly which rows two
 * `WHERE` clauses select out of a table holding every other kind — a granted charge, a declined one,
 * an order that never existed, a delivery that was correctly ignored — and a stub returning a list
 * would be a restatement of the answer rather than a check of it. Every row below is written through
 * the functions that ship (`claimTopUpAttempt`, `recordTopUpOrder`, `settleTopUpAttempt`) so the
 * fixture cannot drift from what the charge path actually writes.
 *
 * **The boundary case is reached by writing a `period_start`, never by waiting** — `topup.db.test.ts`'s
 * rule and `CLAUDE.md`'s. A test that slept across a month boundary would be betting on a wall clock
 * it shares with the rest of the suite, and it would take a month.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "9b1c2d3e-4f50-4a61-8b72-3c4d5e6f7a80";
const OTHER_ACCOUNT = "9b1c2d3e-4f50-4a61-8b72-3c4d5e6f7a81";
const PROVIDER = "test-provider";
const NOW = new Date("2026-09-04T12:00:00Z");
const THIS_PERIOD = periodStart(NOW);
const LAST_PERIOD = periodStart(new Date("2026-08-15T12:00:00Z"));
const CONSENTED = new Date("2026-08-02T09:30:00Z");

function claimOf(
  overrides: {
    readonly periodStart?: Date;
    readonly accountId?: string;
    readonly provider?: string;
  } = {},
) {
  return {
    accountId: overrides.accountId ?? ACCOUNT,
    provider: overrides.provider ?? PROVIDER,
    periodStart: overrides.periodStart ?? THIS_PERIOD,
    consentedAt: CONSENTED,
    runsLeftAtTrigger: 0,
    creditsRemainingAtTrigger: 4,
    // High enough that the per-period bound never refuses a fixture: what that bound does is
    // `topup.db.test.ts`'s subject, and a claim refused here would read as this file's query
    // missing a row.
    maxPerPeriod: 20,
  };
}

describeDb("what the debt report selects out of a table holding every other outcome", () => {
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
    await client.query("TRUNCATE sonny.billing_event");
  });

  /** Claims a slot, optionally records an order id, optionally settles it. */
  async function rowWith(input: {
    readonly outcome: "attempted" | "unconfirmed" | "granted" | "declined" | "provider_error";
    readonly orderId?: string;
    readonly periodStart?: Date;
    readonly accountId?: string;
    readonly provider?: string;
  }): Promise<string> {
    const attempt = await claimTopUpAttempt(client, claimOf(input));
    expect(attempt).toBeDefined();
    const topUpId = attempt!.topUpId;
    if (input.orderId !== undefined) {
      await recordTopUpOrder(client, { topUpId, providerOrderId: input.orderId });
    }
    if (input.outcome !== "attempted") {
      await settleTopUpAttempt(client, {
        topUpId,
        outcome: input.outcome,
        credits: input.outcome === "granted" ? 500 : 0,
        providerOrderId: undefined,
        chargedAmount: input.outcome === "granted" ? 900 : undefined,
        chargedCurrency: input.outcome === "granted" ? "usd" : undefined,
        settledAt: NOW,
      });
    }
    return topUpId;
  }

  itUnderHangBackstop("takes the two resolvable outcomes and only when an order exists", async () => {
    const unconfirmed = await rowWith({ outcome: "unconfirmed", orderId: "order-unconfirmed" });
    const attemptedWithOrder = await rowWith({ outcome: "attempted", orderId: "order-attempted" });
    // **Everything below is a row the report must NOT carry**, and each is a different reason.
    // `attempted` with no order id never reached the charge, so nobody was charged and there is
    // nothing at the provider to ask about; `provider_error` is the same fact with an answer behind
    // it; `granted` and `declined` are the two outcomes that say what happened to the money.
    await rowWith({ outcome: "attempted" });
    await rowWith({ outcome: "provider_error" });
    await rowWith({ outcome: "granted", orderId: "order-granted" });
    await rowWith({ outcome: "declined", orderId: "order-declined" });

    const rows = await readUnresolvedTopUps(client);
    expect(rows.map((row) => row.topUpId).sort()).toEqual([unconfirmed, attemptedWithOrder].sort());
    expect(rows.map((row) => row.providerOrderId).sort()).toEqual(
      ["order-attempted", "order-unconfirmed"],
    );
    // The population really did hold the other four, so the four exclusions above are exclusions
    // rather than an empty table answering every assertion.
    const { rows: all } = await client.query<{ n: string }>("SELECT count(*) AS n FROM sonny.credit_topup");
    expect(Number(all[0]!.n)).toBe(6);
  });

  itUnderHangBackstop("reaches every account, not just the one asking", async () => {
    await rowWith({ outcome: "unconfirmed", orderId: "order-a" });
    await rowWith({ outcome: "unconfirmed", orderId: "order-b", accountId: OTHER_ACCOUNT });

    const rows = await readUnresolvedTopUps(client);
    expect(rows.map((row) => row.accountId).sort()).toEqual([ACCOUNT, OTHER_ACCOUNT].sort());
  });

  itUnderHangBackstop("reports the row the self-healing path can no longer reach", async () => {
    // **This is the whole of PR #196's G7 and of this ticket's boundary decision, in one test.**
    // The order was left outstanding in August; it is September now.
    await rowWith({ outcome: "unconfirmed", orderId: "order-stranded", periodStart: LAST_PERIOD });

    // The self-healing path, asked as `attemptTopUp` asks it — for the account's CURRENT period —
    // finds nothing. That is the filter staying, deliberately, and this assertion is what would
    // fail if somebody widened it without reading `readOutstandingTopUp`'s reasoning.
    expect(
      await readOutstandingTopUp(client, {
        accountId: ACCOUNT,
        provider: PROVIDER,
        periodStart: THIS_PERIOD,
      }),
    ).toBeUndefined();
    // And asked for the period it actually belongs to, it is right there — so the row is unreachable
    // because of the period the caller asks about, not because it stopped being resolvable.
    expect(
      await readOutstandingTopUp(client, {
        accountId: ACCOUNT,
        provider: PROVIDER,
        periodStart: LAST_PERIOD,
      }),
    ).toEqual({ topUpId: expect.any(String), orderId: "order-stranded" });

    const rows = await readUnresolvedTopUps(client);
    expect(rows).toHaveLength(1);
    expect(strandedByPeriodRollover(rows[0]!, NOW)).toBe(true);
    const report = reportBillingDebts({ topUps: rows, deliveries: [] }, NOW);
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("STRANDED");
    expect(report.text).toContain("order-stranded");
  });

  /** A delivery of any outcome, written straight in: this file is about which ones are selected. */
  async function deliveryWith(outcome: string, eventId: string, accountId: string | null): Promise<void> {
    await client.query(
      `INSERT INTO sonny.billing_event (provider, event_id, event_type, outcome, account_id, received_at)
            VALUES ($1, $2, 'subscription.active', $3, $4, $5)`,
      [PROVIDER, eventId, outcome, accountId, NOW],
    );
  }

  itUnderHangBackstop("takes unmatched and conflict deliveries and leaves the other five", async () => {
    await deliveryWith("unmatched", "evt-unmatched", null);
    await deliveryWith("conflict", "evt-conflict", ACCOUNT);
    // The five that are not debt. `applied` moved the entitlement; `ignored` was never ours to act
    // on; `stale` lost to a newer delivery; `unmapped` is a configuration mistake and is fail-closed
    // by design; `unreadable` is a bug report. None of them is somebody paying for nothing.
    await deliveryWith("applied", "evt-applied", ACCOUNT);
    await deliveryWith("ignored", "evt-ignored", ACCOUNT);
    await deliveryWith("stale", "evt-stale", ACCOUNT);
    await deliveryWith("unmapped", "evt-unmapped", ACCOUNT);
    await deliveryWith("unreadable", "evt-unreadable", null);

    const rows = await readUnaccountedDeliveries(client);
    expect(rows.map((row) => row.eventId)).toEqual(["evt-conflict", "evt-unmatched"]);
    expect(rows.map((row) => row.outcome).sort()).toEqual(["conflict", "unmatched"]);
    expect(rows.find((row) => row.eventId === "evt-unmatched")!.accountId).toBeNull();
    expect(rows.find((row) => row.eventId === "evt-conflict")!.accountId).toBe(ACCOUNT);
    const { rows: all } = await client.query<{ n: string }>("SELECT count(*) AS n FROM sonny.billing_event");
    expect(Number(all[0]!.n)).toBe(7);
  });

  itUnderHangBackstop("exits 0 over a database whose billing tables are entirely healthy", async () => {
    // The other direction, and it needs the rows: a report that answered "clean" by failing to read
    // anything would pass every assertion above, because every one of those asserts a non-empty set.
    await rowWith({ outcome: "granted", orderId: "order-granted" });
    await deliveryWith("applied", "evt-applied", ACCOUNT);

    const report = reportBillingDebts(await readBillingDebts(client), NOW);
    expect(report.exitCode).toBe(0);
    expect(report.text).toBe("no unresolved billing debt\n");
  });

  itUnderHangBackstop("reports a current-period row at a provider this deployment no longer runs", async () => {
    // **The second boundary `readOutstandingTopUp` enforces** (PR #201's F3). The query scopes by
    // provider as well as by period, and the report modelled the period alone — so this row printed
    // `resolvable` while nothing would ever find it.
    const OTHER = "an-old-provider";
    await rowWith({ outcome: "unconfirmed", orderId: "order-old-provider", provider: OTHER });

    // Asked exactly as `attemptTopUp` asks it, with the deployment's own provider: never found.
    expect(
      await readOutstandingTopUp(client, {
        accountId: ACCOUNT,
        provider: PROVIDER,
        periodStart: THIS_PERIOD,
      }),
    ).toBeUndefined();
    // The control: asked with the row's own provider the same query finds it, so the `undefined`
    // above is the scoping and not a query that finds nothing.
    expect(
      await readOutstandingTopUp(client, {
        accountId: ACCOUNT,
        provider: OTHER,
        periodStart: THIS_PERIOD,
      }),
    ).toEqual({ topUpId: expect.any(String), orderId: "order-old-provider" });

    const rows = await readUnresolvedTopUps(client);
    expect(rows).toHaveLength(1);
    expect(strandedByPeriodRollover(rows[0]!, NOW)).toBe(false);
    expect(reachOfSelfHeal(rows[0]!, NOW, PROVIDER)).toBe("stranded-provider");
    const report = reportBillingDebts({ topUps: rows, deliveries: [] }, NOW, PROVIDER);
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("STRANDED (provider)");
    expect(report.text).not.toContain("STRANDED (period)");
  });

  itUnderHangBackstop("still calls a same-provider current-period row resolvable, the control", async () => {
    await rowWith({ outcome: "unconfirmed", orderId: "order-same-provider" });

    const rows = await readUnresolvedTopUps(client);
    expect(rows).toHaveLength(1);
    expect(reachOfSelfHeal(rows[0]!, NOW, PROVIDER)).toBe("resolvable");
    const report = reportBillingDebts({ topUps: rows, deliveries: [] }, NOW, PROVIDER);
    expect(report.text).toContain("resolvable  account");
    expect(report.text).not.toContain("STRANDED");
  });

  /** Runs `body` with `constraint` dropped from `table`, and puts it back whatever happens. */
  async function withoutOutcomeConstraint(
    table: string,
    constraint: string,
    body: () => Promise<void>,
  ): Promise<void> {
    const { rows } = await client.query<{ def: string }>(
      `SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conname = $1`,
      [constraint],
    );
    // Refused on its own terms: a constraint that is not there means this test is asserting about a
    // vocabulary nothing enforces, which is not the situation it exists to model.
    const definition = rows[0]?.def;
    expect(definition).toBeDefined();
    await client.query(`ALTER TABLE ${table} DROP CONSTRAINT ${constraint}`);
    try {
      await body();
    } finally {
      // **The table is emptied before the constraint goes back**, and it has to be: the row this
      // helper exists to plant is by construction one the constraint forbids, so re-adding it over
      // that row fails with `is violated by some row` and leaves the schema without its constraint
      // for every test after this one. `beforeEach` truncates anyway, so nothing is lost.
      await client.query(`TRUNCATE ${table}`);
      await client.query(`ALTER TABLE ${table} ADD CONSTRAINT ${constraint} ${definition!}`);
    }
    // And it really came back. A helper that drops a constraint and silently fails to restore it
    // leaves every later test in this file running against a schema nobody chose, and the symptom
    // would be a passing suite.
    const { rows: after } = await client.query<{ def: string }>(
      `SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conname = $1`,
      [constraint],
    );
    expect(after[0]?.def).toBe(definition);
  }

  itUnderHangBackstop("reports a top-up outcome a later migration added and this file does not know", async () => {
    // **The inversion** (PR #201's F4), against the real constraint rather than a fake. Before it,
    // an eighth outcome as the only row in the table answered `no unresolved billing debt` and
    // exit 0 — a reassuring sentence over a row nobody had classified.
    await withoutOutcomeConstraint("sonny.credit_topup", "credit_topup_outcome_known", async () => {
      await client.query(
        `INSERT INTO sonny.credit_topup
             (account_id, provider, provider_order_id, period_start, attempt_no, outcome,
              consented_at, runs_left_at_trigger, credits_remaining_at_trigger)
         VALUES ($1, $2, 'order-future', $3, 1, 'uncredited', $4, 0, 0)`,
        [ACCOUNT, PROVIDER, THIS_PERIOD, CONSENTED],
      );

      const rows = await readUnresolvedTopUps(client);
      expect(rows.map((row) => row.outcome)).toEqual(["uncredited"]);
      const report = reportBillingDebts({ topUps: rows, deliveries: [] }, NOW, PROVIDER);
      expect(report.exitCode).toBe(1);
      expect(report.text).toContain("UNKNOWN  account");
      expect(report.text).toContain("uncredited");
    });
  });

  itUnderHangBackstop("reports a delivery outcome a later migration added, and still hides the five that are not debt", async () => {
    await withoutOutcomeConstraint("sonny.billing_event", "billing_event_outcome_known", async () => {
      await deliveryWith("uncredited", "evt-future", ACCOUNT);
      // The control in the same table: the five known non-debt states stay out, so the inversion
      // did not simply start reporting everything.
      for (const outcome of ["applied", "ignored", "stale", "unmapped", "unreadable"]) {
        await deliveryWith(outcome, `evt-${outcome}`, ACCOUNT);
      }

      const rows = await readUnaccountedDeliveries(client);
      expect(rows.map((row) => row.eventId)).toEqual(["evt-future"]);
      const report = reportBillingDebts({ topUps: [], deliveries: rows }, NOW, PROVIDER);
      expect(report.exitCode).toBe(1);
      expect(report.text).toContain("UNKNOWN uncredited");
    });
  });

  itUnderHangBackstop("puts both populations behind one non-zero exit", async () => {
    await rowWith({ outcome: "unconfirmed", orderId: "order-1" });
    await deliveryWith("unmatched", "evt-1", null);

    const debts = await readBillingDebts(client);
    expect(debts.topUps).toHaveLength(1);
    expect(debts.deliveries).toHaveLength(1);
    expect(reportBillingDebts(debts, NOW).exitCode).toBe(1);
  });
});
