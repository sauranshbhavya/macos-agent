import { describe, expect, it } from "vitest";
import { buildApp, API_VERSION } from "../src/app.js";
import type { Config } from "../src/config.js";

const config = (overrides: Partial<Config> = {}): Config => ({
  environment: "local",
  port: 0,
  host: "127.0.0.1",
  buildId: "test-build-1",
  databaseUrl: undefined,
  logLevel: "fatal",
  credentials: [],
  ...overrides,
});

describe("GET /v1/health", () => {
  it("answers 200 with the build identifier the config carries", async () => {
    const app = buildApp(config());
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      status: "ok",
      version: "test-build-1",
      environment: "local",
    });
    await app.close();
  });

  it("reports the environment it was configured with, so two deployments are distinguishable", async () => {
    // The founder's manual-test item for this ticket is hitting staging and production and
    // confirming they differ. That is only possible if both fields track configuration rather
    // than being baked in, so both are asserted against non-default values.
    const app = buildApp(config({ environment: "production", buildId: "sha-abc123" }));
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.json()).toMatchObject({ environment: "production", version: "sha-abc123" });
    await app.close();
  });

  it("carries the contract's response headers", async () => {
    const app = buildApp(config());
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.headers["sonny-api-version"]).toBe(API_VERSION);
    expect(response.headers["sonny-request-id"]).toBeTruthy();
    expect(response.headers["cache-control"]).toBe("no-store");
    await app.close();
  });

  it("discloses nothing beyond status, version and environment", async () => {
    // Pinned rather than left to convention. This route is unauthenticated and reachable by
    // anyone who finds the hostname, so a later edit that helpfully adds a dependency list or a
    // configured-provider count should fail a test rather than ship.
    const app = buildApp(
      config({
        databaseUrl: "postgres://postgres:postgres@localhost:5432/sonny",
        credentials: [{ provider: "openai", keys: ["k1", "k2"] }],
      }),
    );
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(Object.keys(response.json()).sort()).toEqual(["environment", "status", "version"]);
    expect(response.body).not.toContain("postgres");
    expect(response.body).not.toContain("k1");
    await app.close();
  });

  it("is unauthenticated — contract §2.2 lists it among the routes carrying no bearer token", async () => {
    const app = buildApp(config());
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    await app.close();
  });
});
