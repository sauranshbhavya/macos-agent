import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { errorBody } from "../errors.js";
import { noteContent } from "../content/hook.js";
import { meteredUpstreamCall, noteMetering } from "../metering/hook.js";
import {
  BODY_LIMIT_BYTES,
  DEADLINE_MS,
  MAXIMUM_IMAGE_BYTES,
  RESPONSE_LIMIT_BYTES,
} from "../model/limits.js";
import { sendUpstreamFailure, withDeadlines } from "../model/routing.js";
import type { VisionProvider } from "../model/vision.js";
import { ProviderRejected } from "../model/upstream.js";

/**
 * `POST /v1/screen/analyze` — the screen-control route (SONNY-131), contract §4.5.
 *
 * **Its own file rather than a fifth route in `routes/model.ts`, and the reason is the ticket's
 * own.** SONNY-131 exists separately from SONNY-130 "because it is the one route with a large
 * payload, a long upstream wait, a 12-iteration loop, and redaction guarantees that must not be
 * disturbed" — and `routes/model.ts` is on this ticket's never-touch list. The two files share
 * `model/limits.ts`, `model/routing.ts` and `model/upstream.ts`, which is where the behaviour that
 * genuinely is common lives.
 *
 * **Authenticated by not appearing in `PUBLIC_ROUTES`.** No line in this file mentions auth; that is
 * the whole of what `auth/gate.ts`' deny-by-default means, and `gate.test.ts`' population test is
 * what fails if this route is ever classified public by mistake.
 *
 * **Three things this route deliberately does not do.**
 *
 * - **It does not touch the image.** §4.5 rule 1 forbids resampling, re-encoding, cropping or
 *   rotating it, because the coordinate space the model answers in is the client's `SentImageSize`
 *   and a server-side resize would leave every returned click scaled by a factor nothing on the Mac
 *   knows about. The base64 string is forwarded verbatim; it is decoded exactly once, to count its
 *   bytes against the ceiling, and that buffer is discarded.
 * - **It holds no session state.** §4.5 rule 5: one request is one iteration, continuity lives in the
 *   runner's own `history`, and `session_id` is a client-minted key for metering and for the support
 *   lookup rather than a handle on anything here. That is also why an aborted session is not
 *   resumable server-side, which is an input to SONNY-131's mid-loop decision — recorded on the Mac,
 *   in `VisionSessionRunner`. **`session_id` is now what makes "what did that session cost" a
 *   GROUP BY** rather than a second event shape (SONNY-133): twelve iterations are twelve events
 *   sharing one value, which is the only shape available to a server that holds no session and whose
 *   last iteration does not know it is the last.
 * - **It validates `retention` and does not itself honour it** (updated 2026-08-28, SONNY-134).
 *   §2.4.2 makes an omitted `retention` a loud `400` rather than a guess in either direction. This
 *   bullet used to continue "nothing is stored at all — there is no content store yet", which was
 *   true of SONNY-131 and is not true now: this route's capture and reply are stored, on the 30-day
 *   content clock, when the caller said `standard`. What is unchanged is that no line in this file
 *   decides that, because §10.1 puts the decision where the storing happens; `content/hook.ts` reads
 *   the field, and this route deposits only the provider that served. **It is also recorded on the
 *   metering event**, which is §10.1's other half: "metering runs either way — incognito changes
 *   what is stored, never what is billed", and an event that dropped `retention: "none"` requests
 *   would make exactly those runs free.
 *
 * **What it does do that it did not before: it feeds the metering event** (SONNY-133). This is the
 * route §11 exists for — it is the one call the product will charge for, and it recorded nothing
 * anywhere until this branch. The three things the hook cannot see for itself are deposited below:
 * the image's bytes, dimensions and media type, which is what vision cost is actually derived from
 * (§4.5 rule 3); that an upstream call was opened, which is what separates a provider failure from a
 * refusal that spent nothing; and the provider that served.
 */

/** §2.4: required on every content-bearing request, never defaulted. */
const retentionField = z.enum(["standard", "none"]);
const identifierField = z.string().trim().min(1).max(200);

