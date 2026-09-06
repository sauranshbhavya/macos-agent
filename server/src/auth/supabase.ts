import { z } from "zod";
import {
  ProviderRejected,
  ProviderUnavailable,
  type AuthProvider,
  type SentCode,
  type VerifiedSession,
} from "./provider.js";

/**
 * The concrete `AuthProvider` behind the seam: Supabase Auth (GoTrue) over its REST API (SONNY-307).
 *
 * **Who sends the sign-in code, established from the built shape rather than assumed.** Supabase's
 * own mailer does. `POST /otp` with an `email` is GoTrue's `Otp` handler delegating to `MagicLink`,
 * which composes and sends the message itself and answers the caller `{}` — `message_id` is returned
 * for the SMS branch only (`openapi.yaml`'s `/otp` 200 schema). **The code never crosses this
 * boundary in either direction**: the gateway does not mint it, does not receive it, and could not
 * put it in a mail of its own if it wanted to. So this gateway holds no mail credential, `config.ts`
 * grows no `RESEND_*` or `SMTP_*` name, and `deploy.sh`'s `PASSTHROUGH` grows none either. Where
 * Resend does enter is one layer away and is not code: Supabase's default SMTP is documented as
 * best-effort, non-production, two messages an hour, and the fix is a **custom SMTP transport
 * configured in the Supabase project** (dashboard or Management API) — after which "your project's
 * Auth server will send messages to all addresses", still composed and sent by Supabase. That is a
 * founder-owned deliverability setting on the project, not a variable this process reads.
 *
 * **What this file is, and what it deliberately is not.** `provider.ts` calls the seam "deliberately
 * thin: no retries, no caching, no policy" and that holds here: every method is one HTTP call, one
 * response shape parsed, one failure translated. There is no back-off, no circuit breaker, and no
 * second attempt — a caller that wants one is expressing policy, and policy is the gateway's.
 *
 * **The translation is the reason the seam exists, and it runs in three directions.**
 *
 * 1. **One provider error stands for several contract failures.** GoTrue answers a wrong code, an
 *    expired code and an already-consumed code with the single `otp_expired`
 *    ("OTP code for this sign-in has expired. Ask the user to sign in again."). Contract §3.6 owes
 *    the client three distinct codes. This adapter does **not** invent the distinction: it raises
 *    `ProviderRejected` and `routes/auth.ts` derives `auth.code_invalid` / `auth.code_expired` /
 *    `auth.code_used` from the gateway's **own** issuance record, which is the only place that
 *    knows. An adapter that guessed here would be guessing about the user's account.
 * 2. **Rejected and unavailable are different answers to the user.** A 4xx naming a caller-input
 *    code is `ProviderRejected` — the route turns it into a 400 the user can act on. A 429, a 5xx,
 *    a timeout, a socket failure or a 200 whose body does not parse is `ProviderUnavailable`, and
 *    the route answers 502 `provider.unavailable`, retryable. Collapsing the two either tells a
 *    user their code was wrong when Supabase was down, or tells them to try again when the code
 *    really was wrong.
 * 3. **Supabase's automatic identity linking is not this product's account rule, and nothing here
 *    imports it.** Supabase may attach a newly verified address to an existing `auth.users` row, so
 *    one `supabaseUserId` can cover several addresses. This product's identity key is
 *    `(provider, subject)` and never the email address (`docs/sonny-identity-linking-rule.md`,
 *    `auth/identity.ts`). So `verifyEmailCode` reports `user.email` as the provider's own view and
 *    nothing more — `routes/auth.ts` resolves the account from the address the **caller** asserted,
 *    not from this field. Reading `user.email` back as the subject is precisely how a code sent to
 *    `b@example.com` would land on the account of `a@example.com`, and it is a one-line mistake to
 *    make, which is why the field is documented here rather than merely typed.
 *
 * **Every method throws `ProviderRejected` or `ProviderUnavailable` and nothing else — with one
 * named exception.** `deleteUser` throws `ServiceRoleKeyNotConfigured` when this adapter was built
 * without a service-role key, which is a deployment fault rather than a provider one and is argued
 * at that method. Every other failure, on every method, is one of the seam's two.
 *
 * **No value reaches a message, a log line or an error.** Errors name the operation, the HTTP status
 * and the provider's error **code** — a fixed vocabulary from GoTrue's own `errorcode.go` — and
 * never the URL (which contains the project ref), the response body, the address, the code or a
 * token. `app.ts`'s redaction list is the backstop for what other libraries do; this file is
 * written so it has nothing to catch.
 */

