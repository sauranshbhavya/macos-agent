import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { authWiringFrom, intendsAuth } from "../src/auth/deps.js";
import { ServiceRoleKeyNotConfigured, SupabaseAuthProvider } from "../src/auth/supabase.js";
import { ConfigError, loadConfig, type Config } from "../src/config.js";

/** `fetch`'s first parameter, named without `RequestInfo` — the lib here is ES2023, not DOM. */
type FetchInput = Parameters<typeof globalThis.fetch>[0];

/**
 * Which deployment shape an environment produces, and — the point of the ticket — that the shape
 * carrying credentials really does mount the auth routes (SONNY-307).
 *
 * **The defect this suite exists for could not be seen from any test that existed.** `server.ts`
 * called `buildApp(config)` with no `auth` argument, so every `/v1/auth/*` route answered `404
 * resource.not_found` in every environment — while `auth.db.test.ts` and `authgate.db.test.ts`
 * passed 126 tests against those routes, because each one builds its own app and passes its own
 * fake. Every test in the suite was about routes no process mounted. So the assertions below are
 * about the *composition*: what `loadConfig` produces, what that turns into, and whether a route
 * exists in the app that composition builds.
 *
 * No database is touched: `pg.Pool` connects lazily, so constructing the wiring opens no socket and
 * these tests run in the ordinary `npm test`.
 */

/**
 * Bound to names rather than written inline, exactly as `config.test.ts` does and for its stated
 * reason: a line spelling a known-secret variable followed by a long literal is the shape
 * `npm run check:secrets` refuses, correctly, wherever it appears — and this file spelled three of
 * them. **It scans TRACKED files**, so a clean run before these were committed said nothing about
 * them; the run that matters is the one after `git add`.
 */
const salt = "a-salt-that-is-not-a-real-one";
const secret = "a-signing-key-long-enough-to-clear-the-floor";
const serviceRole = "a-service-role-key";
const anon = "an-anon-key";
const issuer = "https://project-ref.supabase.co/auth/v1";
const database = "postgres://postgres:postgres@localhost:55433/postgres";

/**
 * A complete sign-in environment — **and it deliberately carries no `SUPABASE_SERVICE_ROLE_KEY`**,
 * so every shape test below runs the configuration a real deployment is now expected to have.
 */
const AUTH_ENV = {
  SONNY_ENV: "local",
  DATABASE_URL: database,
  RATE_LIMIT_SALT: salt,
  SUPABASE_JWT_SECRET: secret,
  SUPABASE_JWT_ISSUER: issuer,
  SUPABASE_ANON_KEY: anon,
} as NodeJS.ProcessEnv;

/**
 * Every name whose presence says "this deployment means to serve sign-in".
 *
 * **`SUPABASE_SERVICE_ROLE_KEY` was a fourth and is deliberately not one** (founder decision
 * 2026-08-27, option (c)) — `theServiceRoleKeyIsNotRequired` below is the suite's statement of that,
 * in both directions.
 */
const INTENT_NAMES = ["SUPABASE_JWT_SECRET", "SUPABASE_JWT_ISSUER", "SUPABASE_ANON_KEY"] as const;

function envWithout(...names: string[]): NodeJS.ProcessEnv {
  const env = { ...AUTH_ENV };
  for (const name of names) delete env[name];
  return env;
}

async function closing<T>(wiring: { close: () => Promise<void> } | undefined, value: T): Promise<T> {
  await wiring?.close();
  return value;
}

