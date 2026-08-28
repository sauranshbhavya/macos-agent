import { createPrivateKey, createPublicKey, sign as signBytes, type KeyObject } from "node:crypto";

/**
 * The signed entitlement claim of contract §5.3 — its four durations, its payload, and the one
 * function that mints it (SONNY-135).
 *
 * **Everything here is mechanism. None of it is a plan, a price, an allowance or a credit weight.**
 * `plan` and `capabilities` are opaque values read out of `sonny.entitlement`; which capability keys
 * are gated is row 18's (SONNY-23), and what the tiers are is SONNY-212's. What this file decides is
 * how long a claim lives, how far past its life a client may still honour it, and how much clock
 * disagreement it absorbs — the three values contract §13 assigns to this ticket, plus the refresh
 * cadence they only make sense beside.
 *
 * ## Why EdDSA and not the HS256 the access tokens use
 *
 * `auth/token.ts` verifies Supabase's access tokens with a **shared secret**, which is right there:
 * the same process that verifies also has to be able to talk to the project. It is exactly wrong
 * here. This claim is verified **on every user's Mac**, and a symmetric algorithm would mean every
 * copy of the app shipping a key that can *mint* a claim for any user with any capability list. The
 * client holds a public key and can verify; only the gateway can sign. That asymmetry is the whole
 * reason the contract names EdDSA.
 *
 * The algorithm is written into the header as a literal and the verifier pins it as a literal, the
 * same way `auth/token.ts` pins `HS256` — a verifier that reads `alg` out of the token is a verifier
 * the attacker configures, and `alg: "none"` plus algorithm confusion are the two forgeries that
 * follow.
 */

/** The claim payload's schema version. §5.3's `v`. */
export const ENTITLEMENT_CLAIM_VERSION = 1;

/**
 * How long a minted claim is valid: **24 hours**.
 *
 * **This number is one half of the revocation bound and is chosen against the grace window below,
 * not on its own.** §5.3: "Revocation reaches a live client within the claim's lifetime, because
 * that lifetime is the bound." That sentence is true of an *online* client and understates the
 * offline case, which is why the two constants are documented together here rather than apart:
 *
 * - **Online**, a client refreshes at `refresh_after` — 8 hours — so a cancelled subscription stops
 *   working within 8 hours of the cancellation, not 24. The refresh is what carries the new,
 *   capability-less claim; nothing has to expire for it to take effect.
 * - **Offline**, nothing can be delivered, so the bound is the claim's own life plus the grace
 *   window: **24 h + 72 h = 96 hours**, four days, on a Mac that never reaches the network in that
 *   time. The moment it does, the refusal is immediate.
 *
 * Shorter than 24 h buys a tighter offline bound and costs a refresh that has to succeed more often
 * for an online user to stay working; longer widens the window a revoked plan survives in. A day is
 * where those two meet: it is short enough that "cancelled yesterday" is already enforced for anyone
 * who has opened their laptop, and long enough that a claim is not a per-request dependency.
 */
export const ENTITLEMENT_LIFETIME_SECONDS = 24 * 60 * 60;

/**
 * When a client should refresh: **8 hours** after issue, a third of the lifetime.
 *
 * A third rather than a half, so a client gets **two** refresh opportunities before its claim
 * expires. One missed refresh — a laptop closed over the window, a five-minute outage that happens
 * to land on it — must not put a paying user into the grace window, because grace is the mechanism
 * for being genuinely offline and spending it on an ordinary hiccup leaves nothing for the flight.
 */
export const ENTITLEMENT_REFRESH_AFTER_SECONDS = 8 * 60 * 60;

/**
 * How long past expiry a client may still honour a cached claim: **72 hours**.
 *
 * §5.3's requirement is that "a user on a plane or with bad wifi is not locked out the moment a
 * token expires", and the sizing question is which real absence to cover. A long-haul flight is
 * under 24 hours; a weekend somewhere with no usable connection is about 72. So 72 covers the
 * realistic worst case a paying user meets by accident.
 *
 * **What it costs is stated rather than implied**: it is the second half of the 96-hour offline
 * revocation bound above. A cancelled plan on a Mac that stays offline keeps working for up to four
 * days. That is the deliberate trade — the alternative is locking out a paying customer on a plane,
 * which is a certainty rather than a risk, against a revoked customer who has also disconnected
 * themselves from the service they are trying to keep using.
 *
 * **Grace is not a second lifetime, and the client is what keeps that true.** A claim inside grace
 * is honoured only because nothing newer could be fetched; any successful refresh replaces it
 * immediately, including one that comes back with no capabilities at all.
 */
