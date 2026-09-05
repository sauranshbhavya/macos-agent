import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { errorBody } from "../errors.js";
import { noteContent } from "../content/hook.js";
import { meteredUpstreamCall, noteMetering } from "../metering/hook.js";
import { BODY_LIMIT_BYTES, BODY_READ_DEADLINE_MS, DEADLINE_MS } from "../model/limits.js";
import {
  ProviderRejected,
  ProviderTimedOut,
  ProviderUnavailable,
  type ModelProviders,
  type ProviderAttribution,
  type RoutedTextAdapter,
  type UpstreamUsage,
} from "../model/upstream.js";

/**
 * The four credential-bearing text routes (SONNY-130): `/v1/plan`, `/v1/research/synthesize`,
 * `/v1/transcriptions` and `/v1/search`.
 *
 * All four are authenticated — `auth/gate.ts` covers them by *not* listing them in `PUBLIC_ROUTES`,
 * which is the deny-by-default property that file exists for — and none of them reads the caller's
 * account for anything. Entitlement checks are SONNY-135's, and are not stubbed here, because a
 * stub of an entitlement check is a check that has been written and does nothing.
 *
 * **Metering has since landed and these routes deposit into it** (SONNY-133). This paragraph used to
 * name it as a non-goal alongside entitlements. What the routes contribute is the three facts the
 * hook cannot see for itself — that an upstream call was opened, how long it took, and which
 * provider served it — through `noteMetering` and `meteredUpstreamCall`; the event itself, and the
 * decision to write one at all, are `metering/hook.ts`', on this instance, for every route. A route
 * here that deposited nothing would still be metered, with the provider column empty.
 *
 * **`retention` is validated here and honoured somewhere else, and the split is the guarantee**
 * (updated 2026-08-28, SONNY-134). The field is required on every one of the four and §2.4.2 makes
 * an omitted one a loud `400` rather than a quiet guess in either direction — that part is
 * unchanged. This paragraph used to continue "what it is *not* is honoured, because this ticket
 * stores no content at all", which was true of SONNY-130 and is not true now: the content store
 * exists. What has not changed is that **no line in this file consults the field to decide whether
 * to store**, which is §10.1's rule rather than an omission — "enforced where the storing happens,
 * not at the call site" — and `content/hook.ts` is where that happens.
 *
 * What these routes contribute to retention is the same shape as what they contribute to metering:
 * the facts the hook cannot see for itself. There are two — the serving provider, beside the
 * metering deposit, and `/v1/transcriptions`' audio, which is the one piece of request content that
 * is not in `request.body`.
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

/**
 * Record which provider served, and which were tried first (SONNY-132).
 *
 * **This is the only place the fact leaves the router, and it never leaves this server.** §4.2:
 * "The response names no provider and no model." §11 puts `provider` on the metering event —
 * "Which provider actually served it. Required for failover accounting (SONNY-132) and never
 * returned to the client" — and **that event now exists**, so this function does two things: it
 * deposits the attribution onto the request's metering draft, and it logs. `request.id` ties both to
 * the `Sonny-Request-Id` the caller was given, which §2.3 makes the join key for exactly this kind
 * of lookup.
 *
 * The log line is kept beside the write rather than replaced by it. They answer different questions:
 * a log line is what an operator reads while a deploy is going wrong, and the event is what a cost
 * question is answered from a month later. `logStream` in `app.ts` exists because this line was
 * unpinned by any assertion (PR #143's F3), and it stays pinned.
 *
 * A failover is logged at `warn` and an ordinary request at `debug`: the first is a provider
 * having a bad hour and is worth noticing without anyone asking, the second is every request that
 * has ever worked.
 */
function recordServingProvider(
  request: FastifyRequest,
  route: string,
  served: ProviderAttribution,
): void {
  noteMetering(request, { provider: served.provider, failedOver: served.failedOver });
  // The same fact on the content row, so a retained response says which provider produced it
  // without a join to a table on a different clock (SONNY-134). `failedOver` is not copied: it is
  // failover accounting and belongs to the metering event alone.
  noteContent(request, { provider: served.provider });
  const detail = { route, provider: served.provider, failedOver: served.failedOver };
  if (served.failedOver.length > 0) {
    request.log.warn(detail, "model route served after failover");
  } else {
    request.log.debug(detail, "model route served");
  }
}

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

