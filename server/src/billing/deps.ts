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
    // SONNY-216. Required on the same terms as the three beside it: the portal route mints a
    // customer session through the provider's API, and a deployment that named a provider but no
    // token would mount a Manage-subscription route that fails on every press.
    ["BILLING_PROVIDER_ACCESS_TOKEN", (config) => config.billingProviderAccessToken],
    ["BILLING_PLANS", (config) => (config.billingPlans === "" ? undefined : config.billingPlans)],
  ];

/**
 * The names above, and the one whose presence makes them required (SONNY-405).
 *
 * **Exported so that `scripts/deploy.sh` can be checked against this list rather than against a copy
 * of it.** The defect that produced these two constants is what happens without that link: SONNY-216
 * added `BILLING_PROVIDER_ACCESS_TOKEN` to the array above, nothing carried it -- or any of the
 * others -- into the deploy script's passthrough, and the founders' three billing rows could not be
 * run against the only local gateway this repository documents. `test/deploy-passthrough.test.ts`
 * reads these two and fails until every one of them is forwarded, so a sixth requirement added here
 * arrives at that test rather than at a founder's 404.
 */
export const BILLING_TRIGGER = "BILLING_PROVIDER";
export const BILLING_REQUIREMENT_NAMES: readonly string[] = BILLING_REQUIREMENTS.map(
  ([name]) => name,
);

export function billingDepsFrom(config: Config): BillingDeps | undefined {
  if (config.billingProvider === undefined) return undefined;
  const missing = BILLING_REQUIREMENTS.filter(([, read]) => read(config) === undefined).map(
    ([name]) => name,
  );
  if (missing.length > 0) {
    throw new ConfigError(
      `${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} required wherever ` +
        `BILLING_PROVIDER is set: naming a provider is what mounts the subscription webhook and the ` +
        `billing routes, and each of these is load-bearing for one of them — a webhook endpoint ` +
        `with no secret would refuse every delivery the provider sends, and a portal route with no ` +
        `access token would fail on every press. Values are omitted deliberately; see ` +
        `server/.env.example for the expected shape.`,
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
  // Same reasoning as the checkout link directly above, applied to the optional override: a
  // malformed origin here is a startup failure that names itself rather than a portal route that
  // throws on the first user who presses Manage subscription.
  if (config.billingApiBaseUrl !== undefined) {
    // **The scheme is checked as well as the parse, because this variable decides where a bearer
    // credential is sent** (PR #183, F12). `new URL` accepts anything with a scheme, so
    // `http://api.polar.sh` passed and the adapter would then put `authorization: Bearer <token>`
    // on the wire in cleartext. A route that throws on the first press is recoverable; a credential
    // that has already travelled unencrypted is not, which makes this the half of the guard worth
    // more than the half that was here.
    let origin: URL;
    try {
      origin = new URL(config.billingApiBaseUrl);
    } catch {
      throw new ConfigError(
        `BILLING_API_BASE_URL is not a URL. It is the provider's API origin, and it is optional — ` +
          `leave it unset to use the provider adapter's own default.`,
      );
    }
    if (origin.protocol !== "https:") {
      throw new ConfigError(
        `BILLING_API_BASE_URL must be https. It is the origin an Organization Access Token is sent ` +
          `to, and any other scheme puts that credential on the wire in the clear.`,
      );
    }
    // A path here is silently dropped rather than honoured, because the adapter's request path is
    // root-anchored: `new URL("/v1/customer-sessions/", "https://host/gw")` is `https://host/v1/...`.
    // Refusing it is better than dropping it, because the resulting 404 from the wrong path is the
    // status `looksLikeAMissingCustomer` exists to keep from reading as "no customer".
    if (origin.pathname !== "/") {
      throw new ConfigError(
        `BILLING_API_BASE_URL must be an origin with no path. The provider's request path is ` +
          `appended from the root, so a prefix here would be silently dropped rather than used.`,
      );
    }
  }
  return {
    provider: polarProvider({
      webhookSecret: config.billingWebhookSecret!,
      checkoutUrl: config.billingCheckoutUrl!,
      accessToken: config.billingProviderAccessToken!,
      apiBaseUrl: config.billingApiBaseUrl,
    }),
    plans: parseBillingPlans(config.billingPlans),
    graceMilliseconds: config.billingGraceDays * 24 * 60 * 60 * 1000,
  };
}
