/**
 * The seam between this gateway and the providers it calls (SONNY-130): the typed failures, the
 * request and result shapes, and the helpers every adapter shares. The client never names a provider,
 * a model or an endpoint; they are all gateway configuration.
 *
 * **Deliberately thin, the same way `auth/provider.ts` is.** No retries, no caching, no policy.
 */

/**
 * What a provider said when it refused: its status, a bounded copy of its body, and its request id.
 * Carried on the error rather than in its message, so a body that echoes the user's request never
 * becomes the §7.1 `message` a client is shown.
 *
 * `body` is `null` when the response could not be read at all. `providerRequestId` survives
 * independently of it: it is a header, and it is what a vendor support ticket needs.
 */
export interface ProviderErrorDetail {
  readonly status: number;
  readonly body: string | null;
  readonly providerRequestId: string | null;
}

/**
 * The base the three upstream failures share, so a `detail` can ride on any of them.
 *
 * Every existing `new ProviderRejected("…")` still compiles: the detail is optional and absent means
 * "there was no provider response to describe", which is exactly the case for a refusal this gateway
 * decided on its own — an answer with no usable text, a reply over the response cap.
 */
export class UpstreamError extends Error {
  readonly detail: ProviderErrorDetail | undefined;

  constructor(message: string, detail?: ProviderErrorDetail) {
    super(message);
    this.detail = detail;
  }
}

/** The provider could not be reached, or answered in a way that says "try again" (§7.2 case 5). */
export class ProviderUnavailable extends UpstreamError {}

/** The provider did not answer inside the route's upstream deadline (§7.2 case 5a). */
export class ProviderTimedOut extends UpstreamError {}

/**
 * The provider understood the request and refused it (§7.2 case 5b).
 *
 * Distinct from `ProviderUnavailable` because the client's behaviour differs and §9.3 makes the
 * difference explicit: `provider.rejected` is not retryable, and a retry is guaranteed to fail
 * identically. Mapping a refusal to `unavailable` would put the client into a retry loop against a
 * wall that has already answered.
 */
export class ProviderRejected extends UpstreamError {}

/**
 * The headers a provider names its own request id in, in the order they are consulted.
 *
 * Enumerated rather than guessed at from one vendor's spelling: OpenAI and its API-compatible
 * neighbours use `x-request-id`, Anthropic uses `request-id`. A provider that names it something
 * else contributes nothing here and its status and body still travel, which is the direction this
 * should fail in — a missing correlation id is worse diagnostics, never a worse answer.
 */
const REQUEST_ID_HEADERS = ["x-request-id", "request-id", "x-amzn-requestid"] as const;

/**
 * The longest provider error body kept, in characters. Bounded because this runs on the failure path
 * and the body is a third party's.
 */
export const PROVIDER_ERROR_BODY_BYTES = 8192;

/**
 * Read a failed provider response into a `ProviderErrorDetail`, and never throw doing it.
 *
 * **Every failure here answers with a partial detail rather than propagating**, which is the whole
 * contract of this function: it is called from a path that is already reporting an error, and an
 * exception raised while describing one would replace a `502 provider.unavailable` the client knows
 * how to handle with a `500` about this gateway. So a body that cannot be read is `null` beside a
 * status and a request id that are already known.
 */
export async function providerErrorDetail(response: Response): Promise<ProviderErrorDetail> {
  let providerRequestId: string | null = null;
  for (const header of REQUEST_ID_HEADERS) {
    const value = response.headers.get(header);
    if (value !== null && value.trim().length > 0) {
      providerRequestId = value.trim().slice(0, 200);
      break;
    }
  }
  let body: string | null = null;
  try {
    const text = await response.text();
    body = text.length > 0 ? text.slice(0, PROVIDER_ERROR_BODY_BYTES) : null;
  } catch {
    body = null;
  }
  return { status: response.status, body, providerRequestId };
}

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

/** One message of a text call. Ordered, role-tagged, forwarded verbatim. */
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
  /**
   * The most output tokens the provider may produce, when the caller must bound it: the V2 agents
   * size a credit hold by it, so it has to be what the provider enforces too. Undefined keeps each
   * adapter's own ceiling.
   */
  readonly maxOutputTokens?: number;
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

/** Search's result, an object rather than a bare array so `Routed` can add `served` beside the items. */
export interface SearchResult {
  readonly items: readonly SearchResultItem[];
}

/**
 * Which provider actually served a request, and which were tried and could not (SONNY-132).
 *
 * **Server-side only.** §4.2: "The response names no provider and no model." It rides back to the
 * route handler, which logs it and records it on the metering event; nothing here reaches a response
 * body, and `test/provider-router.test.ts` asserts that on the bytes.
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
 * The split is deliberate: an adapter does not name itself and knows nothing about chains or
 * failover, so the same adapter is correct whether it is a route's only provider or the third one
 * tried. The router owns the name because the router is what chose it.
 */
export type Routed<T> = T & { readonly served: ProviderAttribution };

/**
 * The routed operations the gateway serves over HTTP-configured chains: transcription, for
 * `POST /v1/transcriptions`, and search, for the agents' web search tool. `undefined` is how "this
 * deployment has no credential for that provider" arrives; the transcription route is mounted anyway
 * and answers `502 provider.unavailable`.
 */
export interface ModelProviders {
  readonly transcription:
    | ((request: TranscriptionRequest) => Promise<Routed<TranscriptionResult>>)
    | undefined;
  readonly search: ((request: SearchRequest) => Promise<Routed<SearchResult>>) | undefined;
}

