import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { ConfigError, loadConfig, requireCreditCatalogue } from "../src/config.js";
import { creditBalance, periodEnd } from "../src/credit/balance.js";
import {
  CreditCatalogueError,
  parseCreditCatalogue,
  planFor,
  type CreditCatalogue,
} from "../src/credit/catalogue.js";
import { creditPlanKeyFor } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import { claimFactsFor, unprovisioned, type EntitlementRecord } from "../src/entitlement/store.js";
import { METERED_ROUTES } from "../src/metering/event.js";
import { testConfig } from "./support/config.js";
import {
  catalogueOf,
  creditPlansDocument,
  fakeCreditStore,
  TEST_CREDIT_PLANS,
} from "./support/credit.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";
import { signedInConnectionTo } from "./support/connection.js";
import { WithoutOAuth } from "./support/without-oauth.js";

/**
 * The credit/allowance model, and the one number a user tracks (SONNY-212; spent by tokens since V2
 * plan decision 8).
 *
 * **The split with `credit.db.test.ts` is the same one SONNY-133, SONNY-135 and SONNY-300 made.**
 * *Which rows an account has spent* is a property of one SQL statement over the model-call ledger,
 * and it is proved there, against a real Postgres. What is proved *here* is everything around it:
 * what a catalogue may say, what a plan's allowance and an account's spending become as a balance,
 * what a revoked plan draws on, and what the route hands a client.
 *
 * **Nothing here asserts a price, a plan or an allowance, and nothing here spells a plan key.** The
 * ticket's acceptance criterion is that the tier count and the numbers are not baked into code, so
 * every catalogue below is built by `catalogueOf`, whose plan keys are UUIDs minted microseconds
 * before the assertion that reads them. A suite that asserted `"free"` and `"pro"` would pass just
 * as happily against an implementation with those two words written into it.
 */

const SUPABASE_USER = "3f0b7f1c-6f21-4a0e-8d55-2b6f5f2a77c1";
const ACCOUNT = "6d2c4a9e-1b3d-4f0a-9c77-2b6f5f2a77c2";

