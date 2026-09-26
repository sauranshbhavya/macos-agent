import { acceptedKeys, providers as providerNames, type Config, type Provider } from "../config.js";
import { makeOpenAITranscriptionAdapter } from "./openai.js";
import { meetsZeroRetentionBar, modelRoutes, withFailover, type ModelRoute } from "./provider-router.js";
import { makeTavilySearchAdapter } from "./tavily.js";
import type {
  ModelProviders,
  SearchAdapter,
  TranscriptionAdapter,
} from "./upstream.js";

/**
 * Which provider serves transcription and web search, and the one place that is decided (SONNY-130,
 * SONNY-132).
 *
 * Each route resolves to an ordered chain (`config.routeChains`, from `MODEL_ROUTE_*`); each entry
 * becomes an adapter if this deployment holds that provider's credential, and `withFailover` walks
 * what is left. **A chain entry with no credential is dropped**, so a deployment without a key still
 * starts: transcription then answers `502 provider.unavailable` and the agents' search tool reports
 * search as unavailable. **A chain entry with no adapter is refused at startup** by
 * `parseRouteChain`, because that configuration can never work.
 */

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
    transcription: withFailover(candidatesFor(config, "transcriptions", transcriptionAdapterFor)),
    search: withFailover(candidatesFor(config, "search", searchAdapterFor)),
  };
}

/**
 * What this deployment believes about its own routing, for one log line at startup.
 *
 * **The per-provider data policy needs a reader or it is a setting nobody can be wrong about.**
 * Nothing routes on it, so it is printed once, beside the chains, where an operator can see what the
 * container was told.
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