describe("the shape an environment produces", () => {
  it("mounts the auth routes when the whole set is present — the ticket's own acceptance", async () => {
    // Not "AuthDeps is not undefined": the thing that was broken is that a route did not exist, so
    // the assertion is that the route exists. `{}` is rejected by `startBody` before anything is
    // issued, so this reaches no database and sends nobody a code — the same body `deploy.sh`'s
    // mount probe uses, and for the same reason.
    const config = loadConfig(AUTH_ENV);
    const wiring = authWiringFrom(config);
    expect(wiring).toBeDefined();

    const app = buildApp(config, wiring!.deps);
    const response = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: {} });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("request.invalid");
    await app.close();
    await closing(wiring, undefined);
  });

  it("builds the Supabase adapter, not some other implementation of the seam", async () => {
    const wiring = authWiringFrom(loadConfig(AUTH_ENV));
    expect(wiring!.deps.provider).toBeInstanceOf(SupabaseAuthProvider);
    await closing(wiring, undefined);
  });

  it("stays health-only when no Supabase auth variable is set, and that is still a real server", async () => {
    // `app.ts` takes `auth` as optional precisely so this shape needs no provider, no salt and no
    // JWT secret. Nothing in this ticket narrows it.
    const config = loadConfig({ SONNY_ENV: "local" });
    expect(intendsAuth(config)).toBe(false);
    expect(authWiringFrom(config)).toBeUndefined();

    const app = buildApp(config, authWiringFrom(config)?.deps);
    expect((await app.inject({ method: "GET", url: "/v1/health" })).statusCode).toBe(200);
    const auth = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: {} });
    expect(auth.statusCode).toBe(404);
    expect(auth.json().error.code).toBe("resource.not_found");
    await app.close();
  });

  it("stays health-only for a DATABASE_URL with no auth variables, so a migration host still starts", async () => {
    // DATABASE_URL is required BY auth and is not a signal OF it. Treating it as intent would make a
    // gateway that holds one only to run migrations refuse to start.
    const config = loadConfig({ SONNY_ENV: "local", DATABASE_URL: AUTH_ENV["DATABASE_URL"] });
    expect(authWiringFrom(config)).toBeUndefined();
  });

  it("stays health-only for RATE_LIMIT_SALT alone, for the same reason", () => {
    const config = loadConfig({ SONNY_ENV: "local", RATE_LIMIT_SALT: AUTH_ENV["RATE_LIMIT_SALT"] });
    expect(authWiringFrom(config)).toBeUndefined();
  });

  it("stays health-only for SUPABASE_JWT_AUDIENCE alone, which has a default and says nothing", () => {
    // Its presence carries no intent — it is defaulted — so an environment setting only it must not
    // refuse to start over a variable that changes nothing.
    const config = loadConfig({ SONNY_ENV: "local", SUPABASE_JWT_AUDIENCE: "authenticated" });
    expect(intendsAuth(config)).toBe(false);
    expect(authWiringFrom(config)).toBeUndefined();
  });
});

