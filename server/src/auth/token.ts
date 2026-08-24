import { createHmac, timingSafeEqual } from "node:crypto";
import { isExpiryAcceptable } from "./clock.js";

/**
 * Verification of a presented Supabase access token, and the whole of it.
 *
 * **Nothing verified a token before this file** (SONNY-203; recorded on PR #87 as F2 and again in the
 * ticket's own correction comment of 2026-08-22). SONNY-127 built the `AuthProvider` seam and the
 * skew tolerance in `clock.ts`, and neither was reached by any route: `userFromAccessToken` has no
 * adapter behind it, and `isExpiryAcceptable` had no caller outside its own test. This is what
 * reaches both.
 *
 * **Symmetric, HS256, with the algorithm pinned** — the founder decision of 2026-08-21 (Sauransh with
 * Bhavya). Supabase Auth is the login service; this gateway verifies its tokens locally with the
 * project's JWT secret and never implements a sign-in of its own. Verifying locally rather than
 * asking the provider per request is what keeps an authenticated route from inheriting the
 * provider's latency and availability — and it is why the check below has to be exactly right, since
 * nothing downstream will second-guess it.
 *
 * **Why the algorithm pin is the first thing this file does.** A verifier that reads `alg` out of the
 * token and dispatches on it is a verifier the attacker configures. Two forgeries follow from that
 * and both are the classic ones: `alg: "none"`, which asks the verifier to skip the signature it is
 * being handed; and algorithm confusion, where a token declares `RS256` (or `HS512`, or anything
 * else) and the verifier reaches for a different key type or a different digest than the one the
 * secret is for. **A library default is not a pin** — several JWT libraries accept whatever the
 * header says unless told otherwise, which is why the ticket names this explicitly. Here the header's
 * `alg` is compared to the literal `"HS256"` and every other value is a refusal, so there is no
 * dispatch to confuse.
 *
 * **The secret's bytes are the key.** Supabase's GoTrue signs with the JWT secret's raw UTF-8 bytes
 * rather than a base64 decoding of it, so `createHmac("sha256", secret)` is the matching operation.
 * Decoding it first would produce a key nobody signs with and a gateway that rejects every real
 * token — which fails safe, but fails.
 *
 * **What this file deliberately does not do:** it does not ask whether the session behind a valid
 * token is still live at the provider. A Supabase access token is self-contained, so signing out
 * revokes the *refresh* family and leaves an already-issued access token cryptographically valid
 * until its own `exp` **plus the tolerance below** — `exp` alone understates it by
 * `EXPIRY_SKEW_TOLERANCE_SECONDS` (PR #104's adversarial review, F9, which named three statements of
 * this window; a sweep for the phrase found this one and `routes/auth.ts`'s as well). `gate.ts`
 * covers the part this gateway can see — a closed or deleted account is refused on every request —
 * and the residual is stated there and in `server/README.md` rather than papered over.
 */

/** The three project-specific values a verification is judged against. */
export interface SupabaseJwtPolicy {
  /** The project's JWT secret. Gateway-only: never in the app, never in this repository. */
  readonly secret: string;
  /** The project's auth URL, e.g. `https://<ref>.supabase.co/auth/v1`. Compared exactly. */
  readonly issuer: string;
  /** Supabase's own default is `authenticated`. Compared exactly, or against each array member. */
  readonly audience: string;
}

/**
 * Why a token was refused. Every value maps to exactly one contract §7.2 code in `gate.ts`, and the
 * split is the one the client acts on: `expired` is the only case where refreshing and retrying is
 * the right response, so it is the only one that becomes `auth.token_expired`.
 */
export type TokenRefusal =
  | "malformed"
  | "algorithm"
  | "signature"
  | "issuer"
  | "audience"
  | "subject"
  | "not_yet_valid"
  | "expired";

export interface VerifiedAccessToken {
  /** The `sub` claim — the Supabase user id, which the founder decision says to trust as the user. */
  readonly supabaseUserId: string;
  readonly expiresAt: Date;
  /** True when the token was past `exp` but inside `clock.ts`'s one-directional tolerance. */
  readonly withinSkewTolerance: boolean;
}

export type TokenVerdict =
  | { readonly ok: true; readonly token: VerifiedAccessToken }
  | { readonly ok: false; readonly refusal: TokenRefusal };

