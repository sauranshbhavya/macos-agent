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
 *
 * **And the same missing snapshot runs backwards.** The metering rows are permanent, so a past
 * period's *draw* is fully reconstructable; the catalogue in force at that moment is not, because the
 * weights, `runCredits` and every plan's allowance live in `CREDIT_PLANS`, an environment variable.
 * So after a weight change nobody can answer "how many runs did this account have on the 14th?" from
 * the database — which is precisely the property `usage_period.cap_units` has and this does not: the
 * cap in force is recoverable from a row, the price in force is not. **That is a second reason to
 * prefer the first of the three options SONNY-213 was given** — pinning the weights for a period —
 * rather than a separate constraint: forward drift and backward unreconstructability are the same
 * missing snapshot seen from two ends, and one option closes both. (PR #182's cycle 3, which also
 * withdrew the stronger version of this: a top-up is a payment-provider charge with its own amount
 * and record, so what would be missing there is the justification for the trigger, not the charge.)
 *
 * ## A top-up is a grant, and it is not the ledger this file refuses (SONNY-215)
 *
 * `toppedUpCredits` below is a sum of `sonny.credit_topup` rows and it is the one input here that is
 * not derived from metering. That is not the second writer the section above rejects: what a ledger
 * would duplicate is the **draw**, which stays exactly what the metering rows say, and a top-up is a
 * *grant* — money that moved at the payment provider — which no metering row could carry and nothing
 * else records. It raises the allowance, so `runsIncluded` moves with it and a user who bought a
 * pack reads "3 of 30 left" rather than watching an extra ten arrive from nowhere.
 *
 * **A top-up is spent against the period it was bought in and does not carry over, and that is a
 * consequence of having no ledger rather than a preference.** Carrying credits forward means
 * tracking which credits a later period's draw consumed — the plan's, which reset, or the bought
 * ones, which do not — and that distinction cannot be derived from a metering row, so it would need
 * exactly the ledger this file exists without. What bounds the cost is when a top-up is bought: the
 * only thing that triggers one is a user hitting their limit mid-task, so a pack is bought to be
 * spent immediately rather than banked. The residual case — a top-up bought in the last hours of a
 * period — is real, is a founder call if it ever needs to change, and is recorded rather than
 * papered over.
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
 *
 * **Rounding the figures is only half of that guarantee, and this comment used to claim the whole
 * of it** (PR #182's review, F1). The quotient is a floating-point operation of its own and the last
 * one before the floor, so a perfectly rounded remainder still divides wrong: the response said
 * `remaining 0.3`, `per_run 0.1`, `runs_left 2`, and a reader doing exactly what `credits` is on the
 * wire for computed 3. `runsFrom` below is the other half; neither is sufficient alone.
 */
export const CREDIT_PRECISION = 6;

function round(credits: number): number {
  const scale = 10 ** CREDIT_PRECISION;
  return Math.round(credits * scale) / scale;
}

/**
 * How many whole runs a credit figure is worth.
 *
 * **The division is rounded before the floor, and that is the whole of this function.** Rounding
 * `allowance`, `drawn` and `remaining` does nothing about the quotient, which is the *last* floating
 * point operation before the floor that produces the number a user reads — so a rounded numerator
 * still floors wrong. `7 / 0.07` is `99.99999999999999` and floors to **99** on a plan that includes
 * 100; `0.3 / 0.1` is `2.9999999999999996` and floors to **2** where a reader recomputing by hand
 * gets 3. The second case is worse than it looks: `runsIncluded` is derived the same way, so a tier
 * advertised **99** with nothing drawn — before the user has done anything at all.
 *
 * Rounding first at the same six places the figures beside it use turns `2.9999999999999996` into
 * `3` and leaves a genuine `2.999999` at 2 and a `2.5` at 2, so it corrects float noise without
 * rounding a real remainder up into a run the user has not got.
 *
 * (PR #182's review, F1. The defect was the same IEEE-754 shape this file's own `round` was added
 * for, one line below where it was fixed — and the test that claimed to hold it asserted
 * `runsLeft === Math.floor(remaining / perRun)`, which is the implementation restated and therefore
 * true under the defect by construction. That is the identical circularity SONNY-212's own mutation
 * battery caught in the arm above it at `4c7d6b0`; a value assertion is what replaced both.)
 */
function runsFrom(credits: number, perRun: number): number {
  return Math.floor(round(credits / perRun));
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
    /** The plan's own credits **plus** whatever this period's top-ups granted. */
    readonly allowance: number;
    readonly drawn: number;
    readonly remaining: number;
    readonly perRun: number;
    /**
     * What top-ups added to this period, and **the one figure here that is not derived from
     * metering** (SONNY-215).
     *
     * It is carried separately from `allowance` rather than folded silently into it because the two
     * answer different questions: `allowance` is what this account may spend, and this is how much
     * of it was bought after the fact. A founder sanity-checking a run count against a measured cost
     * needs to be able to subtract it.
     */
    readonly toppedUp: number;
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
  /**
   * What this period's granted top-ups added, in credits (SONNY-215). `0` for every account that
   * has bought none, which is every account by default.
   */
  readonly toppedUpCredits: number;
  readonly now: Date;
}): CreditBalance {
  const plan = planFor(input.catalogue, input.planKey);
  const perRun = input.catalogue.runCredits;
  // **A top-up raises the allowance rather than lowering the draw**, and the difference is visible
  // in `runsIncluded`: an account that bought a pack now reads "3 of 30 left" rather than "3 of 20
  // left" with an extra ten arriving from nowhere. The draw stays exactly what metering measured,
  // which is `balance.ts`'s whole design — the audit row is the charge, and this is a grant.
  const toppedUp = round(Math.max(0, input.toppedUpCredits));
  const allowance = round(plan.monthlyCredits + toppedUp);
  const drawn = creditsForDraw(input.catalogue.weights, input.draw);
  const remaining = round(Math.max(0, allowance - drawn));
  return {
    plan: plan.key,
    periodStart: periodStart(input.now),
    periodEnd: periodEnd(input.now),
    runsLeft: runsFrom(remaining, perRun),
    runsIncluded: runsFrom(allowance, perRun),
    credits: { allowance, drawn, remaining, perRun, toppedUp },
  };
}