/** What one provider's adapter looks like, before the router wraps it. */
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
 * Which of the three provider failures an HTTP status from a provider is.
 *
 * **The line is "is this about our account, or about this request".** A status on the first side is
 * a fact about the gateway's own relationship with a vendor, so another vendor can serve the same
 * request and `withFailover` should try one. A status on the second side is the provider having
 * understood the request and refused it, where §9.3's "a retry is guaranteed to fail identically"
 * holds — and across providers as well as within one, because a refusal is usually about the
 * content, so shopping it elsewhere is routing around an answer rather than resilience.
 *
 * `429` was always on the account side and its reasoning is the whole rule: it is the provider
 * rate-limiting *this gateway*, which is a fact about our account and not about the user's request.
 * It must also never surface as `limit.rate`, which §7.2 defines as the *user's* own limit and which
 * SONNY-133 will raise — telling a user they are over their limit because our upstream account is
 * would be a lie the app renders in the user's own words.
 *
 * **`401`, `402` and `403` moved to the account side** (PR #143, F1), and they had been on the wrong
 * one by exactly the argument the `429` sentence above already made. A revoked or rotated-out key,
 * an account out of credit, an account suspended: every one is a fact about our relationship with
 * that vendor, none is anything the user asked for, and each is among the most likely ways this
 * gateway actually fails. Leaving them as refusals meant an expired `OPENAI_API_KEY` answered
 * `502 provider.rejected` with `retryable: false` on every request while a healthy Anthropic key sat
 * configured and was never called — the exact outcome SONNY-132's third requirement exists to
 * prevent, reached through the most ordinary failure a gateway has.
 *
 * What stays on the request side is what genuinely describes the request: `400`, `404`, `409`,
 * `413`, `422` and the rest of `4xx`. A gateway that failed those over would try every configured
 * vendor with a body all of them will refuse, spending the route's whole deadline to arrive at the
 * same answer more slowly.
 */
export function upstreamStatusError(
  status: number,
  provider: string,
  detail?: ProviderErrorDetail,
): Error {
  if (status === 408 || status === 504) {
    return new ProviderTimedOut(`${provider} answered ${status}`, detail);
  }
  if (status === 401 || status === 402 || status === 403 || status === 429 || status >= 500) {
    return new ProviderUnavailable(`${provider} answered ${status}`, detail);
  }
  return new ProviderRejected(`${provider} answered ${status}`, detail);
}

/**
 * Read a provider's response body as JSON, or fail in the shape the failure actually was.
 *
 * **`await response.json().catch(() => null)` stood at all five call sites and reported a stall as a
 * refusal** (PR #143, F2). `fetch` resolves as soon as headers arrive, so a provider that accepts
 * the connection and then stops sending — the ordinary shape of a bad hour — resolves the fetch and
 * rejects `json()` with an `AbortError` when the route's deadline fires. Swallowed to `null`, that
 * became "answered without text output", which is `ProviderRejected`: `504 provider.timeout` with
 * `retryable: true` reported as `502 provider.rejected` with `retryable: false`, no failover to the
 * healthy second provider, and the user told *"Sonny couldn't do this one."* — the sentence
 * `SonnyBackendCopy` reserves for a retry that would fail identically — over a transient stall.
 * Reproduced by PR #143's reviewer against a local server that writes headers and then stalls;
 * `theStalledProviderProbeShape` in `test/provider-router.test.ts` is that probe as a test.
 *
 * **The distinction this draws, which the swallow could not:** a body that never finished arriving
 * is a transport failure and is retryable — `upstreamTransportError` sorts an abort from a dead
 * socket. A body that arrived complete and is not JSON is an intermediary answering for the
 * provider (a CDN or proxy error page under a `200`, a truncated gateway response), which is also
 * transient and also worth another provider. A body that arrived, parsed, and simply carries no
 * usable answer is the one genuine refusal, and it stays one: each adapter's own
 * `answered without text output` throw is unchanged and is reached only from valid JSON.
 */
export async function readJSONBody(response: Response, provider: string): Promise<unknown> {
  const body = await readJSONBodyOrUnparsed(response, provider);
  if (body === UNPARSEABLE_BODY) {
    // The body arrived complete and is not JSON. On these routes that is an intermediary answering
    // for the provider — a CDN or proxy error page under a `200`, a truncated gateway response —
    // which is transient and worth another provider, so it is `unavailable` rather than a refusal.
    // A body that parses and simply carries no usable answer is the genuine refusal and is each
    // adapter's own throw, unchanged.
    throw new ProviderUnavailable(`${provider} answered with a body that is not JSON`);
  }
  return body;
}

/**
 * "This body is not JSON", as a value distinct from every value `JSON.parse` can return.
 *
 * `null` is a legitimate parse result, so it cannot stand for the failure — the same reason
 * `routes/model.ts` has its own `UNPARSEABLE` symbol for the multipart meta part.
 */
export const UNPARSEABLE_BODY = Symbol("provider body is not JSON");

/**
 * `readJSONBody`'s underlying read, for a caller that treats an unparseable body as an answer: the
 * search adapter reads a malformed body as no results (`tavily.ts` says why). A read that was
 * *aborted* is still a transport failure. The two are told apart by what `json()` rejects with: a
 * `SyntaxError` means the bytes arrived and were not JSON, and anything else means the read did not
 * finish.
 */
export async function readJSONBodyOrUnparsed(
  response: Response,
  provider: string,
): Promise<unknown> {
  try {
    return await response.json();
  } catch (error) {
    if (error instanceof SyntaxError) return UNPARSEABLE_BODY;
    throw upstreamTransportError(error, provider);
  }
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
 * block's shape must not turn a good answer into a failed request. A missing total stays `null`
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
 * The arithmetic was written out at each text adapter and is one function because it
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