export const ENTITLEMENT_GRACE_SECONDS = 72 * 60 * 60;

/**
 * How much clock disagreement a client absorbs when it judges this claim: **300 seconds**.
 *
 * **Not §3.5's 30 seconds, and the difference is which clock is being doubted.** That value is the
 * server judging an access token against *its own* clock, where the only error is network latency
 * and ordinary NTP drift, and where every extra second is a second a revoked token still works. This
 * one is a **client** judging a claim against a clock **the user controls**, with no round trip
 * available to correct it — the offset a client keeps from the `Date` header (§3.5) tracks drift
 * since the last response and cannot see a clock that has been changed since.
 *
 * Five minutes is the size of an honest error: a Mac whose NTP sync has been unavailable for days
 * drifts by seconds, a virtual machine resuming from suspend can be out by minutes, and anything
 * larger than that is not drift but a clock somebody set. Against the 72-hour grace window it is
 * 0.1%, so it cannot meaningfully extend the window a revoked claim survives in.
 *
 * **It is applied in both directions, and that is the opposite of `auth/clock.ts`'s rule.** There,
 * tolerance is granted to a token that looks expired and never to one that looks not-yet-valid,
 * because a token from the future is either the server's own clock being wrong or a forgery.
 * Neither reason holds here. The claim's `issued_at` is *signed by the gateway*, so a forgery cannot
 * choose it; and a claim that looks not-yet-valid on a Mac means that Mac's clock is behind, which
 * is precisely the error this tolerance exists for. Inverting the rule where the reasoning inverts
 * is the point; the client's `EntitlementVerifier` states the same thing from its side.
 */
export const ENTITLEMENT_SKEW_TOLERANCE_SECONDS = 300;

/** §5.3's payload, as it is signed. Field names are the wire's, so this type is the wire format. */
export interface EntitlementClaimPayload {
  readonly v: number;
  readonly sub: string;
  readonly plan: string;
  readonly capabilities: readonly string[];
  readonly issued_at: string;
  readonly expires_at: string;
  readonly grace_seconds: number;
  readonly skew_tolerance_seconds: number;
}

/** §5.3's response body around it. */
export interface EntitlementClaimResponse {
  readonly entitlement: string;
  readonly expires_at: string;
  readonly refresh_after: string;
}

/** What the claim is minted from: the account, and what `sonny.entitlement` says about it. */
export interface EntitlementFacts {
  readonly subject: string;
  readonly plan: string;
  readonly capabilities: readonly string[];
}

/** The key this gateway signs with, and the `kid` that names it in the JWS header. */
export interface EntitlementSigningKey {
  readonly keyId: string;
  readonly privateKey: KeyObject;
}

/**
 * Seconds, ISO-8601 with no fractional part — the form §5.3's example uses and the form every other
 * instant on this wire takes (`auth/clock.ts`'s `expiryFields` does the same).
 */
