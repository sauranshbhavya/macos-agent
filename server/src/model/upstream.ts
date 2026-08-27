/**
 * The seam between this gateway and whichever model provider serves a route (SONNY-130).
 *
 * **This seam is the whole point of the row.** `docs/sonny-backend-api-contract.md` §4.2 states it
 * from the client's side — "the client does not know which mechanism was used and must not need
 * to" — and SONNY-130's sixth requirement states the consequence: model identifiers, endpoints and
 * provider choice live here, which is what turns SONNY-110's move to a paid zero-retention route
 * into a configuration change rather than an app release.
 *
 * Three operations, not one, because the three have genuinely different shapes: text in and text
 * out under a named JSON schema, audio in and a transcript out, a query in and ranked links out. A
 * single `call(provider, payload)` would be a union type pretending to be an abstraction.
 *
 * **Deliberately thin, the same way `auth/provider.ts` is.** No retries, no caching, no policy. The
 * client retries per §9.3, and it is the only side that knows whether the operation is still worth
 * anything to the user.
 */

/** The provider could not be reached, or answered in a way that says "try again" (§7.2 case 5). */
export class ProviderUnavailable extends Error {}

/** The provider did not answer inside the route's upstream deadline (§7.2 case 5a). */
export class ProviderTimedOut extends Error {}

/**
 * The provider understood the request and refused it (§7.2 case 5b).
 *
 * Distinct from `ProviderUnavailable` because the client's behaviour differs and §9.3 makes the
 * difference explicit: `provider.rejected` is not retryable, and a retry is guaranteed to fail
 * identically. Mapping a refusal to `unavailable` would put the client into a retry loop against a
 * wall that has already answered.
 */
export class ProviderRejected extends Error {}

/**
 * **`UpstreamRequestTooLarge` stood here and is gone** (PR #139, F11). It was thrown by one branch
 * on `/v1/transcriptions`, checking the audio part against the same number `bodyLimit` already
 * bounds the whole request by — which a part can never exceed, so the branch could not fire. Every
 * oversize body on these four routes is refused before a handler runs, and `errors.ts` maps
 * Fastify's own 413 onto §7.2's `request.too_large`. A route that one day needs a size refusal of
 * its own — one derived from something other than the body's length — reintroduces a typed error
 * then, with a call site that can reach it.
 */

/** Token counts as the contract's §4.2 `usage` block carries them. */
export interface UpstreamUsage {
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly totalTokens: number | null;
  readonly audioDurationSeconds: number | null;
  /**
   * `"reported"` when the provider gave the numbers, `"estimated"` when this server derived them.
   *
   * §4.2: "The server estimates only when the provider reported nothing, and says which it did."
   * The client renders the distinction — `AIUsageTokenSource` has carried it since long before the
   * gateway — so a summary can say which of its numbers are measured.
   */
  readonly source: "reported" | "estimated";
}

/** One message on a text route. §4.2: ordered, role-tagged, forwarded verbatim. */
export interface UpstreamMessage {
  readonly role: "system" | "user";
  readonly text: string;
}

export interface TextRequest {
  readonly messages: readonly UpstreamMessage[];
  /** §4.2: a short stable identifier for the schema. Never rendered; used by adapters that need it. */
  readonly responseSchemaName: string;
  /** §4.2: a JSON Schema. The adapter maps it to the provider's structured-output mechanism. */
  readonly responseSchema: unknown;
  /** Advisory. A provider with no equivalent ignores them (§4.2). */
  readonly reasoningEffort: string | undefined;
  readonly verbosity: string | undefined;
  readonly signal: AbortSignal;
}

export interface TextResult {
  /** The model's text, unmodified. Parsing stays client-side (§4.2). */
  readonly outputText: string;
  readonly usage: UpstreamUsage;
}

export interface TranscriptionRequest {
  readonly audio: Buffer;
  readonly filename: string;
  readonly contentType: string;
  readonly signal: AbortSignal;
}

export interface TranscriptionResult {
  readonly text: string;
  readonly usage: UpstreamUsage;
}

export interface SearchRequest {
  readonly query: string;
  /** Already clamped to §4.3's 1–20 by the route. */
  readonly maxResults: number;
  readonly signal: AbortSignal;
}

export interface SearchResultItem {
  readonly title: string;
  readonly url: string;
  readonly snippet: string | null;
}

/**
 * Search's own result object, so all three operations return an object rather than two objects and
 * an array (SONNY-132).
 *
 * The array shape was fine while nothing else travelled beside the items. `Routed` below adds
 * `served` to whatever an adapter returns, and an intersection of an array type with an object is
 * a shape TypeScript accepts and nobody should have to read.
 */
