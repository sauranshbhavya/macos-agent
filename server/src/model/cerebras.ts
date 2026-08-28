import {
  estimatedTextUsage,
  ProviderRejected,
  readJSONBody,
  reportedTokenUsage,
  upstreamStatusError,
  upstreamTransportError,
  type TextRequest,
  type TextResult,
  type UpstreamMessage,
} from "./upstream.js";

/**
 * The Cerebras adapter: the open-weights planner, moved off the Mac (SONNY-132).
 *
 * **What moved, and what it stops being.** `CerebrasPlanner` lived in `MacAgentCore`, held
 * `CEREBRAS_API_KEY` in the user's own environment, and was reachable only by launching the app
 * with `SONNY_PLANNER=cerebras`. Row 12's whole argument is that a provider is a server decision,
 * so it is now a `MODEL_ROUTE_PLAN` entry and a credential this gateway holds — the Swift class,
 * its parser and its environment variable are gone in the same change.
 *
 * **Schema-in-prompt, not native structured output, and that is measured rather than assumed.**
 * `CerebrasPlanner`'s doc recorded a live re-check on 2026-08-13 against
 * inference-docs.cerebras.ai/capabilities/structured-outputs: the schema cap is 5,000 characters,
 * ours serializes well past it, and since 2026-07-21 the limits are strictly enforced — so sending
 * `response_format` is a validation error rather than a silent degradation. The Swift side kept a
 * `SONNY_CEREBRAS_STRUCTURED` opt-in so that rejection could be re-measured against the live API;
 * it is not carried across, because the measurement it existed for was made and the answer has not
 * changed. Re-measuring it now is a `curl` against the vendor, not a flag in a shipping gateway.
 *
 * §4.2 names this mapping explicitly as one of the three it delegates to the server — "a prompt
 * suffix on a third, as `CerebrasPlanner` already does today" — so the suffix below is the
 * contract's own example rather than a liberty taken with the client's text.
 */

export interface CerebrasSettings {
  /** Newest first; index 0 serves new requests (`config.ts`, `ProviderCredentials`). */
  readonly keys: readonly string[];
  /** `https://api.cerebras.ai/v1` by default. */
  readonly baseUrl: string;
  /** The model the text routes ask for. Never sent to, or named by, the client. */
  readonly textModel: string;
}

function activeKey(settings: CerebrasSettings): string {
  const key = settings.keys[0];
  if (key === undefined) throw new Error("cerebras adapter constructed with no credential");
  return key;
}

function endpoint(settings: CerebrasSettings, path: string): string {
  const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;
  return `${base}${path}`;
}

/**
 * The schema instruction appended to the system message, byte-for-byte what the Swift planner sent.
 *
 * Kept identical to `CerebrasPlanner.schemaPromptSuffix()` deliberately: that wording is what was
 * measured working against the live model on 2026-08-13, and a reworded instruction is a change to
 * the prompt with no evidence behind it. The schema is serialized with sorted keys for the reason
 * the Swift version gave — a prompt that reordered itself between processes would defeat prompt
 * caching and make any golden untestable.
 */
export function schemaPromptSuffix(schema: unknown): string {
  return (
    "\n\nYour reply must be exactly one JSON object conforming to this JSON Schema — " +
    "no markdown fences, no commentary, nothing before or after it:\n" +
    stableSchemaText(schema)
  );
}

/** Deterministic JSON for a schema: object keys sorted at every depth, stable across runs. */
export function stableSchemaText(schema: unknown): string {
  const sortKeys = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (typeof value !== "object" || value === null) return value;
    const source = value as Record<string, unknown>;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) sorted[key] = sortKeys(source[key]);
    return sorted;
  };
  try {
    return JSON.stringify(sortKeys(schema)) ?? "{}";
  } catch {
    return "{}";
  }
}

/**
 * The messages this provider is sent: the client's, in order, with the suffix on the system one.
 *
 * **Which message the suffix lands on matters and is the Swift version's answer.** It extends the
 * *first* system message rather than being appended as a trailing one, because that is the shape
 * that was measured working — and because a schema instruction arriving after the user's own
 * sentence is a different prompt, not a formatting detail. No user message is touched and no
 * message moves, which is the half of §4.2 that row I's prompt-injection defence actually depends
 * on: the TRUSTED_USER_INSTRUCTION and UNTRUSTED_OBSERVED_CONTENT boundaries live in user text.
 *
 * A request with no system message at all gets one carrying only the suffix, prepended. The client
 * always sends one; this is the honest handling rather than dropping the schema on the floor.
 */
