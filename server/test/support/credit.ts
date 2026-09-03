import { randomUUID } from "node:crypto";
import type { CreditCatalogue } from "../../src/credit/catalogue.js";
import type { CreditFacts } from "../../src/credit/store.js";

/**
 * Credit catalogues for tests (SONNY-212).
 *
 * **Every plan key a test uses is a fresh UUID, and that is the proof rather than a habit.** The
 * ticket's acceptance criterion is that "the tier count and numbers are not baked into code". A
 * suite that asserted the module handles `"free"` and `"pro"` would pass just as happily against an
 * implementation with those two words written into it, so nothing here spells a plan key at all: a
 * catalogue built by `catalogueOf` names tiers no source file could contain, and the assertions are
 * about keys generated microseconds earlier.
 */

/** A catalogue with one tier per allowance given, keyed by values nothing could have hard-coded. */
export function catalogueOf(input: {
  readonly runCredits: number;
  readonly monthlyCredits: readonly number[];
  readonly weights?: CreditCatalogue["weights"];
  /**
   * Which tier is the default. **Defaults to the first, and that default was a hole**
   * (PR #182's review, F3): every catalogue in the suite had `defaultPlan === plans[0]`, so
   * "returns the plan `defaultPlan` names" and "returns whatever is listed first" were the same
   * behaviour everywhere and no test could tell them apart — a mutant returning `plans[0]` survived
   * the whole suite. It is not academic: the two stop coinciding on a real deployment the moment an
   * operator lists the paid tier first, and an unknown plan key then falls to *it*, which is the
   * "unbounded bill nobody sees" `catalogue.ts` argues against. A test about the fallback passes a
   * non-zero index.
   */
  readonly defaultIndex?: number;
}): CreditCatalogue {
  const plans = input.monthlyCredits.map((monthlyCredits) => ({
    key: `plan-${randomUUID()}`,
    monthlyCredits,
  }));
  const defaultIndex = input.defaultIndex ?? 0;
  const fallback = plans[defaultIndex];
  if (fallback === undefined) {
    // Loudly, rather than silently building a catalogue whose `defaultPlan` names nothing: that is a
    // fixture bug that would surface as `parseCreditCatalogue` refusing, several layers from here.
    throw new Error(
      `catalogueOf: defaultIndex ${defaultIndex} names no tier among ${plans.length}`,
    );
  }
  return {
    runCredits: input.runCredits,
    defaultPlan: fallback.key,
    weights: input.weights ?? { perSession: 0, perIteration: 1, perMegapixel: 0 },
    plans,
  };
}

/**
 * The catalogue `testConfig` carries, as the JSON string `CREDIT_PLANS` holds.
 *
 * **Fixture numbers and not allowances**, exactly as `spendCapUnits` in the same file is a fixture
 * ceiling and not a plan's: `config.ts` carries the distinction and SONNY-212 owns the real ones,
 * which live outside this repository. The values are round so that a test reading a response can
 * check the arithmetic by eye — one run is ten credits, a tier includes a hundred runs.
 */
export const TEST_CREDIT_PLANS = JSON.stringify({
  runCredits: 10,
  defaultPlan: "test-plan-a",
  weights: { perSession: 0, perIteration: 1, perMegapixel: 0 },
  plans: [
    { key: "test-plan-a", monthlyCredits: 1000 },
    { key: "test-plan-b", monthlyCredits: 5000 },
  ],
});

/**
 * The same catalogue with a top-up pack on it (SONNY-215).
 *
 * **Separate from `TEST_CREDIT_PLANS` rather than added to it**, because a deployment that sells no
 * pack is the default this repository ships and every suite that says nothing about top-ups should
 * get one — `offered: false`, and a charge route that refuses. A fixture where every app could
 * charge would make "this deployment sells none" a case nothing exercised.
 *
 * One pack is 500 credits — 50 runs at this catalogue's ten per run, half a tier-A month — and three
 * attempts a period, so a test about the bound has two failures to make before it reaches it.
 */
export const TEST_CREDIT_PLANS_WITH_TOP_UP = JSON.stringify({
  ...(JSON.parse(TEST_CREDIT_PLANS) as Record<string, unknown>),
  topUp: { credits: 500, productId: "test-product-topup", maxPerPeriod: 3 },
});

/**
 * An in-memory `CreditStore`.
 *
 * **It is not a model of the draw and must never become one.** It returns whatever a test told it
 * to; it reads no events, knows nothing about routes and does no arithmetic — the arithmetic is
 * `balance.ts`'s and is tested directly, and *which rows count* is the one thing a fake cannot say
 * anything about, so `credit.db.test.ts` proves it against a real Postgres. A fake that appeared to
 * exclude the unpaid routes is how a suite comes to believe it has tested an exclusion.
 */
export function fakeCreditStore(facts: {
  planKey?: string | undefined;
  draw?: { sessions: number; iterations: number; pixels: number };
  /** What this period's granted top-ups added (SONNY-215). */
  toppedUpCredits?: number;
  /** How many attempts this period has already carried, granted or not. */
  topUpAttemptsThisPeriod?: number;
  /**
   * When this account opted in, or `null` (SONNY-215). **`null` is the default and it is the
   * fixture half of "off by default"**: a suite whose fake consented by omission could never
   * notice a route that stopped checking.
   */
  autoTopUpOptedInAt?: Date | null;
}): {
  factsFor: (accountId: string, now: Date) => Promise<CreditFacts>;
  setAutoTopUp: (accountId: string, enabled: boolean, now: Date) => Promise<Date | null>;
  /** Every `setAutoTopUp` this store was asked to make, in order. */
  settings: { accountId: string; enabled: boolean }[];
  asked: Date[];
  /**
   * Every account id the store was asked about, in order.
   *
   * **This exists because nothing held that the route reads the *caller's* account**
   * (PR #182's review, F6): replacing `caller.accountId` with a fixed UUID in `routes/credits.ts`
   * passed the entire suite. The argument was ignored here (`_accountId`) and the route test
   * asserted only that an unauthenticated request gets a 401, so the second half of its own name —
   * "and nobody else's" — was unchecked. A route that serves one account's balance to another is the
   * whole of what that name promises, and `gate.test.ts`'s own comment on this route says why.
   */
  askedAbout: string[];
} {
  const asked: Date[] = [];
  const askedAbout: string[] = [];
  const settings: { accountId: string; enabled: boolean }[] = [];
  let optedInAt = facts.autoTopUpOptedInAt ?? null;
  return {
    asked,
    askedAbout,
    settings,
    factsFor: (accountId, now) => {
      asked.push(now);
      askedAbout.push(accountId);
      return Promise.resolve({
        planKey: facts.planKey,
        draw: facts.draw ?? { sessions: 0, iterations: 0, pixels: 0 },
        toppedUpCredits: facts.toppedUpCredits ?? 0,
        topUpAttemptsThisPeriod: facts.topUpAttemptsThisPeriod ?? 0,
        autoTopUpOptedInAt: optedInAt,
      });
    },
    setAutoTopUp: (accountId, enabled, now) => {
      settings.push({ accountId, enabled });
      // The real store's rule, kept here because a test that reads the setting back after writing
      // it is reading this: on does not refresh an instant that is already set, off clears it.
      optedInAt = enabled ? (optedInAt ?? now) : null;
      return Promise.resolve(optedInAt);
    },
  };
}