export function isoSeconds(instant: Date): string {
  return instant.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function base64url(value: Buffer | string): string {
  return (typeof value === "string" ? Buffer.from(value, "utf8") : value).toString("base64url");
}

/**
 * Mint and sign one claim.
 *
 * **Every instant is derived from the single `issuedAt` argument**, so `expires_at` in the payload,
 * `expires_at` in the envelope and `refresh_after` cannot disagree by a millisecond of clock read —
 * the same reasoning `auth/clock.ts`'s `expiryFields` gives for deriving `expires_in` and
 * `expires_at` from one instant.
 *
 * `issuedAt` is the **server's** clock and is never a value the caller sent. A client-supplied
 * instant reaching here would let the caller choose how long its own entitlement lasts.
 */
export function mintEntitlementClaim(
  facts: EntitlementFacts,
  key: EntitlementSigningKey,
  issuedAt: Date,
): EntitlementClaimResponse {
  const expiresAt = new Date(issuedAt.getTime() + ENTITLEMENT_LIFETIME_SECONDS * 1000);
  const refreshAfter = new Date(issuedAt.getTime() + ENTITLEMENT_REFRESH_AFTER_SECONDS * 1000);
  const payload: EntitlementClaimPayload = {
    v: ENTITLEMENT_CLAIM_VERSION,
    sub: facts.subject,
    plan: facts.plan,
    // Copied into a plain array so the JSON is the same shape whatever the caller passed.
    capabilities: [...facts.capabilities],
    issued_at: isoSeconds(issuedAt),
    expires_at: isoSeconds(expiresAt),
    grace_seconds: ENTITLEMENT_GRACE_SECONDS,
    skew_tolerance_seconds: ENTITLEMENT_SKEW_TOLERANCE_SECONDS,
  };

  // `typ: "JWT"` is what a compact JWS carrying a JSON payload declares, and `kid` is what §5.3
  // makes the key selector: "the signing key named by the JWS header's `kid`". A client that has
  // never heard of this `kid` refuses rather than trying every key it holds.
  const header = { alg: "EdDSA", typ: "JWT", kid: key.keyId };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  // Ed25519 signs the message itself: the algorithm identifier is `null`, not a digest name, and
  // passing one is an error rather than a different digest.
  const signature = signBytes(null, Buffer.from(signingInput, "utf8"), key.privateKey);

  return {
    entitlement: `${signingInput}.${base64url(signature)}`,
    expires_at: payload.expires_at,
    refresh_after: isoSeconds(refreshAfter),
  };
}

/**
 * The raw 32 bytes of the public half, base64url — the form a client's shipped key set holds.
 *
 * **Derived from the private key rather than configured beside it**, so the two cannot be set to a
 * mismatched pair: a gateway signing with one key while publishing another's public half would
 * produce claims every client rejects, and the failure would look like a client bug.
 *
 * The SPKI DER of an Ed25519 public key is a 12-byte prefix followed by the 32 raw bytes, which is
 * what `Curve25519.Signing.PublicKey(rawRepresentation:)` on the Mac takes.
 */
export function publicKeyMaterial(key: EntitlementSigningKey): string {
  const spki = createPublicKey(key.privateKey).export({ type: "spki", format: "der" });
  return spki.subarray(spki.length - 32).toString("base64url");
}

export class EntitlementKeyError extends Error {}

/**
 * Build the signing key from configuration: base64 of a PKCS#8 DER Ed25519 private key.
 *
 * **Base64 of DER rather than PEM**, because a PEM is multi-line and an environment variable is
 * not: every deployment mechanism this gateway targets passes a single string, and the encodings
 * that survive that are the ones without newlines.
 *
 *   openssl genpkey -algorithm ed25519 -outform DER | base64
 *
 * **The curve is checked rather than assumed.** A P-256 or RSA key would parse here perfectly well
 * and then sign with a different algorithm than the `EdDSA` this gateway writes into every header,
 * so every client would reject every claim — a deployment error that presents as a product bug.
 */
export function entitlementSigningKeyFrom(
  encodedKey: string,
  keyId: string,
): EntitlementSigningKey {
  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey({
      key: Buffer.from(encodedKey.trim(), "base64"),
      format: "der",
      type: "pkcs8",
    });
  } catch (error) {
    // The message never carries the value: this is a signing key, and a parse error that echoed it
    // would put it in a log line. `error` is not attached for the same reason — node's own message
    // for a malformed key can quote the input.
    throw new EntitlementKeyError(
      "ENTITLEMENT_SIGNING_KEY is not base64-encoded PKCS#8 DER. Generate one with: " +
        "openssl genpkey -algorithm ed25519 -outform DER | base64",
    );
  }
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new EntitlementKeyError(
      `ENTITLEMENT_SIGNING_KEY is a ${String(privateKey.asymmetricKeyType)} key; the entitlement ` +
        "claim is signed with Ed25519 (contract section 5.3). Generate one with: " +
        "openssl genpkey -algorithm ed25519 -outform DER | base64",
    );
  }
  return { keyId, privateKey };
}
