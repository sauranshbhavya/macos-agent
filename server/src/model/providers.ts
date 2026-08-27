import { acceptedKeys, type Config } from "../config.js";
import { makeOpenAITextAdapter, makeOpenAITranscriptionAdapter } from "./openai.js";
import { makeTavilySearchAdapter } from "./tavily.js";
import type { ModelProviders } from "./upstream.js";

/**
 * Which provider serves which route, and the one place that decision is made (SONNY-130).
 *
 * **This function is what SONNY-130's sixth requirement buys.** Before it, the answer to "which
 * provider plans a command" was four Swift initializers on the user's Mac, each with a vendor URL
 * and a model identifier compiled into a shipping binary. Changing it meant an app release. It is
 * now this file plus four environment variables, so SONNY-110's move to a paid zero-retention
 * route is a redeploy — which is the whole reason the client is not allowed to name a provider.
 *
 * **An absent credential yields an absent adapter rather than a throw.** A deployment that holds an
 * OpenAI key and no search key should serve three routes rather than fail to start, and a
 * health-only deployment — `./scripts/deploy.sh local` today — should hold none of them and still
 * boot. The routes are mounted either way, so the route table does not change shape with the
 * environment; a route whose adapter is missing answers `502 provider.unavailable`, which is both
 * true from the caller's side and a code the client already knows what to do with.
 */
export function modelProvidersFrom(config: Config): ModelProviders {
  const openAIKeys = acceptedKeys(config, "openai");
  const searchKeys = acceptedKeys(config, "tavily");

  const openAI =
    openAIKeys.length > 0
      ? {
          keys: openAIKeys,
          baseUrl: config.openAIBaseUrl,
          textModel: config.openAITextModel,
          transcriptionModel: config.openAITranscriptionModel,
        }
      : undefined;

  return {
    text: openAI === undefined ? undefined : makeOpenAITextAdapter(openAI),
    transcription: openAI === undefined ? undefined : makeOpenAITranscriptionAdapter(openAI),
    search:
      searchKeys.length > 0
        ? makeTavilySearchAdapter({ keys: searchKeys, baseUrl: config.searchBaseUrl })
        : undefined,
  };
}
