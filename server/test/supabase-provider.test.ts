import { describe, expect, it } from "vitest";
import { ProviderRejected, ProviderUnavailable } from "../src/auth/provider.js";
import { SupabaseAuthProvider, errorCodeOf } from "../src/auth/supabase.js";

/** `fetch`'s first parameter, named without `RequestInfo` — the lib here is ES2023, not DOM. */
type FetchInput = Parameters<typeof globalThis.fetch>[0];

/**
 * The Supabase adapter's translation contract (SONNY-307).
 *
 * **What this suite can and cannot establish, stated first so nothing here is read as wider than it
 * is.** There is no Supabase project — the credentials do not exist yet — so `fetch` is injected and
 * every response below is one this repository wrote. That makes these tests authoritative about the
 * translation (which request goes out, which error class comes back, which fields are read) and
 * silent about whether a real project answers in these shapes. The shapes are not invented: each is
 * taken from `supabase/auth`'s own published sources, cited on the test that uses it. The half that
 * needs a live project is recorded on the ticket as owed, not claimed here.
 */

interface Recorded {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

/** A `fetch` that records what it was asked and answers what the test says. */
function stubFetch(
  answer: (request: Recorded) => Response | Promise<Response>,
): { fetch: typeof globalThis.fetch; calls: Recorded[] } {
  const calls: Recorded[] = [];
  const fetch = (async (input: FetchInput, init?: RequestInit) => {
    const headers: Record<string, string> = {};
    for (const [key, value] of Object.entries((init?.headers ?? {}) as Record<string, string>)) {
      headers[key.toLowerCase()] = value;
    }
    const recorded: Recorded = {
      url: String(input),
      method: init?.method ?? "GET",
      headers,
      body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
    };
    calls.push(recorded);
    return await answer(recorded);
  }) as unknown as typeof globalThis.fetch;
  return { fetch, calls };
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

/**
 * A session response in GoTrue's `AccessTokenResponseSchema` shape.
 *
 * `refresh_expires_in` is absent because that schema has no such field — which is the measured fact
 * behind `VerifiedSession.refreshExpiresIn` being optional, and behind §3.2's `refresh_expires_at`
 * never being emitted for this provider.
 */
const SESSION_BODY = {
  access_token: "eyJ-access",
  token_type: "bearer",
  expires_in: 3600,
  expires_at: 1_800_000_000,
  refresh_token: "opaque-refresh",
  user: {
    id: "11111111-2222-3333-4444-555555555555",
    email: "signed-in@example.com",
    email_confirmed_at: "2026-08-27T00:00:00Z",
  },
};

const ANON = "anon-key";
const SERVICE_ROLE = "service-role-key";
const AUTH_URL = "https://project-ref.supabase.co/auth/v1";

function providerAnswering(
  answer: (request: Recorded) => Response | Promise<Response>,
  options: { authUrl?: string } = {},
): { provider: SupabaseAuthProvider; calls: Recorded[] } {
  const { fetch, calls } = stubFetch(answer);
  const provider = new SupabaseAuthProvider({
    authUrl: options.authUrl ?? AUTH_URL,
    anonKey: ANON,
    serviceRoleKey: SERVICE_ROLE,
    fetch,
    // **Named rather than defaulted, because the adapter no longer has a default** (SONNY-425). It
    // carried one of `10_000`, which was §12's upstream deadline for these routes spelled a second
    // time in a file that cites no contract section — so a mutant deleting `deps.ts`' wiring of the
    // real number survived the whole suite, there being nothing left to observe. §12's number is
    // `deps.ts`' to supply; a test that only needs *a* bound says so here.
    timeoutMs: 10_000,
  });
  return { provider, calls };
}

/**
 * The `Error` a promise rejected with, or a failure if it did not reject.
 *
 * `.catch((e) => e)` types as the union of the resolved value and the error, so every assertion on
 * `.message` below would need a cast — and a cast is exactly what would let a test that stopped
 * throwing keep passing. This throws instead, so "it resolved" is a red test rather than a silently
 * skipped assertion.
 */
async function errorFrom(promise: Promise<unknown>): Promise<Error> {
  try {
    await promise;
  } catch (thrown) {
    return thrown as Error;
  }
  throw new Error("expected the call to reject, and it resolved");
}

describe("SupabaseAuthProvider — the requests it makes", () => {
  it("asks Supabase to send the code and never handles the code itself", async () => {
    // The gate this ticket was told to answer before building any mail half, in executable form:
    // the request that starts a sign-in carries an address and nothing else, and the response the
    // adapter accepts carries no code. There is no third call, and no mail credential is in scope
    // because the gateway has nothing to put in a mail.
    const { provider, calls } = providerAnswering(() => json(200, {}));
    const sent = await provider.sendEmailCode("user@example.com");

    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url).toBe("https://project-ref.supabase.co/auth/v1/otp");
    expect(call.body).toEqual({ email: "user@example.com", create_user: true });
    expect(call.headers["apikey"]).toBe(ANON);
    // No bearer: this call is made on the project's behalf, not a user's.
    expect(call.headers["authorization"]).toBeUndefined();
    expect(JSON.stringify(sent)).not.toContain("code");
    // `message_id` is the SMS branch's; GoTrue's email branch answers `{}`.
    expect(sent.providerRequestId).toBeUndefined();
  });

  it("sends create_user explicitly, so a changed provider default cannot silence first sign-ins", async () => {
    // `otp.go` defaults it to true today. If that ever flips, every new user's first code becomes
    // `otp_disabled` — and `routes/auth.ts` answers the same uniform 200 whatever happens here, so
    // nothing would surface it. Pinned rather than inherited.
    const { provider, calls } = providerAnswering(() => json(200, {}));
    await provider.sendEmailCode("new@example.com");
    expect((calls[0]!.body as { create_user: boolean }).create_user).toBe(true);
  });

  it("verifies with type \"email\", which is the OTP branch rather than magiclink", async () => {
    // `mailer.go`: EmailOTPVerification = "email". `verify.go` resolves it to signup or magiclink by
    // checking both token columns, which is what a code from `/otp` needs — that endpoint mails a
    // signup for a new address and a magic link for a known one. Sending "magiclink" would refuse
    // every first-ever sign-in.
    const { provider, calls } = providerAnswering(() => json(200, SESSION_BODY));
    await provider.verifyEmailCode("user@example.com", "123456");

    expect(calls[0]!.url).toBe("https://project-ref.supabase.co/auth/v1/verify");
    expect(calls[0]!.body).toEqual({ type: "email", email: "user@example.com", token: "123456" });
  });

  it("refreshes through the refresh_token grant", async () => {
    const { provider, calls } = providerAnswering(() => json(200, SESSION_BODY));
    await provider.refresh("opaque-refresh");

    expect(calls[0]!.url).toBe(
      "https://project-ref.supabase.co/auth/v1/token?grant_type=refresh_token",
    );
    expect(calls[0]!.body).toEqual({ refresh_token: "opaque-refresh" });
  });

  it("signs out with scope=local, so one Mac's sign-out is not every Mac's", async () => {
    // The seam says `signOut` "revokes only the session whose access token it is given", and
    // distinguishes it from `signOutAllForUser` on exactly that. `logout.go` maps local to
    // LogoutSession(s.ID) and its DEFAULT, global, to Logout(u.ID) — every session the user has. An
    // omitted scope would therefore be the wrong behaviour, silently.
    const { provider, calls } = providerAnswering(() => new Response(null, { status: 204 }));
    await provider.signOut("eyJ-access");

    expect(calls[0]!.url).toBe("https://project-ref.supabase.co/auth/v1/logout?scope=local");
    expect(calls[0]!.headers["authorization"]).toBe("Bearer eyJ-access");
    expect(calls[0]!.headers["apikey"]).toBe(ANON);
  });

  it("sends the service-role key only to the admin surface, never on a user's behalf", async () => {
    // The service-role key bypasses every policy in the project. Of the four calls below, the three
    // made on a user's behalf must not carry it and the admin delete must.
    const { provider, calls } = providerAnswering((request) =>
      // `/admin/users/{id}` and `/user` both answer a bare user object; the session-minting routes
      // answer the token response, whose user is nested.
      request.url.includes("/admin/") || request.url.endsWith("/user")
        ? json(200, { id: "11111111-2222-3333-4444-555555555555" })
        : json(200, SESSION_BODY),
    );
    await provider.verifyEmailCode("user@example.com", "123456");
    await provider.refresh("opaque-refresh");
    await provider.userFromAccessToken("eyJ-access");
    await provider.deleteUser("11111111-2222-3333-4444-555555555555");

    const admin = calls.filter((call) => call.url.includes("/admin/"));
    const rest = calls.filter((call) => !call.url.includes("/admin/"));
    expect(admin).toHaveLength(1);
    expect(rest).toHaveLength(3);
    for (const call of rest) {
      expect(call.headers["apikey"]).toBe(ANON);
      expect(Object.values(call.headers)).not.toContain(`Bearer ${SERVICE_ROLE}`);
      expect(Object.values(call.headers)).not.toContain(SERVICE_ROLE);
    }
    expect(admin[0]!.method).toBe("DELETE");
    expect(admin[0]!.headers["apikey"]).toBe(SERVICE_ROLE);
    expect(admin[0]!.headers["authorization"]).toBe(`Bearer ${SERVICE_ROLE}`);
  });

  it("percent-encodes the user id it puts in the admin path", async () => {
    const { provider, calls } = providerAnswering(() => json(200, { id: "u1" }));
    await provider.deleteUser("a/../b");
    expect(calls[0]!.url).toBe("https://project-ref.supabase.co/auth/v1/admin/users/a%2F..%2Fb");
  });

  it("tolerates a trailing slash on the configured auth URL", async () => {
    const { provider, calls } = providerAnswering(() => json(200, {}), {
      authUrl: "https://project-ref.supabase.co/auth/v1/",
    });
    await provider.sendEmailCode("user@example.com");
    expect(calls[0]!.url).toBe("https://project-ref.supabase.co/auth/v1/otp");
  });

  it("asks for the 2024-01-01 error shape on every call", async () => {
    // Without this header GoTrue marshals its legacy body, whose `code` is the HTTP status rather
    // than the error code. Both shapes are still read; asking for the newer one is what makes the
    // common case unambiguous.
    const { provider, calls } = providerAnswering(() => json(200, SESSION_BODY));
    await provider.refresh("opaque-refresh");
    expect(calls[0]!.headers["x-supabase-api-version"]).toBe("2024-01-01");
  });
});

describe("SupabaseAuthProvider — the session it reports", () => {
  it("reads the fields the token response actually carries", async () => {
    const { provider } = providerAnswering(() => json(200, SESSION_BODY));
    const session = await provider.verifyEmailCode("user@example.com", "123456");

    expect(session).toEqual({
      supabaseUserId: "11111111-2222-3333-4444-555555555555",
      email: "signed-in@example.com",
      emailVerified: true,
      accessToken: "eyJ-access",
      refreshToken: "opaque-refresh",
      expiresIn: 3600,
      refreshExpiresIn: undefined,
    });
  });

  it("never invents a refresh expiry, because the provider's schema has no such field", async () => {
    // §3.2's `refresh_expires_at` is emitted by `routes/auth.ts` only when this is defined. A server
    // -invented value would be a client scheduling a sign-out against a number nobody measured.
    const { provider } = providerAnswering(() => json(200, SESSION_BODY));
    const session = await provider.refresh("opaque-refresh");
    expect(session.refreshExpiresIn).toBeUndefined();
  });

  it("accepts confirmed_at when email_confirmed_at is absent, and reports unconfirmed as false", async () => {
    const { provider } = providerAnswering((request) =>
      json(200, {
        ...SESSION_BODY,
        user:
          request.body && (request.body as { token?: string }).token === "confirmed"
            ? { id: "u1", email: "a@example.com", confirmed_at: "2026-08-27T00:00:00Z" }
            : { id: "u1", email: "a@example.com" },
      }),
    );
    expect((await provider.verifyEmailCode("a@example.com", "confirmed")).emailVerified).toBe(true);
    expect((await provider.verifyEmailCode("a@example.com", "not-yet")).emailVerified).toBe(false);
  });

  it("reports the provider's own email, which can differ from the address just verified", async () => {
    // **Renamed from a claim this test cannot make** (PR #137 review, F7). It said "without ever
    // making it the identity", and nothing here decides the identity — `routes/auth.ts` does, and
    // `auth.db.test.ts`'s `theIdentityIsKeyedOnTheAddressTheCallerAsserted` is the test that holds
    // that boundary. What this one establishes is the premise that makes the boundary matter: the
    // provider's `user.email` really can name a different address from the one just verified,
    // because Supabase's automatic identity linking attaches a newly verified address to an existing
    // `auth.users` row and reports that row's primary address. Reading this field back as the
    // subject is therefore a defect rather than a style choice.
    const { provider } = providerAnswering(() =>
      json(200, { ...SESSION_BODY, user: { id: "u1", email: "primary@example.com" } }),
    );
    const session = await provider.verifyEmailCode("just-verified@example.com", "123456");
    expect(session.email).toBe("primary@example.com");
    expect(session.supabaseUserId).toBe("u1");
  });

  it("ignores fields GoTrue adds, so a provider release does not become an outage", async () => {
    const { provider } = providerAnswering(() =>
      json(200, { ...SESSION_BODY, provider_refresh_token: "x", something_new: { a: 1 } }),
    );
    await expect(provider.verifyEmailCode("a@example.com", "1")).resolves.toMatchObject({
      accessToken: "eyJ-access",
    });
  });

  it("refuses a 200 that is missing the access token rather than minting an empty session", async () => {
    // `routes/auth.ts` sends `session.accessToken` straight to the client, so an unparsed body would
    // become a 200 carrying `"access_token": undefined` — a client signed in against nothing,
    // failing later and somewhere else. Unavailable rather than rejected: it is not the caller's
    // fault, and rejected would surface as `auth.code_invalid`, blaming the user's code.
    const { provider } = providerAnswering(() =>
      json(200, { refresh_token: "r", expires_in: 3600, user: { id: "u1" } }),
    );
    await expect(provider.verifyEmailCode("a@example.com", "1")).rejects.toBeInstanceOf(
      ProviderUnavailable,
    );
  });

  it("refuses a 200 whose user carries no id", async () => {
    const { provider } = providerAnswering(() => json(200, { ...SESSION_BODY, user: {} }));
    await expect(provider.refresh("r")).rejects.toBeInstanceOf(ProviderUnavailable);
  });
});

describe("SupabaseAuthProvider — one provider error, three contract failures", () => {
  it("raises ProviderRejected for otp_expired and does not itself distinguish the three cases", async () => {
    // GoTrue answers a wrong code, an expired code and a consumed code with this one code, whose
    // documented text is "OTP code for this sign-in has expired. Ask the user to sign in again."
    // Contract §3.6 owes the client three. The adapter must NOT guess: `routes/auth.ts` derives
    // `auth.code_invalid` / `auth.code_expired` / `auth.code_used` from the gateway's own issuance
    // record, which is the only thing that knows. So all three inputs produce one outcome here.
    const { provider } = providerAnswering(() =>
      json(403, { code: "otp_expired", message: "Token has expired or is invalid" }),
    );
    for (const code of ["wrong-code", "expired-code", "already-used-code"]) {
      const error = await errorFrom(provider.verifyEmailCode("a@example.com", code));
      expect(error).toBeInstanceOf(ProviderRejected);
      expect((error as Error).message).toContain("otp_expired");
    }
  });

  it("reads the error code from the legacy body shape too", async () => {
    // Without `X-Supabase-Api-Version` a GoTrue that predates it marshals `HTTPError`, whose tags are
    // commented "do not rename the JSON tags!" in apierrors.go: `code` is the HTTP STATUS as a
    // number and `error_code` carries the string. Reading `code` unconditionally would classify
    // every legacy failure as unrecognised.
    const { provider } = providerAnswering(() =>
      json(403, { code: 403, error_code: "otp_expired", msg: "Token has expired or is invalid" }),
    );
    const error = await errorFrom(provider.verifyEmailCode("a@example.com", "1"));
    expect(error).toBeInstanceOf(ProviderRejected);
    expect((error as Error).message).toContain("otp_expired");
    // The status, not the string "403" mistaken for a code.
    expect((error as Error).message).toContain("403");
  });

  it("prefers the x-sb-error-code header, which both body shapes are stamped alongside", async () => {
    const { provider } = providerAnswering(() =>
      json(400, { code: 400, msg: "no code in this body" }, { "x-sb-error-code": "validation_failed" }),
    );
    const error = await errorFrom(provider.verifyEmailCode("a@example.com", "1"));
    expect((error as Error).message).toContain("validation_failed");
  });
});

describe("SupabaseAuthProvider — rejected versus unavailable", () => {
  const rejected = [
    ["otp_expired", 403],
    ["validation_failed", 400],
    ["refresh_token_not_found", 401],
    ["refresh_token_already_used", 401],
    ["session_not_found", 404],
    ["bad_jwt", 401],
    ["user_not_found", 404],
    ["signup_disabled", 422],
  ] as const;

  it.each(rejected)("treats %s (%i) as the caller's failure", async (code, status) => {
    const { provider } = providerAnswering(() => json(status, { code, message: "m" }));
    await expect(provider.verifyEmailCode("a@example.com", "1")).rejects.toBeInstanceOf(
      ProviderRejected,
    );
  });

  const unavailable = [
    ["over_email_send_rate_limit", 429],
    ["over_request_rate_limit", 429],
    ["unexpected_failure", 500],
    ["request_timeout", 504],
  ] as const;

  it.each(unavailable)("treats %s (%i) as the provider's failure", async (code, status) => {
    // The distinction is what the user is told. `routes/auth.ts` turns rejected into a 400 naming
    // their code and unavailable into a 502 `provider.unavailable`, retryable. Telling a user their
    // code was wrong when Supabase was rate-limiting is the failure this table prevents.
    const { provider } = providerAnswering(() => json(status, { code, message: "m" }));
    await expect(provider.verifyEmailCode("a@example.com", "1")).rejects.toBeInstanceOf(
      ProviderUnavailable,
    );
  });

  it("treats a 429 as unavailable even when its code is one the caller could have caused", async () => {
    // A rate limit is never a statement about whether the input was correct, so the status wins over
    // the allow-list here. Without this ordering a 429 carrying `validation_failed` would burn one
    // of the user's five verify attempts and tell them their code was wrong.
    const { provider } = providerAnswering(() => json(429, { code: "validation_failed" }));
    await expect(provider.verifyEmailCode("a@example.com", "1")).rejects.toBeInstanceOf(
      ProviderUnavailable,
    );
  });

  it("rejects an unrecognised 4xx and reports an unrecognised 5xx as unavailable", async () => {
    // The code list is an allow-list of "the caller's fault"; anything unnamed still has to land
    // somewhere, and the status is the honest fallback in both directions.
    const four = providerAnswering(() => json(400, { code: "a_code_from_a_future_release" }));
    await expect(four.provider.refresh("r")).rejects.toBeInstanceOf(ProviderRejected);
    const five = providerAnswering(() => json(503, {}));
    await expect(five.provider.refresh("r")).rejects.toBeInstanceOf(ProviderUnavailable);
  });

  it("turns a transport failure into ProviderUnavailable rather than letting it escape", async () => {
    // A route catching the seam's two errors must not also have to catch a TypeError from fetch.
    const { provider } = providerAnswering(() => {
      throw Object.assign(new Error("connect ECONNREFUSED 10.0.0.1:443"), { name: "TypeError" });
    });
    const error = await errorFrom(provider.refresh("r"));
    expect(error).toBeInstanceOf(ProviderUnavailable);
    expect((error as Error).message).toContain("TypeError");
  });

  it("composes the CALLER's deadline with its own bound, so a route's signal reaches the socket", async () => {
    // **PR #212's F2, R1.** §12 and this branch's own prose both claim "the route's deadline
    // reaching the socket", and until this test nothing held it: every other assertion about a
    // signal in this repository observes a *fake* provider's parameter, so replacing the
    // `AbortSignal.any([...])` composition with the adapter's own timeout alone passed the whole
    // suite. That mutant matters — with the composition gone, `DELETE /v1/account`'s drain is back
    // to N times the adapter's bound, which is the defect SONNY-425 exists to fix.
    //
    // Driven by aborting the caller's controller and reading the signal the adapter actually put on
    // its `fetch`. No clock: `AbortSignal.any` propagates an abort to the composed signal at once,
    // and the adapter's own bound here is long enough that it cannot be what fires.
    let seen: AbortSignal | undefined;
    const fetch = (async (_input: FetchInput, init?: RequestInit) => {
      seen = init?.signal ?? undefined;
      // Rejects on abort, the way a real `fetch` does — a stub that ignored the signal would hang
      // here rather than exercising the path this test is about.
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(Object.assign(new Error("The operation was aborted"), { name: "AbortError" }));
        });
      });
    }) as unknown as typeof globalThis.fetch;
    const provider = new SupabaseAuthProvider({
      authUrl: AUTH_URL,
      anonKey: ANON,
      serviceRoleKey: SERVICE_ROLE,
      fetch,
      timeoutMs: 600_000,
    });
    const caller = new AbortController();
    const pending = provider.refresh("r", caller.signal);
    await Promise.resolve();
    expect(seen).toBeInstanceOf(AbortSignal);
    expect(seen!.aborted).toBe(false);