export function messagesWithSchemaSuffix(
  messages: readonly UpstreamMessage[],
  schema: unknown,
): readonly UpstreamMessage[] {
  const suffix = schemaPromptSuffix(schema);
  const firstSystem = messages.findIndex((message) => message.role === "system");
  if (firstSystem === -1) {
    return [{ role: "system", text: suffix.trimStart() }, ...messages];
  }
  return messages.map((message, index) =>
    index === firstSystem ? { role: message.role, text: message.text + suffix } : message,
  );
}

/**
 * A fenced reply, unwrapped. Ported from `CerebrasPlanner.normalizedPlanText`.
 *
 * **Why the server does this rather than the client.** §4.2 has two sentences that only both hold
 * if it happens here: `output_text` is "the model's text, unmodified", and "the client does not
 * know which mechanism was used and must not need to". A markdown fence is an artifact of *this*
 * mechanism — schema-in-prompt has no server-side output guarantee, and a model told "no markdown
 * fences" still emits them sometimes. A client that stripped fences would be a client compensating
 * for a provider it is not allowed to know it is talking to; leaving them would mean a plan that
 * decoded under one provider and failed under another. So the adapter that chose the mechanism
 * cleans up after it, and what the client receives is the same JSON either way.
 *
 * Only a wrapping fence is removed. Everything else malformed still reaches
 * `AgentPlanDecoder.decodeStrict` and is still rejected there.
 */
export function normalizedPlanText(text: string): string {
  let trimmed = text.trim();
  if (!trimmed.startsWith("```")) return trimmed;
  const firstNewline = trimmed.indexOf("\n");
  // A lone fence line carries no plan; hand it on unmodified so the client's decoder rejects it.
  if (firstNewline === -1) return trimmed;
  trimmed = trimmed.slice(firstNewline + 1);
  if (trimmed.endsWith("```")) trimmed = trimmed.slice(0, -3);
  return trimmed.trim();
}

/**
 * The assistant's message content out of a Chat Completions reply.
 *
 * Same containment `CerebrasChatResponseParser.messageContent` had: a truncated or non-JSON body
 * surfaces as this adapter's own typed failure, never as a raw parse error the client renders.
 */
function messageContent(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const choices = (body as { choices?: unknown }).choices;
  if (!Array.isArray(choices)) return null;
  for (const choice of choices) {
    if (typeof choice !== "object" || choice === null) continue;
    const message = (choice as Record<string, unknown>)["message"];
    if (typeof message !== "object" || message === null) continue;
    const content = (message as Record<string, unknown>)["content"];
    if (typeof content === "string" && content.length > 0) return content;
  }
  return null;
}

export function makeCerebrasTextAdapter(
  settings: CerebrasSettings,
): (request: TextRequest) => Promise<TextResult> {
  return async (request) => {
    const messages = messagesWithSchemaSuffix(request.messages, request.responseSchema);
    const body = {
      model: settings.textModel,
      messages: messages.map((message) => ({ role: message.role, content: message.text })),
      // The Swift planner sent `reasoning_effort: "medium"` unconditionally; the client now supplies
      // it per §4.2 and it is forwarded when present. `verbosity` has no Chat Completions
      // equivalent and is ignored, which §4.2 permits in as many words.
      ...(request.reasoningEffort === undefined
        ? {}
        : { reasoning_effort: request.reasoningEffort }),
    };

    let response: Response;
    try {
      response = await fetch(endpoint(settings, "/chat/completions"), {
        method: "POST",
        headers: {
          authorization: `Bearer ${activeKey(settings)}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "cerebras");
    }

    if (!response.ok) throw upstreamStatusError(response.status, "cerebras");

    const parsed: unknown = await readJSONBody(response, "cerebras");
    const content = messageContent(parsed);
    if (content === null) {
      throw new ProviderRejected("cerebras answered without message content");
    }
    const text = normalizedPlanText(content);
    if (text.length === 0) {
      throw new ProviderRejected("cerebras answered without message content");
    }

    // Estimated from the messages actually sent, suffix included, so the count describes the
    // request that was made rather than the one the client composed.
    return {
      outputText: text,
      usage: reportedTokenUsage(parsed) ?? estimatedTextUsage(messages, text),
    };
  };
}
