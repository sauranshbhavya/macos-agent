import { acceptedKeys, providers as providerNames, type Config, type Provider } from "../config.js";
import { makeAnthropicTextAdapter } from "./anthropic.js";
import { makeCerebrasTextAdapter } from "./cerebras.js";
import { makeOpenAITextAdapter, makeOpenAITranscriptionAdapter } from "./openai.js";
import { meetsZeroRetentionBar, modelRoutes, withFailover, type ModelRoute } from "./provider-router.js";
import { makeTavilySearchAdapter } from "./tavily.js";
import type {
  ModelProviders,
  SearchAdapter,
  TextAdapter,
  TranscriptionAdapter,
} from "./upstream.js";

/**
 * Which provider serves which route, and the one place that decision is made (SONNY-130, SONNY-132).
 *
 * **This function is what SONNY-130's sixth requirement buys.** Before it, the answer to "which
 * provider plans a command" was four Swift initializers on the user's Mac, each with a vendor URL
 * and a model identifier compiled into a shipping binary. Changing it meant an app release. It is
 * now this file plus a set of environment variables, so SONNY-110's move to a paid zero-retention
 * route is a redeploy — which is the whole reason the client is not allowed to name a provider.
 *
 * **What SONNY-132 changed, and what it deliberately did not.** The shape was already right: one
 * function, reading configuration, answering "which adapter serves this route". What it could not
 * express was *more than one* — the answer was `openai` or nothing, written into the body. So a
 * route now resolves to an ordered chain (`config.routeChains`, from `MODEL_ROUTE_*`), each entry
 * becomes an adapter if this deployment holds that provider's credential, and `withFailover` walks
 * what is left. Adding a provider is `adapterFor` plus a config entry, and still never a client
 * change.
 *
 * **An absent credential yields an absent adapter rather than a throw.** A deployment that holds an
 * OpenAI key and no search key should serve three routes rather than fail to start, and a
 * health-only deployment — `./scripts/deploy.sh local` today — should hold none of them and still
 * boot. The routes are mounted either way, so the route table does not change shape with the
 * environment; a route whose chain is empty answers `502 provider.unavailable`, which is both true
 * from the caller's side and a code the client already knows what to do with.
 *
 * **A chain entry with no credential is dropped, and a chain entry with no adapter is refused at
 * startup.** The two look similar and are opposites: the first is a deployment that has not been
 * given a key yet, which is ordinary and recoverable by setting one; the second is a configuration
 * that can never work, which `parseRouteChain` refuses by name in `provider-router.ts`.
 */

/** Settings for whichever provider is being built, assembled once and read by `adapterFor`. */
function textAdapterFor(config: Config, provider: Provider): TextAdapter | undefined {
  const keys = acceptedKeys(config, provider);
  if (keys.length === 0) return undefined;
  switch (provider) {
    case "openai":
      return makeOpenAITextAdapter({
        keys,
        baseUrl: config.openAIBaseUrl,
        textModel: config.openAITextModel,
        transcriptionModel: config.openAITranscriptionModel,
      });
    case "anthropic":
      return makeAnthropicTextAdapter({
        keys,
        baseUrl: config.anthropicBaseUrl,
        textModel: config.anthropicTextModel,
        maxOutputTokens: config.anthropicMaxOutputTokens,
      });
    case "cerebras":
      return makeCerebrasTextAdapter({
        keys,
        baseUrl: config.cerebrasBaseUrl,
        textModel: config.cerebrasTextModel,
      });
    // `tavily` serves search and `vision` is SONNY-131's route; neither has a text adapter, and
    // `PROVIDERS_BY_OPERATION` refuses a chain that names one on a text route before this is
    // reached. The arm exists so the switch is exhaustive rather than defaulting.
    case "tavily":
    case "vision":
      return undefined;
  }
}

function transcriptionAdapterFor(
  config: Config,
  provider: Provider,
): TranscriptionAdapter | undefined {
  if (provider !== "openai") return undefined;
  const keys = acceptedKeys(config, provider);
  if (keys.length === 0) return undefined;
  return makeOpenAITranscriptionAdapter({
    keys,
    baseUrl: config.openAIBaseUrl,
    textModel: config.openAITextModel,
    transcriptionModel: config.openAITranscriptionModel,
  });
}

function searchAdapterFor(config: Config, provider: Provider): SearchAdapter | undefined {
  if (provider !== "tavily") return undefined;
  const keys = acceptedKeys(config, provider);
  if (keys.length === 0) return undefined;
  return makeTavilySearchAdapter({ keys, baseUrl: config.searchBaseUrl });
}

/** The chain for one route, as candidates the router can walk. Entries with no credential drop. */
function candidatesFor<Adapter>(
  config: Config,
  route: ModelRoute,
  build: (config: Config, provider: Provider) => Adapter | undefined,
): readonly { readonly provider: string; readonly call: Adapter }[] {
  const candidates: { provider: string; call: Adapter }[] = [];
  for (const provider of config.routeChains[route]) {
    const call = build(config, provider);
    if (call !== undefined) candidates.push({ provider, call });
  }
  return candidates;
}

export function modelProvidersFrom(config: Config): ModelProviders {
  return {
    plan: withFailover(candidatesFor(config, "plan", textAdapterFor)),
    synthesize: withFailover(candidatesFor(config, "synthesize", textAdapterFor)),
    transcription: withFailover(candidatesFor(config, "transcriptions", transcriptionAdapterFor)),
    search: withFailover(candidatesFor(config, "search", searchAdapterFor)),
  };
}

/**
 * What this deployment believes about its own routing, for one log line at startup.
 *
 * **The per-provider data policy needs a reader or it is a setting nobody can be wrong about.**
 * §16.5 asks for "provider-specific retention/training configuration"; `config.ts` parses it and
 * `provider-router.ts` types it, and until SONNY-110 answers the question nothing routes on it. So it is
 * printed once, beside the chains, where an operator can see what the container was told. A setting
 * that is never surfaced is one that stays at its default through three deployments and is
 * discovered wrong by the thing it was supposed to protect.
 *
 * **No credential, no key, no fragment of one.** What this returns is provider names, model
 * identifiers, endpoints and policy words — all of them values an operator sets by hand and none of
 * them secret. `configured` is a boolean about whether a key is present, never anything about the
 * key itself. `test/provider-router.test.ts` asserts that on the rendered JSON.
 */
export interface RoutingDescription {
  readonly routes: Readonly<Record<ModelRoute, readonly string[]>>;
  readonly providers: readonly {
    readonly provider: Provider;
    readonly configured: boolean;
    readonly retention: string;
    readonly training: string;
    readonly meetsZeroRetentionBar: boolean;
  }[];
}

export function describeRouting(config: Config): RoutingDescription {
  const routes = {} as Record<ModelRoute, readonly string[]>;
  for (const route of modelRoutes) {
    routes[route] = config.routeChains[route].map((provider) =>
      acceptedKeys(config, provider).length > 0 ? provider : `${provider} (no credential)`,
    );
  }

  return {
    routes,
    providers: providerNames.map((provider) => {
      const policy = config.dataPolicies[provider];
      return {
        provider,
        configured: acceptedKeys(config, provider).length > 0,
        retention: policy.retention,
        training: policy.training,
        meetsZeroRetentionBar: meetsZeroRetentionBar(policy),
      };
    }),
  };
}
