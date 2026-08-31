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
}): {
  factsFor: (accountId: string, now: Date) => Promise<CreditFacts>;
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
  return {
    asked,
    askedAbout,
    factsFor: (accountId, now) => {
      asked.push(now);
      askedAbout.push(accountId);
      return Promise.resolve({
        planKey: facts.planKey,
        draw: facts.draw ?? { sessions: 0, iterations: 0, pixels: 0 },
      });
    },
  };
}
