import { randomUUID } from "node:crypto";
import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import { buildApp, DEFAULT_BODY_LIMIT_BYTES } from "../src/app.js";
import { registerErrorHandlers } from "../src/errors.js";
import type { Config } from "../src/config.js";
import { testConfig } from "./support/config.js";

const config: Config = testConfig();

/** Contract §7.1's envelope, asserted structurally rather than by eyeball. */
function expectContractEnvelope(body: unknown, code: string): void {
  expect(Object.keys(body as object)).toEqual(["error"]);
  const error = (body as { error: Record<string, unknown> }).error;
  expect(Object.keys(error).sort()).toEqual([
    "code",
    "message",
    "request_id",
    "retry_after_seconds",
    "retryable",
  ]);
  expect(error["code"]).toBe(code);
  expect(typeof error["message"]).toBe("string");
  expect(typeof error["retryable"]).toBe("boolean");
  expect(error["request_id"]).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
  );
}

describe("error responses use the contract's envelope, not the framework's", () => {
  it("404 on an unknown route is resource.not_found in §7.1 shape", async () => {
    const app = buildApp(config);
    const response = await app.inject({ method: "GET", url: "/v1/nope" });
    expect(response.statusCode).toBe(404);
    expectContractEnvelope(response.json(), "resource.not_found");
    await app.close();
  });

  it("404 leaks none of Fastify's own envelope fields", async () => {
    // The specific regression. Fastify's default body is {statusCode, error, message}, which
    // shares exactly one field name with §7.1 and none of its structure. A client written against
    // the contract would find no `error.code` to map to its copy.
    const app = buildApp(config);
    const body = (await app.inject({ method: "GET", url: "/v1/nope" })).json();
    expect(body).not.toHaveProperty("statusCode");
    expect(typeof (body as { error: unknown }).error).toBe("object");
    await app.close();
  });

  it("a malformed JSON body is request.invalid", async () => {
    const app = buildApp(config);
    const response = await app.inject({
      method: "POST",
      url: "/v1/health",
      headers: { "content-type": "application/json" },
      payload: "{ not json",
    });
    expect(response.statusCode).toBe(400);
    expectContractEnvelope(response.json(), "request.invalid");
    await app.close();
  });

  it("a body over the limit is 413 request.too_large, §7.2 case 4", async () => {
    const app = buildApp(config);
    const response = await app.inject({
      method: "POST",
      url: "/v1/health",
      headers: { "content-type": "application/json" },
      payload: "x".repeat(DEFAULT_BODY_LIMIT_BYTES + 1024),
    });
    expect(response.statusCode).toBe(413);
    expectContractEnvelope(response.json(), "request.too_large");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it("every error response still carries the §2.3 headers", async () => {
    const app = buildApp(config);
    const response = await app.inject({ method: "GET", url: "/v1/nope" });
    expect(response.headers["sonny-api-version"]).toBe("1.0");
    expect(response.headers["sonny-request-id"]).toBeDefined();
    await app.close();
  });

  it("the envelope's request_id matches the response header", async () => {
    // §2.3: the id is "the join key between an error the user saw, the metering event, and the
    // retained content". Two different ids in one response would make that join ambiguous.
    const app = buildApp(config);
    const response = await app.inject({ method: "GET", url: "/v1/nope" });
    expect(response.json().error.request_id).toBe(response.headers["sonny-request-id"]);
    await app.close();
  });

  it("an unexpected throw becomes server.error and never leaks the thrown message", async () => {
    // **Built from `registerErrorHandlers` directly rather than from `buildApp`, and the route is
    // back at `/v1/boom`** (PR #104's adversarial review, F10). The history is worth keeping because
    // it is two lessons rather than one. This test originally registered `/v1/boom` on a `buildApp`
    // instance; SONNY-203's deny-by-default gate then refused the request before the handler ran,
    // which is the gate working exactly as designed — a route added without a thought about
    // authentication is refused rather than served. Moving the route to `/v1/meta` got it past the
    // gate and created a second problem: `/v1/meta` is a real contract route with a real owner
    // (SONNY-155), so the moment that ticket registers it inside `buildApp` this file adds a second
    // handler on the same path and Fastify throws `FST_ERR_DUPLICATED_ROUTE` at `ready()` — handing
    // that ticket a failure it did not cause.
    //
    // What this test is actually about is `registerErrorHandlers`, which is the same function
    // `buildApp` installs. Building the instance around that one function keeps the subject, keeps
    // the route name honest, squats on nobody's path, and needs no token.
    // `genReqId` is `buildApp`'s, repeated here for one reason: `expectContractEnvelope` asserts the
    // request id is a UUID, and a bare Fastify instance would hand it the `req-1` counter. That the
    // real `buildApp` mints UUIDs is pinned separately, against the real thing, by health.test.ts's
    // "mints a UUID request id, not a per-process counter" — so nothing is lost by not re-proving it
    // here, and the envelope assertion stays whole.
    const app = Fastify({ logger: false, genReqId: () => randomUUID() });
    registerErrorHandlers(app);
    app.get("/v1/boom", async () => {
      throw new Error("connection string postgres://postgres:postgres@localhost:5432/db failed");
    });
    const response = await app.inject({ method: "GET", url: "/v1/boom" });
    expect(response.statusCode).toBe(500);
    expectContractEnvelope(response.json(), "server.error");
    expect(response.json().error.retryable).toBe(true);
    // The thrown text is logged, not returned. A framework message can name internal paths, and
    // an error string is exactly where a connection string tends to end up.
    expect(response.body).not.toContain("postgres://");
    expect(response.body).not.toContain("connection string");
    await app.close();
  });

  it("a malformed URL is rejected before routing and still uses the envelope", async () => {
    // The last door out of the framework's own shape. `setErrorHandler` and `setNotFoundHandler`
    // cover errors raised during routing and handling; a URL Fastify cannot parse is refused
    // before either runs. Measured before the fix, `GET /v1/%zz` returned
    // {"error":"Bad Request","code":"FST_ERR_BAD_URL","message":"'/v1/%zz' is not a valid url
    // component","statusCode":400} -- framework shape, a framework error code, and the offending
    // path echoed straight back to the caller.
    const app = buildApp(config);
    const response = await app.inject({ method: "GET", url: "/v1/%zz" });
    expect(response.statusCode).toBe(400);
    expectContractEnvelope(response.json(), "request.invalid");
    expect(response.body).not.toContain("FST_ERR");
    expect(response.body).not.toContain("%zz");
    expect(response.body).not.toHaveProperty("statusCode");
    expect(response.headers["sonny-api-version"]).toBe("1.0");
    await app.close();
  });

  it("a 405 still answers in the taxonomy rather than the framework's shape", async () => {
    const app = buildApp(config);
    const response = await app.inject({ method: "DELETE", url: "/v1/health" });
    expect(response.statusCode).toBeGreaterThanOrEqual(400);
    expectContractEnvelope(response.json(), (response.json() as { error: { code: string } }).error.code);
    expect(["resource.not_found", "request.invalid"]).toContain(response.json().error.code);
    await app.close();
  });
});
