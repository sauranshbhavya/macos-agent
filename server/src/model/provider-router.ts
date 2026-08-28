import { ConfigError, providers, type Provider } from "../config.js";
import { ProviderUnavailable, type ProviderAttribution, type Routed } from "./upstream.js";

/**
 * The provider-agnostic router: which provider serves which route, in what order, and what happens
 * when the first one cannot (SONNY-132).
 *
 * **What this file is, against what `providers.ts` is.** `providers.ts` is still the one place the
 * decision is *made* — SONNY-130 built it for that and this ticket generalizes it rather than
 * forking it. What lives here is the part of the decision that is pure: parsing a route's provider
 * chain out of the environment, and the combinator that walks the chain. Neither function knows
 * what an adapter is beyond "something that can be called and can throw", which is what makes the
 * whole of it testable without a credential, a network, or an app.
 *
 * **Spec §16.5 asks for four things and this file is two of them** — "Model routing controlled
 * server-side" and "Failover where appropriate". The other two, "Provider credentials never ship to
 * client" and "Provider-specific retention/training configuration", are `config.ts`'s; the second
 * of those is read back here as `providerDataPolicy` so the router can report it.
 */

/** The routes whose provider is configuration. §11's `route` enum, minus the one SONNY-131 owns. */
export const modelRoutes = ["plan", "synthesize", "transcriptions", "search"] as const;
export type ModelRoute = (typeof modelRoutes)[number];

/** `MODEL_ROUTE_PLAN`, `MODEL_ROUTE_SYNTHESIZE`, … — one variable per route. */
export function routeVariableName(route: ModelRoute): string {
  return `MODEL_ROUTE_${route.toUpperCase()}`;
}

/**
 * Which providers serve which route when nothing is configured.
 *
 * **The single-entry rows reproduce SONNY-130 exactly, and the two-entry rows are this ticket's
 * only behavioural default change.** A deployment holding one OpenAI key and one Tavily key — which
 * is every deployment that exists today — behaves byte-identically either way, because a chain
 * entry whose provider has no credential is dropped when the chain is built. The second entry costs
 * nothing until somebody sets `ANTHROPIC_API_KEY`, and the moment they do, §16.5's "failover where
 * appropriate" is live without a second, undocumented variable to find.
 *
 * **This is not the default-planner flip, and the distinction is the ticket's never-touch list.**
 * OpenAI is the primary on every request, unconditionally, and nothing here or anywhere else
 * changes that: the second entry is reached only after the first has failed *this one request*, and
 * no state survives it — the next request starts at OpenAI again. Which provider is *first* stays a
 * founder decision, made in configuration.
 *
 * **Transcription is a one-entry chain because Anthropic serves no transcription API**, not because
 * transcription deserves less failover. A chain entry that could never work is a configuration that
 * fails at request time instead of at startup; `parseRouteChain` refuses one for the same reason.
 * Search is one entry because Tavily is the only search provider this gateway has an adapter for.
 */
export const DEFAULT_ROUTE_CHAINS: Readonly<Record<ModelRoute, readonly Provider[]>> = {
  plan: ["openai", "anthropic"],
  synthesize: ["openai", "anthropic"],
  transcriptions: ["openai"],
  search: ["tavily"],
};

/**
 * Which providers this gateway has an adapter for, per operation.
 *
 * Read by `parseRouteChain` so a chain naming a provider that cannot serve that route is refused at
 * startup with the variable's name, rather than silently dropped — a dropped entry is a failover
 * candidate an operator believes they configured and does not have.
 */
export const PROVIDERS_BY_OPERATION: Readonly<Record<ModelRoute, readonly Provider[]>> = {
  plan: ["openai", "anthropic", "cerebras"],
  synthesize: ["openai", "anthropic", "cerebras"],
  transcriptions: ["openai"],
  search: ["tavily"],
};

/**
 * Parse one `MODEL_ROUTE_*` value into an ordered provider chain.
 *
 * Every failure is a startup failure naming the variable and the offending entry, which is the
 * pattern `parseTrustedProxies` established and for the same reason: a provider id is not a secret,
 * and a list cannot be fixed without knowing which element is wrong. The three refusals are an
 * unknown provider, a provider with no adapter for that operation, and a duplicate — the last
 * because a chain naming the same provider twice would try the same failing call twice inside one
 * route deadline while reading, in configuration, like two chances.
 */
