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
 *
 * **The first reason above has been overtaken and the second has not** (SONNY-307, which wrote
 * `supabase.ts` behind this seam). Nothing was ever blocked on Resend: **Supabase's own mailer sends
 * the code**, and the gateway neither mints it nor receives it, so this process holds no mail
 * credential and `config.ts` reads no `RESEND_*` or `SMTP_*` name. The sending domain is still owed
 * and still founder-owned, one layer away — Supabase's default SMTP is documented as best-effort,
 * non-production, two messages an hour, and the fix is a **custom SMTP transport configured in the
 * Supabase project**, after which Supabase Auth still composes and sends. That changes
 * deliverability, not this interface. The translation reason is the one that keeps the seam:
 * `otp_expired` covering three contract failures, and Supabase's automatic identity linking
 * operating on a row that is not our account, are both still true and both still live here.
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
  /**
   * Seconds until the *refresh* token expires, when the provider reports one.
   *
   * Optional because Supabase Auth does not always surface it, and §3.2's `refresh_expires_at` is
   * therefore emitted only when it is known. A server-invented value would be a client scheduling
   * a sign-out against a number nobody measured.
   */
  readonly refreshExpiresIn?: number | undefined;
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
   * **Nothing on the request path calls this, and nothing should.** Verification is local and
   * symmetric — `auth/token.ts` checks the signature with the project's JWT secret and `auth/gate.ts`
   * applies it to every protected route — by the founder decision of 2026-08-21. Asking the provider
   * per request would put its latency and its availability in front of every authenticated route.
   *
   * It exists here because `DELETE /v1/account` cannot be allowed to attribute its caller from a
   * header — a proof of concept destroyed another account with a made-up bearer token — and a
   * destructive route must either verify or not exist. The gate answers that now.
   *
   * **This paragraph said the opposite until SONNY-307.** It read "this is the verification
   * SONNY-203's middleware will do for every authenticated route", which SONNY-203's own changelog
   * entry records as corrected — "the docstring is corrected" — while the correction never reached
   * this file: `git log -- server/src/auth/provider.ts` names only SONNY-127's four commits. The
   * three test fakes throw from this method deliberately, so a middleware that started calling it
   * fails loudly in the suite; `auth/supabase.ts` implements it for real and repeats why nothing
   * calls it.
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