describe("the catalogue is configuration, never code (SONNY-212's acceptance criterion)", () => {
  it("carries whatever tier count it is given — one, two, or seven", () => {
    for (const allowances of [[100], [100, 1000], [0, 10, 20, 30, 40, 50, 60]]) {
      const catalogue = catalogueOf({ monthlyCredits: allowances });
      expect(catalogue.plans).toHaveLength(allowances.length);

      // Every tier answers for its own allowance, through the same code path, with keys no source
      // file could contain.
      for (const [index, plan] of catalogue.plans.entries()) {
        const balance = creditBalance({
          catalogue,
          planKey: plan.key,
          agentCredits: 0,
          toppedUpCredits: 0,
          now: new Date("2026-08-15T12:00:00Z"),
        });
        expect(balance.plan).toBe(plan.key);
        expect(balance.credits.allowance).toBe(allowances[index]);
        expect(balance.credits.remaining).toBe(allowances[index]);
      }
    }
  });

  it("has no default in this repository: an unset CREDIT_PLANS is a startup failure naming it", () => {
    // `loadConfig` invents nothing...
    const config = loadConfig({ SONNY_ENV: "local", SONNY_BUILD_ID: "test" });
    expect(config.creditPlans).toBeUndefined();

    // ...and the point of use refuses rather than serving a balance derived from nothing.
    expect(() => requireCreditCatalogue(config)).toThrow(ConfigError);
    expect(() => requireCreditCatalogue(config)).toThrow(/CREDIT_PLANS is required/);
  });

  it("refuses a catalogue that is present and malformed, at startup rather than on a user", () => {
    const cases: readonly (readonly [string, RegExp])[] = [
      ["not json at all", /not valid JSON/],
      // No plans and no default: a document that says nothing a balance could be computed from.
      [JSON.stringify({}), /not a valid credit catalogue.*plans/],
      [creditPlansDocument({ defaultPlan: "a", plans: [] }), /not a valid credit catalogue.*plans/],
      // A negative allowance is not a tier that owes the user credits; it is a typo. Named by its
      // path, so the refusal is for this field and not for anything else the document lacks.
      [
        creditPlansDocument({ defaultPlan: "a", plans: [{ key: "a", monthlyCredits: -1 }] }),
        /not a valid credit catalogue.*plans\.0\.monthlyCredits/,
      ],
    ];
    for (const [raw, message] of cases) {
      expect(() => parseCreditCatalogue(raw)).toThrow(CreditCatalogueError);
      expect(() => parseCreditCatalogue(raw)).toThrow(message);
      // And the same value reaches an operator through the variable's own name.
      expect(() => requireCreditCatalogue(testConfig({ creditPlans: raw }))).toThrow(ConfigError);
    }
  });

  it("refuses a duplicate plan key, so which tier applies cannot depend on list order", () => {
    const key = `plan-${randomUUID()}`;
    const raw = creditPlansDocument({
      defaultPlan: key,
      plans: [
        { key, monthlyCredits: 100 },
        { key, monthlyCredits: 999_999 },
      ],
    });
    expect(() => parseCreditCatalogue(raw)).toThrow(/twice/);
  });

  it("refuses a defaultPlan naming no tier, whose only symptom would be silent", () => {
    const raw = creditPlansDocument({
      defaultPlan: `plan-${randomUUID()}`,
      plans: [{ key: `plan-${randomUUID()}`, monthlyCredits: 100 }],
    });
    expect(() => parseCreditCatalogue(raw)).toThrow(/defaultPlan/);
  });

  it("refuses a catalogue with no token rates, which would make every model call free", () => {
    const key = `plan-${randomUUID()}`;
    const raw = JSON.stringify({ defaultPlan: key, plans: [{ key, monthlyCredits: 100 }] });
    expect(() => parseCreditCatalogue(raw)).toThrow(/tokenRates/);
  });

  it("falls an unknown plan key to the plan defaultPlan names, not to whatever is listed first", () => {
    // The misconfiguration this is about: a `BILLING_PLANS` entry pointing at a plan nobody added
    // here. The two ways to be wrong are not symmetric — a smaller allowance is complainable, a
    // larger one is a bill nobody sees.
    //
    // **`defaultIndex: 1` is the whole point of this fixture** (PR #182's review, F3). Every
    // catalogue in this suite used to make the default the first entry, so "the named default" and
    // "the first listed" were the same plan and a mutant returning `plans[0]` survived. Here the
    // default is the *second* tier and the first is deliberately the large one, so returning either
    // "the first" or "the largest" fails — and an operator who lists their paid tier first, which is
    // an ordinary thing to do, is the deployment this models.
    const catalogue = catalogueOf({
      monthlyCredits: [100_000, 100],
      defaultIndex: 1,
    });
    expect(catalogue.defaultPlan).not.toBe(catalogue.plans[0]!.key);
    const balance = creditBalance({
      catalogue,
      planKey: `plan-${randomUUID()}`,
      agentCredits: 0,
      toppedUpCredits: 0,
      now: new Date("2026-08-15T12:00:00Z"),
    });
    expect(balance.plan).toBe(catalogue.defaultPlan);
    expect(balance.plan).toBe(catalogue.plans[1]!.key);
    expect(balance.credits.allowance).toBe(100);
    expect(balance.credits.remaining).toBe(100);
    expect(planFor(catalogue, undefined).key).toBe(catalogue.defaultPlan);
  });
});

