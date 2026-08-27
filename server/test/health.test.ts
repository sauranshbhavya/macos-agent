import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { testConfig } from "./support/config.js";

const config = (overrides: Partial<Config> = {}): Config => testConfig(overrides);

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
    const app = buildApp(config({ environment: "production", buildId: "sha-abc123" }));
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.json()).toMatchObject({ environment: "production", version: "sha-abc123" });
    await app.close();
  });

  it("carries the contract's response headers, asserted against the literal §2.3 requires", async () => {
    // The literal "1.0", not the imported API_VERSION. Comparing the constant to itself passes
    // whatever the constant becomes, so it could not fail if the version were changed by accident
    // -- which is the one thing this assertion exists to catch.
    const app = buildApp(config());
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.headers["sonny-api-version"]).toBe("1.0");
    expect(response.headers["cache-control"]).toBe("no-store");
    await app.close();
  });

  it("mints a UUID request id, not a per-process counter", async () => {
    // Contract §2.3 makes Sonny-Request-Id the join key between an error the user saw, the
    // metering event and the retained content. Fastify's default is a counter that restarts at
    // `req-1` every boot, so two instances -- or one across a restart -- reuse ids. A join key
    // that collides is not a join key. `toBeTruthy` passed against exactly that counter, which is
    // why the shape is asserted here rather than mere presence.
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const app = buildApp(config());
    const first = await app.inject({ method: "GET", url: "/v1/health" });
    const second = await app.inject({ method: "GET", url: "/v1/health" });
    const a = first.headers["sonny-request-id"] as string;
    const b = second.headers["sonny-request-id"] as string;
    expect(a).toMatch(uuid);
    expect(b).toMatch(uuid);
    expect(a).not.toBe(b);
    // The specific regression: the default counter's first id.
    expect(a).not.toBe("req-1");
    await app.close();
  });

  it("gives a fresh process ids that do not collide with the previous one's", async () => {
    // The property a counter fails and a UUID holds. Two independently built apps stand in for
    // two instances; with the default counter both would start at `req-1`.
    const first = buildApp(config());
    const second = buildApp(config());
    const a = (await first.inject({ method: "GET", url: "/v1/health" })).headers["sonny-request-id"];
    const b = (await second.inject({ method: "GET", url: "/v1/health" })).headers["sonny-request-id"];
    expect(a).not.toBe(b);
    await first.close();
    await second.close();
  });

  it("discloses nothing beyond status, version and environment", async () => {
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

  it("requires no Authorization header — and rejects nothing when one is absent", async () => {
    // Named for what it asserts. The previous version of this test re-ran the first test's
    // request and re-asserted 200, which proved nothing the first test had not. This sends the
    // route both with and without a bearer token and requires the same answer, which is what
    // "unauthenticated" means in §2.2's list.
    const app = buildApp(config());
    const without = await app.inject({ method: "GET", url: "/v1/health" });
    const with_ = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { authorization: "Bearer not-a-real-token" },
    });
    expect(without.statusCode).toBe(200);
    expect(with_.statusCode).toBe(200);
    expect(with_.json()).toEqual(without.json());
    await app.close();
  });
});
