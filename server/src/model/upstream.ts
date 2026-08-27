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
  readonly text: ((request: TextRequest) => Promise<TextResult>) | undefined;
  readonly transcription:
    | ((request: TranscriptionRequest) => Promise<TranscriptionResult>)
    | undefined;
  readonly search: ((request: SearchRequest) => Promise<readonly SearchResultItem[]>) | undefined;
}

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