    caller.abort();
    expect(seen!.aborted).toBe(true);
    // And it arrives at the caller as this seam's own error rather than a bare `AbortError`, which
    // is what `routes/auth.ts` catches. `provider.ts` states that mapping; this is where it holds.
    await expect(pending).rejects.toBeInstanceOf(ProviderUnavailable);
  });

  it("leaves a call with no caller signal bounded by its own timeout and nothing else", async () => {
    // The other direction of the composition, and it is what stops the mutant being written the
    // easy way round: an adapter that always composed with a *caller* signal would fail on the five
    // call sites that pass none, and one that dropped its own bound would leave those unbounded.
    let seen: AbortSignal | undefined;
    const fetch = (async (_input: FetchInput, init?: RequestInit) => {
      seen = init?.signal ?? undefined;
      // Rejects on abort, the way a real `fetch` does — a stub that ignored the signal would hang
      // here rather than exercising the path this test is about.
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(Object.assign(new Error("The operation was aborted"), { name: "AbortError" }));
        });
      });
    }) as unknown as typeof globalThis.fetch;
    const provider = new SupabaseAuthProvider({
      authUrl: AUTH_URL,
      anonKey: ANON,
      serviceRoleKey: SERVICE_ROLE,
      fetch,
      timeoutMs: 20,
    });
    const error = await errorFrom(provider.refresh("r"));
    expect(seen).toBeInstanceOf(AbortSignal);
    expect(seen!.aborted).toBe(true);
    expect(error).toBeInstanceOf(ProviderUnavailable);
    // **`timeoutMs` is the field the request above actually used, not a second spelling of it.**
    // That is the whole reason it is readable, so the assertion pairing it with the abort has to
    // live beside the abort: a public field nothing ties to behaviour would recreate W9's defect one
    // level out. Twenty milliseconds, so this reads a real bound firing rather than a wall clock.
    expect(provider.timeoutMs).toBe(20);
  });

  it("bounds every call with a timeout and reports a timeout as unavailable", async () => {
    // `revocation.ts` names an unbounded provider call as owed by "whichever ticket lands" the
    // adapter. The signal is asserted on the request rather than by waiting, so this test cannot
    // race a wall clock.
    let seen: AbortSignal | undefined;
    const fetch = (async (_input: FetchInput, init?: RequestInit) => {
      seen = init?.signal ?? undefined;
      throw Object.assign(new Error("The operation was aborted"), { name: "TimeoutError" });
    }) as unknown as typeof globalThis.fetch;
    const provider = new SupabaseAuthProvider({
      authUrl: AUTH_URL,
      anonKey: ANON,
      serviceRoleKey: SERVICE_ROLE,
      fetch,
      timeoutMs: 25,
    });
    const error = await errorFrom(provider.signOut("eyJ-access"));
    expect(seen).toBeInstanceOf(AbortSignal);
    expect(error).toBeInstanceOf(ProviderUnavailable);
    expect((error as Error).message).toContain("TimeoutError");
  });
});

