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

/** The three configuration fields every app built in these tests needs. */
export const TEST_JWT_CONFIG = {
  supabaseJwtSecret: TEST_JWT_POLICY.secret,
  supabaseJwtIssuer: TEST_JWT_POLICY.issuer,
  supabaseJwtAudience: TEST_JWT_POLICY.audience,
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
