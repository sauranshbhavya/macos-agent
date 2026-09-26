import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { classify, errorBody } from "../errors.js";
import { noteRetention } from "../retention.js";
import { meteredUpstreamCall, noteMetering } from "../metering/hook.js";
import { BODY_LIMIT_BYTES, BODY_READ_DEADLINE_MS, DEADLINE_MS } from "../model/limits.js";
import { sendUpstreamFailure, withDeadlines } from "../model/routing.js";
import type { ModelProviders, ProviderAttribution, UpstreamUsage } from "../model/upstream.js";

/**
 * `POST /v1/transcriptions`, the one model route the Mac still calls directly: voice becomes text
 * here, and the text becomes a task on the session (V2 plan section 6, "Composer and voice"). Every
 * other model call is the gateway's own, inside a task.
 *
 * Authenticated by `auth/gate.ts` not listing it in `PUBLIC_ROUTES`, and metered through
 * `meteredUpstreamCall` like any upstream call. `retention` is required and recorded with
 * `noteRetention`, so a recording made with "Don't save this task" on leaves no replayable copy in
 * the idempotency store.
 */

/** §2.4: required, never defaulted. */
const retentionField = z.enum(["standard", "none"]);
const taskIdField = z.string().trim().min(1).max(200);

/**
 * The `meta` part of §4.4's multipart body.
 *
 * `.strict()` is deliberate and is the opposite of §2.1's rule for *responses*. The contract makes
 * the client tolerant of unknown response fields so the server can add them additively; nothing
 * makes the server tolerant of unknown request fields, and it should not be — a field this server
 * silently drops is a client believing it asked for something.
 */
const transcriptionMeta = z
  .object({ task_id: taskIdField, retention: retentionField })
  .strict();

/**
 * Record which provider served (SONNY-132): on the request's metering event, and in a debug log line
 * tied to the `Sonny-Request-Id`. It never reaches the response — §4.2: "The response names no
 * provider and no model." Transcription has one servable provider, so `failedOver` is always empty
 * here; it is recorded anyway because the metering column exists.
 */
function recordServingProvider(
  request: FastifyRequest,
  route: string,
  served: ProviderAttribution,
): void {
  noteMetering(request, { provider: served.provider, failedOver: served.failedOver });
  request.log.debug(
    { route, provider: served.provider, failedOver: served.failedOver },
    "model route served",
  );
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
 * `buildApp` mounts the route whatever the credentials, so a deployment with no OpenAI key reaches
 * this; `answers 502 provider.unavailable when this deployment holds no credential for the route`
 * is the behavioural test.
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
          // **`request.timeout`, and the code is the whole of what the client acts on** (PR #208's
          // F1). This answered `request.invalid`, which the Mac hard-codes as not retryable and
          // renders as "Sonny couldn't send this one" — a sentence whose every clause is false for a
          // body that simply did not arrive fast enough. `errors.ts`'s `classify` owns the mapping,
          // so this route and `app.ts`'s socket-level handler cannot drift apart about one
          // condition; being in `RELEASE_ON_CODES` is what stops the answer being stored and
          // replayed at the retry it is asking for (PR #208's F2).
          const timedOut = classify({ statusCode: 408 } as FastifyError);
          return reply
            .status(timedOut.status)
            .header("Connection", "close")
            .send(errorBody(timedOut.code, timedOut.message, request.id, {
              retryable: timedOut.retryable,
            }));
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
      // Recorded by hand for the reason the two metering fields above are: the body is multipart, so
      // nothing downstream can read `retention` off `request.body`. With `"none"` the idempotency
      // store keeps no replayable copy of the transcript.
      noteRetention(request, parsedMeta.data.retention);
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
