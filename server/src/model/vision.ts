import { acceptedKeys, type Config } from "../config.js";
import { RESPONSE_LIMIT_BYTES } from "./limits.js";
import {
  ProviderRejected,
  providerErrorDetail,
  upstreamStatusError,
  upstreamTransportError,
  type UpstreamUsage,
} from "./upstream.js";

/**
 * The provider seam for `POST /v1/screen/analyze` — the screen-control route (SONNY-131).
 *
 * **Separate from `ModelProviders` and `providers.ts`, and that is a lane boundary rather than a
 * design preference.** `server/src/model/providers.ts` belongs to SONNY-132's branch, which is
 * running in parallel and reshapes it for the provider router; adding a fifth adapter to the same
 * function would have been two branches editing one decision. The route reads its provider from
 * here instead, `providers.ts` is untouched, and when SONNY-132 lands the two collapse into whatever
 * shape that ticket chooses. Nothing here couples to the four text routes.
 *
 * **What this seam buys is the same thing `upstream.ts` buys the other four**: the model identifier,
 * the vendor endpoint and the provider choice live on this server, so SONNY-110's move to a paid
 * zero-retention route is a redeploy rather than an app release. That is SONNY-131's second scoped
 * requirement, and it is the reason the Mac's client is no longer allowed to name any of the three.
 */

export interface VisionSettings {
  /** Newest first; index 0 serves new requests (`config.ts`, `ProviderCredentials`). */
  readonly keys: readonly string[];
  /** The provider's base URL. Configurable so SONNY-110 is a redeploy. */
  readonly baseUrl: string;
  /** The model the route asks for. Never sent to, or named by, the client. */
  readonly model: string;
}

/**
 * One screen-control request, as the route hands it to a provider.
 *
 * **`imageBase64` is carried encoded rather than decoded, and that is §4.5's first rule expressed as
 * a type.** "The server must not resample, re-encode, crop or rotate the image… Forward the bytes."
 * The coordinate space the model answers in is the client's `SentImageSize`, and a server-side
 * resize would leave every returned coordinate scaled by a factor nothing on the Mac knows about —
 * clicks landing inside the window, plausible-looking, and wrong. Keeping the base64 string the
 * client sent, all the way through to the provider's data URL, means there is no code path here that
 * *could* alter a pixel: the bytes are never decoded into an image at all.
 *
 * The route does decode it once, to count it against §6.1's ceiling, and throws that buffer away.
 */
export interface VisionRequest {
  readonly prompt: string;
  readonly imageBase64: string;
  /** `image/png` or `image/jpeg`. §4.5 rule 2: per-capture, never assumed. */
  readonly imageMediaType: string;
  readonly signal: AbortSignal;
}

export interface VisionResult {
  /** The model's text, unmodified. Parsing stays client-side (§4.2, §1.3). */
  readonly outputText: string;
  /**
   * The provider's own numbers, or `undefined` when it reported none.
   *
   * **`undefined` rather than an estimate, and this is the one place this gateway deliberately
   * differs from the text routes.** `openai.ts` estimates from message text at four characters a
   * token, because on those routes the text *is* the request. On this route the text is a small part
   * of a request whose dominant term is an image, and image token cost is a function of pixel
   * dimensions and the provider's own tiling rule — neither of which this gateway knows. So a
   * text-only estimate here would not be a rough number, it would be a number that omits most of the
   * cost, on the one route the product charges for (screen control is SONNY-17's only paid line).
   *
   * Reporting nothing is the honest answer, and it costs nothing: §4.2's `usage` block is optional
   * on the wire, the Mac's `SonnyWireUsage` is already `Optional`, and `AIUsageRecord` with no token
   * counts still records that the call happened — so a user's per-task summary counts the vision
   * calls it made and reports no token figure it cannot stand behind. SONNY-133's metering reads the
   * provider's own numbers and prices the image from the pixel dimensions §4.5 puts on the wire for
   * exactly that purpose.
   */
  readonly usage: UpstreamUsage | undefined;
}

export type VisionProvider = (request: VisionRequest) => Promise<VisionResult>;

/**
 * The key new requests use.
 *
 * Only index 0 is ever *sent*. The later entries exist for the rotation `config.ts` describes — they
 * stay configured so an in-flight deploy is never without a working credential.
 */
function activeKey(settings: VisionSettings): string {
  const key = settings.keys[0];
  if (key === undefined) throw new Error("vision adapter constructed with no credential");
  return key;
}

function endpoint(settings: VisionSettings, path: string): string {
  const base = settings.baseUrl.endsWith("/") ? settings.baseUrl.slice(0, -1) : settings.baseUrl;
  return `${base}${path}`;
}

/**
 * `usage` from a Responses API reply, or `null` when it said nothing.
 *
 * Tolerant on purpose, the same way `openai.ts`' is: usage is telemetry read beside the answer, and a
 * provider that changes the block's shape must not turn a working screen-control iteration into a
 * failed one — which on this route would end a session the user is watching.
 */
