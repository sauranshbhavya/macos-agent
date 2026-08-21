import { describe, expect, it } from "vitest";
import { buildApp, DEFAULT_BODY_LIMIT_BYTES } from "../src/app.js";
import type { Config } from "../src/config.js";

const config: Config = {
  environment: "local",
  port: 0,
  host: "127.0.0.1",
  buildId: "test-build-1",
  databaseUrl: undefined,
  logLevel: "fatal",
  trustProxy: false,
  credentials: [],
};

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
    const app = buildApp(config);
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

  it("a 405 still answers in the taxonomy rather than the framework's shape", async () => {
    const app = buildApp(config);
    const response = await app.inject({ method: "DELETE", url: "/v1/health" });
    expect(response.statusCode).toBeGreaterThanOrEqual(400);
    expectContractEnvelope(response.json(), (response.json() as { error: { code: string } }).error.code);
    expect(["resource.not_found", "request.invalid"]).toContain(response.json().error.code);
    await app.close();
  });
});
