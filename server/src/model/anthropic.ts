import {
  estimatedTextUsage,
  ProviderRejected,
  readJSONBody,
  reportedTokenUsage,
  upstreamStatusError,
  upstreamTransportError,
  type TextRequest,
  type TextResult,
} from "./upstream.js";

/**
 * The Anthropic adapter: the two text routes, `/v1/plan` and `/v1/research/synthesize` (SONNY-132).
 *
 * **The second real provider spec §16.5 asked for "from day one".** The router's whole claim — that
 * adding a provider is a config entry plus an adapter and never a client change — is only worth
 * anything if a second adapter actually exists, so this one is written against the real Messages
 * API rather than stubbed. `test/anthropic.test.ts` drives it through the app with `fetch` stubbed
 * at the boundary, the way SONNY-130's OpenAI tests do; a live round against `api.anthropic.com`
 * needs a real key and is a founder's to run.
 *
 * **Raw `fetch`, not `@anthropic-ai/sdk`, and the reason is this seam rather than taste.**
 * `upstream.ts` is explicit that the seam holds "no retries, no caching, no policy", and the
 * official SDK's default is two automatic retries on `429` and `5xx`. Inside a failover chain,
 * inside a route deadline, that is a hidden multiplier on upstream calls that neither `withFailover`
 * nor `withDeadlines` can see — the same request could be attempted six times inside one 60-second
 * budget while the log said one. Every other provider in this directory is raw `fetch` at the same
 * seam for the same reason, and an adapter that was structurally different from its neighbours
 * would be the thing the seam exists to prevent.
 */

export interface AnthropicSettings {
  /** Newest first; index 0 serves new requests (`config.ts`, `ProviderCredentials`). */
  readonly keys: readonly string[];
  /** `https://api.anthropic.com/v1` by default. Configurable so SONNY-110 is a redeploy. */
  readonly baseUrl: string;
  /** The model the text routes ask for. Never sent to, or named by, the client. */
  readonly textModel: string;
  /** Required by the Messages API on every request; there is no server-side default. */
  readonly maxOutputTokens: number;
}

/** The API version header every Messages request must carry. Not the model, and not a beta. */
export const ANTHROPIC_VERSION = "2023-06-01";

/**
 * The effort values `output_config.effort` accepts.
 *
 * §4.2 makes `reasoning_effort` advisory — "a provider that has no equivalent ignores them" — and
 * this provider has one, so it is passed through when it matches and dropped when it does not.
 * Dropped rather than forwarded, because an unrecognised value is a `400` on a request the user is
 * waiting on, and the field is a hint by contract. `verbosity` has no equivalent and is ignored.
 */
const EFFORT_LEVELS = new Set(["low", "medium", "high", "xhigh", "max"]);

function activeKey(settings: AnthropicSettings): string {
  const key = settings.keys[0];
  if (key === undefined) throw new Error("anthropic adapter constructed with no credential");
  return key;
}

function endpoint(settings: AnthropicSettings, path: string): string {
  const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;
  return `${base}${path}`;
}

/**
 * JSON Schema keywords `output_config.format` does not support, removed recursively.
 *
 * **This is not defensive tidying — the planner's own schema carries one of them.**
 * `AgentPlanSchema.schema()` puts `minItems: 1` on `steps` (`Sources/MacAgentCore/AgentPlan.swift`),
 * and structured outputs reject complex array constraints, so an unpruned schema would `400` on
 * every single plan request rather than on some unusual one.
 *
 * §4.2 is what makes pruning the right answer rather than a liberty: "The server maps it to
 * whichever structured-output mechanism the chosen provider has" — mapping includes dropping what
 * this mechanism cannot express. Nothing is lost, because the client validates the result strictly
 * either way: `AgentPlanDecoder.decodeStrict` is where `steps` being non-empty is actually enforced,
 * and it runs on the answer whichever provider produced it. The official SDKs do exactly this and
 * then validate client-side; this gateway's client already validated client-side before any of it
 * existed.
 */
const UNSUPPORTED_SCHEMA_KEYWORDS = new Set([
  "minimum",
  "maximum",
  "exclusiveMinimum",
  "exclusiveMaximum",
  "multipleOf",
  "minLength",
  "maxLength",
  "pattern",
  "minItems",
  "maxItems",
  "uniqueItems",
  "minProperties",
  "maxProperties",
]);

