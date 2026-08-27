import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { errorBody } from "../errors.js";
import { BODY_LIMIT_BYTES, DEADLINE_MS } from "../model/limits.js";
import {
  ProviderRejected,
  ProviderTimedOut,
  ProviderUnavailable,
  type ModelProviders,
  type SearchResultItem,
  type UpstreamUsage,
} from "../model/upstream.js";

/**
 * The four credential-bearing text routes (SONNY-130): `/v1/plan`, `/v1/research/synthesize`,
 * `/v1/transcriptions` and `/v1/search`.
 *
 * All four are authenticated — `auth/gate.ts` covers them by *not* listing them in `PUBLIC_ROUTES`,
 * which is the deny-by-default property that file exists for — and none of them reads the caller's
 * account for anything yet. Entitlement checks are SONNY-135's and metering is SONNY-133's; both
 * are non-goals here, and neither is stubbed, because a stub of an entitlement check is a check
 * that has been written and does nothing.
 *
 * **What this ticket deliberately does not do with `retention`.** The field is required and
 * validated on every one of the four (§2.4.2 makes an omitted `retention` a loud `400` rather than
 * a quiet guess, in either direction). What it is *not* is honoured, because this ticket stores no
 * content at all — there is no content store yet, and SONNY-134 builds it along with the rule that
 * §10.1 states: enforced where the storing happens, not at the call site. Validating the field now
 * means the client's half is real and testable from the day it ships; claiming the guarantee now
 * would be claiming a promise nothing keeps.
 */

/** §2.4: required on all five model routes, never defaulted. */
const retentionField = z.enum(["standard", "none"]);
const taskIdField = z.string().trim().min(1).max(200);

/**
 * §4.2's one body shape, shared by the two text routes.
 *
 * `.strict()` is deliberate and is the opposite of §2.1's rule for *responses*. The contract makes
 * the client tolerant of unknown response fields so the server can add them additively; nothing
 * makes the server tolerant of unknown request fields, and it should not be — a field this server
 * silently drops is a client believing it asked for something.
 */
const textBody = z
  .object({
    task_id: taskIdField,
    retention: retentionField,
    messages: z
      .array(
        z
          .object({ role: z.enum(["system", "user"]), text: z.string() })
          .strict(),
      )
      .min(1),
    response_schema_name: z.string().trim().min(1).max(100),
    response_schema: z.record(z.unknown()),
    reasoning_effort: z.string().trim().min(1).max(50).optional(),
    verbosity: z.string().trim().min(1).max(50).optional(),
  })
  .strict();

const searchBody = z
  .object({
    task_id: taskIdField,
    retention: retentionField,
    query: z.string().trim().min(1),
    max_results: z.number().int().optional(),
  })
  .strict();

/** §4.4's `meta` part. The audio arrives as the other part, never as a field in here. */
const transcriptionMeta = z
  .object({ task_id: taskIdField, retention: retentionField })
  .strict();

function usageBody(usage: UpstreamUsage): Record<string, unknown> {
  return {
    input_tokens: usage.inputTokens,
    output_tokens: usage.outputTokens,
    total_tokens: usage.totalTokens,
    audio_duration_seconds: usage.audioDurationSeconds,
    source: usage.source,
  };
}

/**
 * Every upstream failure this route family can produce, as §7.2 names it.
 *
 * **Keyed on the thrown type, never on a status this gateway saw.** §9.3 states the client-side
 * version of the same rule and gives the reason: several statuses carry more than one code with
 * opposite semantics. `provider.rejected` and `provider.unavailable` are both 502 and the client
 * retries exactly one of them.
 */