/**
 * A ceiling on what is worth hashing, applied before any parsing.
 *
 * A real Supabase access token is under a kilobyte. This is not a security boundary — Node caps
 * request headers long before this — it is a refusal to spend an HMAC over a megabyte of attacker
 * text on an unauthenticated path.
 */
const MAX_TOKEN_LENGTH = 8192;

/**
 * The shape `sonny.identity.supabase_user_id` is declared as.
 *
 * **Checked here so that a malformed `sub` is a 401 rather than a 500.** The column is `uuid`, so a
 * `sub` that is not one cannot name any identity this gateway has ever stored — and handing it to
 * the attribution query would raise Postgres' `22P02` (invalid input syntax for type uuid) out of a
 * request path whose error handler turns anything unmapped into `server.error`. A refusal is both the
 * accurate answer and the quiet one.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const BASE64URL = /^[A-Za-z0-9_-]+$/;

/**
 * Strict base64url, decoded only if the input is the canonical encoding of what comes back.
 *
 * `Buffer.from(s, "base64url")` is lenient in two ways that matter here. It ignores characters
 * outside the alphabet, so `eyJhbGci*!*` decodes to the same bytes as `eyJhbGci` — which would let
 * two different strings carry one signature-bearing header. And it accepts a final quantum whose
 * unused bits are set, so a segment can be perturbed without changing the bytes it decodes to. The
 * regex closes the first and the re-encode comparison closes the second: what is decoded is the only
 * string that encodes to itself.
 */
function decodeSegment(segment: string): Buffer | undefined {
  if (segment.length === 0 || !BASE64URL.test(segment)) return undefined;
  const decoded = Buffer.from(segment, "base64url");
  // **One check, not two.** A `segment.length % 4 === 1` guard stood above this line and was dead
  // rather than merely uncovered (PR #104's adversarial review, F8): neutralising it left the suite
  // green, because a 4n+1 length has a trailing quantum of six bits, `Buffer` drops it as it cannot
  // form a byte, and the re-encoding below is then shorter than what came in. Removed rather than
  // kept as defence in depth, for the reason `identity.ts` gives for deleting rule 2's account lock:
  // a guard that cannot run is not a second defence, it is a claim about a case the next reader will
  // reason from. `theOnlyCheckRefusesA4nPlus1Segment` is what keeps the surviving line honest.
  if (decoded.toString("base64url") !== segment) return undefined;
  return decoded;
}

/** JSON that is an object, not an array, not `null`, not a bare number. */
function decodeJsonObject(bytes: Buffer): Record<string, unknown> | undefined {
  let value: unknown;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    return undefined;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

/** A NumericDate claim, or `undefined` when it is absent or is not a usable instant. */
function numericDate(value: unknown): Date | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  const date = new Date(value * 1000);
  // `new Date(1e300 * 1000)` is an Invalid Date, and every comparison against one is false — so an
  // absurd `exp` would read as "not expired" to arithmetic that did not check.
  if (Number.isNaN(date.getTime())) return undefined;
  return date;
}

/** Does `aud` — a string, or an array of them per RFC 7519 §4.1.3 — contain the expected value? */
function audienceMatches(claim: unknown, expected: string): boolean {
  if (typeof claim === "string") return claim === expected;
  if (Array.isArray(claim)) return claim.some((entry) => entry === expected);
  return false;
}

/**
 * Verify a compact-serialised HS256 JWT against the policy, judged at `now`.
 *
 * `now` is the **server's** clock and is never a value the caller sent, for the reason `clock.ts`
 * gives: a client-supplied instant reaching the expiry check would let the caller decide whether its
 * own token had expired.
 *
 * **Check order is deliberate.** The signature is verified before any claim is read, so a token this
 * gateway did not sign never reaches the code that decides between `auth.unauthenticated` and
 * `auth.token_expired` — a forged token must not be able to ask the client to go and refresh. And
 * `exp` is checked last, so a token that is both expired and addressed to another project is refused
 * as the wrong issuer: reporting expiry there would invite a refresh-and-retry loop against a
 * gateway that will never accept it.
 */
