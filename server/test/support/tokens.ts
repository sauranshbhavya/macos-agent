import { createHmac } from "node:crypto";
import type { SupabaseJwtPolicy } from "../../src/auth/token.js";

/**
 * Minting access tokens the way Supabase mints them, so the gate can be driven with real ones —
 * and forged ones.
 *
 * **This file is the reason the suite can be adversarial at all.** Every test that matters here is
 * some variation on "a token that is wrong in exactly one way", and the only way to write those is
 * to control the signing. The helpers below take the header, the claims and the secret separately
 * for that reason: each forgery is one argument changed.
 *
 * The secret is a fixed string with no vendor shape, long enough to clear
 * `MIN_JWT_SECRET_LENGTH` — a test that had to work around the floor would be a test that stopped
 * proving the floor exists.
 */
export const TEST_JWT_POLICY: SupabaseJwtPolicy = {
  secret: "sonny-gateway-test-signing-key-not-a-real-one",
  issuer: "https://project-ref.supabase.co/auth/v1",
  audience: "authenticated",
};

/**
 * Every Supabase-shaped field a `Config` literal in these tests needs.
 *
 * **Renamed from the JWT-only name it carried by SONNY-307**, which added the two API-key fields
 * below: the old name described three of the five and would have described a shrinking fraction of
 * them as more Supabase-shaped fields arrive.
 *
 * **The two API keys are `undefined` on purpose, and that is the truthful value here.** They are what
 * `auth/supabase.ts` sends to the real project; every app built in this suite is handed a *fake*
 * provider instead, so no test in it has a Supabase project to call. A test that wants a real
 * adapter sets them itself — `supabase-provider.test.ts` builds one directly and never goes through
 * a `Config` at all.
 */
export const TEST_SUPABASE_CONFIG = {
  supabaseJwtSecret: TEST_JWT_POLICY.secret,
  supabaseJwtIssuer: TEST_JWT_POLICY.issuer,
  supabaseJwtAudience: TEST_JWT_POLICY.audience,
  supabaseAnonKey: undefined,
  supabaseServiceRoleKey: undefined,
} as const;

export function base64url(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

/** Compact-serialise and sign. `secret` is a parameter so a wrong-key forgery is one argument. */
export function signToken(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  secret: string = TEST_JWT_POLICY.secret,
): string {
  const encodedHeader = base64url(JSON.stringify(header));
  const encodedClaims = base64url(JSON.stringify(claims));
  const signature = createHmac("sha256", secret)
    .update(`${encodedHeader}.${encodedClaims}`)
    .digest("base64url");
  return `${encodedHeader}.${encodedClaims}.${signature}`;
}

/**
 * The claim set Supabase issues for a signed-in user, as far as this gateway reads it.
 *
 * `role` and `session_id` are carried because real tokens carry them and a verifier that broke on an
 * unknown claim would break in production; nothing here reads either.
 */
export function claimsFor(
  supabaseUserId: string,
  options: { now?: Date; lifetimeSeconds?: number } = {},
): Record<string, unknown> {
  const now = options.now ?? new Date();
  const issued = Math.floor(now.getTime() / 1000);
  return {
    iss: TEST_JWT_POLICY.issuer,
    sub: supabaseUserId,
    aud: TEST_JWT_POLICY.audience,
    role: "authenticated",
    session_id: "3f1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77aa",
    iat: issued,
    exp: issued + (options.lifetimeSeconds ?? 3600),
  };
}

/** A well-formed, correctly signed token for this user. The baseline every forgery deviates from. */
export function accessTokenFor(
  supabaseUserId: string,
  options: { now?: Date; lifetimeSeconds?: number } = {},
): string {
  return signToken({ alg: "HS256", typ: "JWT" }, claimsFor(supabaseUserId, options));
}

/** A token whose claims differ from the honest set in exactly the ways given. */
export function tokenWithClaims(
  supabaseUserId: string,
  overrides: Record<string, unknown>,
  options: { secret?: string; header?: Record<string, unknown> } = {},
): string {
  const claims = { ...claimsFor(supabaseUserId), ...overrides };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) delete claims[key];
  }
  return signToken(
    options.header ?? { alg: "HS256", typ: "JWT" },
    claims,
    options.secret ?? TEST_JWT_POLICY.secret,
  );
}

/**
 * The base64url alphabet, and the two ways to perturb a signature's final character.
 *
 * **Both exist because `replace(/.$/, "A")` is a coin toss** (PR #104's adversarial review, F2). A
 * 32-byte HMAC is 43 base64url characters; the last one carries four significant bits and two unused
 * ones, so it can only be **one of sixteen values** — and `accessTokenFor` mints at `new Date()`, so
 * which of the sixteen it is changes every second. Replacing it with a fixed `"A"` is therefore a
 * no-op about one run in sixteen, 6.25%. Measured twice over 160,000 successive `iat` values, and
 * the two runs agree on the alphabet and differ in the tail the way two samples of one property do:
 * the reviewer got 10,042 (6.276%) and this session got **9,890 (6.181%)**, both against the
 * observed final-character alphabet `048AEIMQUYcgkosw` (`node` over `createHmac` at `6b31c79`; the
 * sampled `iat` ranges differ, which is the whole of the difference). On those runs the "forgery" is
 * the honest token, it verifies, and the assertion fails — the reviewer saw it once in their first
 * `npm test`, once in 48 runs of one file, and once in 24 full runs. **Deriving the replacement from
 * the character it replaces is what makes it never a no-op**, and `signatureIsAlwaysBroken` in
 * `token.test.ts` is what keeps it that way.
 */
const BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/**
 * The same 32 bytes, spelled differently: only the final character's two **unused** bits change, so
 * `Buffer.from(s, "base64url")` decodes both spellings identically and only a canonicality check
 * can tell them apart.
 */
export function signatureSecondSpelling(signature: string): string {
  const last = signature[signature.length - 1]!;
  const index = BASE64URL_ALPHABET.indexOf(last);
  return `${signature.slice(0, -1)}${BASE64URL_ALPHABET[(index & ~0b11) | ((index + 1) & 0b11)]!}`;
}

/**
 * A genuinely different signature: the final character's four **significant** bits change, so the
 * last byte differs and the HMAC cannot match. Canonical, so it is refused for the signature rather
 * than for its shape — and it can never equal the character it replaced, because the nibble moves.
 */
export function tokenWithBrokenSignature(token: string): string {
  const [header, claims, signature] = token.split(".") as [string, string, string];
  const last = signature[signature.length - 1]!;
  const index = BASE64URL_ALPHABET.indexOf(last);
  const nibble = ((index >> 2) + 1) % 16;
  const replacement = BASE64URL_ALPHABET[(nibble << 2) | (index & 0b11)]!;
  if (replacement === last) throw new Error("perturbation produced the same character");
  return `${header}.${claims}.${signature.slice(0, -1)}${replacement}`;
}
