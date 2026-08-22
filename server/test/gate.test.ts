import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { PUBLIC_ROUTES, callerOf, isPublicRoute, registerAuthGate } from "../src/auth/gate.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import { registerErrorHandlers } from "../src/errors.js";
import { registerAuth } from "../src/routes/auth.js";
import { registerHealth } from "../src/routes/health.js";
import { TEST_JWT_CONFIG, TEST_JWT_POLICY, accessTokenFor, tokenWithClaims } from "./support/tokens.js";

/**
 * The gate as a routing decision, with no database in reach (SONNY-203).
 *
 * Everything here is about *which* requests are challenged and what they are told, so the connection
 * these tests supply throws on use. That is an assertion in itself: a refusal that touched the
 * database would fail loudly, and every refusal below is one an unauthenticated caller can trigger
 * at will — a forged token must cost an HMAC, not a connection.
 */

const USER = "11111111-1111-1111-1111-111111111111";

const config: Config = {
  environment: "local", port: 0, host: "127.0.0.1", buildId: "t",
  databaseUrl: undefined, logLevel: "fatal", trustProxy: false,
  rateLimitSalt: "test-salt", ...TEST_JWT_CONFIG, credentials: [],
};

class UnusedProvider implements AuthProvider {
  async sendEmailCode() { return { providerRequestId: undefined }; }
  async verifyEmailCode(): Promise<VerifiedSession> { throw new Error("not used here"); }
  async refresh(): Promise<VerifiedSession> { throw new Error("not used here"); }
  async signOut() {}
  async userFromAccessToken(): Promise<string> { throw new Error("not used here"); }
  async signOutAllForUser() {}
  async deleteUser() {}
}

/** A connection that cannot be used. Reaching it is the failure these tests are watching for. */
const noDatabase: WithConnection = async () => {
  throw new Error("the gate reached the database on a request it should have refused first");
};

const build = () => buildApp(config, { provider: new UnusedProvider(), withConnection: noDatabase });

/** Every route the server registers, as the gate sees them: one entry per method. */
function registeredRoutes(): { method: string; url: string }[] {
  const collected: { method: string; url: string }[] = [];
  const app = Fastify({ logger: false });
  app.addHook("onRoute", (route) => {
    for (const method of Array.isArray(route.method) ? route.method : [route.method]) {
      collected.push({ method, url: route.url });
    }
  });
  registerHealth(app, config);
  registerAuth(app, config, { provider: new UnusedProvider(), withConnection: noDatabase });
  return collected;
}

