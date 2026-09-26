/**
 * Which models serve each tier (V2 plan section 5, "Model router"). No model name appears in code:
 * each tier is a configured chain of `provider:model` entries, tried in order, where a later entry
 * is used only when an earlier provider is unavailable.
 *
 * `AGENT_MODEL_FAST`, `AGENT_MODEL_STANDARD` and `AGENT_MODEL_STRONG`, each for example
 * `openai:gpt-5.6-luna,cerebras:gpt-oss-120b`.
 */
import { ConfigError } from "../../config.js";
import { TIERS, type Tier } from "../credits.js";

export const AGENT_MODEL_PROVIDERS = ["openai", "anthropic", "cerebras"] as const;
export type AgentModelProvider = (typeof AGENT_MODEL_PROVIDERS)[number];

export interface TierModel {
  readonly provider: AgentModelProvider;
  readonly model: string;
}

export type TierChains = Readonly<Record<Tier, readonly TierModel[]>>;

export const NO_TIER_CHAINS: TierChains = { fast: [], standard: [], strong: [] };

export function tierVariableName(tier: Tier): string {
  return `AGENT_MODEL_${tier.toUpperCase()}`;
}

export function parseTierChain(tier: Tier, raw: string | undefined): readonly TierModel[] {
  const trimmed = (raw ?? "").trim();
  if (trimmed === "") return [];
  const variable = tierVariableName(tier);
  const chain: TierModel[] = [];
  for (const entry of trimmed.split(",").map((part) => part.trim()).filter((part) => part.length > 0)) {
    const colon = entry.indexOf(":");
    const provider = colon === -1 ? "" : entry.slice(0, colon).trim().toLowerCase();
    const model = colon === -1 ? "" : entry.slice(colon + 1).trim();
    if (!(AGENT_MODEL_PROVIDERS as readonly string[]).includes(provider) || model === "") {
      throw new ConfigError(
        `${variable} has ${JSON.stringify(entry)}; each entry is provider:model with a provider of ` +
          `${AGENT_MODEL_PROVIDERS.join(", ")}.`,
      );
    }
    if (chain.some((existing) => existing.provider === provider && existing.model === model)) {
      throw new ConfigError(`${variable} names ${entry} twice.`);
    }
    chain.push({ provider: provider as AgentModelProvider, model });
  }
  return chain;
}

export function parseTierChains(env: NodeJS.ProcessEnv): TierChains {
  const chains = {} as Record<Tier, readonly TierModel[]>;
  for (const tier of TIERS) chains[tier] = parseTierChain(tier, env[tierVariableName(tier)]);
  return chains;
}

/** True when every tier has at least one model, which is what the agents need to run. */
export function tiersConfigured(chains: TierChains): boolean {
  return TIERS.every((tier) => chains[tier].length > 0);
}
