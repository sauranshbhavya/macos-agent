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
 * this window; a sweep for the phrase found this one and `routes/auth.ts`'s as well).
 *
 * **What closes most of that is local after all, and it is not this file's** (SONNY-237). Asking the
 * provider is not the only way to know a session is over: this gateway is *told*, by the sign-out
 * request it serves. `auth/denylist.ts` records the `session_id` this file now extracts and
 * `gate.ts` consults it on every authenticated request, so a signed-out token stops verifying inside
 * the window above rather than at the end of it. This file's contribution is the claim and nothing
 * more — it still asks the provider nothing, and a token whose session is denylisted is *valid* here
 * and refused one layer out, which is the same division `gate.ts` already makes for a closed
 * account. The residual left over is a token carrying no `session_id` at all, stated on
 * `providerSessionId` below, in `gate.ts` and in `server/README.md`.
 */

/**
 * One secret this gateway will verify a signature against, and the instant it stops doing so.
 *
 * **A verifying secret is a signing secret** — HS256 is symmetric, so anyone holding this value can
 * mint a token for any user. That is the whole reason `SUPABASE_JWT_SECRET` was a single value until
 * SONNY-238: every extra secret the gateway still honours extends the blast radius of a leaked one,
 * and the sign-out that a rotation caused was judged the smaller cost. What changes that trade is
 * giving the extra secret an **end**, which is what `acceptedUntil` is.
 */
export interface AcceptedJwtSecret {
  /** The project's JWT secret. Gateway-only: never in the app, never in this repository. */
  readonly value: string;
  /**
   * The instant after which this secret is no longer accepted, or `undefined` for one that is
   * accepted for as long as it is configured.
   *
   * **Only the current secret carries `undefined`**, and `requireSupabaseJwtPolicy` is what builds it
   * that way. An overlap secret with no end is the failure the founders decided against on
   * 2026-08-30 — "left in the environment and forgotten" is indistinguishable from never having
   * rotated — so the configuration refuses one at startup rather than leaving the ending to a person.
   *
   * **Read against the server's clock inside `verifyAccessToken`, not once at startup.** A deadline
   * checked at boot ends the overlap on the next restart, which on a gateway that does not restart is
   * no ending at all; checked per request, it ends on time whatever the process has been doing.
   */
  readonly acceptedUntil: Date | undefined;
}

