import { z } from "zod";

/**
 * The plan catalogue: every number this repository bills against, in one configuration value and
 * nowhere else (SONNY-212).
 *
 * There is no default catalogue here, no plan key written as a literal, no allowance and no rate. A
 * deployment supplies all of it as `CREDIT_PLANS`, and `requireCreditCatalogue` refuses to start
 * without it: an absent catalogue has no safe reading, because "no allowance" locks every user out
 * and "unlimited" is an unbounded bill.
 *
 * `plans` is a list of any length, keyed by opaque strings this repository never spells, so a third
 * tier is configuration rather than a code change.
 *
 * A credit is what a task's model calls spend, by the tokens each call used at its tier's rate (V2
 * plan decision 8). An account's balance for a period is its plan's `monthlyCredits` plus the
 * top-ups it bought, less what its model calls spent.
 */

/**
 * What one automatic top-up buys, and how many a period may carry (SONNY-215).
 *
 * **Optional, and its absence is what "this deployment does not offer top-ups" means.** There is no
 * default here for the catalogue's reason and one of its own: an invented pack size would be an
 * allowance this repository decided, and an invented `productId` would name a product at the
 * provider that does not exist. So a deployment that has not configured a pack cannot charge
 * anybody — the route refuses, the app does not render the control, and that is the second
 * structural fail-closed beside the consent itself.
 *
 * **The credits and the product id are one fact and live together for that reason.** `BILLING_PLANS`
 * maps a *subscription* product onto a plan key and a capability list; this is a one-time product
 * whose only meaning is how much credit it grants, and splitting the two across two variables would
 * let a deployment sell a pack whose size nothing agrees on.
 *
 * **A price is here now, and the line this file has always held is unmoved** (SONNY-215's F6,
 * founder decision option B). What that line forbids is *this repository* naming an amount, and it
 * still names none: `price` has no default, no example value in any source file, and startup refuses
 * a catalogue without it. What changed is that the product **shows** the price on the switch that
 * authorises the charge — a price is what a purchase always carries — so the number has to reach the
 * client, and configuration is the only place it can come from.
 *
 * **It is the deployment's job to keep this in step with the provider's product**, and nothing here
 * can check it: this gateway never reads the product, so a `price` that disagrees with what the card
 * is charged would show one number and take another. Two things bound that. The *record* the product
 * shows after a charge is the provider's own figure whenever the provider gives one — see
 * `credit/topup.ts` — so only the pre-purchase label can be wrong; and SONNY-215's manual rows check
 * the two against each other on the first real order.
 */
const priceSchema = z.object({
  /**
   * **In the currency's smallest unit**, as every payment provider counts money — 500 for $5.00.
   * An integer, because a fractional cent is not a price anybody can be charged, and **strictly
   * positive** for `credits`' reason one field up (PR #196's G6): a configured `0` would render
   * "($0.00)" on a switch that then charges whatever the provider's product really costs, which is
   * the pre-purchase label being wrong in the one way a user would act on.
   */
  amount: z.number().int().positive(),
  /** ISO 4217, lowercase, as the provider writes it. Three letters, checked so a typo is a startup
   * failure rather than a currency symbol the app cannot format. */
  currency: z.string().trim().toLowerCase().regex(/^[a-z]{3}$/),
});

const topUpSchema = z.object({
  /**
   * Credits one top-up grants. **Strictly positive**: a pack worth nothing is a charge that buys
   * nothing, and `credit_topup`'s own CHECK refuses to record one.
   */
  credits: z.number().positive(),
  /**
   * The provider's id for the one-time product a top-up buys. Opaque here, exactly as a plan key is.
   */
  productId: z.string().trim().min(1),
  /**
   * How many top-up **attempts** one account may make in one period. At least one.
   *
   * Attempts rather than grants, which is 0019's decision and is recorded there: a declined card
   * costs the user nothing and costs the founders their standing with the provider, so a run of
   * declines is a reason to stop rather than a reason to keep going for free.
   */
  maxPerPeriod: z.number().int().min(1),
  /** What one pack costs, as the switch that authorises it says out loud. See `priceSchema`. */
  price: priceSchema,
});

const tierRateSchema = z.object({
  inputPerThousand: z.number().nonnegative(),
  outputPerThousand: z.number().nonnegative(),
});

// Credits per thousand tokens at each model tier (V2 plan decision 8). The rates are a pricing
// decision, so they are configuration, never code.
const tokenRatesSchema = z.object({
  fast: tierRateSchema,
  standard: tierRateSchema,
  strong: tierRateSchema,
});

/** One tier. An opaque key and what a month of it includes. */
const planSchema = z.object({
  /**
   * The value `sonny.entitlement.plan` holds — the same opaque key `BILLING_PLANS` maps a provider
   * product onto. **Not a tier name chosen here**: 0013 has said since it was written that
   * SONNY-212 owns the real keys, and owning them means naming them in configuration, not in source.
   */
  key: z.string().trim().min(1),
  /** Credits this plan includes per period. `0` is a real answer: a tier that includes none. */
  monthlyCredits: z.number().nonnegative(),
});

const catalogueSchema = z.object({
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
  /** Every tier, in the order a deployment listed them. At least one; no upper bound. */
  plans: z.array(planSchema).min(1),
  /** What an automatic top-up buys, or nothing — see `topUpSchema` (SONNY-215). */
  topUp: topUpSchema.optional(),
  tokenRates: tokenRatesSchema,
});

export type CreditPlan = z.infer<typeof planSchema>;
export type CreditTopUpPack = z.infer<typeof topUpSchema>;
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
