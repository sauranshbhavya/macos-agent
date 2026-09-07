import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { EXPIRY_SKEW_TOLERANCE_SECONDS } from "../src/auth/clock.js";
import {
  verifyAccessToken, type SupabaseJwtPolicy, type TokenRefusal,
} from "../src/auth/token.js";
import {
  TEST_JWT_OVERLAP_SECRET, TEST_JWT_POLICY, TEST_JWT_SECRET, accessTokenFor, base64url, claimsFor,
  providerSessionFor, signToken, signatureSecondSpelling, tokenWithBrokenSignature, tokenWithClaims,
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
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    const restated = signatureSecondSpelling(signature);
    expect(restated).not.toBe(signature);
    // Same bytes — which is what makes this a real hole rather than a typo.
    expect(Buffer.from(restated, "base64url").equals(Buffer.from(signature, "base64url"))).toBe(true);
    expect(refusalOf(`${header}.${claims}.${restated}`)).toBe("malformed");
  });

  it("breaks a signature deterministically, at every one of the sixteen final characters", () => {
    // **The regression guard for F2**, and the reason it loops rather than sampling: the final
    // character of a 43-character base64url HMAC has only sixteen possible values, so a perturbation
    // that happens to be a no-op for one of them is a test that silently stops testing about one run
    // in sixteen. The tokens below are minted at 200 fixed, successive instants — deterministic
    // input, deterministic output — which covers every one of the sixteen values that occurs at all.
    //
    // The old spelling, `token.replace(/.$/, "A")`, fails this loop on the instants whose signature
    // already ends in "A". This is the assertion that would have caught it.
    const seen = new Set<string>();
    for (let offset = 0; offset < 200; offset += 1) {
      const honest = accessTokenFor(USER, { now: new Date(NOW.getTime() + offset * 1000) });
      const broken = tokenWithBrokenSignature(honest);
      seen.add(honest[honest.length - 1]!);
      expect(broken).not.toBe(honest);
      // Refused for the signature rather than for its shape: the perturbation moves the four
      // significant bits, so the bytes really differ and the result is still canonical base64url.
      expect(refusalOf(broken, new Date(NOW.getTime() + offset * 1000))).toBe("signature");
    }
    // Non-vacuous: if minting ever became constant, this would be a loop over one token.
    expect(seen.size).toBeGreaterThan(1);
  });

  it("refuses a segment padded with '=' or carrying characters outside the alphabet", () => {
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    expect(refusalOf(`${header}.${claims}.${signature}==`)).toBe("malformed");
    expect(refusalOf(`${header}.${claims}.${signature}*`)).toBe("malformed");
  });

  it("refuses a 4n+1 segment — the canonicality check alone, with no separate length guard", () => {
    // Named for what it protects (PR #104's adversarial review, F8). A `length % 4 === 1` guard used
    // to sit above the canonicality check and was dead: `Buffer` drops the orphan six-bit quantum,
    // so the re-encoding is a character short and the surviving line refuses it anyway. The guard is
    // gone; this is the test that says the remaining line covers the case it covered.
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    // Padded to the next 4n+1 length rather than by a fixed count, because the two segments start
    // at different lengths: a 32-byte HMAC is 43 characters and needs two more, this header is 36
    // and needs one. (43 plus ONE is 44 — a canonical encoding of 33 bytes, refused for its length
    // by the signature comparison instead, which is a different case and not this one.)
    const toFourNPlusOne = (segment: string) =>
      `${segment}${"A".repeat((1 - (segment.length % 4) + 4) % 4)}`;

    for (const [name, mutated] of [
      ["signature", `${header}.${claims}.${toFourNPlusOne(signature)}`],
      // The header matters most: a dropped quantum there would otherwise decide which algorithm
      // this verifier believes it was handed.
      ["header", `${toFourNPlusOne(header)}.${claims}.${signature}`],
    ] as const) {
      const segment = mutated.split(".")[name === "header" ? 0 : 2]!;
      expect(`${name} length % 4 = ${segment.length % 4}`).toBe(`${name} length % 4 = 1`);
      // The truncation is real, and it is what a lenient decoder would silently accept.
      expect(Buffer.from(segment, "base64url").toString("base64url")).not.toBe(segment);
      expect(`${name} -> ${refusalOf(mutated)}`).toBe(`${name} -> malformed`);
    }
  });

  it("refuses a non-canonical PAYLOAD even when the signature over it is correct", () => {
    // Reachable only by whoever holds the secret — so this is the property that a token minted by a
    // careless future adapter, rather than by an attacker, is still refused rather than silently
    // decoded. The signature is computed over the perturbed segment, so it verifies; the strict
    // decode is the only thing that refuses.
    const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const padded = `${base64url(JSON.stringify(claimsFor(USER, { now: NOW })))}=`;
    const signature = createHmac("sha256", TEST_JWT_SECRET)
      .update(`${header}.${padded}`).digest("base64url");
    expect(refusalOf(`${header}.${padded}.${signature}`)).toBe("malformed");
  });

  it("verifies the signature BEFORE parsing the claims a caller controls", () => {
    // Ordering, asserted rather than assumed: a token whose payload is not decodable is refused as
    // a bad signature, which is only possible if the signature is checked first. Parsing attacker
    // JSON before authenticating it is the wrong order even when the parser is `JSON.parse`.
    const honest = accessTokenFor(USER, { now: NOW });
    const [header, claims, signature] = honest.split(".") as [string, string, string];
    // `"+"` rather than a derived character, and this is NOT F2's coin toss: `+` belongs to standard
    // base64's alphabet and not to base64url's, so a segment produced by `toString("base64url")` can
    // never already end in one and the replacement can never be a no-op. (F2's bug was replacing
    // with `"A"`, which the signature ends in about one run in sixteen.)
    expect(refusalOf(`${header}.${claims.replace(/.$/, "+")}.${signature}`)).toBe("signature");
  });

  it("signs over the ENCODED segments, so a re-encoding of the same claims does not verify", () => {
    // Proof that the HMAC covers the compact serialisation rather than the decoded objects: the
    // claims below are identical and their JSON spelling is not.
    const claims = claimsFor(USER, { now: NOW });
    const reordered = Object.fromEntries(Object.entries(claims).reverse());
    const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
    const honestSignature = createHmac("sha256", TEST_JWT_SECRET)
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
    const signature = createHmac("sha256", TEST_JWT_SECRET)
      .update(`${header}.${claims}`).digest("base64url");
    expect(refusalOf(`${header}.${claims}.${signature}`)).toBe("malformed");
  });

  it("refuses an oversized token before spending an HMAC on it", () => {
    const honest = accessTokenFor(USER, { now: NOW });
    expect(refusalOf(`${honest}${"A".repeat(8192)}`)).toBe("malformed");
  });
});

