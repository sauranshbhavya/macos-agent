import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { EXPIRY_SKEW_TOLERANCE_SECONDS } from "../src/auth/clock.js";
import { verifyAccessToken, type TokenRefusal } from "../src/auth/token.js";
import {
  TEST_JWT_POLICY, accessTokenFor, base64url, claimsFor, signToken, tokenWithClaims,
} from "./support/tokens.js";

/**
 * The forgery battery (SONNY-203).
 *
 * This is the gate that decides whether a request is authenticated at all, so the tests are written
 * as attacks rather than as coverage: each one is a token that is wrong in exactly one way, and each
 * asserts the specific refusal rather than merely "not accepted". The distinction matters — a
 * verifier that refused everything would pass a suite that only checked truthiness, and so would one
 * that reported every failure as `auth.token_expired` and put every client into a refresh loop.
 */

const USER = "11111111-1111-1111-1111-111111111111";
const NOW = new Date("2026-08-22T12:00:00Z");

/** The refusal, or `"accepted"` — so an assertion reads as one value rather than a branch. */
function refusalOf(token: string, now: Date = NOW): TokenRefusal | "accepted" {
  const verdict = verifyAccessToken(token, TEST_JWT_POLICY, now);
  return verdict.ok ? "accepted" : verdict.refusal;
}

describe("verifyAccessToken — the honest cases", () => {
  it("accepts a well-formed Supabase token and returns the sub as the user id", () => {
    const verdict = verifyAccessToken(accessTokenFor(USER, { now: NOW }), TEST_JWT_POLICY, NOW);
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.token.supabaseUserId).toBe(USER);
    expect(verdict.token.withinSkewTolerance).toBe(false);
    expect(verdict.token.expiresAt.toISOString()).toBe("2026-08-22T13:00:00.000Z");
  });

  it("accepts an aud carrying the expected value among others, per RFC 7519 §4.1.3", () => {
    expect(refusalOf(tokenWithClaims(USER, { aud: ["authenticated", "other"] }))).toBe("accepted");
  });

  it("accepts a token carrying claims this gateway does not read", () => {
    // A verifier that refused unknown claims would refuse every real token the day Supabase adds
    // one. `role`, `session_id`, `app_metadata` and friends ride along untouched.
    const token = tokenWithClaims(USER, {
      app_metadata: { provider: "email" },
      user_metadata: { nickname: "sam" },
      amr: [{ method: "otp", timestamp: 1 }],
    });
    expect(refusalOf(token)).toBe("accepted");
  });
});

describe("verifyAccessToken — the algorithm pin", () => {
  it("refuses alg:none carrying an empty signature segment — at the pin, before the segment", () => {
    // The canonical `alg: "none"` serialisation: three segments, the last one empty. It is refused
    // as `algorithm` rather than `malformed` because the pin runs before anything reads the
    // signature at all, which is the ordering that makes the pin a pin.
    const header = base64url(JSON.stringify({ alg: "none", typ: "JWT" }));
    const claims = base64url(JSON.stringify(claimsFor(USER, { now: NOW })));
    expect(refusalOf(`${header}.${claims}.`)).toBe("algorithm");
  });

  it("refuses alg:none written as two segments, which is the other spelling of the same forgery", () => {
    const header = base64url(JSON.stringify({ alg: "none", typ: "JWT" }));
    const claims = base64url(JSON.stringify(claimsFor(USER, { now: NOW })));
    expect(refusalOf(`${header}.${claims}`)).toBe("malformed");
  });

  it("refuses alg:none even when a plausible signature is attached", () => {
    // The shape a forger actually sends: the structure of a real token with the algorithm swapped,
    // so a verifier that dispatches on `alg` skips the check it is holding the input for.
    expect(refusalOf(tokenWithClaims(USER, {}, { header: { alg: "none", typ: "JWT" } })))
      .toBe("algorithm");
  });

  it.each(["HS384", "HS512", "RS256", "ES256", "PS256", "hs256", "HS256 ", ""])(
    "refuses alg:%s — the pin is one literal, not a family",
    (alg) => {
      expect(refusalOf(tokenWithClaims(USER, {}, { header: { alg, typ: "JWT" } })))
        .toBe("algorithm");
    },
  );

  it("refuses a header with no alg at all", () => {
    expect(refusalOf(tokenWithClaims(USER, {}, { header: { typ: "JWT" } }))).toBe("algorithm");
  });

  it("refuses an RS256-style forgery signed with the HMAC secret — algorithm confusion", () => {
    // The confusion attack in full: the token declares an asymmetric algorithm while its signature
    // is a valid HMAC over the secret. A verifier that read `alg` and reached for the matching
    // primitive would either verify this with the wrong key type or hand the secret to an RSA path.
    const token = signToken({ alg: "RS256", typ: "JWT" }, claimsFor(USER, { now: NOW }));
    expect(refusalOf(token)).toBe("algorithm");
  });

  it("refuses a header carrying crit, which names extensions this verifier does not implement", () => {
    const token = tokenWithClaims(USER, {}, {
      header: { alg: "HS256", typ: "JWT", crit: ["exp"] },
    });
    expect(refusalOf(token)).toBe("malformed");
  });

  it("refuses a typ that is not JWT, and accepts the lowercase spelling of one that is", () => {
    expect(refusalOf(tokenWithClaims(USER, {}, { header: { alg: "HS256", typ: "JWE" } })))
      .toBe("malformed");
    expect(refusalOf(tokenWithClaims(USER, {}, { header: { alg: "HS256", typ: "jwt" } })))
      .toBe("accepted");
    expect(refusalOf(tokenWithClaims(USER, {}, { header: { alg: "HS256" } }))).toBe("accepted");
  });
});

