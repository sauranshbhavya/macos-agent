import {
  estimateTextTokens,
  ProviderRejected,
  upstreamStatusError,
  upstreamTransportError,
  type TextRequest,
  type TextResult,
  type TranscriptionRequest,
  type TranscriptionResult,
  type UpstreamUsage,
} from "./upstream.js";

/**
 * The OpenAI adapter: the text routes (`/v1/plan`, `/v1/research/synthesize`) and transcription.
 *
 * **Everything provider-shaped in this repository's request path now lives in this file and
 * `tavily.ts`.** Before SONNY-130 the same three facts — the endpoint, the model identifier and the
 * key — sat in four Swift initializers on the user's Mac, read from the user's own environment. The
 * move is the whole ticket, and the property it buys is stated in `upstream.ts`: the wire shape
 * below can be replaced without any app release, which is what SONNY-110 needs.
 *
 * **The request bodies are the ones the Mac used to build, and that is deliberate rather than
 * incidental.** `docs/sonny-backend-api-contract.md` §4.2 requires the server to forward message
 * text without editing, re-wrapping or re-ordering it — because the text carries
 * `TRUSTED_USER_INSTRUCTION` / `UNTRUSTED_OBSERVED_CONTENT` boundaries that row I's prompt-injection
 * defence depends on, and a server that reflowed them would silently dissolve that defence a long
 * way from where anyone would look for it.
 */

export interface OpenAISettings {
  /** Newest first; index 0 serves new requests (`config.ts`, `ProviderCredentials`). */
  readonly keys: readonly string[];
  /** `https://api.openai.com/v1` by default. Configurable so SONNY-110 is a redeploy. */
  readonly baseUrl: string;
  /** The model the text routes ask for. Never sent to, or named by, the client. */
  readonly textModel: string;
  /** The model transcription asks for. Same rule. */
  readonly transcriptionModel: string;
}

/**
 * The key new requests use.
 *
 * Only index 0 is ever *sent*. The later entries exist for the rotation `config.ts` describes —
 * they stay configured so an in-flight deploy is never without a working credential — and this
 * gateway has nothing to do with them beyond not being the reason they are there.
 */
function activeKey(settings: OpenAISettings): string {
  const key = settings.keys[0];
  if (key === undefined) throw new Error("openai adapter constructed with no credential");
  return key;
}

function endpoint(settings: OpenAISettings, path: string): string {
  const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;
  return `${base}${path}`;
}

/**
 * `usage` from a Responses API reply, or `null` when it said nothing.
 *
 * Tolerant on purpose: usage is telemetry read beside the answer, and a provider that changes the
 * block's shape must not turn a good plan into a failed request. The same tolerance the Mac's
 * `AIUsagePayloadParser` has, for the same reason.
 */