describe("a half-configured sign-in refuses at startup", () => {
  it.each(INTENT_NAMES)("refuses when only %s is set", (name) => {
    // One Supabase name is intent. Serving health-only here would answer 404 to every sign-in, which
    // is indistinguishable from the bug this ticket fixes and was measured reading exactly that way.
    const config = loadConfig({ SONNY_ENV: "local", [name]: AUTH_ENV[name] });
    expect(intendsAuth(config)).toBe(true);
    expect(() => authWiringFrom(config)).toThrow(ConfigError);
  });

  it.each(INTENT_NAMES)("refuses when everything but %s is set", (name) => {
    expect(() => authWiringFrom(loadConfig(envWithout(name)))).toThrow(ConfigError);
  });

  it("refuses when DATABASE_URL is the only thing missing", () => {
    expect(() => authWiringFrom(loadConfig(envWithout("DATABASE_URL")))).toThrow(ConfigError);
  });

  it("refuses when RATE_LIMIT_SALT is the only thing missing", () => {
    // Without it `bucketKey` would hash email addresses unsalted, which is one rainbow-table lookup
    // from the address. `requireRateLimitSalt` says so; this proves the startup path reaches it.
    expect(() => authWiringFrom(loadConfig(envWithout("RATE_LIMIT_SALT")))).toThrow(ConfigError);
  });

  it("names every missing variable at once, so a fix is one restart rather than four", () => {
    const error = (() => {
      try {
        authWiringFrom(loadConfig({ SONNY_ENV: "local", SUPABASE_ANON_KEY: anon }));
        return undefined;
      } catch (thrown) {
        return thrown as Error;
      }
    })();
    expect(error).toBeInstanceOf(ConfigError);
    for (const name of [
      "SUPABASE_JWT_SECRET",
      "SUPABASE_JWT_ISSUER",
      "DATABASE_URL",
      "RATE_LIMIT_SALT",
    ]) {
      expect(error!.message).toContain(name);
    }
    // The count is asserted, not just the names: a message that listed a fifth would still contain
    // all four of the above.
    expect(error!.message).toContain("4 variables are missing");
    // The one that IS set is not listed as missing.
    expect(error!.message).not.toContain("SUPABASE_ANON_KEY,");
    // **And the one that is no longer required is not listed either** (founder decision 2026-08-27,
    // option (c)). This is the assertion that fails if it is put back into AUTH_INTENT or
    // AUTH_ALSO_REQUIRED, which is the whole point of naming it here.
    expect(error!.message).not.toContain("SUPABASE_SERVICE_ROLE_KEY");
  });

  it("reads correctly in both the singular and the plural, number and pronoun agreeing", () => {
    // **The singular form said "one variable is missing: RATE_LIMIT_SALT. Set them"** (PR #137
    // review, residual 1). This message is the whole of what an operator gets at `exit 78`, and a
    // copy fix with no test is a copy fix that comes back. Both forms are asserted, so a future
    // edit to either has to keep both grammatical.
    const messageFor = (env: NodeJS.ProcessEnv): string => {
      try {
        authWiringFrom(loadConfig(env));
        throw new Error("expected a refusal");
      } catch (thrown) {
        return (thrown as Error).message;
      }
    };

    // Exactly one missing: everything set except the salt.
    const singular = messageFor(envWithout("RATE_LIMIT_SALT"));
    expect(singular).toContain("one variable is missing: RATE_LIMIT_SALT. Set it,");
    expect(singular).not.toContain("Set them");

    // More than one missing.
    const plural = messageFor(envWithout("RATE_LIMIT_SALT", "DATABASE_URL"));
    expect(plural).toContain("2 variables are missing: DATABASE_URL, RATE_LIMIT_SALT. Set them,");
    expect(plural).not.toContain("Set it,");
  });

  it("never echoes a value into the message it prints at startup", () => {
    // This message goes to stderr before any logger exists and lands in whatever collects the
    // container's output. `config.ts` states the property for its own errors; this is the same
    // property for the message this ticket added.
    try {
      authWiringFrom(loadConfig({ SONNY_ENV: "local", SUPABASE_ANON_KEY: anon }));
      expect.unreachable("should have thrown");
    } catch (error) {
      expect((error as Error).message).not.toContain(anon);
    }
  });

  it("still applies the existing validations rather than only checking for presence", () => {
    // A short secret and a non-URL issuer are `requireSupabaseJwtPolicy`'s refusals, and a presence
    // sweep that ran instead of them would have quietly widened what starts.
    expect(() =>
      authWiringFrom(loadConfig({ ...AUTH_ENV, SUPABASE_JWT_SECRET: "short" })),
    ).toThrow(ConfigError);
    expect(() =>
      authWiringFrom(loadConfig({ ...AUTH_ENV, SUPABASE_JWT_ISSUER: "not-a-url" })),
    ).toThrow(ConfigError);
  });
});