/**
 * The `session_id` claim (SONNY-237), which is the only claim this verifier reads that another
 * component then *acts* on: `auth/denylist.ts` keys a revocation on it.
 *
 * Two directions matter and they are one line apart in the code. A claim that is present and
 * unusable must be a refusal rather than an absence — treating it as absent would make the token
 * silently undenylistable, which is the whole property. And an absent claim must be accepted, because
 * GoTrue declares it `omitempty` and handles the absence itself, so a token without one is a shape
 * the provider mints rather than a forgery.
 */
describe("verifyAccessToken — the provider session claim", () => {
  it("carries a well-formed session_id through to the verdict", () => {
    const verdict = verifyAccessToken(accessTokenFor(USER, { now: NOW }), TEST_JWT_POLICY, NOW);
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.token.providerSessionId).toBe(providerSessionFor(USER));
  });

  it("accepts a token that carries none, and reports it as absent", () => {
    const verdict = verifyAccessToken(
      tokenWithClaims(USER, { session_id: undefined }), TEST_JWT_POLICY, NOW,
    );
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.token.providerSessionId).toBeUndefined();
  });

  it("refuses a session_id that is present and not a uuid, rather than reading it as absent", () => {
    // Every one of these is a token that would otherwise verify. `session` and not `subject`: the
    // log line is how an operator tells a re-keyed project from a forged claim, and collapsing the
    // two would cost that.
    for (const spelling of ["not-a-uuid", "", "3f1d0c8e1c5a4a9f9f6b2b6f5f2a77aa", " "]) {
      expect(refusalOf(tokenWithClaims(USER, { session_id: spelling })))
        .toBe("session");
    }
  });

  it("refuses a session_id that is not a string at all", () => {
    for (const shape of [null, 7, true, ["a"], { id: "a" }]) {
      expect(refusalOf(tokenWithClaims(USER, { session_id: shape })))
        .toBe("session");
    }
  });

  it("refuses the claim AFTER the signature, so a forgery is never told which claim was wrong", () => {
    // Check order is the file's own rule: nothing about the claims may be reported for a token this
    // gateway did not sign. A junk session_id on a wrongly-signed token reads as `signature`.
    const forged = tokenWithClaims(
      USER, { session_id: "not-a-uuid" }, { secret: "a-different-secret-of-adequate-length" },
    );
    expect(refusalOf(forged)).toBe("signature");
  });
});