function reportedTokenUsage(body: unknown): UpstreamUsage | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const usage = (body as { usage?: unknown }).usage;
  if (typeof usage !== "object" || usage === null) return undefined;
  const read = (name: string): number | null => {
    const value = (usage as Record<string, unknown>)[name];
    return typeof value === "number" && Number.isFinite(value) ? value : null;
  };
  const inputTokens = read("input_tokens");
  const outputTokens = read("output_tokens");
  const totalTokens = read("total_tokens");
  if (inputTokens === null && outputTokens === null && totalTokens === null) return undefined;
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
 * Byte-for-byte the rule `openai.ts` uses, which is itself the rule `OpenAIResponseParser` used on
 * the Mac: the flattened `output_text` when the provider supplies it, otherwise the first non-empty
 * text part of the structured `output` array. **The Mac still parses the result** — the string this
 * returns goes to `VisionDecisionParser` unchanged (§1.3) — so what this function does is find the
 * text, never interpret it.
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

/**
 * Read a provider reply, refusing one over §6.3's ceiling before it is parsed.
 *
 * **The point is the allocation, so the check has to come before the parse.** §6.3 exists so "an
 * unexpected provider reply cannot become an unbounded client-side allocation", and reading the whole
 * body and *then* measuring it would do the allocating this is meant to prevent — on this server
 * rather than on the Mac, which is no better. `Content-Length` is checked first when the provider
 * sent one, and the streamed read is capped either way, because a chunked reply carries no length to
 * believe.
 *
 * `ProviderRejected` and not `ProviderUnavailable`, on the precedent `openai.ts` already sets for a
 * 2xx whose body it cannot use: a retry produces the same unusable reply, so §9.3 must not send the
 * client back for it.
 */
async function readBoundedJSON(response: Response, limit: number): Promise<unknown> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) {
    throw new ProviderRejected(`vision provider answered ${declared} bytes, over the ${limit} cap`);
  }
  const body = response.body;
  if (body === null) return null;

  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        throw new ProviderRejected(`vision provider answered over the ${limit}-byte cap`);
      }
      chunks.push(value);
    }
  } finally {
    // Released as hygiene, and **not because it gets the connection reused** — the sentence that
    // stood here said it did, read as a measurement, and was not one (PR #144, F5). The reviewer
    // measured the two arms against a control on Node v22.23.1, four sequential `fetch`es to a
    // loopback server counting `connection` events: body fully read, **2 connections**; abandoned at
    // a cap with `releaseLock()` alone, **4**; abandoned at a cap with `reader.cancel()` first,
    // **6**. So this arm is about one socket per request, which is the state the old comment claimed
    // to avoid — and the obvious "fix" is worse, which is the part worth knowing before anyone
    // reaches for it. Read those as a comparison between the arms rather than as absolute counts:
    // the harness is a loopback `http` server, not this provider path.
    //
    // It stays because an un-released reader is a lock held until GC either way, and this costs
    // nothing. The path is a provider reply over §6.3's cap, which is rare and where a socket is the
    // cheapest thing being spent.
    reader.releaseLock();
  }

  const text = Buffer.concat(chunks).toString("utf8");
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}

/**
 * The screen-control adapter.
 *
 * The request body is the one the Mac used to build for itself, and that is deliberate rather than
 * incidental: §1.3 keeps prompt composition on the client because `VisionSessionPromptBuilder` is a
 * prompt-injection boundary, and rebuilding the prompt here would create the second copy of a
 * security boundary that `.claude/rules/macagentcore-conventions.md` warns about. So the prompt
 * arrives assembled and is forwarded as one `input_text` part.
 */
export function makeVisionAdapter(settings: VisionSettings): VisionProvider {
  return async (request) => {
    const body = {
      model: settings.model,
      input: [
        {
          role: "user",
          content: [
            { type: "input_text", text: request.prompt },
            {
              // The base64 the client sent, spliced into the data URL without a decode-and-re-encode
              // round trip. §4.5 rule 1, and rule 2's media type comes off the request rather than
              // being a literal — the encoder picks PNG or JPEG per capture, so a hardcoded one
              // would mislabel roughly half of real captures.
              type: "input_image",
              image_url: `data:${request.imageMediaType};base64,${request.imageBase64}`,
            },
          ],
        },
      ],
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
      throw upstreamTransportError(error, "vision");
    }

    if (!response.ok) {
      // The body reaches the content store and never the thrown message. §7.1 makes `message` a
      // field the support lookup reads, and a provider error body can echo the request back — which
      // on this route is a prompt describing the user's screen. §10.3 puts it on the content clock
      // instead, where the same `retention` rule governs it as governs the capture it describes.
      throw upstreamStatusError(response.status, "vision", await providerErrorDetail(response));
    }

    const parsed = await readBoundedJSON(response, RESPONSE_LIMIT_BYTES);
    const text = outputText(parsed);
    if (text === null) {
      throw new ProviderRejected("vision provider answered without text output");
    }
    return { outputText: text, usage: reportedTokenUsage(parsed) };
  };
}

/**
 * The provider this deployment serves `/v1/screen/analyze` with, or `undefined` when it holds no
 * credential for one.
 *
 * **An absent credential yields an absent adapter rather than a throw**, and the route is mounted
 * either way — the same decision `providers.ts` records for the four text routes, for the same
 * reason: the route table must not change shape with the environment, because the alternative is a
 * `404 resource.not_found` standing in for a missing key, and a client reads that as "no such route",
 * does not retry, and cannot explain it. An adapterless route answers `502 provider.unavailable`,
 * which is true from the caller's side.
 */
export function visionProviderFrom(config: Config): VisionProvider | undefined {
  const keys = acceptedKeys(config, "vision");
  if (keys.length === 0) return undefined;
  return makeVisionAdapter({
    keys,
    baseUrl: config.visionBaseUrl,
    model: config.visionModel,
  });
}