/** Raised when a request body did not finish arriving inside `BODY_READ_DEADLINE_MS`. */
class BodyReadTimedOut extends Error {}

/**
 * Run a body read under its own deadline (SONNY-322).
 *
 * **Racing an async iterator does not stop it, so the caller has two things to do and not one.**
 * `request.parts()` pulls from a socket the caller still controls, so a race that merely rejects
 * leaves the iterator, its buffers and the connection exactly where they were — the handler returns,
 * the claim is released, and the stalled upload goes on holding the socket, which is the defect with
 * a timer in front of it. Ending the stream is what settles the pending `toBuffer()` and frees the
 * connection.
 *
 * **The stream is ended AFTER the answer is written, not here, and that ordering is measured rather
 * than reasoned.** Destroying it from inside the timer was the first version, and it destroys the
 * *response* with it: an `IncomingMessage`'s destroy takes the socket, so the 408 can never be
 * delivered. It failed as `response destroyed before completion` / `LIGHT_ECONNRESET`, which is the
 * correct outcome for that ordering and a silent one in production — the caller would have got a
 * dropped connection where a typed refusal was intended. So this function only bounds and reports;
 * the handler answers and then ends the stream once the reply has finished.
 *
 * **Why the route needs this when `app.ts` sets `requestTimeout`.** That option is a coarse
 * backstop: measured at Fastify 5.12.1 / Node v22.23.1, a 2000 ms setting answered at 89955 ms and a
 * 35000 ms setting at 60003 ms, because Node checks expired connections on a thirty-second sweep.
 * `CLAIM_LEASE_SECONDS`' arithmetic needs an interval held to the second, so it is held here, on a
 * timer this process owns.
 */