function sendUpstreamFailure(
  request: FastifyRequest,
  reply: FastifyReply,
  error: unknown,
): FastifyReply {
  // **No `request.too_large` arm here** (PR #139, F11). Every oversize body on these four routes is
  // refused before a handler runs — by `bodyLimit`, or by the multipart parser's own `fileSize` —
  // and `errors.ts` maps Fastify's 413 onto §7.2's code. An arm here would be unreachable.
  if (error instanceof ProviderTimedOut) {
    request.log.info({ err: error }, "upstream timed out");
    return reply.status(504).send(
      errorBody("provider.timeout", "The upstream provider did not answer in time.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderUnavailable) {
    request.log.warn({ err: error }, "upstream unavailable");
    return reply.status(502).send(
      errorBody("provider.unavailable", "The upstream provider could not be reached.", request.id, {
        retryable: true,
      }),
    );
  }
  if (error instanceof ProviderRejected) {
    request.log.warn({ err: error }, "upstream rejected the request");
    return reply.status(502).send(
      errorBody("provider.rejected", "The upstream provider refused this request.", request.id, {
        retryable: false,
      }),
    );
  }
  // Anything else is this gateway's own bug, and §7.2 case 6 makes that a retryable 500. Rethrown
  // rather than answered here, so the root error handler logs it at `error` with the stack.
  throw error;
}

/**
 * Run `work` under the route's total deadline (§12), with an `AbortSignal` bounded by its upstream
 * deadline.
 *
 * **Two deadlines and not one, because they fail in different places.** The signal ends a provider
 * call that is still open. The total-deadline race ends a handler that is stuck anywhere else —
 * parsing a pathological body, an adapter that resolved and then hung. Without the second, §12's
 * "server total deadline" column would be a number nothing enforces, and the failure it describes
 * would arrive as whatever the platform in front does when it gives up, which the client cannot
 * tell apart from a dead network.
 */
async function withDeadlines<T>(
  deadlines: { readonly upstream: number; readonly total: number },
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const upstreamTimer = setTimeout(() => controller.abort(), deadlines.upstream);
  let totalTimer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work(controller.signal),
      new Promise<never>((_resolve, reject) => {
        totalTimer = setTimeout(() => {
          controller.abort();
          reject(new ProviderTimedOut("the route's total deadline elapsed"));
        }, deadlines.total);
      }),
    ]);
  } finally {
    clearTimeout(upstreamTimer);
    if (totalTimer !== undefined) clearTimeout(totalTimer);
  }
}

function invalid(request: FastifyRequest, reply: FastifyReply, message: string): FastifyReply {
  return reply.status(400).send(errorBody("request.invalid", message, request.id));
}

/**
 * A sentinel for "this was not JSON", distinct from every value `JSON.parse` can return.
 *
 * `null` and `undefined` are both legitimate parse results, so neither can stand for the failure —
 * and collapsing "the part said `null`" into "the part was unreadable" would answer one wrong
 * request with the other one's message.
 */
const UNPARSEABLE = Symbol("meta part is not JSON");

function parseJSON(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return UNPARSEABLE;
  }
}

/**
 * The route is configured but this deployment holds no credential for the provider behind it.
 *
 * `502 provider.unavailable` rather than a 500: from the caller's side that is exactly what it is —
 * the thing Sonny needed could not be reached — and it is the code §7.2 gives a client the right
 * behaviour for.
 *
 * **This branch is reachable, and this comment said it was not** (PR #139, F4). It claimed the
 * deployment-shaped failure is caught at startup by `buildApp` refusing to mount an adapterless
 * route; `buildApp` does no such thing and deliberately mounts all four unconditionally. A
 * deployment holding one credential and not another really does reach this, which is why it answers
 * a code the client knows what to do with — and why `answers 502 provider.unavailable when this
 * deployment holds no credential for the route` is a behavioural test rather than a note.
 */
function noProvider(request: FastifyRequest, reply: FastifyReply): FastifyReply {
  request.log.error({ url: request.url }, "route reached with no configured provider adapter");
  return reply.status(502).send(
    errorBody("provider.unavailable", "No provider is configured for this route.", request.id, {
      retryable: true,
    }),
  );
}