describe("which routes the gate challenges", () => {
  it("PUBLIC_ROUTES is exactly the contract §4.1 set with no Authorization header", () => {
    // Written out as literals rather than derived from the source, so changing the production list
    // fails here instead of agreeing with itself. §2.2 names §4.1's Auth column the single source of
    // truth for this question, and this is that column's `none` rows plus the refresh route, whose
    // body carries its own credential.
    expect([...PUBLIC_ROUTES].sort()).toEqual([
      "GET /v1/health",
      "GET /v1/meta",
      "POST /v1/auth/email/start",
      "POST /v1/auth/email/verify",
      "POST /v1/auth/oauth/apple",
      "POST /v1/auth/oauth/google",
      "POST /v1/auth/refresh",
    ]);
  });

  it("challenges EVERY registered route that is not on that list — the population, not a sample", () => {
    // The scan that makes deny-by-default checkable. A route added by a later ticket appears here
    // automatically: it is either public, which is a decision someone had to write down, or it
    // answers 401 to a caller with no token.
    const routes = registeredRoutes();
    // Non-vacuous: if the collector ever stops seeing routes, this fails rather than passing empty.
    expect(routes.length).toBeGreaterThanOrEqual(6);
    expect(routes.some((route) => route.url === "/v1/account" && route.method === "DELETE")).toBe(true);

    const protectedRoutes = routes.filter((route) => !isPublicRoute(route.method, route.url));
    expect(protectedRoutes.map((route) => `${route.method} ${route.url}`).sort()).toEqual([
      "DELETE /v1/account",
      "POST /v1/auth/signout",
    ]);
  });

  it("refuses every protected route with 401 auth.unauthenticated when no token is presented", async () => {
    const app = build();
    for (const route of registeredRoutes().filter((r) => !isPublicRoute(r.method, r.url))) {
      const response = await app.inject({ method: route.method as "GET", url: route.url });
      expect(`${route.method} ${route.url} -> ${response.statusCode}`)
        .toBe(`${route.method} ${route.url} -> 401`);
      expect(response.json().error.code).toBe("auth.unauthenticated");
      expect(response.json().error.retryable).toBe(false);
    }
    await app.close();
  });

  it("leaves the public routes alone, with and without a bearer token", async () => {
    const app = build();
    const bare = await app.inject({ method: "GET", url: "/v1/health" });
    const bearing = await app.inject({
      method: "GET", url: "/v1/health", headers: { authorization: "Bearer nonsense" },
    });
    expect(bare.statusCode).toBe(200);
    expect(bearing.statusCode).toBe(200);
    expect(bearing.json()).toEqual(bare.json());
    await app.close();
  });

  it("judges HEAD as the GET it mirrors, so a HEAD liveness probe is not challenged", async () => {
    // Fastify generates a HEAD route for every GET one, and its method is not `GET` — so without
    // the normalisation `HEAD /v1/health` would be a protected route by omission.
    expect(isPublicRoute("HEAD", "/v1/health")).toBe(true);
    const app = build();
    const response = await app.inject({ method: "HEAD", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    await app.close();
  });

  it("leaves an unknown path as 404, rather than turning it into 401", async () => {
    // The gate runs before routing has anything to say, so it has to sit out the not-found case.
    // A 404 that became a 401 would be neither true nor useful.
    const app = build();
    const response = await app.inject({ method: "GET", url: "/v1/nope" });
    expect(response.statusCode).toBe(404);
    expect(response.json().error.code).toBe("resource.not_found");
    await app.close();
  });
});

describe("what a refused caller is told", () => {
  const send = async (authorization?: string) => {
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/auth/signout",
      ...(authorization === undefined ? {} : { headers: { authorization } }),
    });
    await app.close();
    return response;
  };

  it("answers 401 auth.unauthenticated for a missing, non-bearer or empty Authorization header", async () => {
    for (const header of [undefined, "", "Basic abc", "Bearer", "Bearer ", "Bearer    "]) {
      const response = await send(header);
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.unauthenticated");
    }
  });

  it("accepts the scheme case-insensitively, as RFC 7235 requires", async () => {
    // Refused on attribution rather than on the header: `bearer` reached the verifier, which is the
    // point. The throwing connection is what proves it got that far.
    const response = await send(`bearer ${accessTokenFor(USER)}`);
    expect(response.statusCode).toBe(500);
    expect(response.json().error.code).toBe("server.error");
  });

  it("answers auth.token_expired ONLY for expiry, and marks it retryable", async () => {
    // §3.3: this is the one 401 a client answers by refreshing once and retrying once. §9.3 lists
    // it as the only retryable auth code. Every other refusal must not put a client into that loop.
    const expired = await send(`Bearer ${accessTokenFor(USER, {
      now: new Date(Date.now() - 7200 * 1000),
    })}`);
    expect(expired.statusCode).toBe(401);
    expect(expired.json().error.code).toBe("auth.token_expired");
    expect(expired.json().error.retryable).toBe(true);
  });

  it("answers auth.unauthenticated for every forgery, with one message that names no check", async () => {
    // A caller learns that the token was refused and whether refreshing would help. It does not
    // learn which check refused it: "wrong audience" for one attempt and "bad signature" for the
    // next is a tuning signal for the third.
    const forgeries = [
      accessTokenFor(USER).replace(/.$/, "A"),
      tokenWithClaims(USER, {}, { secret: "another-secret-of-entirely-adequate-length" }),
      tokenWithClaims(USER, {}, { header: { alg: "none", typ: "JWT" } }),
      tokenWithClaims(USER, { iss: "https://elsewhere.supabase.co/auth/v1" }),
      tokenWithClaims(USER, { aud: "anon" }),
      tokenWithClaims(USER, { sub: "not-a-uuid" }),
      tokenWithClaims(USER, { nbf: Math.floor(Date.now() / 1000) + 600 }),
      "not.a.token",
    ];
    const messages = new Set<string>();
    for (const token of forgeries) {
      const response = await send(`Bearer ${token}`);
      expect(`${token.slice(0, 12)} -> ${response.statusCode}`).toBe(`${token.slice(0, 12)} -> 401`);
      expect(response.json().error.code).toBe("auth.unauthenticated");
      messages.add(response.json().error.message);
    }
    expect([...messages]).toEqual(["Access token is not valid."]);
  });

  it("carries the contract's envelope on a refusal, request id included", async () => {
    const response = await send();
    expect(Object.keys(response.json().error).sort())
      .toEqual(["code", "message", "request_id", "retry_after_seconds", "retryable"]);
    expect(response.json().error.request_id).toBe(response.headers["sonny-request-id"]);
    expect(response.headers["sonny-api-version"]).toBe("1.0");
  });
});

describe("the gate when nothing is configured to authenticate with", () => {
  it("refuses a protected route rather than serving it", async () => {
    // The shape a deployment reaches by mounting a route without supplying auth. There is no
    // configuration of this server in which a non-public route is open.
    const app = Fastify({ logger: false });
    registerErrorHandlers(app);
    registerAuthGate(app);
    app.post("/v1/plan", async () => ({ ok: true }));
    const response = await app.inject({
      method: "POST", url: "/v1/plan", headers: { authorization: `Bearer ${accessTokenFor(USER)}` },
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.unauthenticated");
    await app.close();
  });

  it("still serves a public route, since none of them needs a caller", async () => {
    const app = Fastify({ logger: false });
    registerErrorHandlers(app);
    registerAuthGate(app);
    registerHealth(app, config);
    expect((await app.inject({ method: "GET", url: "/v1/health" })).statusCode).toBe(200);
    await app.close();
  });
});

describe("callerOf", () => {
  it("throws rather than acting for nobody when a route was wrongly listed as public", async () => {
    // The failure mode this guards: a route added to PUBLIC_ROUTES by mistake, whose handler then
    // reads an account id that was never derived from a token. A 500 is the loud answer; acting on
    // `undefined` is the quiet one.
    const app = Fastify({ logger: false });
    registerErrorHandlers(app);
    registerAuthGate(app, { policy: TEST_JWT_POLICY, withConnection: noDatabase });
    app.get("/v1/health", async (request) => ({ id: callerOf(request).accountId }));
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(500);
    expect(response.json().error.code).toBe("server.error");
    await app.close();
  });
});