describe("the balance, spent by tokens (V2 plan decision 8)", () => {
  const catalogue = (): CreditCatalogue => catalogueOf({ monthlyCredits: [1000] });
  const now = new Date("2026-08-15T12:00:00Z");
  const balanceOf = (input: {
    readonly catalogue?: CreditCatalogue;
    readonly agentCredits: number;
    readonly toppedUpCredits?: number;
  }) =>
    creditBalance({
      catalogue: input.catalogue ?? catalogue(),
      planKey: undefined,
      agentCredits: input.agentCredits,
      toppedUpCredits: input.toppedUpCredits ?? 0,
      now,
    });

  it("draws what the account's model calls spent against the plan's allowance and its top-ups", () => {
    // Allowance is the plan's month plus what was topped up; drawn is what was spent; remaining is
    // the difference. Each figure asserted as a value, not recomputed from the others.
    expect(balanceOf({ agentCredits: 300, toppedUpCredits: 250 }).credits).toEqual({
      allowance: 1250,
      drawn: 300,
      remaining: 950,
      toppedUp: 250,
    });
    // Nothing spent leaves the whole allowance.
    expect(balanceOf({ agentCredits: 0 }).credits).toEqual({
      allowance: 1000,
      drawn: 0,
      remaining: 1000,
      toppedUp: 0,
    });
    // A top-up raises the allowance and leaves the drawn figure alone: it is credit bought, not
    // spending undone.
    const before = balanceOf({ agentCredits: 1000 });
    const after = balanceOf({ agentCredits: 1000, toppedUpCredits: 500 });
    expect(before.credits.remaining).toBe(0);
    expect(after.credits.drawn).toBe(before.credits.drawn);
    expect(after.credits.allowance).toBe(1500);
    expect(after.credits.remaining).toBe(500);
  });

  it("floors at zero rather than reporting a negative balance", () => {
    // Reachable: a call already in flight when the allowance runs out still settles at what it
    // actually cost, so spending can pass the allowance.
    const balance = balanceOf({ agentCredits: 2800, toppedUpCredits: 500 });
    expect(balance.credits.allowance).toBe(1500);
    expect(balance.credits.drawn).toBe(2800);
    expect(balance.credits.remaining).toBe(0);
    // Exactly spent is zero too, not a negative zero or float residue.
    expect(Object.is(balanceOf({ agentCredits: 1000 }).credits.remaining, 0)).toBe(true);
  });

  it("never lets a negative input raise the balance", () => {
    // Neither figure is negative in a real store; a negative one is a bug upstream, and reading it
    // as credit would hand the account money it never had.
    const balance = balanceOf({ agentCredits: -50, toppedUpCredits: -200 });
    expect(balance.credits).toEqual({ allowance: 1000, drawn: 0, remaining: 1000, toppedUp: 0 });
  });

  it("rounds every figure to six decimals, so a sum of per-call charges reads as the sum", () => {
    // Per-call charges are fractional credits, and the float residue of adding them is where a
    // response could contradict itself: 0.5 - 0.4 is 0.09999999999999998 in IEEE 754.
    const small = catalogueOf({ monthlyCredits: [0.5] });
    const residue = balanceOf({ catalogue: small, agentCredits: 0.4 });
    expect(residue.credits.remaining).toBe(0.1);
    expect(residue.credits.remaining).not.toBe(0.5 - 0.4);

    // 0.1 + 0.2 spent is 0.30000000000000004 unrounded; the allowance side rounds the same way.
    const summed = balanceOf({
      catalogue: catalogueOf({ monthlyCredits: [0.1] }),
      agentCredits: 0.1 + 0.2,
      toppedUpCredits: 0.2,
    });
    expect(summed.credits).toEqual({ allowance: 0.3, drawn: 0.3, remaining: 0, toppedUp: 0.2 });

    // Six places exactly: a genuine sub-credit remainder survives, and only the seventh place goes.
    // Rounding to fewer places would turn 2.999999 into 3, which is credit nobody bought.
    const genuine = balanceOf({ catalogue: catalogueOf({ monthlyCredits: [2.999999] }), agentCredits: 0 });
    expect(genuine.credits.remaining).toBe(2.999999);
    expect(balanceOf({ agentCredits: 0.0000004 }).credits.drawn).toBe(0);
    expect(balanceOf({ agentCredits: 0.0000006 }).credits.drawn).toBe(0.000001);
    expect(balanceOf({ agentCredits: 999.9999994 }).credits.remaining).toBe(0.000001);
  });

  it("reports the calendar month the server is in, as an instant pair", () => {
    const balance = creditBalance({
      catalogue: catalogue(),
      planKey: undefined,
      agentCredits: 0,
      toppedUpCredits: 0,
      now: new Date("2026-12-31T23:59:59Z"),
    });
    expect(balance.periodStart.toISOString()).toBe("2026-12-01T00:00:00.000Z");
    // December rolls into the next year rather than into month 12 of this one.
    expect(balance.periodEnd.toISOString()).toBe("2027-01-01T00:00:00.000Z");
    expect(periodEnd(new Date("2026-02-09T00:00:00Z")).toISOString()).toBe(
      "2026-03-01T00:00:00.000Z",
    );
    expect(periodStart(new Date("2026-02-09T00:00:00Z")).toISOString()).toBe(
      "2026-02-01T00:00:00.000Z",
    );
  });
});