function reportedTokenUsage(body: unknown): UpstreamUsage | null {
  if (typeof body !== "object" || body === null) return null;
  const usage = (body as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return null;
  const read = (name: string): number | null => {
    const value = (usage as Record<string, unknown>)[name];
    return typeof value === "number" && Number.isFinite(value) ? value : null;
  };
  const inputTokens = read("input_tokens");
  const outputTokens = read("output_tokens");
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
 * The model's text out of a Responses API reply.
 *
 * Mirrors `OpenAIResponseParser.outputText` on the Mac, which is the parser this route replaced:
 * the flattened `output_text` when the provider supplies it, otherwise the first non-empty text
 * part of the structured `output` array. Kept deliberately identical so a reply that used to
 * produce a plan still produces one — a divergence here would look like the model changing.
 */
function outputText(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const record = body as Record<string, unknown>;
  const direct = record["output_text"];
  if (typeof direct === "string" && direct.length > 0) return direct;

  const output = record["output"];
  if (!Array.isArray(output)) return null;
  for (const item of output) {
    if (typeof item !== "object" || item === null) continue;
    const content = (item as Record<string, unknown>)["content"];
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (typeof part !== "object" || part === null) continue;
      const text = (part as Record<string, unknown>)["text"];
      if (typeof text === "string" && text.length > 0) return text;
    }
  }
  return null;
}

export function makeOpenAITextAdapter(
  settings: OpenAISettings,
): (request: TextRequest) => Promise<TextResult> {
  return async (request) => {
    const body = {
      model: settings.textModel,
      input: request.messages.map((message) => ({
        role: message.role,
        content: [{ type: "input_text", text: message.text }],
      })),
      ...(request.reasoningEffort === undefined
        ? {}
        : { reasoning: { effort: request.reasoningEffort } }),
      text: {
        ...(request.verbosity === undefined ? {} : { verbosity: request.verbosity }),
        // §4.2: "The server maps it to whichever structured-output mechanism the chosen provider
        // has." This is that mapping for this provider, and `strict` is the server's call rather
        // than a client field — a client that could turn strictness off would be a client that can
        // widen what the model may return, on a route whose output is decoded strictly downstream.
        format: {
          type: "json_schema",
          name: request.responseSchemaName,
          strict: true,
          schema: request.responseSchema,
        },
      },
    };

    let response: Response;
    try {
      response = await fetch(endpoint(settings, "/responses"), {
        method: "POST",
        headers: {
          authorization: `Bearer ${activeKey(settings)}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "openai");
    }

    if (!response.ok) {
      // The provider's own body is deliberately not read into the thrown message. §7.1 makes
      // `message` a field the support lookup reads, and a provider error body can carry the
      // request back verbatim — which on these routes is the user's own command.
      throw upstreamStatusError(response.status, "openai");
    }

    const parsed: unknown = await response.json().catch(() => null);
    const text = outputText(parsed);
    if (text === null) {
      // A 2xx whose body holds no text is the provider answering something this adapter cannot
      // use. `rejected` rather than `unavailable`: a retry produces the same unreadable reply.
      throw new ProviderRejected("openai answered without text output");
    }

    const reported = reportedTokenUsage(parsed);
    if (reported !== null) return { outputText: text, usage: reported };

    const inputTokens = request.messages.reduce(
      (sum, message) => sum + estimateTextTokens(message.text),
      0,
    );
    const outputTokens = estimateTextTokens(text);
    return {
      outputText: text,
      usage: {
        inputTokens,
        outputTokens,
        totalTokens: inputTokens + outputTokens,
        audioDurationSeconds: null,
        source: "estimated",
      },
    };
  };
}

/**
 * Transcription's own `usage` block, which is a different shape from the text routes'.
 *
 * The provider reports one of two forms and says which: `{type: "tokens", input_tokens, …}` or
 * `{type: "duration", seconds}`. The contract's response carries both possibilities in one block
 * (§4.4), because `AIUsageRecord` on the Mac already has a field for each and the local summary
 * sums them separately.
 */
function transcriptionUsage(body: unknown, text: string): UpstreamUsage {
  const estimated: UpstreamUsage = {
    inputTokens: null,
    outputTokens: estimateTextTokens(text),
    totalTokens: estimateTextTokens(text),
    audioDurationSeconds: null,
    source: "estimated",
  };
  if (typeof body !== "object" || body === null) return estimated;
  const usage = (body as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return estimated;
  const record = usage as Record<string, unknown>;

  const seconds = record["seconds"];
  if (typeof seconds === "number" && Number.isFinite(seconds)) {
    return {
      inputTokens: null,
      outputTokens: null,
      totalTokens: null,
      audioDurationSeconds: seconds,
      source: "reported",
    };
  }

  const read = (name: string): number | null => {
    const value = record[name];
    return typeof value === "number" && Number.isFinite(value) ? value : null;
  };
  const inputTokens = read("input_tokens");
  const outputTokens = read("output_tokens");
  const totalTokens = read("total_tokens");
  if (inputTokens === null && outputTokens === null && totalTokens === null) return estimated;
  return {
    inputTokens,
    outputTokens,
    totalTokens,
    audioDurationSeconds: null,
    source: "reported",
  };
}

export function makeOpenAITranscriptionAdapter(
  settings: OpenAISettings,
): (request: TranscriptionRequest) => Promise<TranscriptionResult> {
  return async (request) => {
    const form = new FormData();
    form.append("model", settings.transcriptionModel);
    form.append("response_format", "json");
    form.append(
      "file",
      new Blob([new Uint8Array(request.audio)], { type: request.contentType }),
      request.filename,
    );

    let response: Response;
    try {
      response = await fetch(endpoint(settings, "/audio/transcriptions"), {
        method: "POST",
        // No `content-type` header: `fetch` sets `multipart/form-data` with the boundary it
        // generated. Setting one by hand names a boundary the body does not use.
        headers: { authorization: `Bearer ${activeKey(settings)}` },
        body: form,
        signal: request.signal,
      });
    } catch (error) {
      throw upstreamTransportError(error, "openai");
    }

    if (!response.ok) throw upstreamStatusError(response.status, "openai");

    const parsed: unknown = await response.json().catch(() => null);
    const text =
      typeof parsed === "object" && parsed !== null
        ? (parsed as { text?: unknown }).text
        : undefined;
    if (typeof text !== "string" || text.trim().length === 0) {
      // An empty transcript and a missing one are the same outcome for the user — no words — and
      // the Mac's `TranscriptionError.missingText` already collapsed them. Kept collapsed here so
      // the client sees one typed failure rather than two that mean the same thing.
      throw new ProviderRejected("openai answered without a transcript");
    }
    const trimmed = text.trim();
    return { text: trimmed, usage: transcriptionUsage(parsed, trimmed) };
  };
}
