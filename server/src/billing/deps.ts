import { ConfigError, type Config } from "../config.js";
import { polarProvider } from "./polar.js";
import type { BillingProvider } from "./provider.js";
import type { BillingPlan, BillingPlans } from "./store.js";

/**
 * Environment → the billing wiring, or nothing at all (SONNY-211).
 *
 * **The same three-outcome shape as `auth/deps.ts`, deliberately**, because the failure it prevents
 * is the same one: a deployment that has said it intends billing and is missing a value must refuse
 * to start, rather than mounting a webhook endpoint that answers every delivery with an error nobody
 * is watching.
 *
 * | environment holds        | outcome                                                     |
 * |--------------------------|-------------------------------------------------------------|
 * | no `BILLING_PROVIDER`    | `undefined` — no billing routes. A supported deployment      |
 * | `BILLING_PROVIDER` alone | `ConfigError` at startup, naming every missing name          |
 * | all four                 | the provider, its plans, and the grace window                |
 *
 * **`BILLING_PROVIDER` is the trigger and the other three are requirements it carries**, on
 * `deps.ts`'s own reasoning: a variable with a default says nothing about intent, and a secret says
 * nothing about which provider it belongs to.
 */
export interface BillingDeps {
  readonly provider: BillingProvider;
  readonly plans: BillingPlans;
  readonly graceMilliseconds: number;
}

const PLAN_ENTRY = /^([^=,\s]+)=([^:,\s]+):(.+)$/;

/**
 * Parse `BILLING_PLANS`: `<product id>=<plan key>:<capability>|<capability>`, comma-separated.
 *
 * **Every refusal names the offending entry**, for `parseTrustedProxies`' reason: there is no way to
 * fix a list without knowing which element is wrong, and none of these values is a secret. The
 * failure direction matters more here than in most parsers — a silently dropped entry is a product
 * that grants nothing, which presents as one customer's subscription not working and nothing else.
 */
export function parseBillingPlans(raw: string): BillingPlans {
  const plans = new Map<string, BillingPlan>();
  const entries = raw
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  for (const entry of entries) {
    const match = PLAN_ENTRY.exec(entry);
    if (match === null) {
      throw new ConfigError(
        `BILLING_PLANS entry ${JSON.stringify(entry)} is not ` +
          `"<product id>=<plan key>:<capability>|<capability>". Entries are comma-separated; ` +
          `capabilities within one entry are separated by "|".`,
      );
    }
    const [, productId, plan, rawCapabilities] = match as unknown as [string, string, string, string];
    const capabilities = rawCapabilities
      .split("|")
      .map((capability) => capability.trim())
      .filter((capability) => capability.length > 0);
    if (capabilities.length === 0) {
      throw new ConfigError(
        `BILLING_PLANS entry ${JSON.stringify(entry)} names no capability. A plan that grants ` +
          `nothing is written by leaving its product out of this variable, which records it as ` +
          `unmapped rather than as a plan worth zero.`,
      );
    }
    if (plans.has(productId)) {
      throw new ConfigError(
        `BILLING_PLANS names product ${JSON.stringify(productId)} twice. One of the two would win ` +
          `silently, and which one is not something to leave to ordering.`,
      );
    }
    plans.set(productId, { plan, capabilities });
  }
  return plans;
}

/** The names a deployment that has named a provider must also set. */
const BILLING_REQUIREMENTS: readonly (readonly [name: string, read: (config: Config) => unknown])[] =
  [
    ["BILLING_WEBHOOK_SECRET", (config) => config.billingWebhookSecret],
    ["BILLING_CHECKOUT_URL", (config) => config.billingCheckoutUrl],
    ["BILLING_PLANS", (config) => (config.billingPlans === "" ? undefined : config.billingPlans)],
  ];

export function billingDepsFrom(config: Config): BillingDeps | undefined {
  if (config.billingProvider === undefined) return undefined;
  const missing = BILLING_REQUIREMENTS.filter(([, read]) => read(config) === undefined).map(
    ([name]) => name,
  );
  if (missing.length > 0) {
    throw new ConfigError(
      `${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} required wherever ` +
        `BILLING_PROVIDER is set: naming a provider is what mounts the subscription webhook, and a ` +
        `webhook endpoint with no secret would refuse every delivery the provider sends. Values are ` +
        `omitted deliberately; see server/.env.example for the expected shape.`,
    );
  }
  // `new URL` refuses a malformed checkout link here, at startup, rather than on the first user who
  // presses Subscribe — the same reason `parseTrustedProxies` validates rather than passing through.
  try {
    void new URL(config.billingCheckoutUrl!);
  } catch {
    throw new ConfigError(
      `BILLING_CHECKOUT_URL is not a URL. It is the hosted checkout link from the provider's ` +
        `dashboard, and the account id is appended to it as a query parameter.`,
    );
  }
  return {
    provider: polarProvider({
      webhookSecret: config.billingWebhookSecret!,
      checkoutUrl: config.billingCheckoutUrl!,
    }),
    plans: parseBillingPlans(config.billingPlans),
    graceMilliseconds: config.billingGraceDays * 24 * 60 * 60 * 1000,
  };
}
