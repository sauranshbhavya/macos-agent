import { z } from "zod";

/**
 * The plan catalogue and the cost weights — **every number this repository bills against, in one
 * configuration value and nowhere else** (SONNY-212).
 *
 * ## What this file is, and the one thing it deliberately is not
 *
 * SONNY-17 fixed the *shape* of row 13's pricing on 2026-08-16 and left every *number* unset: they
 * wait on a measured per-session screen-control cost. Twelve files across `server/src` say so in
 * prose — `entitlement/store.ts`'s `unitsForMeteredCall`, `0013`'s column comments, `config.ts`'s
 * `SPEND_CAP_UNITS` and `BILLING_PLANS`, `metering/query.ts`'s header — each of them promising that
 * the price lands here. This is that landing, and the promise is kept by **holding the mechanism and
 * none of the numbers**: there is no default catalogue in this repository, no plan key written as a
 * literal, no allowance, no weight, and no tier count. A deployment supplies all of it as
 * `CREDIT_PLANS`, and `requireCreditCatalogue` refuses to start without it.
 *
 * **That refusal is the same call `SPEND_CAP_UNITS` makes and it is made for the same reason.** An
 * absent catalogue has no safe reading: treating it as "no allowance" locks every user out of the
 * one paid feature, and treating it as "unlimited" is SONNY-16's leaked-token cost with a mechanism
 * in front of it doing nothing. Neither is a default worth having, so there is none.
 *
 * ## Why the tier count is data rather than two branches
 *
 * The product decision today is free plus exactly one paid tier (founder, 2026-08-16, ratified
 * 2026-08-21; contract §14's table). The ticket's acceptance criterion is nonetheless that "the tier
 * count and numbers are not baked into code", and the two are not in tension: a decision that is
 * true today is exactly the kind of thing that becomes a release-time input, and a catalogue built
 * around `free`/`paid` fields would make the third tier a code change in every file that reads one.
 * So `plans` is a list of any length, keyed by opaque strings this repository never spells.
 * `theCatalogueCarriesWhateverTierCountItIsGiven` drives one, two and seven tiers through the same
 * parse, and every plan key in that test is a value no source file could contain.
 *
 * ## What a credit is, and what a "run" is
 *
 * A **credit** is an abstract unit of screen-control cost. A **run** is the user-facing unit — the
 * single number SONNY-17 says a user tracks, "screen-control runs left this month" — and it is
 * `runCredits` credits. The two are separate release-time inputs on purpose: the weights price a
 * *real* session out of what it actually consumed, and `runCredits` prices the *nominal* session the
 * display divides by. A twelve-iteration session therefore costs more runs than a three-iteration
 * one, which is what "weighted by real cost" means and is the whole reason the pool is denominated
 * in credits rather than counting sessions.
 *
 * **What that costs the user-facing number, stated rather than left to be discovered:** "runs left"
 * does not fall by exactly one per run. A heavy session takes more than one and a session refused
 * before any provider call takes none. The alternative — one session, one run — is a count instead
 * of an estimate and reads more honestly, and it was declined because it leaves the founders' cost
 * per run varying by the full twelve-to-one range a session's iteration count spans, which is the
 * exposure this ticket exists to bound.
 */

/**
 * How a screen-control session's credits are computed from what row 12 measured.
 *
 * **Three components, and the set is chosen by what the metering table can honestly answer for this
 * route rather than by what would be tidy.** `screen.analyze` reports **no tokens**: `model/vision.ts`
 * sends no estimate, because the dominant term is an image whose cost is a function of pixel
 * dimensions and a provider's tiling rule, and `metering/query.ts` carries `iterationsWithoutTokens`
 * precisely so a caller cannot read that absence as a measurement of zero. A token component here
 * would therefore be a coefficient multiplied by a number that is almost always missing — which is
 * the mistake that file spends a paragraph warning against, made in the file that consumes it.
 *
 * Every component is a rate a deployment sets, and any of them may be zero.
 *
 * ## Two of these three are priced on numbers the client declares
 *
 * Stated because it is a new consequence of this ticket and it was named nowhere
 * (PR #182's review, F7). Under row 12 these fields were diagnostics, where a client lying corrupts
 * only its own `npm run usage` output; pricing on them turns them into money.
 *
 * - **`perMegapixel` is self-reported.** `routes/screen.ts` validates `pixel_width` and
 *   `pixel_height` as positive integers and never compares them against the image it decoded, so a
 *   modified client can declare `1 x 1` while sending a full-resolution capture the vendor bills for.
 * - **`perSession` is self-reported.** `session_id` is client-minted by design (§4.5 rule 5 — the
 *   gateway holds no session state), and the draw counts `count(DISTINCT session_id)`, so a client
 *   reusing one id for a whole month pays this weight once instead of once per session.
 * - **`perIteration` is the honest one.** It counts rows the metering hook writes whether the caller
 *   likes it or not, so nothing a client sends can deflate it.
 *
 * **The founders' exposure is still bounded, and by the spend cap rather than by anything here.**
 * That was checked rather than assumed: the cap counts *calls*, is deliberately unweighted, and
 * applies to every metered route — which is exactly why SONNY-212 declined `unitsForMeteredCall`'s
 * invitation to weight it. So a client that deflates every declaration it can still makes one
 * metered call per iteration, each charged one unit, each bounded in turn by §6.1's body limit and
 * §12's deadlines. Total exposure per account per period is `SPEND_CAP_UNITS` maximum-size calls,
 * whatever the weights say.
 *
 * **What is not bounded is the revenue, and the gap is the distance between two very different
 * numbers.** `SPEND_CAP_UNITS` is an anti-abuse ceiling chosen so no legitimate user ever reaches
 * it, so it necessarily sits far above any plan's allowance — a client that under-declares buys
 * extra runs anywhere in between. Today that buys nothing at all, because nothing refuses on this
 * number; **it becomes real at SONNY-213**, which is where the decision belongs.
 *
 * **A deployment that wants a non-gameable allowance already has one, with no code change:** set
 * `perSession` and `perMegapixel` to zero and price entirely on `perIteration`. That is what the
 * weights being configuration buys, and it is the cheapest answer available before anything refuses.
 * Bounding `pixels` by the decoded byte length the route already computes is the other answer and is
 * a bigger call than this file should take.
 */
