/**
 * The seam between this gateway and Supabase Auth.
 *
 * **Why a seam rather than calling the SDK from the route.** Two reasons, and neither is taste.
 * First, the founder's Resend sending domain is not ready, so nothing can send a real code yet;
 * without a seam the whole sign-in path would be untestable until an external dependency lands, and
 * the tests would arrive after the code they are meant to constrain. Second, this is the boundary
 * where the platform's behaviour has to be *translated* rather than passed through — Supabase
 * returns one `otp_expired` for three distinct contract failures, and its automatic identity linking
 * operates on a row that is not our account. A named boundary is where that translation is visible.
 *
 * It is deliberately thin: no retries, no caching, no policy. Policy is the gateway's.
 */

export interface SentCode {
  /** Supabase's own identifier for the request, kept for support lookups. Never the code. */
  readonly providerRequestId: string | undefined;
}

export interface VerifiedSession {
  readonly supabaseUserId: string;
  readonly email: string | undefined;
  readonly emailVerified: boolean;
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Seconds. The provider's, not ours — the contract's response reports what it was given. */
  readonly expiresIn: number;
}

export class ProviderRejected extends Error {}
export class ProviderUnavailable extends Error {}

export interface AuthProvider {
  /** Ask the provider to mint and send a code. Never returns the code. */
  sendEmailCode(email: string): Promise<SentCode>;
  /** Exchange a code for a session. Throws `ProviderRejected` when the provider refuses it. */
  verifyEmailCode(email: string, code: string): Promise<VerifiedSession>;
  /** Rotate. The provider owns rotation, the 10s reuse interval and family revocation (§3.3). */
  refresh(refreshToken: string): Promise<VerifiedSession>;
  /** Revoke this session's family server-side. */
  signOut(accessToken: string): Promise<void>;
  /**
   * The provider-side user this access token belongs to, or `ProviderRejected`.
   *
   * **This is the verification SONNY-128's middleware will do for every authenticated route.** It
   * exists here because `DELETE /v1/account` cannot be allowed to attribute its caller from a
   * header — a proof of concept destroyed another account with a made-up bearer token — and a
   * destructive route must either verify or not exist.
   */
  userFromAccessToken(accessToken: string): Promise<string>;

  /**
   * Revoke every session belonging to one provider-side user.
   *
   * Distinct from `signOut`, which revokes only the session whose access token it is given. One
   * Sonny account can map to several Supabase users — that is the whole point of the identity
   * separation — so signing out an account means iterating its identities and calling this for
   * each. Needs Supabase's admin API, so it is unimplemented until the real adapter lands
   * (PR #87 F5).
   */
  signOutAllForUser(supabaseUserId: string): Promise<void>;

  /** Remove the provider-side user. Our account row is closed separately. */
  deleteUser(supabaseUserId: string): Promise<void>;
}