/**
 * The client's JSON Schema, in the subset `output_config.format` accepts.
 *
 * Three transformations, all of them the mapping §4.2 delegates here.
 *
 * 1. **Unsupported keywords go**, per the set above.
 * 2. **A type *union* becomes an `anyOf`** — see `withoutTypeUnions` below. This one is not
 *    cosmetic: the plan schema carries 27 of them and a type array is not a documented form.
 * 3. **Every object node is given `additionalProperties: false`** — structured outputs require it
 *    and accept no other value, and a node that omitted it would be refused. Our own schemas
 *    already set it everywhere, so this is a floor rather than a rewrite.
 */
export function prunedSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(prunedSchema);
  if (typeof schema !== "object" || schema === null) return schema;

  const source = schema as Record<string, unknown>;
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(source)) {
    if (UNSUPPORTED_SCHEMA_KEYWORDS.has(key)) continue;
    result[key] = prunedSchema(value);
  }
  if (result["type"] === "object" || typeof result["properties"] === "object") {
    result["additionalProperties"] = false;
  }
  return withoutTypeUnions(result);
}

/**
 * `{"type": ["string", "null"]}` becomes `{"anyOf": [{"type":"string"}, {"type":"null"}]}`.
 *
 * **The plan schema is made of these and the branch shipped without noticing** (PR #143, F9).
 * `AgentPlanSchema.schema()` carries **53** type-union nodes once serialized — counted by walking
 * `test/fixtures/agent-plan-schema.json`, which is that schema checked in — because almost every
 * optional step field is spelled `["string","null"]` and `stepSchema` is embedded twice, for `steps`
 * and for the nested `routineSteps`. (The *source* has 27 occurrences,
 * `grep -c '"type": [' Sources/MacAgentCore/AgentPlan.swift`, which is the figure PR #143's F9
 * quoted; the wire figure is the one this function has to survive.) Anthropic's structured-output subset documents the scalar types and `anyOf`;
 * a type *array* is not among the documented forms, so on the reading that it is unsupported,
 * **every** plan request served by Anthropic would have `400`ed and the shipped default chain's
 * second entry would have been dead on arrival — a failure no test could see, because no test ran
 * the real schema through this function and there is no live round in this branch.
 *
 * Converting is the safe direction whichever way that reading goes: `anyOf` is documented, the two
 * spellings are semantically identical in JSON Schema, and a provider that accepted the union would
 * accept the `anyOf` too. So this costs nothing if the union was fine and saves the route if it was
 * not.
 *
 * **The sibling keywords ride along deliberately.** `mediaProvider` is
 * `{"type":["string","null"], "enum":[...,null], "description":"…"}`, and splitting the type without
 * the `enum` would widen what the model may return on that field. Everything other than `type` stays
 * on the parent, where it constrains both branches — which is what the union spelling meant.
 *
 * **What this does not handle, and why it is a note rather than a branch** (PR #143, cycle 2's
 * closing observation). `anyOf` is written unconditionally, so a node carrying *both* a `type` array
 * and an `anyOf` of its own would lose the second. No schema this gateway serves has such a node —
 * the plan schema's 53 unions produce 53 `anyOf`s and contribute none of their own, which
 * `test/anthropic.test.ts` asserts as a count rather than leaving to inspection — so the case is
 * unreachable today and merging the two correctly (an `allOf` of both) is speculative machinery for
 * a shape nobody sends. It is written down here instead, because the failure would be silent: a
 * constraint quietly dropped from a request, visible only as a model returning something it should
 * not have been allowed to. A client schema that ever grows one starts here.
 */
function withoutTypeUnions(node: Record<string, unknown>): Record<string, unknown> {
  const type = node["type"];
  if (!Array.isArray(type)) return node;
  // A one-element array is a union of one; unwrap rather than wrap it in a pointless `anyOf`.
  if (type.length === 1) return { ...node, type: type[0] };
  const { type: _dropped, ...rest } = node;
  return { ...rest, anyOf: type.map((member) => ({ type: member })) };
}

