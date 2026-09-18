/**
 * The wire constants of Sign in with Google (SONNY-129; contract §3.6).
 *
 * **The redirect is fixed here and never taken from a request.** It is where the provider sends the
 * one-time code, and a caller able to choose it could send a victim's code anywhere Supabase's own
 * allow-list admits. PKCE already makes a stolen code useless without the verifier; this makes the
 * destination not a parameter in the first place. The Mac app waits on the same scheme —
 * `SonnyGoogleSignIn.callbackScheme` — and a Swift test reads this file to hold the two to one string.
 *
 * **A reverse-DNS private scheme**, the form RFC 8252 §7.1 recommends for a native app: the bundle
 * identifier, lowercased, because URL schemes compare case-insensitively and the Mac's
 * `ASWebAuthenticationSession` is handed the scheme alone. The founder adds this exact string to the
 * Supabase project's redirect allow-list; Supabase refuses to redirect anywhere that list does not
 * name.
 */
export const OAUTH_REDIRECT_URL = "com.sonny.macagent://auth/callback";

/**
 * RFC 7636 §4.2's S256 challenge: `BASE64URL(SHA256(verifier))`, which is always 43 characters of the
 * base64url alphabet. Anything else is not a challenge this flow produced.
 */
export const CODE_CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** RFC 7636 §4.1's verifier: 43 to 128 unreserved characters. */
export const CODE_VERIFIER_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;

/**
 * The provider's one-time code. GoTrue mints a UUID; this admits any bounded run of URL-unreserved
 * characters, so a later format change on the provider's side is not a refusal here, while a body
 * carrying whitespace, a path or a megabyte is.
 */
export const AUTH_CODE_PATTERN = /^[A-Za-z0-9._~-]{1,512}$/;