/**
 * §4.5's `image` object.
 *
 * `media_type` is an enum of exactly the two formats `RedactedCaptureEncoder` produces. **A closed
 * set rather than a string**, because the value is spliced into a `data:` URL the provider parses —
 * so an open string is a field the client controls inside a URL the server builds, and the two
 * formats are the whole of what the encoder can emit.
 *
 * `encoding` is a literal rather than an omitted constant, because §4.5 puts it on the wire and a
 * field on the wire that the server ignores is a field a client can believe it chose.
 */
const imageObject = z
  .object({
    media_type: z.enum(["image/png", "image/jpeg"]),
    encoding: z.literal("base64"),
    data: z.string().min(1),
    pixel_width: z.number().int().positive(),
    pixel_height: z.number().int().positive(),
  })
  .strict();

/**
 * §4.5's request body.
 *
 * `.strict()` for the reason `routes/model.ts` gives for the text routes: the contract makes the
 * *client* tolerant of unknown response fields so the server can add them additively, and nothing
 * makes the server tolerant of unknown request fields. A field this server silently dropped would be
 * a client believing it asked for something.
 */
const screenAnalyzeBody = z
  .object({
    task_id: identifierField,
    session_id: identifierField,
    session_iteration: z.number().int().positive(),
    retention: retentionField,
    prompt: z.string().min(1),
    image: imageObject,
  })
  .strict();

/**
 * Is this string base64, exactly?
 *
 * **Checked before the decode rather than inferred from it**, because `Buffer.from(s, "base64")`
 * silently skips characters it does not recognise. A mangled payload would decode to a shorter
 * buffer, pass the size ceiling, and be forwarded to the provider as a corrupt image — a failure
 * that would surface as the model saying something odd about the user's screen, several layers from
 * its cause. Refusing here turns it into one `400 request.invalid`.
 *
 * The length check is part of it: base64 is a multiple of four characters, and a string that is not
 * cannot be a faithful encoding of anything.
 */
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

function isBase64(value: string): boolean {
  return value.length % 4 === 0 && BASE64.test(value);
}

function invalid(request: FastifyRequest, reply: FastifyReply, message: string): FastifyReply {
  return reply.status(400).send(errorBody("request.invalid", message, request.id));
}

/**
 * §6.2's refusal, carrying the two numbers that section names.
 *
 * **`limit_bytes` and `actual_bytes` sit inside the error object beside §7.1's five fields**, rather
 * than being folded into `message`. §6.2 asks for them by name "so the refusal is diagnosable", and
 * §2.1 makes the client tolerant of response fields it does not know, so this is the additive change
 * §8 describes rather than a second envelope. `errorBody` still builds the five required fields, so
 * they cannot drift from every other refusal this gateway sends.
 *
 * **The client should never see this**, and that is the point of the pair being here. The Mac
 * refuses above the same ceiling before it builds a request body at all
 * (`SonnyVisionModelClient.decide`), so a 413 from this route means the two ceilings have come apart
 * — which §6.1 says is the failure to look for, since "a server limit sized for an old client
 * ceiling is a limit that means nothing".
 */
function tooLarge(
  request: FastifyRequest,
  reply: FastifyReply,
  actualBytes: number,
  limitBytes: number,
): FastifyReply {
  request.log.info(
    { actualBytes, limitBytes },
    "screen capture over the ceiling the client should have refused at",
  );
  const envelope = errorBody(
    "request.too_large",
    "The screen capture is over the size limit for one request.",
    request.id,
    { retryable: false },
  );
  return reply
    .status(413)
    .send({ error: { ...envelope.error, limit_bytes: limitBytes, actual_bytes: actualBytes } });
}

/**
 * The route is configured but this deployment holds no vision credential.
 *
 * `502 provider.unavailable` rather than a 500: from the caller's side that is exactly what it is,
 * and it is the code §7.2 gives a client the right behaviour for. Reachable — `./scripts/deploy.sh
 * local` with no `VISION_API_KEY` reaches it — which is why it is a behavioural test rather than a
 * note.
 */