/**
 * The model's text out of a Messages reply: the first non-empty `text` block.
 *
 * With `output_config.format` set, that block is the JSON the schema describes, so it is exactly
 * what `output_text` means on the wire — the model's text, handed to the client's own decoder
 * unmodified. Thinking blocks, when the model produces them, are a different `type` and are skipped
 * rather than concatenated; a summary of the model's reasoning is not the answer and would fail the
 * client's strict decode.
 */
function outputText(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const content = (body as { content?: unknown }).content;
  if (!Array.isArray(content)) return null;
  for (const block of content) {
    if (typeof block !== "object" || block === null) continue;
    const record = block as Record<string, unknown>;
    if (record["type"] !== "text") continue;
    const text = record["text"];
    if (typeof text === "string" && text.length > 0) return text;
  }
  return null;
}

function stopReason(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const reason = (body as { stop_reason?: unknown }).stop_reason;
  return typeof reason === "string" ? reason : null;
}

export function makeAnthropicTextAdapter(
  settings: AnthropicSettings,
): (request: TextRequest) => Promise<TextResult> {
  return async (request) => {
    // §4.2: the text is forwarded, never edited, re-wrapped or re-ordered — it carries row I's
    // TRUSTED_USER_INSTRUCTION / UNTRUSTED_OBSERVED_CONTENT boundaries. The Messages API takes
    // system content in its own top-level field rather than as a message, so the system messages
    // are joined in order with a blank line and every user message keeps its place; no text is
    // rewritten and no ordering within either group changes.
    const system = request.messages
      .filter((message) => message.role === "system")
      .map((message) => message.text)
      .join("\n\n");
    const messages = request.messages
      .filter((message) => message.role === "user")
      .map((message) => ({ role: "user", content: [{ type: "text", text: message.text }] }));

    // A body with no user message is one the API refuses; the client always sends one, and the
    // route's own schema requires at least one message, so this is the honest failure rather than a
    // guess at what the caller meant.
    if (messages.length === 0) {
      throw new ProviderRejected("anthropic requires at least one user message");
    }

    const effort =
      request.reasoningEffort !== undefined && EFFORT_LEVELS.has(request.reasoningEffort)
        ? request.reasoningEffort
        : undefined;

    const body = {
      model: settings.textModel,
      max_tokens: settings.maxOutputTokens,
      ...(system.length > 0 ? { system } : {}),
      messages,
      output_config: {
        ...(effort === undefined ? {} : { effort }),
        // §4.2's "whichever structured-output mechanism the chosen provider has", for this one.
        // `response_schema_name` is not sent: this mechanism takes the schema and no name, unlike
        // the Responses API's `text.format`, and unlike a tool-use mapping which would need one.
        format: { type: "json_schema", schema: prunedSchema(request.responseSchema) },
      },
    };

    let response: Response;
    try {
      response = await fetch(endpoint(settings, "/messages"), {
        method: "POST",
        headers: {
          "x-api-key": activeKey(settings),
          "anthropic-version": ANTHROPIC_VERSION,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "anthropic");
    }

    if (!response.ok) {
      // The provider's own body is deliberately not read into the thrown message, for the reason
      // `openai.ts` gives: §7.1 makes `message` a field the support lookup reads, and a provider
      // error body can carry the request back verbatim — which on these routes is the user's own
      // command.
      throw upstreamStatusError(response.status, "anthropic");
    }

    const parsed: unknown = await readJSONBody(response, "anthropic");

    // Two `stop_reason`s mean the answer is not usable, and both are refusals rather than outages:
    // a retry hits the same safety classifier or the same output ceiling. `refusal` is the model
    // declining; `max_tokens` is a truncated body that would fail the client's strict decode with a
    // parse error that says nothing about why.
    const reason = stopReason(parsed);
    if (reason === "refusal") {
      throw new ProviderRejected("anthropic declined this request");
    }
    if (reason === "max_tokens") {
      throw new ProviderRejected("anthropic stopped at the output ceiling");
    }

    const text = outputText(parsed);
    if (text === null) {
      throw new ProviderRejected("anthropic answered without text output");
    }

    // Anthropic reports `input_tokens` and `output_tokens` and no total, so `total_tokens` stays
    // null rather than being summed here — `source` says `"reported"`, and a number this server
    // added is not one the provider reported. `AIUsageRecord` on the Mac has always allowed a nil
    // total.
    return { outputText: text, usage: reportedTokenUsage(parsed) ?? estimatedTextUsage(request.messages, text) };
  };
}