/** Where the requests go and what authenticates them. Built by `deps.ts` from the environment. */
export interface SupabaseAuthConfig {
  /**
   * The project's auth base URL — `https://<project-ref>.supabase.co/auth/v1`.
   *
   * **Deliberately the same string as `SUPABASE_JWT_ISSUER` rather than a variable of its own**, and
   * the reason is a correctness property rather than economy. GoTrue stamps `iss` with its own API
   * base, and `auth/token.ts` compares every access token's `iss` against this value exactly. Taking
   * both from one variable makes "the project that mints the tokens is the project that verifies
   * them" structural: they cannot be pointed at two different projects, which is the failure that
   * presents as every request answering 401 with nothing in the logs to say why. A trailing slash is
   * stripped so the caller may write it either way.
   */
  readonly authUrl: string;
  /**
   * The project's anon/publishable key, sent as `apikey` on the non-admin endpoints.
   *
   * Required by Supabase's edge for any call to the project ("this server requires an `apikey`
   * header containing a valid Supabase-issued API key to call any endpoint"). It is publishable by
   * design — the Mac app would hold one too — so it is a configuration value rather than a secret in
   * the sense `SUPABASE_JWT_SECRET` is.
   */
  readonly anonKey: string;
  /**
   * The service-role key, sent on the `/admin/*` endpoints only — **and optional**.
   *
   * **This one is a real secret** and is on `scripts/check-secrets.sh`'s name-anchored list already.
   * It is used by exactly one method here, `deleteUser`, and is never sent on a request a user's
   * token could have made instead.
   *
   * **`undefined` is a supported and expected value** (founder decision of 2026-08-27, option (c)).
   * Nothing calls `deleteUser` today, so requiring this key would make every gateway serving sign-in
   * hold the project's most dangerous credential in order to use none of it. When it is absent the
   * adapter is fully functional for every other method and `deleteUser` throws
   * `ServiceRoleKeyNotConfigured` at its own call site — loudly, rather than sending a request with
   * no `apikey` and reading Supabase's 401 as something else. `config.ts`'s
   * `requireSupabaseAuthCredentials` carries the reasoning where the requirement used to be.
   */
  readonly serviceRoleKey: string | undefined;
  /**
   * Per-request timeout. **A bound this repository already owes** (`auth/revocation.ts`: "there is
   * no timeout on `signOutAllForUser` to bound it further. A real adapter should set one; whichever
   * ticket lands it owns that").
   *
   * The ceiling that matters is not patience: `sonny.revocation_lease_seconds()` is 300 (migration
   * 0008), and a provider call outliving its lease is re-claimed by a second drain and made twice.
   * It is also in front of a user waiting on a sign-in, where ten seconds is already long.
   *
   * **Required, and it carried a default of `10_000` until SONNY-425.** That default was §12's
   * upstream deadline for these routes written a second time, in a file that cites no contract
   * section — so `deps.ts` reading the number from `DEADLINE_MS.auth.upstream` and the adapter
   * defaulting to a literal produced the same behaviour, and *deleting* the wiring produced it too.
   * A mutation battery found exactly that: the mutant survived the whole suite, because there was
   * nothing left for a test to see. No test can close a gap between two spellings of one number;
   * removing one spelling can. A caller that names no bound now fails to compile, which is the same
   * answer `ClipboardHistoryStore` gives for a store that names no location.
   */
  readonly timeoutMs: number;
  /** Injected so the translation can be tested without a project. Defaults to the global `fetch`. */
  readonly fetch?: typeof globalThis.fetch;
}

/**
 * `deleteUser` was called on an adapter built without `SUPABASE_SERVICE_ROLE_KEY`.
 *
 * **Not one of the seam's two errors, on purpose.** `provider.ts` declares `ProviderRejected` and
 * `ProviderUnavailable`, and both are statements about what the *provider* did; this is a statement
 * about this deployment's configuration, and the two want opposite responses from whoever sees it —
 * an operator sets a variable rather than waiting for Supabase to recover. It is exported so the
 * ticket that lands a caller for `deleteUser` (SONNY-196's) can catch it by type rather than by
 * message, and so a reader grepping for it finds the argument in one place.
 */
