/**
 * The model router: a small deterministic function, with no model of its own (V2 plan section 5).
 *
 * Each agent call names its purpose and what has gone wrong so far; the router answers with a
 * tier, and then runs the call on that tier's chain, failing over only when a provider is
 * unavailable.
 */
import { ProviderTimedOut, ProviderUnavailable } from "../../model/upstream.js";
import { ModelUnavailable, type ModelInvocation } from "../agent.js";
import { TIERS, type Tier } from "../credits.js";
import type { AgentModelChains, AgentModelRequest } from "./adapter.js";

export type ModelPurpose = "plan" | "screen_step";

export interface RoutingSignals {
  readonly purpose: ModelPurpose;
  /** How many times this decision has already come back unusable. */
  readonly invalidOutputRetries: number;
  /** How many steps in a row changed nothing. */
  readonly stepsWithoutProgress: number;
  /** The model said it was unsure. */
  readonly ambiguityFlagged: boolean;
}

export interface TierChoice {
  readonly tier: Tier;
  readonly reasons: readonly string[];
}

const BASE_TIER: Readonly<Record<ModelPurpose, Tier>> = {
  plan: "standard",
  screen_step: "fast",
};

/** Starts from the purpose's tier and goes up one for each thing that went wrong. */
export function chooseTier(signals: RoutingSignals): TierChoice {
  const reasons: string[] = [];
  let index = TIERS.indexOf(BASE_TIER[signals.purpose]);
  if (signals.invalidOutputRetries > 0) {
    index += 1;
    reasons.push("the last answer was unusable");
  }
  if (signals.stepsWithoutProgress >= 2) {
    index += 1;
    reasons.push("two steps changed nothing");
  }
  if (signals.ambiguityFlagged) {
    index += 1;
    reasons.push("the model said it was unsure");
  }
  return { tier: TIERS[Math.min(index, TIERS.length - 1)]!, reasons };
}

export interface ModelRouter {
  run(tier: Tier, request: AgentModelRequest): Promise<ModelInvocation<string>>;
}

export function modelRouter(chains: AgentModelChains): ModelRouter {
  return {
    async run(tier, request) {
      const candidates = chains[tier].filter((entry) => request.images.length === 0 || entry.images);
      if (candidates.length === 0) {
        throw new ModelUnavailable(`no ${tier} model can take this call`);
      }
      for (const entry of candidates) {
        try {
          const answer = await entry.call(request);
          return {
            value: answer.outputText,
            usage: { inputTokens: answer.inputTokens, outputTokens: answer.outputTokens },
            provider: entry.provider,
            model: entry.model,
          };
        } catch (error) {
          if (error instanceof ProviderUnavailable) continue;
          if (error instanceof ProviderTimedOut) throw new ModelUnavailable(`${entry.provider} did not answer in time`);
          throw error;
        }
      }
      throw new ModelUnavailable(`every ${tier} provider is unavailable`);
    },
  };
}
