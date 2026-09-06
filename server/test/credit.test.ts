import { randomUUID } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { ConfigError, loadConfig, requireCreditCatalogue } from "../src/config.js";
import {
  creditBalance,
  creditsForDraw,
  periodEnd,
  type ScreenControlDraw,
} from "../src/credit/balance.js";
import { itUnderHangBackstop } from "./support/backstop.js";
import {
  CreditCatalogueError,
  parseCreditCatalogue,
  planFor,
  type CreditCatalogue,
} from "../src/credit/catalogue.js";
import { creditPlanKeyFor } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import { claimFactsFor, unprovisioned, type EntitlementRecord } from "../src/entitlement/store.js";
import { METERED_ROUTES, type MeteringEvent } from "../src/metering/event.js";
import type { MeteringStore } from "../src/metering/store.js";
import type { ClaimOutcome, KeyStore } from "../src/idempotency/store.js";
import { testConfig } from "./support/config.js";
import { catalogueOf, fakeCreditStore, TEST_CREDIT_PLANS } from "./support/credit.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";
import { signedInConnectionTo } from "./support/connection.js";

/**
 * The credit/allowance model, and the one number a user tracks (SONNY-212).
 *
 * **The split with `credit.db.test.ts` is the same one SONNY-133, SONNY-135 and SONNY-300 made.**
 * *Which rows draw* is a property of one SQL statement over a table row 12 writes, and it is proved
 * there, against a real Postgres — a fake that appeared to exclude the four unpaid routes would be a
 * suite believing it had tested an exclusion. What is proved *here* is everything around it: what a
 * catalogue may say, what a plan's allowance becomes in runs, what a revoked plan draws on, and what
 * the route hands a client.
 *
 * **Nothing here asserts a price, a plan or an allowance, and nothing here spells a plan key.** The
 * ticket's acceptance criterion is that the tier count and the numbers are not baked into code, so
 * every catalogue below is built by `catalogueOf`, whose plan keys are UUIDs minted microseconds
 * before the assertion that reads them. A suite that asserted `"free"` and `"pro"` would pass just
 * as happily against an implementation with those two words written into it.
 */

const SUPABASE_USER = "3f0b7f1c-6f21-4a0e-8d55-2b6f5f2a77c1";
const ACCOUNT = "6d2c4a9e-1b3d-4f0a-9c77-2b6f5f2a77c2";

function drawOf(input: Partial<ScreenControlDraw>): ScreenControlDraw {
  return { sessions: 0, iterations: 0, pixels: 0, ...input };
}

describe("the catalogue is configuration, never code (SONNY-212's acceptance criterion)", () => {
  it("carries whatever tier count it is given — one, two, or seven", () => {
    for (const allowances of [[100], [100, 1000], [0, 10, 20, 30, 40, 50, 60]]) {
      const catalogue = catalogueOf({ runCredits: 10, monthlyCredits: allowances });
      expect(catalogue.plans).toHaveLength(allowances.length);

      // Every tier answers for its own allowance, through the same code path, with keys no source
      // file could contain.
      for (const [index, plan] of catalogue.plans.entries()) {
        const balance = creditBalance({
          catalogue,
          planKey: plan.key,
          draw: drawOf({}),
          toppedUpCredits: 0,
          now: new Date("2026-08-15T12:00:00Z"),
        });
        expect(balance.plan).toBe(plan.key);
        expect(balance.credits.allowance).toBe(allowances[index]);
        expect(balance.runsLeft).toBe(Math.floor(allowances[index]! / 10));
      }
    }
  });

  it("has no default in this repository: an unset CREDIT_PLANS is a startup failure naming it", () => {
    // `loadConfig` invents nothing...
    const config = loadConfig({ SONNY_ENV: "local", SONNY_BUILD_ID: "test" });
    expect(config.creditPlans).toBeUndefined();

    // ...and the point of use refuses rather than serving a run count derived from nothing.
    expect(() => requireCreditCatalogue(config)).toThrow(ConfigError);
    expect(() => requireCreditCatalogue(config)).toThrow(/CREDIT_PLANS is required/);
  });

  it("refuses a catalogue that is present and malformed, at startup rather than on a user", () => {
    const cases: readonly (readonly [string, RegExp])[] = [
      ["not json at all", /not valid JSON/],
      [JSON.stringify({ runCredits: 10 }), /not a valid credit catalogue/],
      // A zero divisor: "runs left" would be infinite or undefined depending on the rounding.
      [
        JSON.stringify({
          runCredits: 0,
          defaultPlan: "a",
          weights: { perSession: 0, perIteration: 0, perMegapixel: 0 },
          plans: [{ key: "a", monthlyCredits: 1 }],
        }),
        /not a valid credit catalogue/,
      ],
      // A negative allowance is not a tier that owes the user runs; it is a typo.
      [
        JSON.stringify({
          runCredits: 1,
          defaultPlan: "a",
          weights: { perSession: 0, perIteration: 0, perMegapixel: 0 },
          plans: [{ key: "a", monthlyCredits: -1 }],
        }),
        /not a valid credit catalogue/,
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
    const raw = JSON.stringify({
      runCredits: 10,
      defaultPlan: key,
      weights: { perSession: 0, perIteration: 0, perMegapixel: 0 },
      plans: [
        { key, monthlyCredits: 100 },
        { key, monthlyCredits: 999_999 },
      ],
    });
    expect(() => parseCreditCatalogue(raw)).toThrow(/twice/);
  });

  it("refuses a defaultPlan naming no tier, whose only symptom would be silent", () => {
    const raw = JSON.stringify({
      runCredits: 10,
      defaultPlan: `plan-${randomUUID()}`,
      weights: { perSession: 0, perIteration: 0, perMegapixel: 0 },
      plans: [{ key: `plan-${randomUUID()}`, monthlyCredits: 100 }],
    });
    expect(() => parseCreditCatalogue(raw)).toThrow(/defaultPlan/);
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
      runCredits: 10,
      monthlyCredits: [100_000, 100],
      defaultIndex: 1,
    });
    expect(catalogue.defaultPlan).not.toBe(catalogue.plans[0]!.key);
    const balance = creditBalance({
      catalogue,
      planKey: `plan-${randomUUID()}`,
      draw: drawOf({}),
      toppedUpCredits: 0,
      now: new Date("2026-08-15T12:00:00Z"),
    });
    expect(balance.plan).toBe(catalogue.defaultPlan);
    expect(balance.plan).toBe(catalogue.plans[1]!.key);
    expect(balance.runsLeft).toBe(10);
    expect(planFor(catalogue, undefined).key).toBe(catalogue.defaultPlan);
  });
});