export function registerModelRoutes(app: FastifyInstance, providers: ModelProviders): void {
  const textRoute = (
    path: string,
    deadlines: { readonly upstream: number; readonly total: number },
    bodyLimit: number,
  ): void => {
    app.post(path, { bodyLimit }, async (request, reply) => {
      const parsed = textBody.safeParse(request.body);
      if (!parsed.success) return invalid(request, reply, "Request body failed validation.");
      const text = providers.text;
      if (text === undefined) return noProvider(request, reply);

      try {
        const result = await withDeadlines(deadlines, (signal) =>
          text({
            messages: parsed.data.messages,
            responseSchemaName: parsed.data.response_schema_name,
            responseSchema: parsed.data.response_schema,
            reasoningEffort: parsed.data.reasoning_effort,
            verbosity: parsed.data.verbosity,
            signal,
          }),
        );
        return reply.send({
          request_id: request.id,
          output_text: result.outputText,
          usage: usageBody(result.usage),
        });
      } catch (error) {
        return sendUpstreamFailure(request, reply, error);
      }
    });
  };

  textRoute("/v1/plan", DEADLINE_MS.plan, BODY_LIMIT_BYTES.plan);
  textRoute("/v1/research/synthesize", DEADLINE_MS.synthesize, BODY_LIMIT_BYTES.synthesize);

  app.post("/v1/search", { bodyLimit: BODY_LIMIT_BYTES.search }, async (request, reply) => {
    const parsed = searchBody.safeParse(request.body);
    if (!parsed.success) return invalid(request, reply, "Request body failed validation.");
    const search = providers.search;
    if (search === undefined) return noProvider(request, reply);

    // §4.3: clamped to 1–20 on both sides. Clamped rather than refused, because the client already
    // clamps and a 400 here would fail a whole research task over a number both sides agree to fix.
    const requested = parsed.data.max_results ?? 5;
    const maxResults = Math.min(Math.max(requested, 1), 20);

    try {
      const results: readonly SearchResultItem[] = await withDeadlines(
        DEADLINE_MS.search,
        (signal) => search({ query: parsed.data.query, maxResults, signal }),
      );
      return reply.send({
        request_id: request.id,
        results: results.map((item) => ({
          title: item.title,
          url: item.url,
          snippet: item.snippet,
        })),
      });
    } catch (error) {
      return sendUpstreamFailure(request, reply, error);
    }
  });

  /**
   * `POST /v1/transcriptions` — §4.4's two-part multipart body.
   *
   * **The audio's byte ceiling is enforced ahead of this handler, twice, and neither is here** (PR
   * #139, F11). `bodyLimit` bounds the whole request before it is buffered, and `@fastify/multipart`
   * bounds the file part while it streams. A third check on the *part* at the same number could
   * never fire: a part cannot be larger than the request that carries it, so `bodyLimit` refuses
   * first by construction. This route had one anyway, with a comment calling the pair "not
   * redundant"; the check is gone and `UpstreamRequestTooLarge` with it, because a guard nothing can
   * reach is worse than no guard — it reads as protection while contributing none.
   *
   * What a caller actually gets is unchanged and is what the tests assert: Fastify's 413, mapped by
   * `errors.ts` to §7.2's `request.too_large`. Both are backstops anyway — SONNY-130's real cap is a
   * duration, enforced on the Mac before a byte is sent, and `model/limits.ts` says why the two
   * sides measure different units.
   */
  app.post(
    "/v1/transcriptions",
    { bodyLimit: BODY_LIMIT_BYTES.transcriptions },
    async (request, reply) => {
      const transcribe = providers.transcription;
      if (transcribe === undefined) return noProvider(request, reply);

      let meta: unknown;
      let sawMeta = false;
      let audio: Buffer | undefined;
      let filename = "recording.m4a";
      let contentType = "audio/mp4";

      try {
        for await (const part of request.parts()) {
          if (part.type === "file") {
            if (part.fieldname !== "audio") {
              // Drained rather than ignored: an undrained file part stalls the multipart iterator.
              await part.toBuffer();
              continue;
            }
            audio = await part.toBuffer();
            if (part.filename) filename = part.filename;
            if (part.mimetype) contentType = part.mimetype;
          } else if (part.fieldname === "meta") {
            sawMeta = true;
            // **`value` is already parsed when the part declares `application/json`, and a string
            // when it does not.** `@fastify/multipart` JSON-parses a field whose own content type
            // says JSON, so insisting on a string here rejected exactly the body §4.4 specifies —
            // which is the shape the Mac sends. Both are accepted, because the part's content type
            // is the client's to set and neither spelling is wrong.
            meta = typeof part.value === "string" ? parseJSON(part.value) : part.value;
          }
        }
      } catch (error) {
        // `@fastify/multipart` throws its own typed errors for a malformed body and for a file over
        // `limits.fileSize`. The size one carries a 413 status, which `errors.ts` maps; anything
        // else here is a body this server could not read.
        const status = (error as { statusCode?: number }).statusCode;
        if (status === 413) throw error;
        request.log.info({ err: error }, "multipart body could not be read");
        return invalid(request, reply, "Request body could not be read as multipart/form-data.");
      }

      if (!sawMeta) return invalid(request, reply, "The meta part is required.");
      if (meta === UNPARSEABLE) return invalid(request, reply, "The meta part is not JSON.");
      const parsedMeta = transcriptionMeta.safeParse(meta);
      if (!parsedMeta.success) return invalid(request, reply, "The meta part failed validation.");
      if (audio === undefined || audio.byteLength === 0) {
        return invalid(request, reply, "The audio part is required and must not be empty.");
      }

      const recording = audio;
      try {
        const result = await withDeadlines(DEADLINE_MS.transcriptions, (signal) =>
          transcribe({ audio: recording, filename, contentType, signal }),
        );
        return reply.send({
          request_id: request.id,
          text: result.text,
          usage: usageBody(result.usage),
        });
      } catch (error) {
        return sendUpstreamFailure(request, reply, error);
      }
    },
  );
}