export interface SearchResult {
  readonly items: readonly SearchResultItem[];
}

/**
 * Which provider actually served a request, and which were tried and could not (SONNY-132).
 *
 * **Server-side only, and the contract says so twice.** §4.2: "The response names no provider and
 * no model." §11's metering event carries a `provider` column — "Which provider actually served it.
 * Required for failover accounting (SONNY-132) and never returned to the client". So this rides
 * back to the route handler, which logs it; SONNY-133 is what records it on the event. Nothing here
 * reaches a response body, and `test/routing.test.ts` asserts that on the bytes.
 *
 * `failedOver` is empty on the ordinary path, which is the case worth keeping cheap: a request the
 * primary served allocates one empty array and says exactly that.
 */
export interface ProviderAttribution {
  readonly provider: string;
  readonly failedOver: readonly string[];
}

/**
 * An adapter's result plus the attribution the router adds to it.
 *
 * The split is deliberate: an adapter does not name itself. `makeOpenAITextAdapter` returns a
 * `TextResult` and knows nothing about routing, chains or failover, so the same adapter is correct
 * whether it is a route's only provider or the third one tried. The router owns the name because
 * the router is what chose it.
 */
export type Routed<T> = T & { readonly served: ProviderAttribution };

/**
 * The three upstream operations the four routes need.
 *
 * One interface rather than three, because a deployment configures one set of adapters and the
 * routes read them by name. `undefined` is how "this deployment has no credential for that
 * provider" arrives, and **the route is mounted anyway** — it answers `502 provider.unavailable`.
 *
 * **This comment said `buildApp` refuses to mount such a route, which is the opposite of what
 * `app.ts` does** (PR #139, F4). Mounting unconditionally is the deliberate choice and
 * `model/providers.ts` carries the reasoning: the route table then does not change shape with the
 * environment, where the alternative is a `404 resource.not_found` — a code the client reads as "no
 * such route", does not retry, and cannot explain — standing in for a deployment missing a key.
 */
export interface ModelProviders {
  readonly plan: RoutedTextAdapter | undefined;
  readonly synthesize: RoutedTextAdapter | undefined;
  readonly transcription:
    | ((request: TranscriptionRequest) => Promise<Routed<TranscriptionResult>>)
    | undefined;
  readonly search: ((request: SearchRequest) => Promise<Routed<SearchResult>>) | undefined;
}

/**
 * **`text` was one entry serving both text routes and is now two** (SONNY-132).
 *
 * §4.2 gives `/v1/plan` and `/v1/research/synthesize` one body shape, and says why: "Keeping them
 * one shape across two paths is what lets the server hold one adapter per provider instead of one
 * per route, while still routing, metering and pricing them separately." One *adapter* per
 * provider, and separate *routing* — which a single `text` entry cannot express, because the two
 * routes would then share one provider chain and `MODEL_ROUTE_SYNTHESIZE` could not mean anything.
 * The adapters are still one per provider: `modelProvidersFrom` builds `makeOpenAITextAdapter` once
 * per chain that names it, from the same settings, and the two entries below differ only in which
 * chain they walked.
 */
export type RoutedTextAdapter = (request: TextRequest) => Promise<Routed<TextResult>>;

/**
 * What one provider's adapter looks like, before the router wraps it.
 *
 * Named so `model/routing.ts` can talk about "a text adapter" without importing four types, and so
 * the difference between an adapter and a routed adapter is visible in the type rather than only in
 * the prose above.
 */
export type TextAdapter = (request: TextRequest) => Promise<TextResult>;
export type TranscriptionAdapter = (request: TranscriptionRequest) => Promise<TranscriptionResult>;
export type SearchAdapter = (request: SearchRequest) => Promise<SearchResult>;

/**
 * A rough token count for a body the provider reported nothing for.
 *
 * **Four characters to a token, and it agrees with the Mac app's own estimator by construction**
 * (`AIUsageEstimator.estimateTextTokens`, `Sources/MacAgentCore/TaskUsage.swift`). That estimator
 * is what produced the app's `estimated` numbers before this gateway existed, so keeping the same
 * arithmetic here means a user's usage summary does not step when their traffic moves behind the
 * backend — which is the exact shape of silent regression SONNY-130's fifth requirement is about.
 *
 * It is an estimate and is labelled one on the wire. Nothing bills off it: metering is SONNY-133's
 * and reads the provider's own numbers.
 */
