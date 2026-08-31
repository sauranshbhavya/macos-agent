import Fastify, { type FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { PUBLIC_ROUTES, callerOf, isPublicRoute, registerAuthGate } from "../src/auth/gate.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import { registerErrorHandlers } from "../src/errors.js";
import { registerHealth } from "../src/routes/health.js";
import { TEST_JWT_POLICY, accessTokenFor, tokenWithBrokenSignature, tokenWithClaims } from "./support/tokens.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { expectPopulationIsReal, registeredRoutes } from "./support/routes.js";

/**
 * The gate as a routing decision, with no database in reach (SONNY-203).
 *
 * Everything here is about *which* requests are challenged and what they are told, so the connection
 * these tests supply throws on use. That is an assertion in itself: a refusal that touched the
 * database would fail loudly, and every refusal below is one an unauthenticated caller can trigger
 * at will — a forged token must cost an HMAC, not a connection.
 */

const USER = "11111111-1111-1111-1111-111111111111";

const config: Config = testConfig();

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

// SONNY-135's check runs on every authenticated route and is Postgres-backed, so this suite — whose
// whole premise is that no refusal may touch the database — injects the fake store. A request that
// gets past the gate reaches it; one that does not must never reach either.
const build = () =>
  buildApp(
    config,
    { provider: new UnusedProvider(), withConnection: noDatabase },
    { entitlementStore: fakeEntitlementStore() },
  );

/**
 * The route population and its "did the parse really parse" guard now live in
 * `test/support/routes.ts`, because `metering.test.ts` asks the router the same question about a
 * different classification and a copied parser is two things to keep in step (SONNY-133). The
 * reasoning that made this a scan rather than a list — PR #104's F5, and the V1 correction about
 * which plugin shapes the gate covers — moved with it, unchanged.
 */

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
      // SONNY-211, and the one entry here that is not public in the sense the seven above are: the
      // payment provider authenticates with an HMAC signature over the raw body instead of a Bearer
      // token, so the gate cannot challenge it and `routes/billing.ts` refuses it. It is in §4.1's
      // table with the mechanism written in the `Auth` cell, which is what keeps this assertion's
      // own claim — that this list is exactly that column's no-Bearer-token set — true.
      "POST /v1/billing/webhook",
    ]);
  });

  it("challenges EVERY route the app serves that is not on that list — the population, not a sample", async () => {
    // The scan that makes deny-by-default checkable, and it is read off the built app rather than
    // off a list of registrars — so a route added by a later ticket appears here whoever registered
    // it, and is either public (a decision someone had to write down) or challenged.
    const app = build();
    const routes = await registeredRoutes(app);
    expectPopulationIsReal(routes);

    const protectedRoutes = routes.filter((route) => !isPublicRoute(route.method, route.url));
    expect(protectedRoutes.map((route) => `${route.method} ${route.url}`).sort()).toEqual([
      "DELETE /v1/account",
      // SONNY-134's, and it arrives here the same way as every other: `routes/tasks.ts` mentions
      // auth nowhere. It is the one route a user can call to destroy their own retained content,
      // so being challenged is not a formality — an unauthenticated caller could otherwise delete
      // any task whose client-minted id they could guess.
      "DELETE /v1/tasks/:task_id",
      // SONNY-135's, arriving the same way as everything below it — and it is also the route that
      // found the scan's own defect: its path sits *under* `DELETE /v1/account`, so Fastify prints
      // it as a child node and the parser read it as `GET /entitlements`, a path nothing serves.
      // `test/support/routes.ts` carries what that would have cost.
      "GET /v1/account/entitlements",
      "HEAD /v1/account/entitlements",
      "POST /v1/auth/signout",
      // SONNY-130's four. They appear here by *not* being listed in `PUBLIC_ROUTES`, which is the
      // whole of what deny-by-default means — no line in the four routes' own file mentions auth.
      "POST /v1/plan",
      "POST /v1/research/synthesize",
      // SONNY-131's, and it arrives here the same way — by not being listed in `PUBLIC_ROUTES`.
      // `routes/screen.ts` mentions auth nowhere either.
      "POST /v1/screen/analyze",
      "POST /v1/search",
      "POST /v1/transcriptions",
    ]);
    await app.close();
  });

  it("challenges every route a BILLING-configured app serves too, which this scan could not see", async () => {
    // **The scan builds from `testConfig()`, which names no payment provider, so `app.ts` mounted
    // neither billing route and this population contained neither** (PR #178 review, F6). Nothing was
    // unprotected — the checkout route has its own 401 test and the webhook has the signature tests —
    // but the scan is the *mechanism* that catches a route added without a thought about auth, and it
    // was blind to anything mounted behind a config flag. A second route added inside that billing
    // scope later would have been invisible to it. This is the same scan over the other shape of the
    // app, so the mechanism covers both.
    const app = buildApp(
      testConfig({
        billingProvider: "polar",
        billingWebhookSecret: "a-webhook-secret-that-is-not-a-real-one",
        billingCheckoutUrl: "https://buy.example.test/checkout/abc",
        billingPlans: "prod_x=paid:screen_control",
        billingGraceDays: 14,
      }),
      { provider: new UnusedProvider(), withConnection: noDatabase },
      { entitlementStore: fakeEntitlementStore() },
    );
    const routes = await registeredRoutes(app);
    expectPopulationIsReal(routes);

    // Both routes are in the population now, which is the half that was missing.
    const billing = routes
      .map((route) => `${route.method} ${route.url}`)
      .filter((route) => route.includes("/v1/billing/"))
      .sort();
    expect(billing).toEqual(["POST /v1/billing/checkout", "POST /v1/billing/webhook"]);

    // And every route this shape of the app serves is either public by a written decision or
    // challenged — the same property the scan above asserts, over the larger population.
    const unclassified = routes.filter(
      (route) => !isPublicRoute(route.method, route.url) && route.url.startsWith("/v1/billing/"),
    );
    expect(unclassified.map((route) => `${route.method} ${route.url}`)).toEqual([
      // The checkout route is authenticated like any other: absent from `PUBLIC_ROUTES`, challenged
      // by the gate, with its own 401 test in `billing.test.ts`. The webhook is NOT here, because it
      // is on the list — authenticated by its signature instead, which is the one entry in that list
      // that is not public in the sense the six beside it are.
      "POST /v1/billing/checkout",
    ]);
    await app.close();
  });

  it("sees a route a third registrar adds, wherever in the plugin tree it added it", async () => {
    // What F5 was about, asserted rather than promised: had this scan still enumerated
    // `registerHealth` and `registerAuth`, it would report the same seven routes it always did while
    // an eighth went unclassified.
    //
    // **The name and comment here said the extra route was in a "sibling plugin" that the gate would
    // MISS, and that was false** (PR #104's verification pass, V1). `app.register(...)` on a
    // `buildApp` instance creates a *descendant* of the gate's root context — F3's own 401 row — so
    // this route is covered, and measurement agrees: it answers 401, as do routes added directly,
    // nested two plugins deep, in a second plugin beside a first, and behind a prefix. The assertion
    // below was always right; only the story around it was wrong.
    //
    // **The stand-in route was `POST /v1/plan` until SONNY-130 built it**, at which point this test
    // stopped proving anything and started failing with `Method 'POST' already declared`. A route
    // that a later ticket might really add is the wrong stand-in for a hypothetical one; the path
    // below is not in the contract's §4.1 table and is not going to be.
    const app = build();
    app.register(async (scope) => {
      scope.post("/v1/not-a-contract-route", async () => ({ served: true }));
    });
    const routes = await registeredRoutes(app);
    expect(routes.map((route) => `${route.method} ${route.url}`))
      .toContain("POST /v1/not-a-contract-route");
    // And it is classified as protected, so the behavioural test above is what would fail for it.
    expect(isPublicRoute("POST", "/v1/not-a-contract-route")).toBe(false);
    // Covered, not missed — the claim V1 corrected, asserted rather than described.
    expect((await app.inject({ method: "POST", url: "/v1/not-a-contract-route" })).statusCode)
      .toBe(401);
    await app.close();
  });

  it("refuses every protected route with 401 auth.unauthenticated when no token is presented", async () => {
    const app = build();
    const routes = await registeredRoutes(app);
    expectPopulationIsReal(routes);
    const challenged = routes.filter((r) => !isPublicRoute(r.method, r.url));
    expect(challenged.length).toBeGreaterThan(0);
    for (const route of challenged) {
      const response = await app.inject({ method: route.method as "GET", url: route.url });
      expect(`${route.method} ${route.url} -> ${response.statusCode}`)
        .toBe(`${route.method} ${route.url} -> 401`);
      // **A `HEAD` response carries no body, by HTTP's own definition**, so there is no envelope to
      // read and `response.json()` throws on the empty payload. The status is the whole of what
      // `HEAD` can say, and it is asserted above for every route including these. This branch
      // arrived with SONNY-135: `GET /v1/account/entitlements` is the first *protected* route with a
      // `GET`, so Fastify's generated `HEAD` for it is the first protected `HEAD` this loop has ever
      // seen — `HEAD /v1/health` is public and never reaches here.
      if (route.method === "HEAD") continue;
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

  it("refuses a VALID token presented under the wrong scheme", async () => {
    // **The scheme check had no test that could fail** (PR #104's adversarial review, F6). The test
    // above sends `Basic abc` — and `abc` is also a malformed token, so deleting the scheme check
    // entirely produced the same 401 and the suite stayed at 244 passed. The token here is one this
    // gateway would accept under `Bearer`, so the only thing that can refuse it is the scheme.
    const response = await send(`Basic ${accessTokenFor(USER)}`);
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.unauthenticated");
    // Not a 500: reaching the throwing connection would mean the token had been accepted.
    expect(response.json().error.message).toBe("A bearer token is required.");
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
    //
    // **The first entry used to be `accessTokenFor(USER).replace(/.$/, "A")`, and that made this
    // test a 1-in-16 coin toss** (PR #104's adversarial review, F2). The final character of a
    // 43-character base64url HMAC comes from a sixteen-value alphabet, `accessTokenFor` mints at
    // `new Date()`, and about 6.276% of the time it already *is* `"A"` — on those runs the
    // "forgery" was the honest token, it verified, and the assertion saw a 500 where it wanted a
    // 401. `tokenWithBrokenSignature` derives the replacement from the character it replaces, so it
    // can never be a no-op. This matters beyond this file: this test co-kills five of the branch's
    // thirteen battery mutants, so a nondeterministic version made five kill counts unreliable too.
    const forgeries = [
      tokenWithBrokenSignature(accessTokenFor(USER)),
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

describe("what decides which routes the gate covers", () => {
  // **Encapsulation, not registration order** (PR #104's adversarial review, F3). Four records said
  // Fastify resolves a route's hook chain at registration, so a hook added afterwards misses it.
  // Measured against Fastify 5.12.1 — the version in `package-lock.json` — that is false, and the
  // rule it hid is the one that can actually go wrong. These two tests are the table in
  // `gate.ts`'s header, made executable: the first says the rule everyone believed does not matter,
  // the second says the rule that does.
  const deps = { policy: TEST_JWT_POLICY, withConnection: noDatabase };
  const probe = async (wire: (app: FastifyInstance) => Promise<void> | void) => {
    const app = Fastify({ logger: false });
    await wire(app);
    await app.ready();
    const response = await app.inject({ method: "POST", url: "/v1/plan" });
    await app.close();
    return response.statusCode;
  };

  it("covers a route registered BEFORE it, so order is not what decides coverage", async () => {
    expect(await probe((app) => {
      app.post("/v1/plan", async () => ({ served: true }));
      registerAuthGate(app, deps);
    })).toBe(401);
    // And after it, which is the case everyone assumes is the only safe one.
    expect(await probe((app) => {
      registerAuthGate(app, deps);
      app.post("/v1/plan", async () => ({ served: true }));
    })).toBe(401);
    // Including into a plugin registered afterwards: descendants of the gate's context are covered.
    expect(await probe((app) => {
      registerAuthGate(app, deps);
      app.register(async (scope) => { scope.post("/v1/plan", async () => ({ served: true })); });
    })).toBe(401);
  });

  it("does NOT cover a route outside the context it was installed in — the real hazard", async () => {
    // Asserted rather than described, because it is the wiring a later ticket could reach for while
    // obeying the rule that used to be written down. `buildApp` installs the gate on the root
    // instance, which is why the shipped app is not either of these.
    expect(await probe(async (app) => {
      await app.register(async (scope) => { registerAuthGate(scope, deps); });
      app.post("/v1/plan", async () => ({ served: true }));
    })).toBe(200);
    expect(await probe(async (app) => {
      await app.register(async (scope) => { registerAuthGate(scope, deps); });
      app.register(async (scope) => { scope.post("/v1/plan", async () => ({ served: true })); });
    })).toBe(200);
  });

  it("installs the shipped gate at the root, which is what makes the app's own routes covered", async () => {
    // The property the two tests above make meaningful. `buildApp`'s protected routes are challenged
    // and its public ones are not — which is only true because the gate is on `app` itself.
    const app = build();
    expect((await app.inject({ method: "POST", url: "/v1/auth/signout" })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: "/v1/health" })).statusCode).toBe(200);
    await app.close();
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