describe("which plan an account draws against", () => {
  const at = new Date("2026-08-15T12:00:00Z");
  const record = (over: Partial<EntitlementRecord>): EntitlementRecord => ({
    ...unprovisioned(ACCOUNT),
    plan: "plan-x",
    capabilities: ["cap.a"],
    ...over,
  });

  it("keeps a live plan's key", () => {
    expect(creditPlanKeyFor(record({}), at)).toBe("plan-x");
  });

  it("falls a revoked plan to the default: the key survives for the claim, the allowance does not", () => {
    expect(creditPlanKeyFor(record({ revokedAt: new Date("2026-08-01T00:00:00Z") }), at)).toBeUndefined();
  });

  it("falls a plan past its payment-failure grace to the default, and not one still inside it", () => {
    const inside = record({
      pastDueSince: new Date("2026-08-10T00:00:00Z"),
      graceUntil: new Date("2026-08-20T00:00:00Z"),
    });
    const past = record({
      pastDueSince: new Date("2026-07-10T00:00:00Z"),
      graceUntil: new Date("2026-08-01T00:00:00Z"),
    });
    // §16.4: billing never cuts a user off mid-task, so a failure sets a deadline.
    expect(creditPlanKeyFor(inside, at)).toBe("plan-x");
    expect(creditPlanKeyFor(past, at)).toBeUndefined();
  });

  it("is live exactly when the claim keeps its capabilities — the two rules cannot drift apart", () => {
    // `creditPlanKeyFor` repeats `claimFactsFor`'s two conditions rather than calling it, because
    // "no capabilities" cannot be read back as "not live": an unprovisioned account and a live plan
    // that gates nothing both carry an empty list, and today every plan does. This is what pins the
    // repetition — it fails if either side's rule moves.
    const withCapability = [
      record({}),
      record({ revokedAt: new Date("2026-08-01T00:00:00Z") }),
      record({ graceUntil: new Date("2026-08-01T00:00:00Z"), pastDueSince: at }),
      record({ graceUntil: new Date("2026-08-20T00:00:00Z"), pastDueSince: at }),
      // **The boundary instant, and it is the only place the two rules can drift**
      // (PR #182's review, F5). Both sides read `now >= graceUntil`, so the sole way they can
      // disagree is one of them becoming `>` — and every fixture above sits days from the boundary,
      // so a mutant that moved it passed this loop untouched. `graceUntil` exactly `at` is the one
      // input that tells `>=` from `>`, and both sides must call it closed.
      record({ graceUntil: at, pastDueSince: new Date("2026-08-01T00:00:00Z") }),
      // One millisecond earlier is still open, so the assertion above is a boundary rather than a
      // rule that refuses everything near it.
      record({
        graceUntil: new Date(at.getTime() + 1),
        pastDueSince: new Date("2026-08-01T00:00:00Z"),
      }),
    ];
    for (const one of withCapability) {
      const keepsCapabilities = claimFactsFor(one, at).capabilities.length > 0;
      expect(creditPlanKeyFor(one, at) !== undefined).toBe(keepsCapabilities);
      // And the claim keeps the key in every case, which is the half that must NOT follow.
      expect(claimFactsFor(one, at).plan).toBe("plan-x");
    }
  });
});