async function withBodyReadDeadline(read: () => Promise<void>): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      read(),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new BodyReadTimedOut("the request body did not finish arriving in time")),
          BODY_READ_DEADLINE_MS,
        );
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
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
    // **The route's own adapter, not one shared entry** (SONNY-132). §4.2 gives the two text routes
    // one body shape so the server can hold one adapter per provider "while still routing, metering
    // and pricing them separately"; a shared entry would make `MODEL_ROUTE_SYNTHESIZE` mean nothing.
    route: "plan" | "research.synthesize",
    adapter: RoutedTextAdapter | undefined,
    deadlines: { readonly upstream: number; readonly total: number },
    bodyLimit: number,
  ): void => {
    app.post(path, { bodyLimit }, async (request, reply) => {
      const parsed = textBody.safeParse(request.body);
      if (!parsed.success) return invalid(request, reply, "Request body failed validation.");
      if (adapter === undefined) return noProvider(request, reply);

      try {
        const result = await meteredUpstreamCall(request, () =>
          withDeadlines(deadlines, (signal) =>
            adapter({
              messages: parsed.data.messages,
              responseSchemaName: parsed.data.response_schema_name,
              responseSchema: parsed.data.response_schema,
              reasoningEffort: parsed.data.reasoning_effort,
              verbosity: parsed.data.verbosity,
              signal,
            }),
          ),
        );
        recordServingProvider(request, route, result.served);
        noteMetering(request, { usage: result.usage });
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

  textRoute("/v1/plan", "plan", providers.plan, DEADLINE_MS.plan, BODY_LIMIT_BYTES.plan);
  textRoute(
    "/v1/research/synthesize",
    "research.synthesize",
    providers.synthesize,
    DEADLINE_MS.synthesize,
    BODY_LIMIT_BYTES.synthesize,
  );

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
      const result = await meteredUpstreamCall(request, () =>
        withDeadlines(DEADLINE_MS.search, (signal) =>
          search({ query: parsed.data.query, maxResults, signal }),
        ),
      );
      recordServingProvider(request, "search", result.served);
      return reply.send({
        request_id: request.id,
        results: result.items.map((item) => ({
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
   * **The audio's byte ceiling is enforced by exactly one guard, and it is not `bodyLimit`** (PR
   * #139's F11, corrected by its G2). `@fastify/multipart`'s `limits.fileSize` — set in `app.ts` —
   * throws `FST_REQ_FILE_TOO_LARGE` with `statusCode: 413` while the part is still streaming, and
   * `errors.ts` maps it on its `status === 413` arm to §7.2's `request.too_large`.
   *
   * **The route's `bodyLimit` below is not consulted for a multipart body**, which is measured
   * rather than reasoned: with it lowered to 1 MiB and `fileSize` left at 10 MiB, a 2 MiB multipart
   * body was **served 200**. Registering the multipart parser replaces the body parser for this
   * content type, and Fastify's own `FST_ERR_CTP_BODY_TOO_LARGE` never enters the picture. The
   * option stays because it still bounds a body sent to this route with some *other* content type,
   * where the JSON parser and its limit do run.
   *
   * **Two comments have now been wrong about this in the same place, in opposite directions.** The
   * first called the removed per-part check and `bodyLimit` a pair that was "not redundant"; the
   * second, written while removing that check, said the ceiling was enforced "twice" and that
   * `bodyLimit` "refuses first by construction". Neither had been measured. What the oversize test
   * pins is the outcome and nothing about the mechanism: an 11 MiB audio part answers
   * `413 request.too_large` with `retryable: false`, and **zero** upstream calls are made.
   *
   * All of it is a backstop anyway — SONNY-130's real cap is a duration, enforced on the Mac before
   * a byte is sent, and `model/limits.ts` says why the two sides measure different units.
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
        await withBodyReadDeadline(async () => {
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
        });
      } catch (error) {
        // **The deadline first, because it is the one failure that is not about the body's
        // content** (SONNY-322). `408` rather than `400`: the body may have been perfectly valid and
        // simply did not arrive, and `errors.ts`' rule for a 4xx §7.2 does not name individually is
        // `request.invalid`, which is the same answer `app.ts`' `clientErrorHandler` gives when the
        // server-wide `requestTimeout` catches this one sweep later. Two doors, one answer.
        if (error instanceof BodyReadTimedOut) {
          request.log.info({ err: error }, "transcription body read exceeded its deadline");
          // **The connection cannot be reused and this is what says so.** The caller is still
          // sending a body this server has stopped reading, so there is no message boundary left to
          // find; `Connection: close` tells the caller, and the destroy on `finish` is what actually
          // releases the socket — after the answer is out, because destroying the request first
          // takes the response with it.
          reply.raw.once("finish", () => request.raw.destroy());
          return reply
            .status(408)
            .header("Connection", "close")
            .send(errorBody("request.invalid", "Request body was not delivered in time.", request.id));
        }
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
      // **The one route whose §2.4 fields the metering hook cannot read for itself.** Everywhere
      // else it reads `request.body`; §4.4's body is `multipart/form-data`, consumed above by
      // `request.parts()`, so `request.body` is undefined here and the `meta` part is deposited by
      // hand. Deposited after validation because that is the first point these two values are known
      // to be what they claim; a `meta` part that fails validation leaves them null on an event that
      // is written anyway, with `outcome: refused`.
      noteMetering(request, {
        taskId: parsedMeta.data.task_id,
        retention: parsedMeta.data.retention,
      });
      if (audio === undefined || audio.byteLength === 0) {
        return invalid(request, reply, "The audio part is required and must not be empty.");
      }

      const recording = audio;
      // **Voice audio into the content store, deposited by hand for the same reason the two fields
      // above are** (SONNY-134). This is the one route whose request content the content hook
      // cannot read for itself: §4.4's body is `multipart/form-data`, consumed by `request.parts()`
      // above, so `request.body` is undefined here. §10.3 names voice audio explicitly as content —
      // "the most personally sensitive of the four types and the one most likely to be overlooked
      // because nobody listed it" — and this line is the whole of why it is not.
      //
      // **Depositing is not storing**: the hook keeps nothing unless this request declared
      // `retention: "standard"`, so a recording made with "Don't save this task" on is deposited on
      // a draft that is discarded. Deposited after the meta part has been validated, because that
      // is the first point `retention` is known to be what it claims.
      noteContent(request, {
        // Deposited because this route's body is not readable by the hook — without it, the one
        // content type §10.3 names as most easily overlooked would be the one that is never kept.
        retention: parsedMeta.data.retention,
        voiceAudio: recording,
        voiceAudioMediaType: contentType,
        voiceAudioFilename: filename,
      });
      try {
        const result = await meteredUpstreamCall(request, () =>
          withDeadlines(DEADLINE_MS.transcriptions, (signal) =>
            transcribe({ audio: recording, filename, contentType, signal }),
          ),
        );
        recordServingProvider(request, "transcription", result.served);
        noteMetering(request, { usage: result.usage });
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
