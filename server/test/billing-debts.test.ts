import { describe, expect, it } from "vitest";
import {
  reportBillingDebts,
  strandedByPeriodRollover,
  type BillingDebts,
  type UnaccountedDelivery,
  type UnresolvedTopUp,
} from "../src/billing-debts.js";

/**
 * What `npm run billing-debts` says and what it exits with (SONNY-408).
 *
 * `billing-debts.db.test.ts` proves the two queries against a real Postgres — which rows they select
 * and, for the boundary case, which rows `readOutstandingTopUp` deliberately no longer reaches. This
 * file proves the half that needs no database: the exit code, and that the stranded paragraph is
 * printed for a stranded row and for no other kind.
 *
 * **The exit code is the whole promise of this command**, so it is asserted as a value on every
 * shape rather than left to a branch only a spawned process could reach. That is why `main` is three
 * lines and `reportBillingDebts` is a function.
 */

const NOW = new Date("2026-09-04T12:00:00Z");
const THIS_PERIOD = new Date("2026-09-01T00:00:00Z");
const LAST_PERIOD = new Date("2026-08-01T00:00:00Z");
const ACCOUNT = "9b1c2d3e-4f50-4a61-8b72-3c4d5e6f7a80";

function topUp(overrides: Partial<UnresolvedTopUp> = {}): UnresolvedTopUp {
  return {
    topUpId: "1f2e3d4c-5b6a-4798-8899-aabbccddeeff",
    accountId: ACCOUNT,
    provider: "polar",
    providerOrderId: "order-1",
    outcome: "unconfirmed",
    periodStart: THIS_PERIOD,
    attemptedAt: new Date("2026-09-03T08:15:00Z"),
    ...overrides,
  };
}

function delivery(overrides: Partial<UnaccountedDelivery> = {}): UnaccountedDelivery {
  return {
    provider: "polar",
    eventId: "evt-1",
    eventType: "subscription.active",
    outcome: "unmatched",
    accountId: null,
    receivedAt: new Date("2026-09-02T10:00:00Z"),
    ...overrides,
  };
}

const NOTHING: BillingDebts = { topUps: [], deliveries: [] };

describe("what an operator is told about money nobody can account for", () => {
  it("exits 0 and says so when there is nothing outstanding", () => {
    const report = reportBillingDebts(NOTHING, NOW);
    expect(report.exitCode).toBe(0);
    expect(report.text).toBe("no unresolved billing debt\n");
  });

  it("exits 1 for an unresolved top-up, and names the order somebody has to look up", () => {
    const report = reportBillingDebts({ topUps: [topUp()], deliveries: [] }, NOW);
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("1 top-up order(s) this gateway granted nothing for:");
    // The order id is the whole reason the row exists — 0019 records it "precisely so somebody can
    // go and look" — so a report that omitted it would be a count with no way to act on it.
    expect(report.text).toContain("order order-1");
    expect(report.text).toContain(`account ${ACCOUNT}`);
    expect(report.text).toContain("unconfirmed");
  });

  it("exits 1 for a delivery alone, so a full billing_event cannot pass as clean", () => {
    // The two populations are one exit code deliberately: a check that ran this and looked only at
    // top-ups would pass while `unmatched` rows piled up.
    const report = reportBillingDebts({ topUps: [], deliveries: [delivery()] }, NOW);
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("1 subscription delivery(s) that changed nothing:");
    expect(report.text).toContain("unmatched  polar event evt-1");
    expect(report.text).toContain("no account");
  });

  it("names a conflict's account, because a conflict has one and an unmatched does not", () => {
    const report = reportBillingDebts(
      { topUps: [], deliveries: [delivery({ outcome: "conflict", accountId: ACCOUNT })] },
      NOW,
    );
    expect(report.text).toContain(`conflict  polar event evt-1  subscription.active  account ${ACCOUNT}`);
  });

  it("calls a current-period row resolvable and does not print the stranded paragraph", () => {
    const report = reportBillingDebts({ topUps: [topUp()], deliveries: [] }, NOW);
    expect(report.text).toContain("resolvable  account");
    // **The negative half, and it is the one that matters.** A report that printed the stranded
    // paragraph unconditionally would pass every positive assertion in this file while telling an
    // operator that a row which will very likely heal itself needs a manual refund.
    expect(report.text).not.toContain("STRANDED");
    expect(report.text).toContain("may still resolve");
  });

  it("marks a row from an earlier period STRANDED and says why nothing will reach it", () => {
    const report = reportBillingDebts(
      { topUps: [topUp({ periodStart: LAST_PERIOD })], deliveries: [] },
      NOW,
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("STRANDED  account");
    expect(report.text).toContain("1 of those is STRANDED");
    expect(report.text).toContain("CHARGES a draft that was never charged");
    // And the resolvable paragraph is absent, for the mirror of the reason above.
    expect(report.text).not.toContain("may still resolve");
  });

  it("separates the two when both are present, rather than counting them together", () => {
    const report = reportBillingDebts(
      {
        topUps: [topUp(), topUp({ topUpId: "other", providerOrderId: "order-2", periodStart: LAST_PERIOD })],
        deliveries: [delivery()],
      },
      NOW,
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("2 top-up order(s)");
    expect(report.text).toContain("1 of those is in the account's CURRENT period");
    expect(report.text).toContain("1 of those is STRANDED");
  });
});

describe("what the period rollover puts out of the self-healing path's reach", () => {
  it("is not stranded inside its own period", () => {
    expect(strandedByPeriodRollover(topUp({ periodStart: THIS_PERIOD }), NOW)).toBe(false);
  });

  it("is stranded once the period has rolled over", () => {
    expect(strandedByPeriodRollover(topUp({ periodStart: LAST_PERIOD }), NOW)).toBe(true);
  });

  it("flips at the first instant of the new period and not before", () => {
    // **The boundary itself, asserted on both sides of one instant.** `periodStart` is the UTC month
    // start, so a row bought at any point in August is stranded from `2026-09-01T00:00:00Z` onwards
    // and not one millisecond earlier. A `<=` in place of the `<` would fail the first of these.
    const lastInstantOfAugust = new Date("2026-08-31T23:59:59.999Z");
    const firstInstantOfSeptember = new Date("2026-09-01T00:00:00.000Z");
    expect(strandedByPeriodRollover(topUp({ periodStart: LAST_PERIOD }), lastInstantOfAugust)).toBe(false);
    expect(strandedByPeriodRollover(topUp({ periodStart: LAST_PERIOD }), firstInstantOfSeptember)).toBe(true);
  });
});