describe("verifyAccessToken — the signature", () => {
  it("refuses a token signed with a different secret", () => {
    const token = tokenWithClaims(USER, {}, { secret: "a-different-secret-of-adequate-length!!" });
    expect(refusalOf(token)).toBe("signature");
  });

  it("refuses a token whose claims were edited after signing", () => {
    // The attack the signature exists for: take a real token for one user and rewrite `sub`.
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, , signature] = honest.split(".") as [string, string, string];
    const forgedClaims = base64url(
      JSON.stringify({ ...claimsFor(USER, { now: NOW }), sub: "22222222-2222-2222-2222-222222222222" }),
    );
    expect(refusalOf(`${header}.${forgedClaims}.${signature}`)).toBe("signature");
  });

  it("refuses a truncated signature rather than throwing on the length mismatch", () => {
    // `timingSafeEqual` throws a RangeError on unequal lengths, which inside a request hook is a 500
    // rather than a 401 — so the length is compared first. This is that guard.
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    expect(refusalOf(`${header}.${claims}.${signature.slice(0, 20)}`)).toBe("signature");
  });

  it("refuses a SECOND SPELLING of a valid signature — strict base64url, not lenient", () => {
    // A 32-byte HMAC encodes to 43 base64url characters, whose final character carries two unused
    // bits. Setting those bits produces a different string that `Buffer.from(s, "base64url")`
    // decodes to the identical 32 bytes — so a lenient verifier accepts both spellings, and the
    // exact bytes a client sent stop being the thing that was checked. The canonicality test in
    // `decodeSegment` is what refuses it.
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    const last = signature[signature.length - 1]!;
    const index = alphabet.indexOf(last);
    const perturbed = alphabet[(index & ~0b11) | ((index + 1) & 0b11)]!;
    expect(perturbed).not.toBe(last);
    const restated = `${signature.slice(0, -1)}${perturbed}`;
    // Same bytes — which is what makes this a real hole rather than a typo.
    expect(Buffer.from(restated, "base64url").equals(Buffer.from(signature, "base64url"))).toBe(true);
    expect(refusalOf(`${header}.${claims}.${restated}`)).toBe("malformed");
  });

  it("refuses a segment padded with '=' or carrying characters outside the alphabet", () => {
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    expect(refusalOf(`${header}.${claims}.${signature}==`)).toBe("malformed");
    expect(refusalOf(`${header}.${claims}.${signature}*`)).toBe("malformed");
  });

  it("refuses a non-canonical PAYLOAD even when the signature over it is correct", () => {
    // Reachable only by whoever holds the secret — so this is the property that a token minted by a
    // careless future adapter, rather than by an attacker, is still refused rather than silently
    // decoded. The signature is computed over the perturbed segment, so it verifies; the strict
    // decode is the only thing that refuses.
    const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const padded = `${base64url(JSON.stringify(claimsFor(USER, { now: NOW })))}=`;
    const signature = createHmac("sha256", TEST_JWT_POLICY.secret)
      .update(`${header}.${padded}`).digest("base64url");
    expect(refusalOf(`${header}.${padded}.${signature}`)).toBe("malformed");
  });

  it("verifies the signature BEFORE parsing the claims a caller controls", () => {
    // Ordering, asserted rather than assumed: a token whose payload is not decodable is refused as
    // a bad signature, which is only possible if the signature is checked first. Parsing attacker
    // JSON before authenticating it is the wrong order even when the parser is `JSON.parse`.
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    expect(refusalOf(`${header}.${claims.replace(/.$/, "+")}.${signature}`)).toBe("signature");
  });

  it("signs over the ENCODED segments, so a re-encoding of the same claims does not verify", () => {
    // Proof that the HMAC covers the compact serialisation rather than the decoded objects: the
    // claims below are identical and their JSON spelling is not.
    const claims = claimsFor(USER, { now: NOW });
    const reordered = Object.fromEntries(Object.entries(claims).reverse());
    const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const honestSignature = createHmac("sha256", TEST_JWT_POLICY.secret)
      .update(`${header}.${base64url(JSON.stringify(claims))}`)
      .digest("base64url");
    expect(refusalOf(`${header}.${base64url(JSON.stringify(reordered))}.${honestSignature}`))
      .toBe("signature");
  });
});