describe("what the wiring hands the adapter", () => {
  it("points the adapter it built at the issuer, so calling and verifying cannot name two projects", async () => {
    // **This test drives `wiring.deps.provider` — the provider `authWiringFrom` actually built — and
    // the first version did not** (PR #137 review, F1). It constructed a *second*
    // `SupabaseAuthProvider` with the URL hardcoded and asserted about that, so `deps.ts` could have
    // passed any string at all and this suite would still have been green. The mutant that proves
    // the difference is one line: replace `authUrl: policy.issuer` in `deps.ts` with a literal and
    // the old test passes while this one fails.
    //
    // Reaching the real provider means stubbing the global `fetch` *before* `authWiringFrom` runs,
    // because the adapter captures `config.fetch ?? globalThis.fetch` at construction. That is the
    // only seam here, and it is deliberately not a test-only parameter on `authWiringFrom`: a
    // production function growing an argument no production caller passes is how the thing under
    // test stops being the thing that ships.
    //
    // One variable for both is what makes it matter. Configured apart, the gateway mints tokens at
    // project A and verifies them against project B — which presents as every request answering 401
    // with nothing in the logs to say why.
    const calls: string[] = [];
    const real = globalThis.fetch;
    globalThis.fetch = (async (input: FetchInput) => {
      calls.push(String(input));
      return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
    }) as unknown as typeof globalThis.fetch;
    try {
      const wiring = authWiringFrom({
        ...loadConfig(AUTH_ENV),
        supabaseJwtIssuer: "https://other-ref.supabase.co/auth/v1",
      })!;
      await wiring.deps.provider.sendEmailCode("a@example.com");
      expect(calls).toEqual(["https://other-ref.supabase.co/auth/v1/otp"]);
      await wiring.close();
    } finally {
      globalThis.fetch = real;
    }
  });

  it("hands the adapter the anon key, and no bearer, on the call that starts a sign-in", async () => {
    // The other half of what `deps.ts` passes. Without it the wiring could hand the adapter an empty
    // string for `anonKey` and only a live Supabase project would notice.
    const seen: Record<string, string>[] = [];
    const real = globalThis.fetch;
    globalThis.fetch = (async (_input: FetchInput, init?: RequestInit) => {
      seen.push((init?.headers ?? {}) as Record<string, string>);
      return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
    }) as unknown as typeof globalThis.fetch;
    try {
      const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
      await wiring.deps.provider.sendEmailCode("a@example.com");
      expect(seen[0]!["apikey"]).toBe(anon);
      expect(seen[0]!["authorization"]).toBeUndefined();
      await wiring.close();
    } finally {
      globalThis.fetch = real;
    }
  });

  it("supplies a withConnection and leaves `now` to the route's own default", async () => {
    const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
    expect(typeof wiring.deps.withConnection).toBe("function");
    expect(wiring.deps.now).toBeUndefined();
    await wiring.close();
  });

  it("theServiceRoleKeyIsNotRequired — a full sign-in environment without one still mounts", async () => {
    // **Founder decision of 2026-08-27, option (c).** It is the project's most dangerous credential
    // and exactly one method uses it — `deleteUser` — which nothing calls today, so requiring it
    // made every sign-in deployment hold a key it could not spend. AUTH_ENV deliberately omits it,
    // so every other test in this file exercises this path too; this one says so by name.
    const wiring = authWiringFrom(loadConfig(AUTH_ENV));
    expect(wiring).toBeDefined();
    await wiring!.close();
  });

  it("theServiceRoleKeyIsNotATrigger — setting only it leaves a health-only gateway", () => {
    // The other direction, and the one a presence check gets wrong. It was a fourth AUTH_INTENT
    // name; if it still were, this environment would refuse to start instead of serving health.
    const config = loadConfig({ SONNY_ENV: "local", SUPABASE_SERVICE_ROLE_KEY: serviceRole });
    expect(intendsAuth(config)).toBe(false);
    expect(authWiringFrom(config)).toBeUndefined();
  });

  it("still forwards the service-role key to the adapter when one is set", async () => {
    // Not required is not the same as not used. A deployment that sets it must still reach the admin
    // surface, or `deleteUser` would be dead code the moment SONNY-196 lands a caller.
    const seen: Record<string, string>[] = [];
    const real = globalThis.fetch;
    globalThis.fetch = (async (_input: FetchInput, init?: RequestInit) => {
      seen.push((init?.headers ?? {}) as Record<string, string>);
      return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
    }) as unknown as typeof globalThis.fetch;
    try {
      const wiring = authWiringFrom(
        loadConfig({ ...AUTH_ENV, SUPABASE_SERVICE_ROLE_KEY: serviceRole }),
      )!;
      await wiring.deps.provider.deleteUser("11111111-2222-3333-4444-555555555555");
      expect(seen[0]!["apikey"]).toBe(serviceRole);
      await wiring.close();
    } finally {
      globalThis.fetch = real;
    }
  });

  it("fails deleteUser at its own call site when no service-role key was configured", async () => {
    // The cost of not requiring it, paid where it is cheapest to diagnose. Not `ProviderUnavailable`
    // — that would send an operator hunting a Supabase outage that is not happening — and not
    // `ProviderRejected`, which `revocation.ts` reads as "already done". No request is sent.
    let called = false;
    const real = globalThis.fetch;
    globalThis.fetch = (async () => {
      called = true;
      return new Response("{}", { status: 200 });
    }) as unknown as typeof globalThis.fetch;
    try {
      const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
      const error = await wiring.deps.provider
        .deleteUser("11111111-2222-3333-4444-555555555555")
        .then(() => undefined)
        .catch((thrown: unknown) => thrown as Error);
      expect(error).toBeInstanceOf(ServiceRoleKeyNotConfigured);
      expect(error!.message).toContain("SUPABASE_SERVICE_ROLE_KEY");
      expect(called).toBe(false);
      await wiring.close();
    } finally {
      globalThis.fetch = real;
    }
  });

  it("closes the pool idempotently, so a second signal cannot fail the shutdown", async () => {
    const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
    await wiring.close();
    await expect(wiring.close()).resolves.toBeUndefined();
  });
});