function noProvider(request: FastifyRequest, reply: FastifyReply): FastifyReply {
  request.log.error({ url: request.url }, "screen route reached with no configured provider adapter");
  return reply.status(502).send(
    errorBody("provider.unavailable", "No provider is configured for this route.", request.id, {
      retryable: true,
    }),
  );
}

export function registerScreenRoutes(app: FastifyInstance, vision: VisionProvider | undefined): void {
  app.post(
    "/v1/screen/analyze",
    { bodyLimit: BODY_LIMIT_BYTES.screenAnalyze },
    async (request, reply) => {
      const parsed = screenAnalyzeBody.safeParse(request.body);
      if (!parsed.success) return invalid(request, reply, "Request body failed validation.");
      if (vision === undefined) return noProvider(request, reply);

      const image = parsed.data.image;
      if (!isBase64(image.data)) {
        return invalid(request, reply, "The image data is not base64.");
      }
      // The one decode, and its only consumer is `byteLength`. §4.5 rule 1 is why nothing downstream
      // ever sees this buffer: what is forwarded is `image.data`, the string the client sent.
      const imageBytes = Buffer.from(image.data, "base64").byteLength;
      // **Deposited before the ceiling check, not after.** §6.2 asks for the refusal to be
      // diagnosable, and the event is where that is answered a week later: a `413` whose row does
      // not carry the size it refused is a refusal nobody can size. It also costs nothing on the
      // ordinary path, since the decode has already happened by here.
      noteMetering(request, {
        imageBytes,
        imagePixelWidth: image.pixel_width,
        imagePixelHeight: image.pixel_height,
        imageMediaType: image.media_type,
      });
      if (imageBytes > MAXIMUM_IMAGE_BYTES) {
        return tooLarge(request, reply, imageBytes, MAXIMUM_IMAGE_BYTES);
      }

      try {
        const result = await meteredUpstreamCall(request, () =>
          withDeadlines(DEADLINE_MS.screenAnalyze, (signal) =>
            vision({
              prompt: parsed.data.prompt,
              imageBase64: image.data,
              imageMediaType: image.media_type,
              signal,
            }),
          ),
        );
        // §11's `provider`, and the vision route has exactly one — it is not on SONNY-132's router,
        // so there is no chain to fail over and `failedOver` is empty by construction rather than by
        // luck. `app.ts` records why the two have not been collapsed and who owns doing it.
        noteMetering(request, { provider: "vision", failedOver: [], usage: result.usage });
        // The same fact on the content row (SONNY-134), so a retained capture and reply say which
        // provider produced it without a join to a table on a different clock.
        noteContent(request, { provider: "vision" });

        const body: Record<string, unknown> = {
          request_id: request.id,
          output_text: result.outputText,
        };
        // Present when the provider reported numbers and absent when it did not — `model/vision.ts`
        // carries the reasoning, and it is the one place this route differs from the four text ones.
        if (result.usage !== undefined) {
          body["usage"] = {
            input_tokens: result.usage.inputTokens,
            output_tokens: result.usage.outputTokens,
            total_tokens: result.usage.totalTokens,
            audio_duration_seconds: result.usage.audioDurationSeconds,
            source: result.usage.source,
          };
        }

        // §6.3's ceiling on what *leaves*, measured on the serialized bytes rather than on the
        // model's text alone — the envelope is part of what the Mac allocates.
        //
        // **This is reachable and a test drives it**, which is worth saying because the first version
        // of this comment called it "effectively unreachable" from a reading rather than from a
        // measurement. The adapter bounds what it *reads* at the same cap, so a reply just under it
        // plus this route's own `request_id` and JSON envelope really does cross the line —
        // `refuses to send a response over the cap even when the provider's reply was under it` is
        // that case, and it fails if this branch is removed.
        const serialized = JSON.stringify(body);
        if (Buffer.byteLength(serialized, "utf8") > RESPONSE_LIMIT_BYTES) {
          return sendUpstreamFailure(
            request,
            reply,
            new ProviderRejected("the reply would exceed the response cap"),
          );
        }
        return reply.send(body);
      } catch (error) {
        return sendUpstreamFailure(request, reply, error);
      }
    },
  );
}