class UnusedAuthProvider extends WithoutOAuth implements AuthProvider {
  async sendEmailCode() {
    return { providerRequestId: undefined };
  }
  async verifyEmailCode(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async refresh(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async signOut() {}
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

/** Answers the gate's attribution query and refuses everything else, as the other suites' does. */
const signedInConnection = signedInConnectionTo({ account: ACCOUNT, where: "outside the credit store" });

describe("GET /v1/account/credits", () => {
  const at = new Date("2026-08-15T12:00:00Z");

  function build(
    store: ReturnType<typeof fakeCreditStore>,
    overrides: Record<string, unknown> = {},
  ) {
    return buildApp(
      testConfig(overrides),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection, now: () => at },
      // A fake entitlement store as well, for the reason `entitlement.test.ts` gives: the real one
      // is built from `withConnection`, and this suite's connection answers the gate's attribution
      // query and nothing else. The cap is not what is under test here.
      { creditStore: store, entitlementStore: fakeEntitlementStore() },
    );
  }

  it("hands the caller the one number the product asks them to track", async () => {
    // The fixture catalogue: tier A includes a thousand credits a month. Thirty and a half spent on
    // model calls leaves 969.5.
    const store = fakeCreditStore({ planKey: "test-plan-a", agentCredits: 30.5 });
    const app = build(store);
    const response = await app.inject({
      method: "GET",
      url: "/v1/account/credits",
      headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    const body = response.json() as Record<string, unknown>;
    expect(body.plan).toBe("test-plan-a");
    expect(body.period_start).toBe("2026-08-01T00:00:00.000Z");
    expect(body.period_end).toBe("2026-09-01T00:00:00.000Z");
    expect(body.credits).toEqual({
      allowance: 1000,
      drawn: 30.5,
      remaining: 969.5,
      topped_up: 0,
    });
    // V1's run figures are gone from the body, not left behind as stale numbers.
    expect(body).not.toHaveProperty("screen_control_runs_left");
    expect(body).not.toHaveProperty("screen_control_runs_included");

    // One clock read for the whole response: the instant judging the grace window is the instant
    // whose period is counted.
    expect(store.asked).toEqual([at]);
    // **And it asked about the caller's own account** (PR #182's review, F6). Replacing
    // `caller.accountId` with a fixed UUID in the route passed the whole suite before this line
    // existed, which is a route that would serve one account's balance to another with nothing
    // noticing. `ACCOUNT` is what `signedInConnection` answers the gate's attribution query with, so
    // this is the id the token really resolved to and not one the test chose for the route.
    expect(store.askedAbout).toEqual([ACCOUNT]);
  });

  it("is authenticated — an unauthenticated caller is refused before any account is read", async () => {
    const app = build(fakeCreditStore({}));
    const response = await app.inject({ method: "GET", url: "/v1/account/credits" });
    await app.close();
    expect(response.statusCode).toBe(401);
  });

  it("is not metered: asking how much is left may never spend it", async () => {
    expect(METERED_ROUTES.get("GET /v1/account/credits")).toBeUndefined();
    expect(METERED_ROUTES.get("/v1/account/credits")).toBeUndefined();
  });

  it("refuses to start when CREDIT_PLANS is absent, rather than answering from nothing", () => {
    expect(() => build(fakeCreditStore({}), { creditPlans: undefined })).toThrow(ConfigError);
  });

  it("serves a free-tier account with no entitlement row at all", async () => {
    // An account nothing has provisioned is a free user, and it reads a real number rather than a
    // refusal: the default plan's whole month.
    const app = build(fakeCreditStore({ planKey: undefined }));
    const response = await app.inject({
      method: "GET",
      url: "/v1/account/credits",
      headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
    });
    await app.close();
    const body = response.json() as Record<string, unknown>;
    expect(response.statusCode).toBe(200);
    expect(body.plan).toBe(parseCreditCatalogue(TEST_CREDIT_PLANS).defaultPlan);
    expect(body.credits).toEqual({ allowance: 1000, drawn: 0, remaining: 1000, topped_up: 0 });
  });
});
