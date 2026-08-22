/**
 * Clock-skew tolerance for token expiry.
 *
 * **Nothing calls `isExpiryAcceptable` in a request path today, and the record has been corrected
 * to say so** (PR #87 F2). Token verification — checking a presented access token's signature and
 * expiry — is SONNY-203's scope, and this file is the tolerance that verification will apply. The
 * closing comment and the changelog claimed clock skew was "implemented and tested"; it is
 * implemented and tested as a function, and it is not yet reached by any route. `expiryFields` IS
 * used, by the token responses in `routes/auth.ts`.
 *
 * Contract §3.5 fixes the *mechanism* — every response carries `Date`, the client stores the offset
 * and does its expiry arithmetic in server time, and the server never trusts a client-supplied
 * timestamp for anything billable or expiring. It assigns the concrete value for the *entitlement
 * grace* to SONNY-135. This file sets the value for *token expiry*, which is SONNY-127's acceptance
 * criterion, and uses the same mechanism so the two cannot drift — which is what §3.5 says the
 * mechanism is fixed for.
 */

/**
 * Thirty seconds, applied in one direction only.
 *
 * **Why any tolerance at all:** the server owns the clock but the two ends still disagree by network
 * latency and by ordinary NTP drift, so a token issued to expire at T is legitimately presented a
 * little after T by a client that scheduled honestly from `expires_in`.
 *
 * **Why it is small:** every second of tolerance is a second a revoked or expired token still works.
 * Thirty covers drift and a slow request; it does not cover a user who has set their clock back.
 *
 * **Why one direction:** tolerance is granted to a token that looks *expired* — accepting it briefly
 * past its stated life. It is never granted to one that looks *not yet valid*, because a token from
 * the future is not a clock problem the server should absorb; it is either the server's own clock
 * being wrong, which tolerance cannot fix, or a forged claim, which tolerance must not help.
 */
export const EXPIRY_SKEW_TOLERANCE_SECONDS = 30;

export interface ExpiryVerdict {
  readonly valid: boolean;
  /** True when the token is past its stated expiry but inside the tolerance. */
  readonly withinTolerance: boolean;
}

/**
 * Is a token with this expiry still acceptable, judged against server time?
 *
 * `now` is the *server's* clock and is never a value the caller sent. A client-supplied timestamp
 * reaching this function would let the caller choose whether its own token had expired.
 */
export function isExpiryAcceptable(
  expiresAt: Date,
  now: Date,
  toleranceSeconds: number = EXPIRY_SKEW_TOLERANCE_SECONDS,
): ExpiryVerdict {
  const past = now.getTime() - expiresAt.getTime();
  if (past <= 0) return { valid: true, withinTolerance: false };
  if (past <= toleranceSeconds * 1000) return { valid: true, withinTolerance: true };
  return { valid: false, withinTolerance: false };
}

/**
 * `expires_in` and `expires_at` for the contract's §3.2 token response, both derived from one server
 * instant so they cannot disagree.
 *
 * The contract requires both on purpose: `expires_in` is immune to clock skew and is what a client
 * should schedule from, `expires_at` is what it should log and compare against server time. Deriving
 * them separately — one from a duration, one from a second `new Date()` — is how they drift by a
 * millisecond and then by a second.
 */
export function expiryFields(issuedAt: Date, lifetimeSeconds: number): {
  expires_in: number;
  expires_at: string;
} {
  return {
    expires_in: lifetimeSeconds,
    expires_at: new Date(issuedAt.getTime() + lifetimeSeconds * 1000).toISOString()
      .replace(/\.\d{3}Z$/, "Z"),
  };
}