export class ServiceRoleKeyNotConfigured extends Error {
  constructor() {
    super(
      "supabase deleteUser needs SUPABASE_SERVICE_ROLE_KEY and this gateway was started without " +
        "one. It is not required at startup because nothing called this method when that decision " +
        "was taken (founder decision, 2026-08-27, option (c)); the ticket that lands a caller adds " +
        "it back to the required set.",
    );
    this.name = "ServiceRoleKeyNotConfigured";
  }
}

/**
 * The token response of GoTrue's `/token`, `/verify` and every other session-minting endpoint
 * (`openapi.yaml`'s `AccessTokenResponseSchema`).
 *
 * **Parsed rather than cast, because `routes/auth.ts` sends these fields straight to the client.** A
 * response missing `access_token` would otherwise become a 200 carrying `"access_token": undefined`
 * — a client signed in against nothing, failing later and somewhere else. Unknown fields are ignored
 * on purpose: GoTrue adds them, and a strict schema would turn every addition into an outage.
 *
 * **`refresh_expires_in` is absent from the schema and that is why `VerifiedSession` makes it
 * optional.** Nothing here invents one; §3.2's `refresh_expires_at` is simply not emitted for this
 * provider, which is what that field's docstring says it is for.
 */
const sessionResponse = z.object({
  access_token: z.string().min(1),
  refresh_token: z.string().min(1),
  expires_in: z.number().int().nonnegative(),
  user: z
    .object({
      id: z.string().min(1),
      email: z.string().min(1).optional(),
      email_confirmed_at: z.string().min(1).nullish(),
      confirmed_at: z.string().min(1).nullish(),
    })
    .passthrough(),
});

/** GoTrue's `/user`. Only the id is read; the rest of the row is the provider's business. */
const userResponse = z.object({ id: z.string().min(1) }).passthrough();

/** `POST /otp`'s 200. `message_id` is the SMS branch's; the email branch answers `{}`. */
const otpResponse = z.object({ message_id: z.string().min(1).optional() }).passthrough();

/**
 * GoTrue's error body, whose shape depends on a request header, so both forms are read.
 *
 * Sending `X-Supabase-Api-Version: 2024-01-01` selects `{ code: "<error_code>", message }`; without
 * it the server marshals its legacy `HTTPError`, whose JSON tags are `{ code: <http status as a
 * number>, error_code: "<error_code>", msg }` and are commented "do not rename the JSON tags!" in
 * `apierrors.go`. **This adapter sends the header** and still reads the legacy shape, because a
 * self-hosted or older GoTrue that does not know the header answers the old way and would otherwise
 * have every failure read as unclassified. `code` is therefore taken only when it is a *string*: in
 * the legacy shape that same key is the HTTP status.
 *
 * The `x-sb-error-code` response header is preferred over both. `errors.go` sets it whenever the
 * error carries a code, on both branches, before either body is chosen.
 */
const errorResponse = z
  .object({
    code: z.union([z.string(), z.number()]).optional(),
    error_code: z.string().optional(),
    error: z.string().optional(),
  })
  .passthrough();

/**
 * The GoTrue error codes that mean **the caller's input or credential was refused**, as opposed to
 * the provider being unable to answer. Taken from `internal/api/apierrors/errorcode.go`.
 *
 * **The list is an allow-list of "this is the caller's fault" rather than a deny-list**, because the
 * safe direction is asymmetric: a code missing from here is treated as unavailable, which costs a
 * user one retry against a 502; a transient failure wrongly listed here tells a user their code was
 * wrong when it was not, and on `email/verify` it burns an attempt from their rate-limit budget.
 * Anything not named falls through to the status check below, where 4xx is still rejected — the list
 * exists so the *reason* is recorded, and so that 4xx codes which are really provider-side (the two
 * rate-limit ones, which GoTrue answers 429 for) cannot be swept in by status alone.
 */
const CALLER_REJECTED_CODES: ReadonlySet<string> = new Set([
  "otp_expired",
  "otp_disabled",
  "validation_failed",
  "bad_json",
  "bad_jwt",
  "no_authorization",
  "user_not_found",
  "user_banned",
  "session_not_found",
  "session_expired",
  "refresh_token_not_found",
  "refresh_token_already_used",
  "email_address_invalid",
  "email_address_not_authorized",
  "email_provider_disabled",
  "signup_disabled",
  "email_not_confirmed",
  "invalid_credentials",
  "flow_state_not_found",
  "flow_state_expired",
]);