/** The project-specific values a verification is judged against. */
export interface SupabaseJwtPolicy {
  /**
   * The secrets a signature may match, in the order they are tried. Index 0 is the current one.
   *
   * **An ordered list rather than a `current`/`previous` pair**, for the reason `server/README.md`
   * gives for the provider credentials being one: with two named fields, retiring the current secret
   * means editing two variables at once and a deploy that catches them half-applied has either a
   * duplicate or none. **The direction is the mirror of a provider credential's**, which is worth
   * having straight before reading the runbook: a provider key is one this gateway *sends*, so that
   * list is "what to try"; this is one Supabase *signs* with and this gateway only verifies, so this
   * list is "what to accept" and the overlap has to straddle the moment Supabase's own value changes.
   * `SUPABASE_JWT_SECRET_2` is therefore the *incoming* secret in one deploy and the *retiring* one in
   * the next.
   *
   * Never empty: `requireSupabaseJwtPolicy` refuses a configuration with no current secret. A policy
   * built by hand with an empty list refuses every token, which is the safe direction.
   */
  readonly secrets: readonly AcceptedJwtSecret[];
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
  | "session"
  | "not_yet_valid"
  | "expired";

export interface VerifiedAccessToken {
  /** The `sub` claim — the Supabase user id, which the founder decision says to trust as the user. */
  readonly supabaseUserId: string;
  readonly expiresAt: Date;
  /** True when the token was past `exp` but inside `clock.ts`'s one-directional tolerance. */
  readonly withinSkewTolerance: boolean;
  /**
   * The `session_id` claim — Supabase's own id for the login session this token belongs to — or
   * `undefined` when the token carries none (SONNY-237).
   *
   * **This is the only thing a local verifier can key a revocation on**, and `auth/denylist.ts` is
   * what does. It survives a refresh: the same session mints a succession of access tokens under one
   * id, which is what makes "this session is signed out" a durable statement rather than a statement
   * about one string.
   *
   * **`undefined` is a real value and not a defensive branch.** GoTrue declares the claim
   * `omitempty` and handles its absence itself — `internal/api/logout.go:52` logs
   * `"user has an empty session_id claim"` and then signs the user out globally whatever scope was
   * asked for. So a token without one is a shape the provider mints, and it is the shape the
   * denylist cannot cover; migration 0022's header carries the evidence and `gate.ts` states the
   * residual.
   *
   * **Not contract §5.2's task session**, which is a different thing with the same spelling and is
   * carried by the metering and content tables. Nothing in this file or the denylist uses the bare
   * word.
   */
  readonly providerSessionId: string | undefined;
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
  // **The overlap, and the whole of it** (SONNY-238). Each accepted secret is tried in order and the
  // first match wins, which is at most two HMACs. Everything that decides whether a token is
  // acceptable — the pin above, and `iss`, `aud`, `sub`, `session_id`, `nbf` and `exp` below — sits
  // outside this loop and always did, so a second accepted secret cannot arrive with a relaxed check
  // behind it. The ticket names that as the thing that would be worse than the sign-out it avoids;
  // `theSecondSecretGetsNoWeakerChecksThanTheFirst` in `token.test.ts` is what holds it.
  //
  // **A secret past its `acceptedUntil` is skipped rather than matched**, judged against the same
  // `now` every other time-dependent check here uses. This is where the overlap actually ends: no
  // restart, no deploy, no operator. `>=` rather than `>` so the stated instant is the first one at
  // which the secret is refused, matching how `acceptedUntil` reads.
  let signatureMatched = false;
  for (const accepted of policy.secrets) {
    if (accepted.acceptedUntil !== undefined && now.getTime() >= accepted.acceptedUntil.getTime()) {
      continue;
    }
    const expected = createHmac("sha256", accepted.value)
      .update(`${encodedHeader}.${encodedPayload}`)
      .digest();
    // `timingSafeEqual` throws on a length mismatch, so the length is compared first. That comparison
    // is not constant-time and does not need to be: the length of an HMAC-SHA256 digest is public.
    if (signature.length !== expected.length) continue;
    if (timingSafeEqual(signature, expected)) {
      signatureMatched = true;
      break;
    }
  }
  // Reached with no accepted secret configured, with every one of them retired, and with a signature
  // matching none — three different configurations, one answer, and the safe one in all three.
  if (!signatureMatched) return { ok: false, refusal: "signature" };

  const payloadBytes = decodeSegment(encodedPayload);
  if (!payloadBytes) return { ok: false, refusal: "malformed" };
  const payload = decodeJsonObject(payloadBytes);
  if (!payload) return { ok: false, refusal: "malformed" };

  if (payload["iss"] !== policy.issuer) return { ok: false, refusal: "issuer" };
  if (!audienceMatches(payload["aud"], policy.audience)) return { ok: false, refusal: "audience" };

  const subject = payload["sub"];
  if (typeof subject !== "string" || !UUID.test(subject)) return { ok: false, refusal: "subject" };

  // **A `session_id` that is present and unusable is a refusal, not an absence** (SONNY-237). The
  // two readings are one line apart and opposite in effect: treating a malformed claim as absent
  // would make the token silently undenylistable, which is the one property the denylist exists to
  // provide, and it would do it quietly. Refusing costs nothing real — Supabase mints the claim as a
  // uuid (`internal/api/token.go:311` reads it back with `uuid.FromString`) and omits it entirely
  // when there is none, so no token this gateway is meant to accept lands here. The column it is
  // bound to is `uuid`, which is the same reason `sub` is shape-checked above: a malformed value
  // reaching the query raises Postgres' `22P02` out of a request path instead of a refusal.
  const claimedSession = payload["session_id"];
  let providerSessionId: string | undefined;
  if (claimedSession !== undefined) {
    if (typeof claimedSession !== "string" || !UUID.test(claimedSession)) {
      return { ok: false, refusal: "session" };
    }
    providerSessionId = claimedSession;
  }

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
      providerSessionId,
    },
  };
}