describe("SupabaseAuthProvider — what its errors are allowed to say", () => {
  /**
   * **The one property that protects the logs.** `routes/auth.ts` logs `err_message` from the
   * sign-in path, and `app.ts`'s redaction list exists because provider libraries put URLs, headers
   * and bodies into their errors. This adapter is written so that list has nothing to catch, and
   * this is the test that keeps it that way: the URL carries the project ref, the body can carry the
   * address, and the token is the credential itself.
   */
  it("names the operation, the status and the code — never a URL, a token, an address or a body", async () => {
    const secrets = [
      "project-ref",
      "supabase.co",
      "https://",
      "user@example.com",
      "123456",
      "eyJ-access",
      "opaque-refresh",
      ANON,
      SERVICE_ROLE,
      "Token has expired or is invalid",
    ];
    const failing = () =>
      json(403, { code: "otp_expired", message: "Token has expired or is invalid" });
    const { provider } = providerAnswering(failing);

    const errors = await Promise.all([
      errorFrom(provider.verifyEmailCode("user@example.com", "123456")),
      errorFrom(provider.refresh("opaque-refresh")),
      errorFrom(provider.signOut("eyJ-access")),
      errorFrom(provider.userFromAccessToken("eyJ-access")),
      errorFrom(provider.deleteUser("11111111-2222-3333-4444-555555555555")),
      errorFrom(provider.sendEmailCode("user@example.com")),
    ]);

    // All six raise. `sendEmailCode`'s is raised here and caught by the route, which answers the
    // uniform 200 whatever happened -- so its message reaches the log and nothing else.
    expect(errors.filter((error) => error instanceof Error)).toHaveLength(6);
    for (const error of errors) {
      for (const secret of secrets) {
        expect(error.message).not.toContain(secret);
      }
      expect(error.message).toContain("otp_expired");
      expect(error.message).toContain("403");
    }
  });

  it("keeps the transport failure's name and drops its message, which carries the URL", async () => {
    // Node puts the target URL in a fetch failure's message, and the URL contains the project ref.
    const { provider } = providerAnswering(() => {
      throw Object.assign(
        new Error("request to https://project-ref.supabase.co/auth/v1/otp failed"),
        { name: "FetchError" },
      );
    });
    const error = await errorFrom(provider.sendEmailCode("user@example.com"));
    expect(error.message).toContain("FetchError");
    expect(error.message).not.toContain("project-ref");
  });
});