/**
 * The codes that are the provider telling us to come back later. Answered with 429, so the status
 * check would reach the same verdict — they are named so that a future reader changing the status
 * rule cannot accidentally reclassify them as the caller's fault.
 */
const PROVIDER_BUSY_CODES: ReadonlySet<string> = new Set([
  "over_request_rate_limit",
  "over_email_send_rate_limit",
  "over_sms_send_rate_limit",
  "request_timeout",
  "unexpected_failure",
]);

/** What a failed call knows about itself. Never carries a body, a URL, an address or a token. */
interface ProviderFailure {
  readonly status: number;
  readonly code: string | undefined;
}

export class SupabaseAuthProvider implements AuthProvider {
  readonly #authUrl: string;
  readonly #anonKey: string;
  readonly #serviceRoleKey: string | undefined;
  readonly #timeoutMs: number;
  readonly #fetch: typeof globalThis.fetch;

  constructor(config: SupabaseAuthConfig) {
    this.#authUrl = config.authUrl.replace(/\/+$/, "");
    this.#anonKey = config.anonKey;
    this.#serviceRoleKey = config.serviceRoleKey;
    this.#timeoutMs = config.timeoutMs;
    this.#fetch = config.fetch ?? globalThis.fetch;
  }

  /**
   * `POST /otp` — Supabase mints the code and mails it. This never sees it.
   *
   * `create_user: true` is sent explicitly even though it is GoTrue's own default (`otp.go`'s
   * `OtpParams{CreateUser: true}`), because first-ever sign-in **is** sign-up in this product and a
   * default that changed under us would turn every new user's first code into `otp_disabled` —
   * silently, since `routes/auth.ts` answers the same uniform 200 whatever happens here.
   */
  async sendEmailCode(email: string, signal?: AbortSignal): Promise<SentCode> {
    const body = await this.#call("sendEmailCode", "/otp", {
      method: "POST",
      key: this.#anonKey,
      json: { email, create_user: true },
      signal,
    });
    const parsed = otpResponse.safeParse(body);
    // A 200 whose body is not an object is not worth failing a send over: the mail is already gone,
    // and this identifier exists for support lookups rather than for correctness.
    return { providerRequestId: parsed.success ? parsed.data.message_id : undefined };
  }

  /**
   * `POST /verify` with `type: "email"` — the OTP branch.
   *
   * **`"email"` is not in `openapi.yaml`'s enum and is nonetheless the right value**; the published
   * spec lags the server. `mailer.go` defines `EmailOTPVerification = "email"` and `verify.go`
   * handles it by checking both the confirmation and recovery token columns and resolving it to
   * `signup` or `magiclink` itself — which is exactly what a code obtained from `/otp` needs, since
   * that endpoint's mail is a signup for a new address and a magic link for a known one. Sending
   * `magiclink` instead would refuse every first-ever sign-in.
   */
  async verifyEmailCode(
    email: string,
    code: string,
    signal?: AbortSignal,
  ): Promise<VerifiedSession> {
    const body = await this.#call("verifyEmailCode", "/verify", {
      method: "POST",
      key: this.#anonKey,
      json: { type: "email", email, token: code },
      signal,
    });
    return this.#session("verifyEmailCode", body);
  }

  /**
   * `POST /token?grant_type=refresh_token`. Rotation, the 10s reuse interval and family revocation
   * on reuse are all the provider's, per contract §3.3 — this hands the token over and reports back.
   */
  async refresh(refreshToken: string, signal?: AbortSignal): Promise<VerifiedSession> {
    const body = await this.#call("refresh", "/token?grant_type=refresh_token", {
      method: "POST",
      key: this.#anonKey,
      json: { refresh_token: refreshToken },
      signal,
    });
    return this.#session("refresh", body);
  }

  /**
   * `POST /logout?scope=local` — **this session and no other**.
   *
   * The scope is the whole of the decision and `global` would be the wrong one. `provider.ts` says
   * `signOut` "revokes only the session whose access token it is given", and distinguishes it from
   * `signOutAllForUser` on exactly that. GoTrue's `logout.go` maps `local` to
   * `models.LogoutSession(tx, s.ID)` and its default, `global`, to `models.Logout(tx, u.ID)` — every
   * session the user has. A user signing out on one Mac must not sign themselves out on another.
   */
  async signOut(accessToken: string, signal?: AbortSignal): Promise<void> {
    await this.#call("signOut", "/logout?scope=local", {
      method: "POST",
      key: this.#anonKey,
      bearer: accessToken,
      signal,
    });
  }

  /**
   * `GET /user` — the provider-side user this access token belongs to.
   *
   * **Nothing on the request path calls this, and that is a decision rather than an omission.**
   * Access-token verification is local and symmetric (`auth/token.ts`, founder decision of
   * 2026-08-21): asking the provider per request would put its latency and its availability in front
   * of every authenticated route. It is implemented because it is on the seam and a caller with a
   * token and no gateway session — a support tool, a future ticket — has no other way to ask. The
   * three test fakes throw from it deliberately, so a middleware that started reaching for it fails
   * loudly in the suite; that guard is about the fakes and is not weakened by this being real.
   */
  async userFromAccessToken(accessToken: string): Promise<string> {
    const body = await this.#call("userFromAccessToken", "/user", {
      method: "GET",
      key: this.#anonKey,
      bearer: accessToken,
    });
    const parsed = userResponse.safeParse(body);
    if (!parsed.success) {
      throw new ProviderUnavailable("supabase userFromAccessToken returned an unreadable user");
    }
    return parsed.data.id;
  }

  /**
   * **Not implemented, because Supabase Auth exposes no endpoint that does it** — stated here rather
   * than approximated, and reported on SONNY-307 as owed.
   *
   * The operation this needs is "revoke every session of user X, given X's id and no token of
   * theirs". GoTrue's whole path list is in `supabase/auth`'s published `openapi.yaml` — **43 paths**,
   * counted rather than eyeballed and dated rather than pinned to a commit, because it is somebody
   * else's file: `curl -s https://raw.githubusercontent.com/supabase/auth/master/openapi.yaml |
   * grep -cE "^  /"` answered 43 on 2026-08-27. The operation is not among them:
   * `/logout` is the only session-revoking endpoint and it is authenticated by the **user's own
   * bearer token** (`UserAuth`), deriving the user from that token rather than from a parameter;
   * the entire `/admin/*` surface — `generate_link`, `audit`, `users`, `users/{id}`,
   * `users/{id}/factors`, `sso`, `oauth` and `custom-providers` — contains no session route at all.
   *
   * **`ProviderUnavailable`, not `ProviderRejected`, and the difference is the whole design.**
   * `revocation.ts` treats `ProviderRejected` as "the provider says this is already done" and stamps
   * `provider_session_revoked_at`; anything else leaves the row owed, releases the lease, and lets
   * the next drain find it. So this failure is recorded as debt rather than written off, `DELETE
   * /v1/account` still closes the account and still answers 204 — its own docstring covers that — and
   * `npm run revocations` reports the residual and exits 1, which is what that command is for.
   *
   * **What the account holder is actually exposed to meanwhile, enumerated rather than waved at.**
   * Nothing at this gateway: `auth/gate.ts` attributes every authenticated request through
   * `accountForSupabaseUser`, which excludes a closed account, so every route refuses immediately,
   * and `POST /v1/auth/refresh` refuses on the same read. What survives is at Supabase — a refresh
   * token already in someone's hands can still mint Supabase access tokens against the project
   * directly. Those tokens open nothing here.
   *
   * **The two ways to close it, neither of which is an adapter's to choose.** Delete the provider
   * user (`deleteUser` below, `DELETE /admin/users/{id}`, which takes the sessions with it) — a
   * different act from signing out, and the account model deliberately keeps identities for their
   * audit trail. Or mint a short-lived token for the user with `SUPABASE_JWT_SECRET` and present it
   * to `/logout?scope=global`, which `logout.go` shows would work even with no `session_id` claim —
   * that is the gateway forging a user credential, and it is a founder's decision, not a session's.
   */
  async signOutAllForUser(supabaseUserId: string, signal?: AbortSignal): Promise<void> {
    void supabaseUserId;
    // **The signal reaches no socket here, and saying so is the point of naming it.** This method
    // throws before it sends anything, so the route deadline `revocation.ts` threads down is
    // honoured by the seam's declaration and by nothing in this body. It is accepted rather than
    // omitted so that the implementation this comment's own docstring says is owed inherits the
    // bound instead of having to be told about it.
    void signal;
    throw new ProviderUnavailable(
      "supabase signOutAllForUser is not implementable: Supabase Auth exposes no endpoint that " +
        "revokes a user's sessions from their id alone. The revocation stays owed and is reported " +
        "by `npm run revocations` (SONNY-307).",
    );
  }

  /**
   * `DELETE /admin/users/{id}` — the service-role endpoint, and the only place that key is sent.
   *
   * Hard delete: GoTrue soft-deletes only when the body asks it to, and no body is sent. A
   * `user_not_found` is `ProviderRejected` by the classification below, which is the state being
   * asked for.
   */
  async deleteUser(supabaseUserId: string): Promise<void> {
    // **The one failure here that is neither of the seam's two errors, and it is deliberate.** A
    // missing service-role key is a deployment fault, not a provider one: answering
    // `ProviderUnavailable` would send an operator hunting a Supabase outage that is not happening,
    // and `ProviderRejected` would be read by `revocation.ts` as "already done". Failing before the
    // request is also the only way to avoid sending Supabase an admin call with no `apikey` and
    // then having to guess whether its 401 meant "no key" or "wrong key".
    const key = this.#serviceRoleKey;
    if (key === undefined) throw new ServiceRoleKeyNotConfigured();
    await this.#call("deleteUser", `/admin/users/${encodeURIComponent(supabaseUserId)}`, {
      method: "DELETE",
      key,
      bearer: key,
    });
  }

  /** Parse a session response, or fail as unavailable — a malformed 200 is not the caller's fault. */
  #session(operation: string, body: unknown): VerifiedSession {
    const parsed = sessionResponse.safeParse(body);
    if (!parsed.success) {
      throw new ProviderUnavailable(`supabase ${operation} returned an unreadable session response`);
    }
    const { access_token, refresh_token, expires_in, user } = parsed.data;
    return {
      supabaseUserId: user.id,
      // The provider's own view of this user's primary address, reported and never used as the
      // identity key -- see this file's header, translation (3).
      email: user.email,
      // GoTrue confirms an address by stamping one of these. Either is proof; neither being present
      // means the row exists unconfirmed, which this flow should not be able to produce.
      emailVerified: Boolean(user.email_confirmed_at ?? user.confirmed_at),
      accessToken: access_token,
      refreshToken: refresh_token,
      expiresIn: expires_in,
      // Absent from `AccessTokenResponseSchema`, so never invented. §3.2's `refresh_expires_at` is
      // simply not emitted for this provider.
      refreshExpiresIn: undefined,
    };
  }

  /**
   * One request, one translation. The only place in this file that touches the network.
   *
   * Returns the parsed JSON body, or `undefined` for a 204 / empty body. Throws `ProviderRejected`
   * or `ProviderUnavailable` and never anything else — a route catching those two must not also have
   * to catch a `TypeError` from `fetch`.
   */
  async #call(
    operation: string,
    path: string,
    options: {
      method: "GET" | "POST" | "DELETE";
      key: string;
      bearer?: string;
      json?: unknown;
      /** The caller's deadline, when it has one. See the composition at the `fetch` below. */
      signal?: AbortSignal | undefined;
    },
  ): Promise<unknown> {
    const headers: Record<string, string> = {
      apikey: options.key,
      accept: "application/json",
      // Selects the 2024-01-01 error body, whose `code` is the error code rather than the HTTP
      // status. The legacy shape is still read, for a server that does not know this header.
      "x-supabase-api-version": "2024-01-01",
    };
    if (options.bearer !== undefined) headers["authorization"] = `Bearer ${options.bearer}`;
    if (options.json !== undefined) headers["content-type"] = "application/json";

    let response: Response;
    try {
      response = await this.#fetch(`${this.#authUrl}${path}`, {
        method: options.method,
        headers,
        ...(options.json === undefined ? {} : { body: JSON.stringify(options.json) }),
        // **Every call is bounded, and after SONNY-425 it is bounded twice.** An unbounded one is
        // what `revocation.ts` names as owed, and it is also a request handler holding a connection
        // while a socket hangs. `#timeoutMs` bounds THIS call — `auth/deps.ts` sets it from
        // `DEADLINE_MS.auth.upstream`, so it is §12's own number rather than a literal that happens
        // to match it — and the caller's signal bounds the ROUTE's whole upstream budget, which is a
        // larger quantity wherever a handler makes more than one call. `AbortSignal.any` honours
        // whichever fires first and is not given an array with a hole in it: composing only when the
        // caller supplied one keeps the single-signal path byte-identical to what it was.
        signal:
          options.signal === undefined
            ? AbortSignal.timeout(this.#timeoutMs)
            : AbortSignal.any([options.signal, AbortSignal.timeout(this.#timeoutMs)]),
      });
    } catch (error) {
      // A timeout, a DNS failure, a refused socket, an aborted body. The name is safe to repeat --
      // it is `TimeoutError`, `AbortError` or an errno class -- and the message is not, because
      // Node puts the URL in it and the URL carries the project ref.
      throw new ProviderUnavailable(
        `supabase ${operation} could not be reached (${(error as Error)?.name || "Error"})`,
      );
    }

    const body = await this.#body(response);
    if (response.ok) return body;
    throw this.#failure(operation, { status: response.status, code: errorCodeOf(response, body) });
  }

  /** JSON when there is any, `undefined` otherwise. A body that will not parse is not an error yet. */
  async #body(response: Response): Promise<unknown> {
    if (response.status === 204) return undefined;
    const text = await response.text().catch(() => "");
    if (text.trim() === "") return undefined;
    try {
      return JSON.parse(text);
    } catch {
      return undefined;
    }
  }

  /**
   * Status and code → which of the two errors the seam declares.
   *
   * Order matters and is the safe one. Read in the order the code checks them: a named busy code
   * wins over everything; then **429 and every 5xx are unavailable whatever code they name**; then a
   * named caller code makes it rejected; then a remaining 4xx does. The reason the status outranks
   * the caller-code list here and not below it is the same for both statuses — a rate limit and a
   * server error are statements about the provider's ability to answer, never about whether the
   * user's input was correct, so `429 validation_failed` and `500 otp_expired` are both the
   * provider's failure. **This paragraph said "a named caller code wins next, and only then does the
   * status decide"**, which is true of 4xx and false of 5xx, and would have had a reader expect a
   * 500 naming a caller code to come back rejected (PR #137 review, residual 2). The behaviour was
   * the intended one; only the sentence was wrong.
   */
  #failure(operation: string, failure: ProviderFailure): Error {
    const named = failure.code === undefined ? "" : ` (${failure.code})`;
    const detail = `supabase ${operation} refused with ${failure.status}${named}`;
    if (failure.code !== undefined && PROVIDER_BUSY_CODES.has(failure.code)) {
      return new ProviderUnavailable(detail);
    }
    if (failure.status === 429 || failure.status >= 500) return new ProviderUnavailable(detail);
    if (failure.code !== undefined && CALLER_REJECTED_CODES.has(failure.code)) {
      return new ProviderRejected(detail);
    }
    if (failure.status >= 400) return new ProviderRejected(detail);
    // A non-ok status below 400 is a redirect this adapter did not ask for and cannot follow
    // meaningfully -- `fetch` follows them by default, so reaching here means one it would not.
    return new ProviderUnavailable(detail);
  }
}

/**
 * The provider's error code, from the response header first and the body second.
 *
 * `x-sb-error-code` is set by `errors.go` on both body shapes whenever a code exists, which makes it
 * the one place that does not depend on which API version the server decided to answer. The body is
 * read after it: `error_code` is the legacy field, and `code` is the 2024-01-01 field — taken **only
 * when it is a string**, because in the legacy body that same key holds the HTTP status as a number.
 */
export function errorCodeOf(response: Response, body: unknown): string | undefined {
  const header = response.headers.get("x-sb-error-code");
  if (header !== null && header.trim() !== "") return header.trim();
  const parsed = errorResponse.safeParse(body);
  if (!parsed.success) return undefined;
  const { error_code, code, error } = parsed.data;
  if (error_code !== undefined && error_code !== "") return error_code;
  if (typeof code === "string" && code !== "") return code;
  // The OAuth-shaped body (`{"error": "...", "error_description": "..."}`) that `/token` can answer.
  if (error !== undefined && error !== "") return error;
  return undefined;
}
