import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { authWiringFrom, intendsAuth } from "../src/auth/deps.js";
import { SupabaseAuthProvider } from "../src/auth/supabase.js";
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

const AUTH_ENV = {
  SONNY_ENV: "local",
  DATABASE_URL: "postgres://postgres:postgres@localhost:55433/postgres",
  RATE_LIMIT_SALT: "a-salt-that-is-not-a-real-one",
  SUPABASE_JWT_SECRET: "a-signing-key-long-enough-to-clear-the-floor",
  SUPABASE_JWT_ISSUER: "https://project-ref.supabase.co/auth/v1",
  SUPABASE_ANON_KEY: "an-anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "a-service-role-key",
} as NodeJS.ProcessEnv;

/** Every name whose presence says "this deployment means to serve sign-in". */
const INTENT_NAMES = [
  "SUPABASE_JWT_SECRET",
  "SUPABASE_JWT_ISSUER",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
] as const;

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
        authWiringFrom(loadConfig({ SONNY_ENV: "local", SUPABASE_ANON_KEY: "an-anon-key" }));
        return undefined;
      } catch (thrown) {
        return thrown as Error;
      }
    })();
    expect(error).toBeInstanceOf(ConfigError);
    for (const name of ["SUPABASE_JWT_SECRET", "SUPABASE_JWT_ISSUER", "SUPABASE_SERVICE_ROLE_KEY"]) {
      expect(error!.message).toContain(name);
    }
    expect(error!.message).toContain("DATABASE_URL");
    expect(error!.message).toContain("RATE_LIMIT_SALT");
    // The one that IS set is not listed as missing.
    expect(error!.message).not.toContain("SUPABASE_ANON_KEY,");
  });

  it("never echoes a value into the message it prints at startup", () => {
    // This message goes to stderr before any logger exists and lands in whatever collects the
    // container's output. `config.ts` states the property for its own errors; this is the same
    // property for the message this ticket added.
    try {
      authWiringFrom(loadConfig({ SONNY_ENV: "local", SUPABASE_ANON_KEY: "an-anon-key" }));
      expect.unreachable("should have thrown");
    } catch (error) {
      expect((error as Error).message).not.toContain("an-anon-key");
    }
  });

  it("still applies the existing validations rather than only checking for presence", () => {
    // A short secret and a non-URL issuer are `requireSupabaseJwtPolicy`'s refusals, and a presence
    // sweep that ran instead of them would have quietly widened what starts.
    expect(() =>
      authWiringFrom(loadConfig({ ...AUTH_ENV, SUPABASE_JWT_SECRET: "too-short" })),
    ).toThrow(ConfigError);
    expect(() =>
      authWiringFrom(loadConfig({ ...AUTH_ENV, SUPABASE_JWT_ISSUER: "project-ref" })),
    ).toThrow(ConfigError);
  });
});

describe("what the wiring hands the adapter", () => {
  it("points the adapter at the issuer, so calling and verifying cannot name two projects", async () => {
    // One variable for both. Configured apart, the gateway would mint tokens at project A and verify
    // them against project B — which presents as every request answering 401 with nothing in the
    // logs to say why.
    const calls: string[] = [];
    const config: Config = {
      ...loadConfig(AUTH_ENV),
      supabaseJwtIssuer: "https://other-ref.supabase.co/auth/v1",
    };
    const wiring = authWiringFrom(config)!;
    // Reach the URL the only way the seam exposes: make a call and see where it went.
    const provider = new SupabaseAuthProvider({
      authUrl: "https://other-ref.supabase.co/auth/v1",
      anonKey: "k",
      serviceRoleKey: "s",
      fetch: (async (input: FetchInput) => {
        calls.push(String(input));
        return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
      }) as unknown as typeof globalThis.fetch,
    });
    await provider.sendEmailCode("a@example.com");
    expect(calls[0]).toContain("other-ref.supabase.co/auth/v1/otp");
    expect(wiring.deps.provider).toBeInstanceOf(SupabaseAuthProvider);
    await wiring.close();
  });

  it("supplies a withConnection and leaves `now` to the route's own default", async () => {
    const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
    expect(typeof wiring.deps.withConnection).toBe("function");
    expect(wiring.deps.now).toBeUndefined();
    await wiring.close();
  });

  it("closes the pool idempotently, so a second signal cannot fail the shutdown", async () => {
    const wiring = authWiringFrom(loadConfig(AUTH_ENV))!;
    await wiring.close();
    await expect(wiring.close()).resolves.toBeUndefined();
  });
});
