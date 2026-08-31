import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Verifying a [Standard Webhooks](https://www.standardwebhooks.com/) delivery (SONNY-211).
 *
 * **This is the security control of the whole billing row, and it is worth saying why in one
 * sentence before any code**: the route it protects grants paid entitlements, it is reachable by
 * anyone on the internet, and it carries no user credential — so if this function can be made to
 * answer `ok` for a body an attacker chose, that attacker gives themselves a paid subscription. The
 * `PUBLIC_ROUTES` entry that lets the delivery past the auth gate is bookkeeping; this is the check.
 *
 * **Provider-neutral on purpose.** Standard Webhooks is a specification several merchants of record
 * implement, Polar among them; nothing in this file knows what Polar is. What a provider adapter
 * supplies is the key bytes (`billing/polar.ts` carries why Polar's differ from the specification's
 * default encoding) and, if it ever differs, its own verifier.
 *
 * ## What is signed, and why the raw bytes are the whole point
 *
 * The signed content is `<id>.<timestamp>.<body>`, where `<body>` is **the exact bytes of the
 * request**. Not the re-serialisation of a parsed object: JSON round-tripping reorders nothing in
 * V8 today but is free to change spacing, number formatting and escaping, and any one of those
 * turns a genuine delivery into a rejected one — or, far worse, makes the verified bytes different
 * from the bytes that are then interpreted. `routes/billing.ts` installs a content-type parser
 * scoped to this one route that hands the handler a `Buffer` and parses nothing.
 *
 * ## The three refusals, and the two that are not about the signature
 *
 * A signature is not the only thing a delivery has to survive:
 *
 * - **Missing or malformed headers** — refused before any HMAC is computed. Nothing is a signature
 *   until it says which version it is.
 * - **A timestamp outside the tolerance** — refused whatever the signature says. A signature never
 *   expires on its own, so without this a delivery captured once is replayable forever. This bounds
 *   that to the window below; the *unbounded* replay guard is the provider's event id being a
 *   primary key in `sonny.billing_event`, and the two are complementary rather than alternatives —
 *   the timestamp bounds what is worth storing, the key makes even that idempotent.
 * - **A signature that does not match** — the actual check.
 *
 * ## Why the comparison is a loop over a list
 *
 * `webhook-signature` carries **space-separated** signatures, because a rotating endpoint secret
 * means a window during which the sender signs with both. Verifying only the first would break
 * every rotation. Each candidate is compared with `timingSafeEqual`, and the length is compared
 * first because `timingSafeEqual` throws a `RangeError` on a length mismatch — inside a request
 * hook that is a `500` where a `400` is meant, which is exactly the mistake `auth/token.ts:209`
 * records having made.
 */

/** The three headers the specification names, lower-cased as Fastify presents them. */
export const WEBHOOK_ID_HEADER = "webhook-id";
export const WEBHOOK_TIMESTAMP_HEADER = "webhook-timestamp";
export const WEBHOOK_SIGNATURE_HEADER = "webhook-signature";

/**
 * How far a delivery's own timestamp may sit from this gateway's clock: **five minutes** either
 * way, which is the specification's own recommendation.
 *
 * **Both directions, and for the reason `entitlement/claim.ts` gives rather than the one
 * `auth/clock.ts` gives.** A delivery from the future is not a forgery attempt — the timestamp is
 * inside the signed content, so an attacker cannot choose it without the secret — it is two clocks
 * disagreeing, and refusing it would make this gateway's own NTP drift look like a provider outage.
 *
 * What five minutes costs, stated plainly: a delivery captured on the wire is replayable for up to
 * five minutes after it was sent. That is the window `sonny.billing_event`'s primary key closes.
 */
export const WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS = 300;

/** The prefix on each entry of `webhook-signature`. Version 1 is HMAC-SHA256, base64. */
const SIGNATURE_VERSION = "v1,";

export type SignatureRefusal =
  /** A required header is absent, empty, or not a single value. */
  | "headers"
  /** `webhook-timestamp` is not an integer number of seconds. */
  | "timestamp_malformed"
  /** `webhook-timestamp` is outside `WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS` of now. */
  | "timestamp_outside_tolerance"
  /** `webhook-signature` carried no `v1,` entry at all. */
  | "signature_malformed"
  /** Every `v1,` entry was computed under a different key, or over different bytes. */
  | "signature_mismatch";

export type SignatureVerdict =
  | { readonly ok: true; readonly eventId: string; readonly sentAt: Date }
  | { readonly ok: false; readonly refusal: SignatureRefusal };

/**
 * A header as Fastify hands it over: absent, one value, or several.
 *
 * **Several is refused rather than joined or first-wins.** A duplicated `webhook-signature` is
 * either a proxy misbehaving or a request-splitting attempt, and both deserve the same answer.
 */
function single(value: string | string[] | undefined): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

/** The bytes signed: `<id>.<timestamp>.<body>`, with the body's own bytes appended unchanged. */
export function signedContent(id: string, timestamp: string, body: Buffer): Buffer {
  return Buffer.concat([Buffer.from(`${id}.${timestamp}.`, "utf8"), body]);
}

/**
 * The signature this gateway expects, base64 — exported because the tests that prove a *tampered*
 * body is refused have to be able to sign an honest one first, and a test that hand-rolls the
 * construction is a test that can agree with a bug in it.
 */
export function signatureFor(key: Buffer, id: string, timestamp: string, body: Buffer): string {
  return createHmac("sha256", key).update(signedContent(id, timestamp, body)).digest("base64");
}

export interface SignatureInput {
  readonly key: Buffer;
  readonly headers: Readonly<Record<string, string | string[] | undefined>>;
  readonly body: Buffer;
  readonly now: Date;
}

export function verifyWebhookSignature(input: SignatureInput): SignatureVerdict {
  const id = single(input.headers[WEBHOOK_ID_HEADER]);
  const timestamp = single(input.headers[WEBHOOK_TIMESTAMP_HEADER]);
  const presented = single(input.headers[WEBHOOK_SIGNATURE_HEADER]);
  if (id === undefined || timestamp === undefined || presented === undefined) {
    return { ok: false, refusal: "headers" };
  }

  // Seconds since the epoch, as an integer. `Number` would accept `"1e9"`, `" 12 "` and `"0x10"`,
  // each of which is a value nothing legitimate sends and a shape worth refusing rather than
  // interpreting.
  if (!/^-?\d{1,15}$/.test(timestamp)) return { ok: false, refusal: "timestamp_malformed" };
  const sentAt = new Date(Number(timestamp) * 1000);
  // **A digit string can be in range for the regex and out of range for a `Date`, and the arithmetic
  // below fails OPEN when it is** (PR #178 review, F3). ECMAScript bounds a `Date` at ±8.64e15 ms, so
  // a 13-to-15-digit second count overflows it; `new Date` is then `Invalid Date`, `getTime()` is
  // `NaN`, `drift` is `NaN`, and **`NaN > tolerance` is `false`** — so the comparison that exists to
  // refuse says accept. The verdict then travels on carrying an `Invalid Date`, which reaches
  // Postgres as `0NaN-NaN-NaNTNaN:NaN:NaN.NaN+NaN:NaN` and throws.
  //
  // Refused here rather than by narrowing the regex, because the regex would then be encoding the
  // `Date` range in digit counts — true today and a silent trap the day either bound moves. Asking
  // the `Date` whether it is a date is the check that cannot drift.
  //
  // **Not an authentication bypass, and it is worth saying so rather than letting the fix imply
  // one**: the timestamp is inside the signed content, so only the provider or a holder of the
  // secret can reach this at all. What it was, exactly, is the replay bound having a hole for a
  // class of values and a 500 where a refusal belongs.
  if (Number.isNaN(sentAt.getTime())) return { ok: false, refusal: "timestamp_malformed" };
  const drift = Math.abs(input.now.getTime() - sentAt.getTime()) / 1000;
  if (drift > WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS) {
    return { ok: false, refusal: "timestamp_outside_tolerance" };
  }

  const expected = Buffer.from(signatureFor(input.key, id, timestamp, input.body), "base64");
  const candidates = presented
    .split(" ")
    .filter((entry) => entry.startsWith(SIGNATURE_VERSION))
    .map((entry) => entry.slice(SIGNATURE_VERSION.length));
  if (candidates.length === 0) return { ok: false, refusal: "signature_malformed" };

  for (const candidate of candidates) {
    const bytes = Buffer.from(candidate, "base64");
    // Length first: `timingSafeEqual` throws on a mismatch, and a thrown `RangeError` inside a route
    // handler is a `500` standing in for a refusal.
    //
    // **Held by `refuses a v1 entry that decodes to the wrong number of bytes` and by nothing else**
    // (PR #178 review, F2, where mutant R1 survived). Every `v1,` entry that reaches this loop in an
    // ordinary test is a real HMAC-SHA256 and therefore always 32 bytes — the wrong-secret and
    // tampered-body cases included — so the whole suite passed with this guard deleted while a 401
    // became a 500. The test that holds it presents a short `v1,` value with otherwise valid headers,
    // which is the only shape that reaches the comparison at the wrong length.
    if (bytes.length === expected.length && timingSafeEqual(bytes, expected)) {
      return { ok: true, eventId: id, sentAt };
    }
  }
  return { ok: false, refusal: "signature_mismatch" };
}