export function verifyAccessToken(
  compact: string,
  policy: SupabaseJwtPolicy,
  now: Date,
): TokenVerdict {
  if (compact.length === 0 || compact.length > MAX_TOKEN_LENGTH) {
    return { ok: false, refusal: "malformed" };
  }

  // Exactly three segments. Two is the shape an `alg: "none"` forgery arrives in (JWS allows an
  // empty signature segment, and a bare `header.payload` is the other spelling); five is JWE, which
  // this gateway does not accept at all.
  const segments = compact.split(".");
  if (segments.length !== 3) return { ok: false, refusal: "malformed" };
  const [encodedHeader, encodedPayload, encodedSignature] = segments as [string, string, string];

  const headerBytes = decodeSegment(encodedHeader);
  if (!headerBytes) return { ok: false, refusal: "malformed" };
  const header = decodeJsonObject(headerBytes);
  if (!header) return { ok: false, refusal: "malformed" };

  // **The pin.** One literal, compared with `!==`, before anything reads the signature — so there is
  // no algorithm dispatch for a header to steer. `alg: "none"`, `HS512`, `RS256` and every other
  // value land here identically.
  if (header["alg"] !== "HS256") return { ok: false, refusal: "algorithm" };
  // RFC 7515 §4.1.11: `crit` names header parameters the verifier MUST understand. This verifier
  // understands no extensions, so any `crit` at all is a refusal rather than something to ignore.
  if (header["crit"] !== undefined) return { ok: false, refusal: "malformed" };
  const typ = header["typ"];
  if (typ !== undefined && (typeof typ !== "string" || typ.toUpperCase() !== "JWT")) {
    return { ok: false, refusal: "malformed" };
  }

  const signature = decodeSegment(encodedSignature);
  if (!signature) return { ok: false, refusal: "malformed" };
  const expected = createHmac("sha256", policy.secret)
    .update(`${encodedHeader}.${encodedPayload}`)
    .digest();
  // `timingSafeEqual` throws on a length mismatch, so the length is compared first. That comparison
  // is not constant-time and does not need to be: the length of an HMAC-SHA256 digest is public.
  if (signature.length !== expected.length) return { ok: false, refusal: "signature" };
  if (!timingSafeEqual(signature, expected)) return { ok: false, refusal: "signature" };

  const payloadBytes = decodeSegment(encodedPayload);
  if (!payloadBytes) return { ok: false, refusal: "malformed" };
  const payload = decodeJsonObject(payloadBytes);
  if (!payload) return { ok: false, refusal: "malformed" };

  if (payload["iss"] !== policy.issuer) return { ok: false, refusal: "issuer" };
  if (!audienceMatches(payload["aud"], policy.audience)) return { ok: false, refusal: "audience" };

  const subject = payload["sub"];
  if (typeof subject !== "string" || !UUID.test(subject)) return { ok: false, refusal: "subject" };

  // **`nbf` gets no tolerance, and `iat` is not a gate at all.** `clock.ts` states the rule: tolerance
  // is granted to a token that looks *expired* and never to one that looks *not yet valid*, because a
  // token from the future is either this server's clock being wrong — which tolerance cannot fix — or
  // a forged claim, which tolerance must not help. `iat` is left alone on the other side of the same
  // reasoning: it is a statement about when the *issuer* minted the token, so a gateway clock a second
  // behind Supabase's would refuse every freshly issued token, and refusing a token for being too new
  // buys nothing that `nbf` and the signature do not already give.
  if (payload["nbf"] !== undefined) {
    const notBefore = numericDate(payload["nbf"]);
    if (!notBefore) return { ok: false, refusal: "malformed" };
    if (notBefore.getTime() > now.getTime()) return { ok: false, refusal: "not_yet_valid" };
  }

  // **A token with no `exp` is refused as malformed, not treated as unexpiring.** Absent expiry is
  // the third forgery in the same family as `alg: "none"`: it asks the verifier to drop a check by
  // omitting its input. `malformed` rather than `expired` on purpose — telling a client to refresh
  // and retry a token that will never expire is a loop, and the token is not expired, it is wrong.
  const expiresAt = numericDate(payload["exp"]);
  if (!expiresAt) return { ok: false, refusal: "malformed" };
  const verdict = isExpiryAcceptable(expiresAt, now);
  if (!verdict.valid) return { ok: false, refusal: "expired" };

  return {
    ok: true,
    token: {
      supabaseUserId: subject,
      expiresAt,
      withinSkewTolerance: verdict.withinTolerance,
    },
  };
}
