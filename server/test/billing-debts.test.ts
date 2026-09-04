import { describe, expect, it } from "vitest";
import {
  reachOfSelfHeal,
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
    expect(report.text).toContain("in the account's CURRENT period, at this");
  });

  it("marks a row from an earlier period STRANDED and says why nothing will reach it", () => {
    const report = reportBillingDebts(
      { topUps: [topUp({ periodStart: LAST_PERIOD })], deliveries: [] },
      NOW,
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("STRANDED (period)  account");
    expect(report.text).toContain("1 of those is STRANDED by a period rollover");
    expect(report.text).toContain("CHARGES a draft that was never charged");
    // And the resolvable paragraph is absent, for the mirror of the reason above.
    expect(report.text).not.toContain("in the account's CURRENT period, at this");
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
    expect(report.text).toContain("1 of those is STRANDED by a period rollover");
  });
});

describe("what else puts a row out of the self-healing path's reach", () => {
  // **The second of the two boundaries `readOutstandingTopUp` enforces** (PR #201's F3). That query
  // scopes by account, provider, period and outcome; the report modelled the period alone, so a
  // current-period row bought at a provider this deployment no longer runs printed `resolvable`
  // while nothing would ever find it. Consent withdrawal is the reachable variant of the same shape
  // and is named in the report rather than modelled — see `reachOfSelfHeal`.
  const OTHER_PROVIDER = "an-old-provider";

  it("marks a current-period row at another provider STRANDED, not resolvable", () => {
    const report = reportBillingDebts(
      { topUps: [topUp({ provider: OTHER_PROVIDER })], deliveries: [] },
      NOW,
      "polar",
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("STRANDED (provider)  account");
    expect(report.text).toContain("1 of those is STRANDED at another PROVIDER");
    expect(report.text).toContain('BILLING_PROVIDER is now\n"polar"');
    // It is in the current period, so the period label must NOT be the one that fired.
    expect(report.text).not.toContain("STRANDED (period)");
  });

  it("still calls a same-provider current-period row resolvable, which is the control", () => {
    // Without this the fix above could be "call everything stranded", which passes the assertion
    // that matters to F3 and destroys the only distinction the report makes.
    const report = reportBillingDebts({ topUps: [topUp({ provider: "polar" })] , deliveries: [] }, NOW, "polar");
    expect(report.text).toContain("resolvable  account");
    expect(report.text).not.toContain("STRANDED");
    expect(reachOfSelfHeal(topUp({ provider: "polar" }), NOW, "polar")).toBe("resolvable");
    expect(reachOfSelfHeal(topUp({ provider: OTHER_PROVIDER }), NOW, "polar")).toBe("stranded-provider");
  });

  it("says which half it could not check when BILLING_PROVIDER is not set", () => {
    // The honest third state. With no provider given the mismatch is unknowable, so the row keeps
    // the label it had and the report names the gap rather than quietly leaving it.
    const report = reportBillingDebts({ topUps: [topUp({ provider: OTHER_PROVIDER })], deliveries: [] }, NOW, undefined);
    expect(report.text).toContain("resolvable  account");
    expect(report.text).toContain("BILLING_PROVIDER was not set when this ran");
    expect(reachOfSelfHeal(topUp({ provider: OTHER_PROVIDER }), NOW, undefined)).toBe("resolvable");
    // And the note is absent when the provider IS known, or it would be permanent noise.
    const known = reportBillingDebts({ topUps: [topUp({ provider: "polar" })], deliveries: [] }, NOW, "polar");
    expect(known.text).not.toContain("BILLING_PROVIDER was not set");
  });

  it("puts the period ahead of the provider, so a row failing both reads as period", () => {
    // Order matters for the operator: the period case carries this branch's whole argument about
    // why widening the lookback is wrong, and a row that fails both should carry that reasoning.
    const both = topUp({ provider: OTHER_PROVIDER, periodStart: LAST_PERIOD });
    expect(reachOfSelfHeal(both, NOW, "polar")).toBe("stranded-period");
  });
});

describe("an outcome this command has never heard of", () => {
  // **The inversion** (PR #201's F4). Both vocabularies were closed `IN` lists with nothing tying
  // them to the migrations' CHECKs, so an outcome added by a later migration fell silently on the
  // not-debt side and a report over one such row alone printed "no unresolved billing debt" and
  // exited 0 — the clean-zero family, on a money report.
  it("is reported with its own label and a non-zero exit, never hidden", () => {
    const report = reportBillingDebts(
      { topUps: [topUp({ outcome: "uncredited" })], deliveries: [] },
      NOW,
      "polar",
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("UNKNOWN  account");
    expect(report.text).toContain("uncredited");
    expect(report.text).toContain("carrying an outcome this command has never heard");
    // Checked before the period and provider rules, because a state nothing classifies cannot be
    // reasoned about with rules written for the states that are classified.
    expect(reachOfSelfHeal(topUp({ outcome: "uncredited", periodStart: LAST_PERIOD }), NOW, "polar")).toBe(
      "unknown-outcome",
    );
  });

  it("is reported on a delivery too, with its own label", () => {
    const report = reportBillingDebts(
      { topUps: [], deliveries: [delivery({ outcome: "uncredited" })] },
      NOW,
      "polar",
    );
    expect(report.exitCode).toBe(1);
    expect(report.text).toContain("UNKNOWN uncredited  polar event evt-1");
    expect(report.text).toContain("1 of those is marked UNKNOWN");
  });

  it("leaves a known debt outcome unmarked, which is the control", () => {
    // Without this, labelling everything UNKNOWN would satisfy both assertions above.
    const report = reportBillingDebts(
      { topUps: [topUp()], deliveries: [delivery()] },
      NOW,
      "polar",
    );
    expect(report.text).not.toContain("UNKNOWN");
    expect(report.text).toContain("resolvable  account");
    expect(report.text).toContain("unmatched  polar event evt-1");
  });

  it("prints 'no order id' rather than null for an unknown outcome that carries none", () => {
    const report = reportBillingDebts(
      { topUps: [topUp({ outcome: "uncredited", providerOrderId: null })], deliveries: [] },
      NOW,
      "polar",
    );
    expect(report.text).toContain("polar no order id");
    expect(report.text).not.toContain("null");
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