describe("verifyAccessToken — the claims", () => {
  it("refuses a token issued by another project, or by nobody", () => {
    expect(refusalOf(tokenWithClaims(USER, { iss: "https://other-ref.supabase.co/auth/v1" })))
      .toBe("issuer");
    expect(refusalOf(tokenWithClaims(USER, { iss: undefined }))).toBe("issuer");
    // A prefix is not a match: the comparison is exact.
    expect(refusalOf(tokenWithClaims(USER, { iss: `${TEST_JWT_POLICY.issuer}/x` }))).toBe("issuer");
  });

  it("refuses the wrong audience, a missing one, and an array that does not contain it", () => {
    expect(refusalOf(tokenWithClaims(USER, { aud: "anon" }))).toBe("audience");
    expect(refusalOf(tokenWithClaims(USER, { aud: undefined }))).toBe("audience");
    expect(refusalOf(tokenWithClaims(USER, { aud: ["anon", "service_role"] }))).toBe("audience");
    expect(refusalOf(tokenWithClaims(USER, { aud: [] }))).toBe("audience");
  });

  it("refuses a sub that is missing, empty, not a string, or not a uuid", () => {
    // Not merely hygiene: `sonny.identity.supabase_user_id` is a uuid column, so a non-uuid sub
    // reaching the attribution query is a Postgres 22P02 — a 500 out of a request path — rather
    // than a refusal.
    expect(refusalOf(tokenWithClaims(USER, { sub: undefined }))).toBe("subject");
    expect(refusalOf(tokenWithClaims(USER, { sub: "" }))).toBe("subject");
    expect(refusalOf(tokenWithClaims(USER, { sub: 7 }))).toBe("subject");
    expect(refusalOf(tokenWithClaims(USER, { sub: "not-a-uuid" }))).toBe("subject");
    expect(refusalOf(tokenWithClaims(USER, { sub: `${USER} OR 1=1` }))).toBe("subject");
  });
});

