/**
 * One model call as the agents make it: a system prompt, one user prompt, optional images, and a
 * strict JSON schema the answer must follow.
 *
 * OpenAI's Responses API takes the images; the Anthropic and Cerebras adapters the text routes
 * already use serve text-only calls. The router skips a text-only model for a call with images.
 */
import { acceptedKeys, type Config } from "../../config.js";
import { makeAnthropicTextAdapter } from "../../model/anthropic.js";
import { makeCerebrasTextAdapter } from "../../model/cerebras.js";
import {
  estimateTextTokens,
  ProviderRejected,
  providerErrorDetail,
  readJSONBody,
  reportedTokenUsage,
  upstreamStatusError,
  upstreamTransportError,
  type TextAdapter,
} from "../../model/upstream.js";
import type { Tier } from "../credits.js";
import type { TierChains, TierModel } from "./tiers.js";

export interface AgentImage {
  readonly mediaType: string;
  readonly base64: string;
}

export interface AgentModelRequest {
  readonly system: string;
  readonly user: string;
  readonly images: readonly AgentImage[];
  readonly schemaName: string;
  readonly schema: object;
  readonly signal: AbortSignal;
}

export interface AgentModelAnswer {
  readonly outputText: string;
  readonly inputTokens: number;
  readonly outputTokens: number;
}

export interface AgentModelEntry {
  readonly provider: string;
  readonly model: string;
  readonly images: boolean;
  readonly call: (request: AgentModelRequest) => Promise<AgentModelAnswer>;
}

export type AgentModelChains = Readonly<Record<Tier, readonly AgentModelEntry[]>>;

/** A rough token count for an image, used only to size a credit hold before the call. */
export const IMAGE_TOKEN_ESTIMATE = 1600;

export function estimateRequestTokens(request: Pick<AgentModelRequest, "system" | "user" | "images">): number {
  return (
    estimateTextTokens(request.system) +
    estimateTextTokens(request.user) +
    request.images.length * IMAGE_TOKEN_ESTIMATE
  );
}

function responsesOutputText(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const record = body as Record<string, unknown>;
  if (typeof record["output_text"] === "string" && record["output_text"].length > 0) return record["output_text"];
  const output = record["output"];
  if (!Array.isArray(output)) return null;
  for (const item of output) {
    const content = (item as Record<string, unknown> | null)?.["content"];
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      const text = (part as Record<string, unknown> | null)?.["text"];
      if (typeof text === "string" && text.length > 0) return text;
    }
  }
  return null;
}

/** OpenAI's Responses API, with images, strict JSON output and `store: false`. */
export function openAIAgentModel(settings: {
  readonly keys: readonly string[];
  readonly baseUrl: string;
  readonly model: string;
}): AgentModelEntry["call"] {
  return async (request) => {
    const key = settings.keys[0];
    if (key === undefined) throw new Error("openai agent model constructed with no credential");
    const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;
    const body = {
      model: settings.model,
      store: false,
      input: [
        { role: "system", content: [{ type: "input_text", text: request.system }] },
        {
          role: "user",
          content: [
            { type: "input_text", text: request.user },
            ...request.images.map((image) => ({
              type: "input_image",
              image_url: `data:${image.mediaType};base64,${image.base64}`,
            })),
          ],
        },
      ],
      text: { format: { type: "json_schema", name: request.schemaName, strict: true, schema: request.schema } },
    };
    let response: Response;
    try {
      response = await fetch(`${base}/responses`, {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "openai");
    }
    if (!response.ok) throw upstreamStatusError(response.status, "openai", await providerErrorDetail(response));
    const parsed = await readJSONBody(response, "openai");
    const text = responsesOutputText(parsed);
    if (text === null) throw new ProviderRejected("openai answered without output text");
    const usage = reportedTokenUsage(parsed);
    return {
      outputText: text,
      inputTokens: usage?.inputTokens ?? estimateRequestTokens(request),
      outputTokens: usage?.outputTokens ?? estimateTextTokens(text),
    };
  };
}

/** One of the text routes' adapters, serving a call that carries no image. */
export function textOnlyAgentModel(adapter: TextAdapter): AgentModelEntry["call"] {
  return async (request) => {
    const messages = [
      { role: "system" as const, text: request.system },
      { role: "user" as const, text: request.user },
    ];
    const result = await adapter({
      messages,
      responseSchemaName: request.schemaName,
      responseSchema: request.schema,
      reasoningEffort: undefined,
      verbosity: undefined,
      signal: request.signal,
    });
    return {
      outputText: result.outputText,
      inputTokens: result.usage.inputTokens ?? estimateRequestTokens(request),
      outputTokens: result.usage.outputTokens ?? estimateTextTokens(result.outputText),
    };
  };
}

function entryFor(config: Config, tierModel: TierModel): AgentModelEntry | undefined {
  const keys = acceptedKeys(config, tierModel.provider);
  if (keys.length === 0) return undefined;
  const { provider, model } = tierModel;
  switch (provider) {
    case "openai":
      return { provider, model, images: true, call: openAIAgentModel({ keys, baseUrl: config.openAIBaseUrl, model }) };
    case "anthropic":
      return {
        provider,
        model,
        images: false,
        call: textOnlyAgentModel(
          makeAnthropicTextAdapter({
            keys,
            baseUrl: config.anthropicBaseUrl,
            textModel: model,
            maxOutputTokens: config.anthropicMaxOutputTokens,
          }),
        ),
      };
    case "cerebras":
      return {
        provider,
        model,
        images: false,
        call: textOnlyAgentModel(makeCerebrasTextAdapter({ keys, baseUrl: config.cerebrasBaseUrl, textModel: model })),
      };
  }
}

/** The configured tiers, keeping only models whose provider has a credential. */
export function agentModelChainsFrom(config: Config, chains: TierChains): AgentModelChains {
  const build = (models: readonly TierModel[]) =>
    models.map((model) => entryFor(config, model)).filter((entry): entry is AgentModelEntry => entry !== undefined);
  return { fast: build(chains.fast), standard: build(chains.standard), strong: build(chains.strong) };
}