describe("SupabaseAuthProvider — signOutAllForUser, which Supabase cannot do", () => {
  it("fails as unavailable so the revocation stays owed rather than being written off", async () => {
    // `revocation.ts` stamps `provider_session_revoked_at` on `ProviderRejected` — "the provider says
    // this is already done" — and leaves the row owed on anything else. Rejected here would record a
    // revocation that never happened, in the one table that exists to say whether it did. The
    // message names the ticket so an operator reading `npm run revocations` output has somewhere to
    // go.
    const { provider, calls } = providerAnswering(() => json(200, {}));
    const error = await errorFrom(
      provider.signOutAllForUser("11111111-2222-3333-4444-555555555555"),
    );

    expect(error).toBeInstanceOf(ProviderUnavailable);
    expect(error).not.toBeInstanceOf(ProviderRejected);
    expect(error.message).toContain("SONNY-307");
    // It does not reach for an endpoint that does not exist, and it names no user id.
    expect(calls).toHaveLength(0);
    expect(error.message).not.toContain("11111111");
  });
});

describe("errorCodeOf", () => {
  it("takes a numeric code as a status rather than as a code", () => {
    expect(errorCodeOf(json(400, { code: 400, msg: "m" }), { code: 400, msg: "m" })).toBeUndefined();
  });

  it("reads the OAuth-shaped body /token can answer", () => {
    const body = { error: "invalid_grant", error_description: "refresh token expired" };
    expect(errorCodeOf(json(400, body), body)).toBe("invalid_grant");
  });

  it("answers undefined for a body with nothing to read", () => {
    expect(errorCodeOf(json(500, {}), undefined)).toBeUndefined();
    expect(errorCodeOf(json(500, {}), "not json at all")).toBeUndefined();
  });
});
