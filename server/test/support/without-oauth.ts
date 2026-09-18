import type { OAuthProviderName, OAuthSession } from "../../src/auth/provider.js";

/**
 * The two methods SONNY-129 added to `AuthProvider`, for the fakes whose suites never start a Google
 * sign-in.
 *
 * **One base class rather than two stubs pasted into every fake.** Twenty-three suites implement the
 * seam, and every one of them would otherwise carry the same two throwing methods — the shape where
 * one copy is edited and the others are not. Extending this is one word per fake.
 *
 * **They throw, and loudly, on purpose** — the same reason the fakes already throw from
 * `userFromAccessToken`: a suite that is not about Google sign-in and reaches one of these has found
 * a route calling the provider where it should not, and a quiet answer would hide it.
 * `oauth.db.test.ts` is the suite that drives these for real, through its own fake.
 */
export abstract class WithoutOAuth {
  oauthAuthorizeUrl(_provider: OAuthProviderName, _redirectTo: string, _codeChallenge: string): string {
    throw new Error("this suite's fake provider never starts a Google sign-in");
  }

  async exchangeOAuthCode(
    _provider: OAuthProviderName,
    _authCode: string,
    _codeVerifier: string,
    _signal?: AbortSignal,
  ): Promise<OAuthSession> {
    throw new Error("this suite's fake provider never exchanges a Google sign-in code");
  }
}