export function parseRouteChain(route: ModelRoute, raw: string | undefined): readonly Provider[] {
  const trimmed = (raw ?? "").trim();
  if (trimmed === "") return DEFAULT_ROUTE_CHAINS[route];

  const variable = routeVariableName(route);
  const entries = trimmed
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);
  if (entries.length === 0) {
    throw new ConfigError(
      `${variable} names no provider. Leave it unset for the default ` +
        `(${DEFAULT_ROUTE_CHAINS[route].join(", ")}), or give a comma-separated list of ` +
        `${PROVIDERS_BY_OPERATION[route].join(", ")}.`,
    );
  }

  const known = new Set<string>(providers);
  const servable = new Set<string>(PROVIDERS_BY_OPERATION[route]);
  const seen = new Set<string>();
  const chain: Provider[] = [];
  for (const entry of entries) {
    if (!known.has(entry)) {
      throw new ConfigError(
        `${variable} names ${JSON.stringify(entry)}, which is not a provider this gateway ` +
          `knows. Known providers: ${providers.join(", ")}.`,
      );
    }
    if (!servable.has(entry)) {
      throw new ConfigError(
        `${variable} names ${JSON.stringify(entry)}, which this gateway has no adapter for on ` +
          `that route. Providers that can serve it: ${PROVIDERS_BY_OPERATION[route].join(", ")}. ` +
          `Refused at startup rather than dropped, because a silently dropped entry is a failover ` +
          `candidate you believe you configured and do not have.`,
      );
    }
    if (seen.has(entry)) {
      throw new ConfigError(
        `${variable} names ${JSON.stringify(entry)} more than once. A repeated entry makes the ` +
          `same failing call twice inside one route deadline while reading like two chances.`,
      );
    }
    seen.add(entry);
    chain.push(entry as Provider);
  }
  return chain;
}

/**
 * How long a provider keeps our request and response content, as this deployment has been told.
 *
 * §16.5: "Provider-specific retention/training configuration." **`unknown` is the default for every
 * provider, and that is the honest current value rather than a placeholder** — no vendor agreement
 * has been read on this project's behalf, and writing a vendor's public default here as if it were
 * a checked fact is the kind of confident claim this repository bans. SONNY-110 is where a real
 * value comes from, and this is the field it lands in.
 */
export const retentionPolicies = ["unknown", "none", "retains"] as const;
export type ProviderRetentionPolicy = (typeof retentionPolicies)[number];

/** Whether the provider reserves the right to train on our data. Same three-state honesty. */
export const trainingPolicies = ["unknown", "none", "reserved"] as const;
export type ProviderTrainingPolicy = (typeof trainingPolicies)[number];

export interface ProviderDataPolicy {
  readonly retention: ProviderRetentionPolicy;
  readonly training: ProviderTrainingPolicy;
}

export const UNVERIFIED_DATA_POLICY: ProviderDataPolicy = {
  retention: "unknown",
  training: "unknown",
};

/** `OPENAI_DATA_RETENTION`, `ANTHROPIC_TRAINING`, … — two variables per provider. */
export function dataPolicyVariableNames(provider: Provider): {
  readonly retention: string;
  readonly training: string;
} {
  const prefix = provider.toUpperCase();
  return { retention: `${prefix}_DATA_RETENTION`, training: `${prefix}_TRAINING` };
}

function parseEnumSetting<T extends string>(
  variable: string,
  raw: string | undefined,
  allowed: readonly T[],
  fallback: T,
): T {
  const trimmed = (raw ?? "").trim().toLowerCase();
  if (trimmed === "") return fallback;
  if ((allowed as readonly string[]).includes(trimmed)) return trimmed as T;
  throw new ConfigError(
    `${variable} is ${JSON.stringify(trimmed)}; expected one of ${allowed.join(", ")}. ` +
      `Leave it unset for ${JSON.stringify(fallback)}, which means nobody has verified this ` +
      `provider's terms — see SONNY-110.`,
  );
}

/** Every provider's declared data policy, read from the environment. */
export function providerDataPolicies(
  env: NodeJS.ProcessEnv,
): Readonly<Record<Provider, ProviderDataPolicy>> {
  const entries = providers.map((provider) => {
    const names = dataPolicyVariableNames(provider);
    return [
      provider,
      {
        retention: parseEnumSetting(
          names.retention,
          env[names.retention],
          retentionPolicies,
          "unknown",
        ),
        training: parseEnumSetting(names.training, env[names.training], trainingPolicies, "unknown"),
      },
    ] as const;
  });
  return Object.fromEntries(entries) as Record<Provider, ProviderDataPolicy>;
}