describe("verifyAccessToken — the rotation overlap (SONNY-238)", () => {
  // **What this suite is defending.** Rotating `SUPABASE_JWT_SECRET` used to invalidate every token
  // signed with the previous value at the instant the new one deployed: every signed-in user signed
  // out. A second accepted secret fixes that and is, by construction, a second key that can mint a
  // token for any user — so the tests below are two claims, not one. The rotation must work, AND the
  // second secret must be held to every check the first one is and must stop being accepted.

  /** Mid-rotation: the current secret, plus one overlap secret good for another hour. */
  const OVERLAP_ENDS = new Date("2026-08-22T13:00:00Z");
  const rotating: SupabaseJwtPolicy = {
    ...TEST_JWT_POLICY,
    secrets: [
      { value: TEST_JWT_SECRET, acceptedUntil: undefined },
      { value: TEST_JWT_OVERLAP_SECRET, acceptedUntil: OVERLAP_ENDS },
    ],
  };
  const verdictOf = (token: string, policy: SupabaseJwtPolicy, now: Date = NOW) => {
    const verdict = verifyAccessToken(token, policy, now);
    return verdict.ok ? "accepted" : verdict.refusal;
  };

  it("accepts a token signed with the overlap secret, which is the whole point", () => {
    const token = tokenWithClaims(USER, {}, { secret: TEST_JWT_OVERLAP_SECRET });
    // The control: the same token against a policy without the overlap is refused, so the acceptance
    // above is the second secret doing something rather than the assertion being vacuous.
    expect(verdictOf(token, TEST_JWT_POLICY)).toBe("signature");
    expect(verdictOf(token, rotating)).toBe("accepted");
  });

  it("still accepts a token signed with the current secret while the overlap is live", () => {
    // A rotation that accepted only the incoming secret would be the sign-out it was meant to avoid,
    // arriving one deploy earlier.
    expect(verdictOf(accessTokenFor(USER, { now: NOW }), rotating)).toBe("accepted");
  });

  it("stops accepting the overlap secret at its instant, with no deploy and nobody remembering", () => {
    // **This is the founders' 2026-08-30 decision made mechanical**: a retired secret gets a stated
    // maximum overlap, and their own note was that a number nothing checks is worse than a check.
    // The check is here rather than at startup, because a deadline read once at boot ends the overlap
    // on the next restart — which, on a gateway that does not restart, is no ending at all.
    const overlapToken = tokenWithClaims(
      USER,
      { exp: Math.floor(OVERLAP_ENDS.getTime() / 1000) + 7200 },
      { secret: TEST_JWT_OVERLAP_SECRET },
    );
    const aMomentBefore = new Date(OVERLAP_ENDS.getTime() - 1);
    const atTheInstant = OVERLAP_ENDS;
    const wellAfter = new Date(OVERLAP_ENDS.getTime() + 60_000);

    expect(verdictOf(overlapToken, rotating, aMomentBefore)).toBe("accepted");
    // The stated instant is the first one at which it is refused, which is how `acceptedUntil` reads.
    expect(verdictOf(overlapToken, rotating, atTheInstant)).toBe("signature");
    expect(verdictOf(overlapToken, rotating, wellAfter)).toBe("signature");
  });

  it("does not let the overlap's end touch the current secret", () => {
    // The asymmetry is load-bearing: if the ending applied to index 0 as well, this gateway would
    // refuse every token from that instant — the outage the overlap exists to prevent, arriving from
    // inside the fix for it. The current secret's token is minted to outlive the overlap's end.
    const long = tokenWithClaims(USER, { exp: Math.floor(OVERLAP_ENDS.getTime() / 1000) + 7200 });
    expect(verdictOf(long, rotating, new Date(OVERLAP_ENDS.getTime() + 60_000))).toBe("accepted");
  });

  it("theSecondSecretGetsNoWeakerChecksThanTheFirst", () => {
    // **The ticket names this as the thing that would be worse than the sign-out it avoids**: "a
    // rotation that quietly relaxed the pin for the second key would be worse". Every refusal below
    // is asserted against a token signed with the OVERLAP secret, so a verifier that had grown a
    // second, laxer path for it would be caught here rather than in production.
    const withOverlap = (claims: Record<string, unknown>, header?: Record<string, unknown>) =>
      verdictOf(
        tokenWithClaims(USER, claims, {
          secret: TEST_JWT_OVERLAP_SECRET,
          ...(header === undefined ? {} : { header }),
        }),
        rotating,
      );

    // The pin. `alg: "none"` and algorithm confusion, the two forgeries the pin exists for.
    expect(withOverlap({}, { alg: "none", typ: "JWT" })).toBe("algorithm");
    expect(withOverlap({}, { alg: "HS512", typ: "JWT" })).toBe("algorithm");
    expect(withOverlap({}, { alg: "RS256", typ: "JWT" })).toBe("algorithm");
    // `crit`, which names header parameters a verifier must understand and this one understands none.
    expect(withOverlap({}, { alg: "HS256", typ: "JWT", crit: ["x"] })).toBe("malformed");
    // The claim checks, each in its own right.
    expect(withOverlap({ iss: "https://elsewhere.supabase.co/auth/v1" })).toBe("issuer");
    expect(withOverlap({ aud: "someone-else" })).toBe("audience");
    expect(withOverlap({ sub: "not-a-uuid" })).toBe("subject");
    expect(withOverlap({ session_id: "not-a-uuid" })).toBe("session");
    // The one-directional skew rule: tolerance past `exp`, none before `nbf`.
    expect(withOverlap({ nbf: Math.floor(NOW.getTime() / 1000) + 60 })).toBe("not_yet_valid");
    expect(withOverlap({ exp: Math.floor(NOW.getTime() / 1000) - 60 })).toBe("expired");
    expect(withOverlap({ exp: undefined })).toBe("malformed");
    // And the control that says the battery above is refusing for its stated reasons rather than
    // refusing everything signed with this secret.
    expect(withOverlap({})).toBe("accepted");
  });

  it("refuses a secret that is in neither slot", () => {
    const stranger = tokenWithClaims(USER, {}, { secret: "a-third-secret-nobody-configured-here" });
    expect(verdictOf(stranger, rotating)).toBe("signature");
  });

  it("refuses everything when every accepted secret has retired, rather than letting one through", () => {
    // Not a configuration `requireSupabaseJwtPolicy` can build — it gives index 0 no end — and
    // asserted anyway, because the loop's fail-open direction would be silent: a policy whose
    // secrets are all skipped must reach the same refusal an unmatched signature does.
    const allRetired: SupabaseJwtPolicy = {
      ...TEST_JWT_POLICY,
      secrets: rotating.secrets.map((entry) => ({ ...entry, acceptedUntil: OVERLAP_ENDS })),
    };
    const after = new Date(OVERLAP_ENDS.getTime() + 60_000);
    expect(verdictOf(accessTokenFor(USER, { now: NOW }), allRetired, after)).toBe("signature");
    expect(verdictOf(accessTokenFor(USER, { now: NOW }), { ...TEST_JWT_POLICY, secrets: [] }))
      .toBe("signature");
  });
});