describe("verifyAccessToken — expiry, and the one-directional tolerance", () => {
  const at = (offsetSeconds: number) => new Date(NOW.getTime() + offsetSeconds * 1000);

  it("accepts a token inside its life", () => {
    expect(refusalOf(accessTokenFor(USER, { now: NOW }), at(3599))).toBe("accepted");
  });

  it("accepts a token just past exp, inside clock.ts's tolerance, and says so", () => {
    // The wiring the ticket asks for: `isExpiryAcceptable` had no caller outside its own test until
    // this file's subject reached it (PR #87 F2). A second skew policy is how two answers to one
    // question drift apart, so there is exactly one and this is it.
    const verdict = verifyAccessToken(
      accessTokenFor(USER, { now: NOW }),
      TEST_JWT_POLICY,
      at(3600 + EXPIRY_SKEW_TOLERANCE_SECONDS),
    );
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.token.withinSkewTolerance).toBe(true);
  });

  it("refuses one millisecond past the tolerance", () => {
    const past = new Date(NOW.getTime() + (3600 + EXPIRY_SKEW_TOLERANCE_SECONDS) * 1000 + 1);
    expect(refusalOf(accessTokenFor(USER, { now: NOW }), past)).toBe("expired");
  });

  it("grants NO tolerance to a token that is not yet valid — the direction clock.ts refuses", () => {
    // Tolerance absorbs a token that looks expired. A token from the future is either this server's
    // clock being wrong, which tolerance cannot fix, or a forged claim, which tolerance must not
    // help — so one second is enough to refuse.
    expect(refusalOf(tokenWithClaims(USER, { nbf: Math.floor(NOW.getTime() / 1000) + 1 })))
      .toBe("not_yet_valid");
    expect(refusalOf(tokenWithClaims(USER, { nbf: Math.floor(NOW.getTime() / 1000) })))
      .toBe("accepted");
  });

  it("does not gate on iat, so a gateway clock slightly behind the issuer still verifies", () => {
    // Deliberate, and stated in `token.ts`: `iat` describes when the issuer minted the token, so
    // refusing a token for being too new would refuse every freshly issued one whenever this
    // server's clock trailed Supabase's by a second.
    expect(refusalOf(tokenWithClaims(USER, { iat: Math.floor(NOW.getTime() / 1000) + 600 })))
      .toBe("accepted");
  });

  it("refuses a token with no exp as malformed rather than as expired", () => {
    // Same family as alg:none — a check dropped by omitting its input. `malformed` on purpose:
    // `auth.token_expired` tells the client to refresh and retry, and a token that never expires
    // would be refused identically forever.
    expect(refusalOf(tokenWithClaims(USER, { exp: undefined }))).toBe("malformed");
  });

  it("refuses an exp that is not a usable instant", () => {
    expect(refusalOf(tokenWithClaims(USER, { exp: "9999999999" }))).toBe("malformed");
    expect(refusalOf(tokenWithClaims(USER, { exp: null }))).toBe("malformed");
    // An absurd value is an Invalid Date, and every comparison against one is false — so unchecked
    // it reads as "not expired".
    expect(refusalOf(tokenWithClaims(USER, { exp: 1e300 }))).toBe("malformed");
    expect(refusalOf(tokenWithClaims(USER, { nbf: "soon" }))).toBe("malformed");
  });

  it("refuses a long-expired token", () => {
    expect(refusalOf(accessTokenFor(USER, { now: new Date("2020-01-01T00:00:00Z") }))).toBe("expired");
  });
});

describe("verifyAccessToken — check order, which decides what the client does next", () => {
  it("reports the wrong issuer rather than expiry when a token is both", () => {
    // `auth.token_expired` is the one 401 a client answers by refreshing and retrying. A token this
    // gateway will never accept must not be the one that starts that loop.
    const token = tokenWithClaims(USER, {
      iss: "https://other-ref.supabase.co/auth/v1",
      exp: Math.floor(NOW.getTime() / 1000) - 86400,
    });
    expect(refusalOf(token)).toBe("issuer");
  });

  it("reports the signature rather than expiry when a forged token is also expired", () => {
    const token = tokenWithClaims(
      USER,
      { exp: Math.floor(NOW.getTime() / 1000) - 86400 },
      { secret: "a-different-secret-of-adequate-length!!" },
    );
    expect(refusalOf(token)).toBe("signature");
  });

  it("reports the algorithm rather than the signature, before any HMAC is computed", () => {
    const token = signToken({ alg: "HS512", typ: "JWT" }, claimsFor(USER, { now: NOW }), "wrong");
    expect(refusalOf(token)).toBe("algorithm");
  });
});

describe("verifyAccessToken — shapes that are not tokens", () => {
  it.each([
    ["empty", ""],
    ["one segment", "eyJhbGciOiJIUzI1NiJ9"],
    ["four segments", "a.b.c.d"],
    ["five segments, the JWE shape", "a.b.c.d.e"],
    ["empty header", ".eyJzdWIiOiJhIn0.sig"],
    ["a bare word", "undefined"],
    ["JSON", '{"sub":"11111111-1111-1111-1111-111111111111"}'],
    ["a header that is an array", `${base64url("[1,2]")}.${base64url("{}")}.sig`],
  ])("refuses %s", (_name, token) => {
    expect(refusalOf(token)).toBe("malformed");
  });

  it("refuses a payload that is valid JSON but not an object", () => {
    const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const claims = base64url("[1,2,3]");
    const signature = createHmac("sha256", TEST_JWT_POLICY.secret)
      .update(`${header}.${claims}`).digest("base64url");
    expect(refusalOf(`${header}.${claims}.${signature}`)).toBe("malformed");
  });

  it("refuses an oversized token before spending an HMAC on it", () => {
    const honest = accessTokenFor(USER, { now: NOW });
    expect(refusalOf(`${honest}${"A".repeat(8192)}`)).toBe("malformed");
  });
});
