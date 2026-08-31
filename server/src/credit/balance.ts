import { periodStart } from "../entitlement/period.js";
import { planFor, type CreditCatalogue, type CreditWeights } from "./catalogue.js";

/**
 * From what row 12 measured to the one number a user tracks — **"screen-control runs left this
 * month"** (SONNY-212).
 *
 * Everything here is pure. The reading of the metering table is `store.ts`'s, the numbers are
 * `catalogue.ts`'s, and this is the arithmetic between them, so the derivation can be driven with no
 * database and no configuration file.
 *
 * ## Derived, never ledgered — the shape three later tickets inherit
 *
 * There is **no credit ledger table**, and that is the central design choice of this ticket rather
 * than an omission. The draw is a query over `sonny.metering_event`, which row 12 already writes on
 * every served call and which nothing in this gateway ever deletes or ages (§10.3's long clock). A
 * ledger would be a second writer of the same fact, and this repository has now twice written down
 * what that costs: 0012's own header refuses a unique constraint beside `claimMeteringEvent` because
 * "two things that both believe they enforce 'at most once' is how it ends up enforced by neither",
 * and `metering/hook.ts`'s placement argument turns entirely on a charge never existing without the
 * audit row that justifies it. Deriving makes that structural — the audit row *is* the charge — and
 * it means no reconciliation, no drift, and no backfill for the sessions already on disk when the
 * first real weights land.
 *
 * **What deriving costs, stated because a later ticket will meet it.** The weights are applied at
 * read time, so changing them re-prices the period already under way: a user's "runs left" moves
 * when the founders deploy a new number. That is the opposite of the call `usage_period.cap_units`
 * makes, where the cap is *copied* into the period so a mid-period change cannot retroactively
 * re-decide refusals already issued — and the difference between the two is which way the mistake
 * hurts. A refusal already issued is a thing that happened to a user, and re-deciding it makes a
 * record false. "Runs left" is a forward-looking estimate that has never been promised to anybody:
 * re-pricing it is visible, bounded by how often the founders re-price at all, and strictly better
 * than the alternative, which is a period whose old sessions are priced at numbers no longer in
 * force. **The one thing that must not follow from this file** is a *refusal* derived the same way
 * without snapshotting — that is SONNY-213's decision to make, and it should make it deliberately.
 */

/**
 * What an account's screen-control sessions consumed in one period, as the metering table answers
 * it. `store.ts` produces this; nothing here knows how.
 */
export interface ScreenControlDraw {
  /** Distinct sessions that drew anything at all. */
  readonly sessions: number;
  /** Iterations that reached a provider. See `store.ts` for why unreached ones are excluded. */
  readonly iterations: number;
  /** Pixels sent, summed across those iterations. */
  readonly pixels: number;
}

/** A draw of nothing — a period with no screen control in it. */
export const NO_DRAW: ScreenControlDraw = { sessions: 0, iterations: 0, pixels: 0 };

/**
 * How many decimal places a credit figure is reported to: **six**.
 *
 * **A readability measure that is load-bearing for one property.** Credits are floating point, and a
 * weight of `0.1` per megapixel against 30 megapixels leaves a value like `2.9999999999999996`.
 * Every figure this module publishes is rounded here, and `runsLeft` is then derived from the
 * *rounded* remainder — so the numbers in a response are mutually consistent and a reader can
 * recompute the run count from the credits beside it. Deriving from the unrounded value and
 * publishing the rounded one would produce a response that contradicts its own arithmetic at the
 * boundary, which is exactly where somebody checking it would look.
 */
export const CREDIT_PRECISION = 6;

function round(credits: number): number {
  const scale = 10 ** CREDIT_PRECISION;
  return Math.round(credits * scale) / scale;
}

/**
 * What one period's screen-control draw costs in credits.
 *
 * **Pixels are divided by a million rather than the weight being per-pixel**, because the number an
 * operator has to write down is then in the units the metering command already prints
 * (`npm run usage`'s `megapixels` column), and a per-pixel rate is a figure with seven leading zeros
 * that nobody can check by eye.
 */
export function creditsForDraw(weights: CreditWeights, draw: ScreenControlDraw): number {
  return round(
    weights.perSession * draw.sessions +
      weights.perIteration * draw.iterations +
      weights.perMegapixel * (draw.pixels / 1_000_000),
  );
}

/** The exclusive end of the period `at` falls in — the start of the next one. */
export function periodEnd(at: Date): Date {
  const start = periodStart(at);
  // `Date.UTC` normalises month 12 into January of the next year, so December needs no special case.
  return new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1));
}

/** The whole answer for one account in one period. */
export interface CreditBalance {
  /** The plan actually applied — the account's, or the catalogue's default. See `planFor`. */
  readonly plan: string;
  readonly periodStart: Date;
  readonly periodEnd: Date;
  /** **The number the user tracks.** Never negative. */
  readonly runsLeft: number;
  /** What a full period on this plan is worth, in runs. The denominator of "3 of 20 left". */
  readonly runsIncluded: number;
  /** The derivation, so a founder can sanity-check the runs figure against the measured cost. */
  readonly credits: {
    readonly allowance: number;
    readonly drawn: number;
    readonly remaining: number;
    readonly perRun: number;
  };
}

/**
 * Runs left, from an account's plan and what it drew.
 *
 * **`remaining` floors at zero and `runsLeft` follows it**, so an account that has drawn past its
 * allowance reads as `0 left` rather than as a negative number. Drawing past the allowance is
 * reachable today and will stay reachable: nothing in this ticket refuses a request — the gate is
 * SONNY-213's — and even once it does, a session already in flight when the allowance runs out
 * finishes and is metered. A number that can go negative would be a number the UI has to special-case
 * and a user has to interpret.
 */
export function creditBalance(input: {
  readonly catalogue: CreditCatalogue;
  readonly planKey: string | undefined;
  readonly draw: ScreenControlDraw;
  readonly now: Date;
}): CreditBalance {
  const plan = planFor(input.catalogue, input.planKey);
  const perRun = input.catalogue.runCredits;
  const allowance = round(plan.monthlyCredits);
  const drawn = creditsForDraw(input.catalogue.weights, input.draw);
  const remaining = round(Math.max(0, allowance - drawn));
  return {
    plan: plan.key,
    periodStart: periodStart(input.now),
    periodEnd: periodEnd(input.now),
    runsLeft: Math.floor(remaining / perRun),
    runsIncluded: Math.floor(allowance / perRun),
    credits: { allowance, drawn, remaining, perRun },
  };
}