describe("runs left, derived from what row 12 measured", () => {
  const catalogue = (): CreditCatalogue =>
    catalogueOf({
      runCredits: 100,
      monthlyCredits: [1000],
      weights: { perSession: 20, perIteration: 5, perMegapixel: 10 },
    });
  const now = new Date("2026-08-15T12:00:00Z");

  it("weights a session by what it actually consumed", () => {
    const weights = catalogue().weights;
    // One session, three iterations, two megapixels: 20 + 15 + 20.
    expect(creditsForDraw(weights, drawOf({ sessions: 1, iterations: 3, pixels: 2_000_000 }))).toBe(
      55,
    );
    // Nothing drawn costs nothing — not the per-session weight, which is per session that drew.
    expect(creditsForDraw(weights, drawOf({}))).toBe(0);
  });

  it("costs a heavy session more runs than a light one — the point of weighting", () => {
    const light = creditBalance({
      catalogue: catalogue(),
      planKey: undefined,
      draw: drawOf({ sessions: 1, iterations: 2, pixels: 1_000_000 }),
      toppedUpCredits: 0,
      now,
    });
    const heavy = creditBalance({
      catalogue: catalogue(),
      planKey: undefined,
      draw: drawOf({ sessions: 1, iterations: 12, pixels: 24_000_000 }),
      toppedUpCredits: 0,
      now,
    });
    expect(light.credits.drawn).toBe(40);
    expect(heavy.credits.drawn).toBe(320);
    expect(heavy.runsLeft).toBeLessThan(light.runsLeft);
    expect(light.runsLeft).toBe(9);
    expect(heavy.runsLeft).toBe(6);
    // The denominator does not move with usage: it is what a full period is worth.
    expect(light.runsIncluded).toBe(10);
    expect(heavy.runsIncluded).toBe(10);
  });

  it("floors at zero rather than reporting a negative number of runs", () => {
    // Reachable today and after SONNY-213: nothing here refuses, and a session already in flight
    // when an allowance runs out still finishes and is still metered.
    const balance = creditBalance({
      catalogue: catalogue(),
      planKey: undefined,
      draw: drawOf({ sessions: 40, iterations: 400, pixels: 0 }),
      toppedUpCredits: 0,
      now,
    });
    expect(balance.credits.drawn).toBe(2800);
    expect(balance.credits.remaining).toBe(0);
    expect(balance.runsLeft).toBe(0);
  });

  it("rounds, and the run count is what a missing round would cost a user", () => {
    // **This arm exists because the battery said the one below it was not enough** (SONNY-212's
    // four-property run at `00b8fcc`): with `round` replaced by the identity function the whole
    // suite still passed, because the sweep below only ever checks the response against *itself*
    // and a self-consistent response is self-consistent unrounded too. So this asserts the values,
    // the way `theWipesOwnSentenceNamesEveryStoreItDeletes` does and for its reason — a
    // completeness check cannot see a wrong answer, only a missing one.
    //
    // The fixture is chosen so the defect is invisible everywhere except the number the user reads:
    // `drawn` is 0.4 either way, and it is `0.5 - 0.4` that leaves `0.09999999999999998`, which
    // floors to **zero runs left when the user has one**. A whole run lost to IEEE 754, on the last
    // one they have, which is exactly when they would notice.
    const catalogue = catalogueOf({
      runCredits: 0.1,
      monthlyCredits: [0.5],
      weights: { perSession: 0.1, perIteration: 0.1, perMegapixel: 0 },
    });
    const balance = creditBalance({
      catalogue,
      planKey: undefined,
      draw: drawOf({ sessions: 1, iterations: 3 }),
      toppedUpCredits: 0,
      now,
    });
    expect(balance.credits.drawn).toBe(0.4);
    expect(balance.credits.remaining).toBe(0.1);
    expect(balance.runsLeft).toBe(1);
    // Stated as the thing that must not happen, so the assertion above cannot be read as arbitrary.
    expect(balance.credits.remaining).not.toBe(0.5 - 0.4);
    expect(Math.floor((0.5 - 0.4) / 0.1)).toBe(0);
  });

  it("publishes credit figures that recompute to the run count beside them", () => {
    // Fractional weights are where a response could contradict its own arithmetic: 0.1 per megapixel
    // against 30 megapixels is 2.9999999999999996 in IEEE 754. `balance.ts` rounds first and derives
    // the run count from the rounded remainder, so the four numbers and the count always agree.
    const fractional = catalogueOf({
      runCredits: 0.7,
      monthlyCredits: [10],
      weights: { perSession: 0, perIteration: 0, perMegapixel: 0.1 },
    });
    for (const pixels of [0, 3_000_000, 30_000_000, 77_000_000, 100_000_000]) {
      const balance = creditBalance({
        catalogue: fractional,
        planKey: undefined,
        draw: drawOf({ sessions: 1, iterations: 4, pixels }),
        toppedUpCredits: 0,
        now,
      });
      const { allowance, drawn, remaining } = balance.credits;
      expect(remaining).toBe(Math.max(0, Math.round((allowance - drawn) * 1e6) / 1e6));
      expect(Number.isInteger(balance.runsLeft)).toBe(true);
    }
    // **The run count is NOT recomputed from the response here, and that removal is the finding**
    // (PR #182's review, F1). The line that stood here was
    // `expect(balance.runsLeft).toBe(Math.floor(remaining / perRun))` — the implementation restated,
    // so it was true under the very defect it was meant to catch, which is the identical circularity
    // the battery caught one arm above at `4c7d6b0`. Values are what hold the quotient now, below.
  });

  it("divides without losing a run to the quotient, which rounding the numerator does not fix", () => {
    // **Three catalogues, three exact answers, from PR #182's review F1.** Each is a plausible
    // release-time value for "what is one run worth" and each is a divisor the unrounded quotient
    // gets wrong on an exact multiple. The published `credits` block is asserted beside the run
    // count in every row, because the guarantee is that the two agree — a founder recomputing
    // `remaining / per_run` by hand must reach the number the response already shows them.
    const at = new Date("2026-08-15T12:00:00Z");
    const weights = { perSession: 0.1, perIteration: 0.1, perMegapixel: 0 };

    // 0.5 - 0.2 = 0.3, and 0.3 / 0.1 is 2.9999999999999996 unrounded.
    const one = creditBalance({
      catalogue: catalogueOf({ runCredits: 0.1, monthlyCredits: [0.5], weights }),
      planKey: undefined,
      draw: drawOf({ sessions: 1, iterations: 1 }),
      toppedUpCredits: 0,
      now: at,
    });
    expect(one.credits).toEqual({
      allowance: 0.5,
      drawn: 0.2,
      remaining: 0.3,
      perRun: 0.1,
      toppedUp: 0,
    });
    expect(one.runsLeft).toBe(3);

    // **The row worth looking at twice: nothing has been drawn at all.** 7 / 0.07 is
    // 99.99999999999999, so a tier that includes 100 runs advertised 99 before the user had done
    // anything — and `runsIncluded` is the denominator of "3 of 20 left".
    const untouched = creditBalance({
      catalogue: catalogueOf({ runCredits: 0.07, monthlyCredits: [7], weights }),
      planKey: undefined,
      draw: drawOf({}),
      toppedUpCredits: 0,
      now: at,
    });
    expect(untouched.credits).toEqual({
      allowance: 7,
      drawn: 0,
      remaining: 7,
      perRun: 0.07,
      toppedUp: 0,
    });
    expect(untouched.runsLeft).toBe(100);
    expect(untouched.runsIncluded).toBe(100);

    // And rounding the quotient must not round a real remainder UP into a run nobody has: 2.5 and a
    // genuine 2.999999 both floor to 2, so this corrects float noise and nothing else.
    const half = catalogueOf({ runCredits: 0.2, monthlyCredits: [0.5], weights });
    expect(creditBalance({
      catalogue: half,
      planKey: undefined,
      draw: drawOf({}),
      toppedUpCredits: 0,
      now: at,
    }).runsLeft)
      .toBe(2);

    // **The other half of that sentence, which nothing held until PR #182's cycle 3** (its R2). A
    // mutant loosening the rounding from six places to three turned a genuine `2.999999` into `3` —
    // the exact over-grant the sentence promises against — and the whole suite passed. `2.5` was
    // covered and `2.999999` was not, which is the direction that costs revenue rather than the one
    // that costs a user a run.
    //
    // **`runCredits: 1` is load-bearing and the obvious fixture does not work.** A catalogue of
    // `runCredits: 0.1` with `monthlyCredits: [0.2999999]` rounds the *allowance* to `0.3` before
    // the division ever happens, which lands back on the float-noise case the first assertion in
    // this test already covers. The genuine sub-integer remainder has to sit where rounding cannot
    // reach it.
    const genuineRemainder = catalogueOf({
      runCredits: 1,
      monthlyCredits: [2.999999],
      weights: { perSession: 0, perIteration: 0, perMegapixel: 0 },
    });
    const untouchedRemainder = creditBalance({
      catalogue: genuineRemainder,
      planKey: undefined,
      draw: drawOf({}),
      toppedUpCredits: 0,
      now: at,
    });
    expect(untouchedRemainder.credits.remaining).toBe(2.999999);
    expect(untouchedRemainder.runsLeft).toBe(2);
    expect(untouchedRemainder.runsIncluded).toBe(2);
  });

  it("reports the calendar month the server is in, as an instant pair", () => {
    const balance = creditBalance({
      catalogue: catalogue(),
      planKey: undefined,
      draw: drawOf({}),
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

class UnusedAuthProvider implements AuthProvider {
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

/**
 * A `KeyStore` that grants every claim and remembers nothing.
 *
 * The smallest thing that lets a request through the idempotency hook. This suite asserts nothing
 * about §9.2 — `idempotency.test.ts` owns that — and a store modelling replay here would be a second
 * model of a mechanism this file is not testing.
 */
function alwaysClaims(): KeyStore {
  return {
    claim: () => Promise.resolve({ kind: "claimed", token: randomUUID() } as ClaimOutcome),
    complete: () => Promise.resolve(),
    release: () => Promise.resolve(),
  };
}

describe("what a cancelled iteration leaves behind (PR #182's review, F2)", () => {
  /**
   * **The premise the credit filter rests on, proved against the real app rather than assumed.**
   *
   * `credit/store.ts` prices an iteration when `upstream_duration_ms IS NOT NULL` **or** the outcome
   * is `client_cancelled`, and the second half of that is only defensible if rows of that shape
   * actually occur. They do, and this is why: `meteredUpstreamCall` sets `upstreamAttempted` before
   * the provider call and writes the duration in a `finally` afterwards, while the metering event
   * has a *second* writer — the response's `close` listener — which fires when the caller
   * disconnects **while the handler is still awaiting the provider**. At that instant the `finally`
   * has not run.
   *
   * **A real socket, because `inject` has none**, and the construction is `metering.test.ts`'s own:
   * nothing sleeps, every step waits on a signal the other side publishes, and the provider is still
   * held when the event is read so that the `close` listener is the only thing that can have written
   * it. Releasing first would let the two writers race and this would pass or fail on which won.
   */
  itUnderHangBackstop(
    "a cancelled screen-control iteration really does write a row of this shape",
    async () => {
      let reachedProvider!: () => void;
      const providerReached = new Promise<void>((resolve) => {
        reachedProvider = resolve;
      });
      let letProviderAnswer!: () => void;
      const providerMayAnswer = new Promise<void>((resolve) => {
        letProviderAnswer = resolve;
      });

      // Kept before the stub replaces the global: the client request below is a real `fetch`, and a
      // stubbed one would call the provider stub instead of the server.
      const realFetch = globalThis.fetch;
      let upstreamCalls = 0;
      vi.stubGlobal("fetch", async () => {
        upstreamCalls += 1;
        reachedProvider();
        await providerMayAnswer;
        return new Response(JSON.stringify({ output_text: '{"action":"done"}' }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      });

      let eventWritten!: (event: MeteringEvent) => void;
      const written = new Promise<MeteringEvent>((resolve) => {
        eventWritten = resolve;
      });
      const events: MeteringEvent[] = [];
      const meteringStore: MeteringStore = {
        async write(event) {
          events.push(event);
          eventWritten(event);
          return "written";
        },
      };

      // The spend cap's own answer, recorded beside the event's: the point of the finding is that
      // the two disagreed, so both are read in one test rather than argued about across two.
      const entitlement = fakeEntitlementStore();
      const settled: boolean[] = [];
      const recordingEntitlement = {
        ...entitlement,
        settle: async (reservationId: string, charge: boolean) => {
          settled.push(charge);
          return entitlement.settle(reservationId, charge);
        },
      };

      const app = buildApp(
        testConfig({ credentials: [{ provider: "vision", keys: ["vk-test-vision-key"] }] }),
        { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
        { idempotencyStore: alwaysClaims(), meteringStore, entitlementStore: recordingEntitlement },
      );
      await app.listen({ port: 0, host: "127.0.0.1" });
      const address = app.server.address();
      if (address === null || typeof address === "string") throw new Error("no port to call");

      const controller = new AbortController();
      const inflight = realFetch(`http://127.0.0.1:${address.port}/v1/screen/analyze`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}`,
          "content-type": "application/json",
          "idempotency-key": randomUUID(),
        },
        body: JSON.stringify({
          task_id: "task-1",
          session_id: "session-cancelled",
          session_iteration: 1,
          retention: "standard",
          prompt: "Decide the next action.",
          image: {
            media_type: "image/jpeg",
            encoding: "base64",
            data: Buffer.alloc(9, 0x41).toString("base64"),
            pixel_width: 1000,
            pixel_height: 1000,
          },
        }),
        signal: controller.signal,
      }).catch(() => undefined);

      await providerReached;
      // The user presses Stop. The vision call is open and is still being held.
      controller.abort();
      const event = await written;

      // The provider was reached, so the vendor has been paid for this iteration.
      expect(upstreamCalls).toBe(1);
      expect(event.route).toBe("screen.analyze");
      expect(event.sessionId).toBe("session-cancelled");
      expect(event.outcome).toBe("client_cancelled");
      // **The finding.** The `finally` has not run, so the column the draw used to rely on is null.
      expect(event.upstreamDurationMs).toBeNull();

      letProviderAnswer();
      await inflight;
      expect(events).toHaveLength(1);
      // And the spend cap charged it, which is §12's rule and is what made the disagreement matter:
      // the same iteration was billed by one mechanism and given away by the other.
      expect(settled).toContain(true);
      await app.close();
      vi.unstubAllGlobals();

      // The two now agree: a row of exactly this shape draws.
      expect(
        creditsForDraw(
          { perSession: 10, perIteration: 5, perMegapixel: 1 },
          { sessions: 1, iterations: 1, pixels: 1_000_000 },
        ),
      ).toBe(16);
    },
  );
});

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
    // The fixture catalogue: one run is ten credits, tier A includes a thousand of them, one credit
    // per iteration. Thirty iterations drawn leaves 970 credits, which is 97 runs.
    const store = fakeCreditStore({
      planKey: "test-plan-a",
      draw: { sessions: 3, iterations: 30, pixels: 0 },
    });
    const app = build(store);
    const response = await app.inject({
      method: "GET",
      url: "/v1/account/credits",
      headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    const body = response.json() as Record<string, unknown>;
    expect(body.screen_control_runs_left).toBe(97);
    expect(body.screen_control_runs_included).toBe(100);
    expect(body.plan).toBe("test-plan-a");
    expect(body.period_start).toBe("2026-08-01T00:00:00.000Z");
    expect(body.period_end).toBe("2026-09-01T00:00:00.000Z");
    expect(body.credits).toEqual({
      allowance: 1000,
      drawn: 30,
      remaining: 970,
      per_run: 10,
      topped_up: 0,
    });

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
    // "The free tier gets a small monthly screen-control allowance (not a hard wall)": an account
    // nothing has provisioned is a free user, and it reads a real number rather than a refusal.
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
    expect(body.screen_control_runs_left).toBe(100);
  });
});