export function estimateTextTokens(text: string): number {
  const trimmed = text.trim();
  if (trimmed.length === 0) return 0;
  return Math.max(1, Math.ceil(trimmed.length / 4));
}

/**
 * Translate a `fetch` failure into this seam's vocabulary.
 *
 * An aborted fetch is the deadline firing, and it must not read as "the provider is down": §7.2
 * separates `provider.timeout` from `provider.unavailable` because the client retries the first
 * once and the second with backoff. Everything else that stops a fetch — DNS, TLS, a refused
 * connection — is genuinely "could not reach it".
 */
export function upstreamTransportError(error: unknown, provider: string): Error {
  if (error instanceof DOMException && error.name === "AbortError") {
    return new ProviderTimedOut(`${provider} did not answer within the route's upstream deadline`);
  }
  if (error instanceof Error && error.name === "TimeoutError") {
    return new ProviderTimedOut(`${provider} did not answer within the route's upstream deadline`);
  }
  return new ProviderUnavailable(`${provider} could not be reached`);
}

/**
 * Which of the two provider failures an HTTP status from a provider is.
 *
 * `429` sits on the unavailable side deliberately. It is the provider rate-limiting *this gateway*,
 * which is a fact about our account and not about the user's request — so it is retryable, and it
 * must never surface as `limit.rate`, which §7.2 defines as the *user's* own limit and which
 * SONNY-133 will raise. Telling a user they are over their limit because our upstream account is
 * would be a lie the app renders in the user's own words.
 */
export function upstreamStatusError(status: number, provider: string): Error {
  if (status === 408 || status === 504) {
    return new ProviderTimedOut(`${provider} answered ${status}`);
  }
  if (status === 429 || status >= 500) {
    return new ProviderUnavailable(`${provider} answered ${status}`);
  }
  return new ProviderRejected(`${provider} answered ${status}`);
}

/**
 * A provider's own reported token counts, or `null` when it said nothing.
 *
 * **One reader for three providers, and the alias list is the reason it is shared** (SONNY-132).
 * The Responses API says `input_tokens` / `output_tokens`; Chat Completions — which is the dialect
 * Cerebras speaks — says `prompt_tokens` / `completion_tokens`; Anthropic's Messages API says
 * `input_tokens` / `output_tokens` and reports no total at all. Three near-identical readers is
 * three places for one of them to quietly stop matching a provider's block.
 *
 * The aliases are exactly the ones `AIUsagePayloadParser.tokenCounts` on the Mac already accepts
 * (`Sources/MacAgentCore/TaskUsage.swift`), which matters for the same reason `estimateTextTokens`
 * agrees with the Mac's estimator: a user's usage summary must not step when their traffic moves
 * between providers.
 *
 * Tolerant on purpose. Usage is telemetry read beside the answer, and a provider that changes the
 * block's shape must not turn a good plan into a failed request. A missing total stays `null`
 * rather than being derived from the other two — `source` says `"reported"`, and a number this
 * server added is not one the provider reported.
 */
export function reportedTokenUsage(body: unknown): UpstreamUsage | null {
  if (typeof body !== "object" || body === null) return null;
  const usage = (body as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return null;
  const record = usage as Record<string, unknown>;
  const read = (...names: readonly string[]): number | null => {
    for (const name of names) {
      const value = record[name];
      if (typeof value === "number" && Number.isFinite(value)) return value;
    }
    return null;
  };
  const inputTokens = read("input_tokens", "prompt_tokens");
  const outputTokens = read("output_tokens", "completion_tokens");
  const totalTokens = read("total_tokens");
  if (inputTokens === null && outputTokens === null && totalTokens === null) return null;
  return {
    inputTokens,
    outputTokens,
    totalTokens,
    audioDurationSeconds: null,
    source: "reported",
  };
}

/**
 * Token counts this server derived, for a provider that reported none.
 *
 * The arithmetic was written out at each of the three text adapters and is one function because it
 * is one rule: estimate the input from what was sent, the output from what came back, and label the
 * result `"estimated"` so §4.2's `usage.source` stays honest about which numbers are measured.
 */
export function estimatedTextUsage(
  messages: readonly UpstreamMessage[],
  outputText: string,
): UpstreamUsage {
  const inputTokens = messages.reduce((sum, message) => sum + estimateTextTokens(message.text), 0);
  const outputTokens = estimateTextTokens(outputText);
  return {
    inputTokens,
    outputTokens,
    totalTokens: inputTokens + outputTokens,
    audioDurationSeconds: null,
    source: "estimated",
  };
}
