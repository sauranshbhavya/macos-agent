import {
  providerErrorDetail,
  estimateTextTokens,
  ProviderRejected,
  readJSONBody,
  upstreamStatusError,
  upstreamTransportError,
  type TranscriptionRequest,
  type TranscriptionResult,
  type UpstreamUsage,
} from "./upstream.js";

/**
 * The OpenAI transcription adapter, behind `POST /v1/transcriptions`. The V2 agents call OpenAI
 * through `agent/model/adapter.ts`.
 */

export interface OpenAISettings {
  /** Newest first; index 0 serves new requests (`config.ts`, `ProviderCredentials`). */
  readonly keys: readonly string[];
  /** `https://api.openai.com/v1` by default. */
  readonly baseUrl: string;
  /** The model transcription asks for. Never sent to, or named by, the client. */
  readonly transcriptionModel: string;
}

/**
 * The key new requests use. Only index 0 is ever sent; the later entries exist for the rotation
 * `config.ts` describes.
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
 * Transcription's own `usage` block.
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

    if (!response.ok) {
      // The status goes on the thrown message and the body travels only on the error's `detail`: a
      // provider error body can echo the request back, and here the request is the user's voice.
      throw upstreamStatusError(response.status, "openai", await providerErrorDetail(response));
    }

    const parsed: unknown = await readJSONBody(response, "openai");
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
