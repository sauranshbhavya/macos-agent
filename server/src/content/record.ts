import type { MeteredRoute } from "../metering/event.js";

/**
 * What is kept per call, as a type and one pure decision: is this request's content storable at all
 * (SONNY-134). Contract §10.
 *
 * **This module decides nothing about billing and reads metering's shape without redefining it.**
 * `MeteredRoute` is imported rather than restated, so the five routes that produce a metering event
 * and the five that produce a content row cannot drift apart; the ticket's never-touch list says
 * this branch reads that shape and does not change it.
 *
 * **The whole of the incognito guarantee's first half is `isStorable` below.** §10.1: "enforced
 * where the storing happens, not at the call site. A flag the client sets and the server is trusted
 * to remember to check is a request, not a guarantee." So there is exactly one predicate, every
 * write goes through it, and the database carries a CHECK underneath it that makes the storable set
 * a property of the schema as well (0013's header).
 */

/**
 * How the caller asked this request's content to be treated, as the storage layer sees it.
 *
 * Three values rather than §10.1's two, and the third is the one that matters: `undefined` is a
 * request that declared nothing, which happens on every refusal before validation and on a body
 * this server could not read. §2.4.2 makes an omitted `retention` a `400` on the wire precisely
 * because neither default is safe — `"standard"` silently stores what a user asked not to store,
 * `"none"` silently loses the retention the founder decided to have — and the storage layer takes
 * the same line: a request that did not say is a request whose content is not kept.
 */
export type DeclaredRetention = "standard" | "none" | undefined;

/**
 * May this request's content be stored?
 *
 * The only answer that is `true` is an explicit `"standard"`. Everything else — incognito, and a
 * request that never declared — is `false`, and the two are false for different reasons that arrive
 * at the same place: one is a promise to the user, the other is §2.4.2's refusal to guess.
 */
export function isStorable(retention: DeclaredRetention): boolean {
  return retention === "standard";
}

/** What a route or an adapter deposits as it learns it. Every field optional. */
export interface ContentFacts {
  /**
   * §2.4's `retention`, for the one route whose body the hook cannot read.
   *
   * **`/v1/transcriptions` and nothing else.** §4.4's body is `multipart/form-data`, consumed inside
   * the handler, so `request.body` is undefined there and a hook reading the field off the body
   * would find nothing — which `isStorable` then reads as "declared nothing", and **voice audio, the
   * content type §10.3 singles out as the one most likely to be overlooked, would silently never be
   * stored at all**. That is exactly the failure it warns about, reached through a mechanism nobody
   * would look at. It is deposited from the validated `meta` part instead.
   *
   * A deposited value wins over the body's, because the only depositor is that route and the only
   * body it could disagree with is one that does not exist.
   */
  readonly retention?: "standard" | "none";
  readonly voiceAudio?: Buffer;
  readonly voiceAudioMediaType?: string;
  readonly voiceAudioFilename?: string;
  readonly provider?: string;
  readonly providerRequestId?: string;
  readonly providerErrorStatus?: number;
  readonly providerErrorBody?: string;
}

/**
 * The textual and image halves of a request, pulled out of the parsed body.
 *
 * **Read from `request.body` rather than deposited by each route**, which is the same call
 * `metering/hook.ts` makes about §2.4's fields and for the same reason: a route that has to
 * remember to hand over its own content is a route where the author who did not think about
 * retention ships something that serves correctly, passes its own tests, and quietly keeps nothing.
 * `/v1/transcriptions` is the one exception in both files, because §4.4's body is
 * `multipart/form-data` and `request.body` is undefined there — its audio is deposited by hand.
 */
export interface RequestContent {
  readonly requestText: unknown | null;
  readonly screenshot: Buffer | null;
  readonly screenshotMediaType: string | null;
}

const EMPTY: RequestContent = { requestText: null, screenshot: null, screenshotMediaType: null };

function asRecord(body: unknown): Record<string, unknown> | undefined {
  return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : undefined;
}

/**
 * This route's content, out of the body the client sent.
 *
 * **Tolerant of a body that failed validation, and that is deliberate**: a request refused at
 * validation still declared `retention`, and if it declared `standard` then whatever it did send is
 * content the user's Mac transmitted. Every field is type-checked here rather than assumed, so a
 * body carrying a number where a string belongs contributes nothing instead of a surprise — the
 * same tolerance `clientFieldsOf` applies to the metering event's client-supplied fields.
 *
 * The screenshot is decoded here rather than at deposit time so that an incognito capture is never
 * decoded into a second buffer at all: this function runs only after `isStorable` has said yes.
 */
export function requestContentOf(route: MeteredRoute, body: unknown): RequestContent {
  const record = asRecord(body);
  if (record === undefined) return EMPTY;

  switch (route) {
    case "plan":
    case "research.synthesize":
      return { ...EMPTY, requestText: Array.isArray(record["messages"]) ? record["messages"] : null };
    case "search":
      return { ...EMPTY, requestText: typeof record["query"] === "string" ? record["query"] : null };
    case "screen.analyze": {
      const prompt = typeof record["prompt"] === "string" ? record["prompt"] : null;
      const image = asRecord(record["image"]);
      const data = image?.["data"];
      const mediaType = image?.["media_type"];
      if (typeof data !== "string" || typeof mediaType !== "string") {
        return { ...EMPTY, requestText: prompt };
      }
      return {
        requestText: prompt,
        screenshot: Buffer.from(data, "base64"),
        screenshotMediaType: mediaType,
      };
    }
    // The audio is not in `request.body` on this route, and never will be: §4.4's body is
    // multipart and is consumed inside the handler. `routes/model.ts` deposits it.
    case "transcription":
      return EMPTY;
  }
}

/**
 * One row of `sonny.retained_content`. Every column the table holds, and nothing derived.
 *
 * `null` rather than `undefined` throughout, for the reason `MeteringEvent` gives: each of these is
 * bound to a column and the two would otherwise be one more thing to normalise at the boundary.
 *
 * `retention` is absent by construction. The table admits one value, the writer has already
 * answered `isStorable`, and a field here would be a third place the same fact was written down.
 */
export interface RetainedContent {
  readonly requestId: string;
  readonly accountId: string;
  readonly taskId: string | null;
  readonly sessionId: string | null;
  readonly sessionIteration: number | null;
  readonly route: MeteredRoute;
  readonly expiresAt: Date;
  readonly provider: string | null;
  readonly providerRequestId: string | null;
  readonly requestText: unknown | null;
  readonly voiceAudio: Buffer | null;
  readonly voiceAudioMediaType: string | null;
  readonly voiceAudioFilename: string | null;
  readonly screenshot: Buffer | null;
  readonly screenshotMediaType: string | null;
  readonly responseStatus: number | null;
  readonly responseContentType: string | null;
  readonly responseBody: Buffer | null;
  readonly providerErrorStatus: number | null;
  readonly providerErrorBody: string | null;
}

/**
 * When this row's content stops being kept, from when the call happened.
 *
 * **Computed at insert and stored, never derived at read.** A window that were evaluated against
 * whatever `CONTENT_RETENTION_DAYS` says today would silently extend the life of everything already
 * held the moment somebody raised the setting — content the user was told would be gone in thirty
 * days, kept for ninety by a configuration change nobody connected to it. Stored, a row carries the
 * promise it was written under, and raising the setting applies only to what arrives afterwards.
 */
export function contentExpiryFrom(occurredAt: Date, retentionDays: number): Date {
  return new Date(occurredAt.getTime() + retentionDays * 24 * 60 * 60 * 1000);
}