/**
 * Does this provider meet SONNY-110's bar — retains nothing **and** reserves no training rights?
 *
 * **Both halves, because either alone defeats the purpose.** SONNY-110's requirement widened on
 * 2026-08-16 for exactly this reason: a provider that retains nothing but trains on what it saw has
 * not protected the content, since training is one of the three named purposes retention exists
 * for. `unknown` is not `none` — an unverified provider fails this, which is the safe direction and
 * is why the default is `unknown` rather than an optimistic guess.
 *
 * **This is the field, not the answer.** Nothing routes on it today, deliberately: making
 * `retention: "none"` on the wire mean "refuse a provider that retains" is SONNY-110's decision to
 * take and SONNY-131's route to enforce it on, and building it here with every policy `unknown`
 * would refuse every request this gateway can currently serve.
 */
export function meetsZeroRetentionBar(policy: ProviderDataPolicy): boolean {
  return policy.retention === "none" && policy.training === "none";
}

/** One candidate in a route's chain: a provider name and the adapter that speaks to it. */
export interface RouteCandidate<Req, Res> {
  readonly provider: string;
  readonly call: (request: Req) => Promise<Res>;
}

/**
 * Walk a route's chain, and return whichever provider answered plus the ones that could not.
 *
 * **What triggers failover: `ProviderUnavailable`, and nothing else.** The seam's three typed
 * failures mean genuinely different things and only one of them says "ask somebody else":
 *
 * - `ProviderUnavailable` — could not be reached, a `429`, or a `5xx` (`upstreamStatusError`). The
 *   request is fine and this provider is not, which is precisely the "one provider having a bad
 *   hour" the ticket's third requirement names. Fail over.
 * - `ProviderRejected` — the provider understood the request and refused it. §9.3 makes it not
 *   retryable because "a retry is guaranteed to fail identically", and the same reasoning applies
 *   across providers: a refusal is usually about the *content*, so shopping it to a second vendor
 *   is not resilience, it is routing around one vendor's answer. Rethrown, and the client gets
 *   `502 provider.rejected` exactly as it does today.
 * - `ProviderTimedOut` — the deadline. The whole chain runs inside one `withDeadlines` call and
 *   shares one `AbortSignal`, so by the time this is thrown the signal is already aborted and a
 *   second attempt would fail before it opened a socket. Rethrown.
 *
 * Anything else is this gateway's own bug and is rethrown untouched, so `routes/model.ts` still
 * turns it into §7.2 case 6's retryable 500 with a logged stack.
 *
 * **The deadline is shared across the whole chain and that is the point.** §12's governing rule is
 * that the client's timeout is longer than this server's total deadline, so a slow route surfaces
 * as a typed `504 provider.timeout` the app can explain rather than as an opaque transport timeout
 * it cannot tell from a dead network. Giving each attempt its own fresh deadline would let two
 * attempts run past `total` and hand the failure to whatever is in front of this gateway. So the
 * signal is checked between attempts: a chain that has already run out of time stops rather than
 * opening a request it cannot finish.
 *
 * **Every candidate failing rethrows the last error, not the first.** The client is told what
 * actually happened at the end of the road it went down; a first error would describe a provider
 * that has since been replaced by another that also failed.
 */
export function withFailover<Req extends { readonly signal: AbortSignal }, Res extends object>(
  candidates: readonly RouteCandidate<Req, Res>[],
): ((request: Req) => Promise<Routed<Res>>) | undefined {
  if (candidates.length === 0) return undefined;

  return async (request) => {
    const failedOver: string[] = [];
    let lastError: unknown;
    for (const candidate of candidates) {
      try {
        const result = await candidate.call(request);
        const served: ProviderAttribution = {
          provider: candidate.provider,
          failedOver: [...failedOver],
        };
        return { ...result, served };
      } catch (error) {
        if (!(error instanceof ProviderUnavailable)) throw error;
        lastError = error;
        failedOver.push(candidate.provider);
        if (request.signal.aborted) throw error;
      }
    }
    throw lastError;
  };
}