const weightsSchema = z.object({
  /** Credits charged once per session that drew anything at all — the fixed cost of starting one. */
  perSession: z.number().nonnegative(),
  /** Credits per charged iteration. A session is up to twelve (`VisionSessionLimits.default`). */
  perIteration: z.number().nonnegative(),
  /** Credits per megapixel sent. What vision cost actually tracks — contract §4.5 rule 3. */
  perMegapixel: z.number().nonnegative(),
});

/** One tier. An opaque key and what a month of it includes. */
const planSchema = z.object({
  /**
   * The value `sonny.entitlement.plan` holds — the same opaque key `BILLING_PLANS` maps a provider
   * product onto. **Not a tier name chosen here**: 0013 has said since it was written that
   * SONNY-212 owns the real keys, and owning them means naming them in configuration, not in source.
   */
  key: z.string().trim().min(1),
  /** Credits this plan includes per period. `0` is a real answer: a tier that includes no runs. */
  monthlyCredits: z.number().nonnegative(),
});

const catalogueSchema = z.object({
  /**
   * What one screen-control run is worth, in credits. **Strictly positive**, because it is a
   * divisor: a zero here would make "runs left" either infinite or undefined depending on the
   * rounding, and neither is a number to show somebody.
   */
  runCredits: z.number().positive(),
  /**
   * The plan an account falls to when its entitlement names none, or names one this catalogue does
   * not — the free tier, in the shape the founders decided.
   *
   * **Both of those are fail-closed to the *smallest* thing a user can be, and the second is the one
   * that matters.** An entitlement row carrying `'none'` is an unprovisioned account and is a free
   * user in practice. An entitlement carrying a key this catalogue has never heard of is a
   * *misconfiguration* — a `BILLING_PLANS` entry pointing at a plan nobody added here — and the two
   * directions are not symmetric: falling to the default costs a paying customer the difference
   * between their tier and free, loudly, in a number they can see and complain about, while falling
   * to anything generous is an unbounded bill nobody sees until it arrives.
   */
  defaultPlan: z.string().trim().min(1),
  weights: weightsSchema,
  /** Every tier, in the order a deployment listed them. At least one; no upper bound. */
  plans: z.array(planSchema).min(1),
});

export type CreditWeights = z.infer<typeof weightsSchema>;
export type CreditPlan = z.infer<typeof planSchema>;
export type CreditCatalogue = z.infer<typeof catalogueSchema>;

/** A catalogue that could not be read, named for the operator who has to fix it. */
export class CreditCatalogueError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CreditCatalogueError";
  }
}

/**
 * Parse `CREDIT_PLANS`, or throw with something an operator can act on.
 *
 * **Two checks live here rather than in the schema, because both are about the whole document.**
 * Duplicate keys would make `planFor` depend on list order, which is not a thing a deployment should
 * be able to express by accident; and a `defaultPlan` naming no listed plan is a typo whose only
 * symptom would otherwise be every unprovisioned user silently receiving nothing.
 */
export function parseCreditCatalogue(raw: string): CreditCatalogue {
  let document: unknown;
  try {
    document = JSON.parse(raw);
  } catch (error) {
    throw new CreditCatalogueError(
      `CREDIT_PLANS is not valid JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  const parsed = catalogueSchema.safeParse(document);
  if (!parsed.success) {
    const detail = parsed.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("; ");
    throw new CreditCatalogueError(`CREDIT_PLANS is not a valid credit catalogue: ${detail}`);
  }
  const catalogue = parsed.data;

  const seen = new Set<string>();
  for (const plan of catalogue.plans) {
    if (seen.has(plan.key)) {
      throw new CreditCatalogueError(
        `CREDIT_PLANS names the plan key ${JSON.stringify(plan.key)} twice; plan keys must be ` +
          "unique, or which of the two applies would depend on the order they were written in.",
      );
    }
    seen.add(plan.key);
  }
  if (!seen.has(catalogue.defaultPlan)) {
    throw new CreditCatalogueError(
      `CREDIT_PLANS names ${JSON.stringify(catalogue.defaultPlan)} as its defaultPlan, and no plan ` +
        "in the catalogue carries that key. Every account whose entitlement names no plan would " +
        "fall to a tier that does not exist.",
    );
  }
  return catalogue;
}

/**
 * The plan an account on `planKey` is on.
 *
 * `undefined` and an unrecognised key are the same answer — the default plan — and
 * `catalogueSchema`'s `defaultPlan` comment argues why that direction is the safe one. The caller
 * gets the plan back rather than a key, so nothing downstream has to repeat the lookup or the
 * fallback.
 */
export function planFor(catalogue: CreditCatalogue, planKey: string | undefined): CreditPlan {
  const named = planKey === undefined ? undefined : catalogue.plans.find((p) => p.key === planKey);
  if (named !== undefined) return named;
  // Non-null by `parseCreditCatalogue`: no catalogue exists whose `defaultPlan` names no plan.
  return catalogue.plans.find((plan) => plan.key === catalogue.defaultPlan)!;
}
