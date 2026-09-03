import { createPublicKey, verify as verifySignature } from "node:crypto";
import { describe, expect, it } from "vitest";
import { API_VERSION, buildApp } from "../src/app.js";
import {
  ConfigError,
  requireClientVersionPolicy,
  type Config,
} from "../src/config.js";
import { entitlementSigningKeyFrom, mintEntitlementClaim } from "../src/entitlement/claim.js";
import { errorBody } from "../src/errors.js";
import {
  bandFor,
  compareVersions,
  parseMarketingVersion,
  type ClientVersionPolicy,
} from "../src/version/policy.js";
import { testConfig } from "./support/config.js";

/**
 * Contract §8 — `GET /v1/meta`, the `410 version.unsupported` gate, and §8.4's deprecation headers
 * (SONNY-204).
 *
 * §8 is the part of the contract that is expensive to add later, and the reason is that its whole
 * subject is a client that has already shipped. So the assertions here are about *literals* wherever
 * a shipped client would see one: the status `410`, the code `version.unsupported`, the two header
 * names spelled as §2.3 spells them. Comparing a constant to itself would pass whatever the constant
 * became, which is the one thing these cannot afford.
 */

/** A policy that refuses below 2.0.0 and warns below 3.0.0. Its band boundaries are far apart so a
 * test naming one is never accidentally about the other. */
const armed = (overrides: Partial<Config> = {}): Config =>
  testConfig({
    minimumSupportedClient: "2.0.0",
    recommendedClient: "3.0.0",
    upgradeUrl: "https://sonny.test/download",
    ...overrides,
  });

const get = (app: ReturnType<typeof buildApp>, url: string, clientVersion?: string) =>
  app.inject({
    method: "GET",
    url,
    ...(clientVersion === undefined ? {} : { headers: { "sonny-client-version": clientVersion } }),
  });

describe("parsing a Sonny-Client-Version", () => {
  it("reads one, two and three components, defaulting the missing ones to zero", () => {
    // Two components is not a hypothetical: `SonnyClientIdentity.version` builds the header from
    // CFBundleShortVersionString, which is "1.0" in Packaging/Info.plist, so `1.0+1` is what the
    // packaged app sends. A parser demanding three would refuse the only build a user runs.
    expect(parseMarketingVersion("1")).toEqual({ major: 1, minor: 0, patch: 0 });
    expect(parseMarketingVersion("1.2")).toEqual({ major: 1, minor: 2, patch: 0 });
    expect(parseMarketingVersion("1.2.3")).toEqual({ major: 1, minor: 2, patch: 3 });
  });

  it("drops build metadata and a prerelease suffix, in that order", () => {
    expect(parseMarketingVersion("1.0+1")).toEqual({ major: 1, minor: 0, patch: 0 });
    expect(parseMarketingVersion("1.0.0+412")).toEqual({ major: 1, minor: 0, patch: 0 });
    // Semver writes prerelease before build (`1.0.0-beta+exp`), so the `+` cut has to come first or
    // the `-` cut never reaches the suffix.
    expect(parseMarketingVersion("1.0.0-beta.2+412")).toEqual({ major: 1, minor: 0, patch: 0 });
  });

  it("answers undefined for anything it cannot read, rather than a version", () => {
    for (const raw of ["", "   ", "banana", "1.0.0.0", "v1.0.0", "-1.0", "1.-2", "1..2", "1,0"]) {
      expect(parseMarketingVersion(raw), raw).toBeUndefined();
    }
    // Bounded: ten digits is one past the nine the pattern allows, which is what keeps a component
    // inside Number.MAX_SAFE_INTEGER.
    expect(parseMarketingVersion("1234567890.0.0")).toBeUndefined();
    expect(parseMarketingVersion("123456789.0.0")).toEqual({
      major: 123456789,
      minor: 0,
      patch: 0,
    });
    expect(parseMarketingVersion(`1.0.${"0".repeat(200)}`)).toBeUndefined();
  });

  it("orders by major, then minor, then patch", () => {
    const at = (raw: string) => {
      const parsed = parseMarketingVersion(raw);
      if (parsed === undefined) throw new Error(`fixture ${raw} does not parse`);
      return parsed;
    };
    expect(compareVersions(at("1.0.0"), at("2.0.0"))).toBeLessThan(0);
    expect(compareVersions(at("1.9.9"), at("1.10.0"))).toBeLessThan(0);
    expect(compareVersions(at("1.0.1"), at("1.0.0"))).toBeGreaterThan(0);
    expect(compareVersions(at("1.0"), at("1.0.0"))).toBe(0);
    expect(compareVersions(at("1.0+7"), at("1.0+412"))).toBe(0);
  });
});

describe("which band a client is in", () => {
  const policy = (): ClientVersionPolicy => requireClientVersionPolicy(armed());

  it("puts a version below the minimum in unsupported and one at it in deprecated", () => {
    // The boundary is inclusive on the minimum: §8.3 refuses a client *below* it, and §8.4 serves
    // "a client at or above the minimum but below the recommended version".
    expect(bandFor("1.9.9", policy())).toBe("unsupported");
    expect(bandFor("2.0.0", policy())).toBe("deprecated");
    expect(bandFor("2.9.9", policy())).toBe("deprecated");
  });

  it("puts a version at or above the recommended one in current", () => {
    expect(bandFor("3.0.0", policy())).toBe("current");
    expect(bandFor("9.9.9", policy())).toBe("current");
  });

  it("puts an absent, unreadable or repeated header in unknown, never in unsupported", () => {
    // The fail-open decision, asserted as the thing it is. Every caller that is not the Mac app
    // sends no version: a liveness probe, the payment provider's signed delivery, deploy.sh's own
    // health check, a founder with curl. `unknown` is served; `unsupported` would be an outage.
    expect(bandFor(undefined, policy())).toBe("unknown");
    expect(bandFor("banana", policy())).toBe("unknown");
    expect(bandFor(["1.0.0", "9.9.9"], policy())).toBe("unknown");
  });
});

describe("the version policy this deployment was configured with", () => {
  it("is disarmed by default, so shipping the gate refuses nobody", () => {
    const policy = requireClientVersionPolicy(testConfig());
    expect(policy.armed).toBe(false);
    expect(policy.minimumText).toBe("0.0.0");
    expect(policy.recommendedText).toBe("0.0.0");
    // The version a bare `swift run MacAgent` reports, which has no bundle to read one from. A
    // default above zero would have refused it on the day this landed.
    expect(bandFor("0.0+0", policy)).toBe("current");
  });

  it("normalises both bounds to three components", () => {
    const policy = requireClientVersionPolicy(
      armed({ minimumSupportedClient: "2", recommendedClient: "3.1" }),
    );
    expect(policy.minimumText).toBe("2.0.0");
    expect(policy.recommendedText).toBe("3.1.0");
  });

  it("refuses a bound it cannot read, naming the variable", () => {
    expect(() => requireClientVersionPolicy(armed({ minimumSupportedClient: "banana" }))).toThrow(
      ConfigError,
    );
    expect(() => requireClientVersionPolicy(armed({ minimumSupportedClient: "banana" }))).toThrow(
      /MINIMUM_SUPPORTED_CLIENT/,
    );
    expect(() => requireClientVersionPolicy(armed({ recommendedClient: "1.x" }))).toThrow(
      /RECOMMENDED_CLIENT/,
    );
  });

  it("refuses a recommended version below the minimum, which describes no client", () => {
    expect(() =>
      requireClientVersionPolicy(
        armed({ minimumSupportedClient: "3.0.0", recommendedClient: "2.0.0" }),
      ),
    ).toThrow(/RECOMMENDED_CLIENT \(2\.0\.0\) is below MINIMUM_SUPPORTED_CLIENT \(3\.0\.0\)/);
    // Equal is legitimate: it arms the wall with no warning period.
    const equal = requireClientVersionPolicy(
      armed({ minimumSupportedClient: "3.0.0", recommendedClient: "3.0.0" }),
    );
    expect(equal.armed).toBe(true);
  });

  it("refuses to arm either bound without somewhere to send the user", () => {
    expect(() => requireClientVersionPolicy(armed({ upgradeUrl: undefined }))).toThrow(
      /UPGRADE_URL is required/,
    );
    // A recommended version alone arms it too: §8.4's Sonny-Deprecation-Info needs the same URL.
    expect(() =>
      requireClientVersionPolicy(
        armed({ minimumSupportedClient: "0.0.0", recommendedClient: "3.0.0", upgradeUrl: undefined }),
      ),
    ).toThrow(/UPGRADE_URL is required/);
  });

  it("keeps a configured URL on a disarmed policy, so /v1/meta still publishes it", () => {
    const policy = requireClientVersionPolicy(
      testConfig({ upgradeUrl: "https://sonny.test/download" }),
    );
    expect(policy.armed).toBe(false);
    expect(policy.upgradeUrl).toBe("https://sonny.test/download");
  });

  it("refuses an upgrade URL with no scheme, or a scheme the client should never open", () => {
    expect(() => requireClientVersionPolicy(armed({ upgradeUrl: "sonny.test/download" }))).toThrow(
      /UPGRADE_URL is not a URL/,
    );
    for (const raw of ["file:///Applications/Sonny.app", "javascript:alert(1)", "ftp://a.test/x"]) {
      expect(() => requireClientVersionPolicy(armed({ upgradeUrl: raw })), raw).toThrow(
        /UPGRADE_URL must be http or https/,
      );
    }
  });

  it("is checked at startup, so a malformed bound never reaches a request", () => {
    // buildApp calls requireClientVersionPolicy unconditionally, which is what makes this a named
    // startup failure on every deployment rather than a gateway that refuses the wrong people.
    expect(() => buildApp(armed({ minimumSupportedClient: "banana" }))).toThrow(ConfigError);
  });
});

describe("GET /v1/meta", () => {
  it("answers §8.3's six fields and nothing else", async () => {
    const app = buildApp(armed());
    const response = await get(app, "/v1/meta", "3.0.0");
    expect(response.statusCode).toBe(200);
    expect(Object.keys(response.json()).sort()).toEqual([
      "api_version",
      "entitlement_keys",
      "minimum_supported_client",
      "recommended_client",
      "server_time",
      "upgrade_url",
    ]);
    await app.close();
  });

  it("publishes the bounds this deployment was configured with, normalised", async () => {
    const app = buildApp(armed({ minimumSupportedClient: "2", recommendedClient: "3.1" }));
    const body = (await get(app, "/v1/meta", "3.1.0")).json();
    // The literal "1.0", not API_VERSION: comparing the constant to itself would pass whatever it
    // became, and a client reads this string. `health.test.ts` makes the same call for the header.
    expect(body.api_version).toBe("1.0");
    expect(API_VERSION).toBe("1.0");
    expect(body.minimum_supported_client).toBe("2.0.0");
    expect(body.recommended_client).toBe("3.1.0");
    expect(body.upgrade_url).toBe("https://sonny.test/download");
    await app.close();
  });

  it("publishes a null upgrade_url when the deployment has named none", async () => {
    const app = buildApp(testConfig());
    const body = (await get(app, "/v1/meta")).json();
    expect(body.upgrade_url).toBeNull();
    expect(body.minimum_supported_client).toBe("0.0.0");
    await app.close();
  });

  it("answers server_time in §2.1's form, on the server's own clock", async () => {
    const app = buildApp(testConfig());
    const before = Date.now();
    const body = (await get(app, "/v1/meta")).json();
    const after = Date.now();
    // RFC 3339, UTC, `Z`, whole seconds -- §2.1's form and the one §5.3's claim instants take,
    // through the same `isoSeconds` helper so two documents from this gateway cannot disagree.
    expect(body.server_time).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    // Asserted as a value and not only as a shape: the instant sits inside the window the request
    // was served in, rounded down by the second `isoSeconds` truncates. A hard-coded or stale clock
    // fails this; `Date.now()` compared to itself would not.
    const parsed = Date.parse(body.server_time);
    expect(Number.isNaN(parsed)).toBe(false);
    expect(parsed).toBeGreaterThanOrEqual(Math.floor(before / 1000) * 1000);
    expect(parsed).toBeLessThanOrEqual(after);
    await app.close();
  });

  it("publishes a key set that actually verifies a claim this gateway signed", async () => {
    // The property §5.3 rests on, asserted end to end rather than by re-deriving the same bytes the
    // route derives: take the public_key /v1/meta published, rebuild an Ed25519 public key from it,
    // and verify a claim minted by the signing key the config carries. If the route published the
    // wrong key, or the wrong encoding, this fails.
    const config = armed();
    const app = buildApp(config);
    const body = (await get(app, "/v1/meta", "3.0.0")).json();
    const keys = body.entitlement_keys as { kid: string; alg: string; public_key: string }[];
    expect(keys).toHaveLength(1);
    const published = keys[0];
    if (published === undefined) throw new Error("the key set is empty");
    expect(published.alg).toBe("EdDSA");
    expect(published.kid).toBe("test-key-1");

    if (config.entitlementSigningKey === undefined) throw new Error("fixture has no signing key");
    const signingKey = entitlementSigningKeyFrom(config.entitlementSigningKey, "test-key-1");
    const claim = mintEntitlementClaim(
      { subject: "user-1", plan: "free", capabilities: [] },
      signingKey,
      new Date("2026-08-17T09:41:07Z"),
    );
    const [header, payload, signature] = claim.entitlement.split(".");
    expect(JSON.parse(Buffer.from(header ?? "", "base64url").toString("utf8")).kid).toBe(
      published.kid,
    );

    // An Ed25519 SPKI is a fixed 12-byte prefix followed by the raw 32 bytes, which is the form
    // `publicKeyMaterial` publishes and the form `Curve25519.Signing.PublicKey(rawRepresentation:)`
    // takes on the Mac.
    const raw = Buffer.from(published.public_key, "base64url");
    expect(raw).toHaveLength(32);
    const spki = Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      raw,
    ]);
    const publicKey = createPublicKey({ key: spki, format: "der", type: "spki" });
    expect(
      verifySignature(
        null,
        Buffer.from(`${header ?? ""}.${payload ?? ""}`, "utf8"),
        publicKey,
        Buffer.from(signature ?? "", "base64url"),
      ),
    ).toBe(true);
    await app.close();
  });

  it("publishes an empty key set on a deployment that signs nothing", async () => {
    // A health-only deployment mounts no authenticated route and holds no signing key. §5.3.1 makes
    // an empty set refuse every gated capability on the Mac and affect no free one, which is the
    // direction that document requires — and it is a true statement about the deployment, unlike a
    // 404 the client would read as "no such route".
    const app = buildApp(
      testConfig({ entitlementSigningKey: undefined, entitlementSigningKeyId: undefined }),
    );
    const response = await get(app, "/v1/meta");
    expect(response.statusCode).toBe(200);
    expect(response.json().entitlement_keys).toEqual([]);
    await app.close();
  });

  it("requires no Authorization header, and answers the same with one", async () => {
    const app = buildApp(armed());
    const without = await get(app, "/v1/meta", "3.0.0");
    const with_ = await app.inject({
      method: "GET",
      url: "/v1/meta",
      headers: { "sonny-client-version": "3.0.0", authorization: "Bearer not-a-real-token" },
    });
    expect(without.statusCode).toBe(200);
    expect(with_.statusCode).toBe(200);
    expect(with_.json().minimum_supported_client).toBe(without.json().minimum_supported_client);
    await app.close();
  });

  it("is never cached, because every field on it is one a client asks about after it changed", async () => {
    const app = buildApp(armed());
    const response = await get(app, "/v1/meta", "3.0.0");
    expect(response.headers["cache-control"]).toBe("no-store");
    expect(response.headers["sonny-api-version"]).toBe("1.0");
    await app.close();
  });
});

describe("a client below the minimum supported version", () => {
  it("gets 410 version.unsupported with an upgrade_url in the error body", async () => {
    const app = buildApp(armed());
    const response = await get(app, "/v1/health", "1.9.9");
    expect(response.statusCode).toBe(410);
    expect(response.json()).toEqual({
      error: {
        code: "version.unsupported",
        message: expect.any(String),
        retryable: false,
        retry_after_seconds: null,
        request_id: expect.any(String),
        upgrade_url: "https://sonny.test/download",
      },
    });
    await app.close();
  });

  it("gets it on every endpoint, including /v1/meta itself answering honestly", async () => {
    // §8.3's own words. /v1/meta is not exempt, which is why the upgrade_url is in the error body:
    // a client that predates whatever changed never has to parse the meta document at all.
    const app = buildApp(armed());
    for (const url of ["/v1/meta", "/v1/health", "/v1/account/entitlements", "/v1/nothing-here"]) {
      const response = await get(app, url, "1.0+1");
      expect(response.statusCode, url).toBe(410);
      expect(response.json().error.code, url).toBe("version.unsupported");
    }
    await app.close();
  });

  it("is refused before authentication, so an expired token cannot hide the reason", async () => {
    // The order that matters. An outdated build's access token is usually long expired, and §7.2
    // makes auth.token_expired the one 401 a client answers by refreshing and retrying — so with
    // the auth gate first this client loops forever and never learns the one fact that ends it.
    const app = buildApp(armed());
    const protectedRoute = { method: "POST" as const, url: "/v1/plan" };
    const modern = await app.inject({
      ...protectedRoute,
      headers: { "sonny-client-version": "3.0.0" },
      payload: {},
    });
    expect(modern.statusCode).toBe(401);
    expect(modern.json().error.code).toBe("auth.unauthenticated");

    const outdated = await app.inject({
      ...protectedRoute,
      headers: { "sonny-client-version": "1.0.0" },
      payload: {},
    });
    expect(outdated.statusCode).toBe(410);
    expect(outdated.json().error.code).toBe("version.unsupported");
    await app.close();
  });

  it("is decided on the marketing version alone, ignoring the build number", async () => {
    const app = buildApp(armed({ minimumSupportedClient: "2.0.0" }));
    expect((await get(app, "/v1/health", "1.9.9+99999")).statusCode).toBe(410);
    expect((await get(app, "/v1/health", "2.0.0+1")).statusCode).toBe(200);
    await app.close();
  });

  it("is exactly the versions below the bound, not the one at it", async () => {
    const app = buildApp(armed({ minimumSupportedClient: "2.0.0", recommendedClient: "2.0.0" }));
    expect((await get(app, "/v1/health", "1.999.999")).statusCode).toBe(410);
    expect((await get(app, "/v1/health", "2.0.0")).statusCode).toBe(200);
    await app.close();
  });
});

describe("a client above the minimum but below the recommended version", () => {
  it("is served normally, with §8.4's two headers", async () => {
    const app = buildApp(armed());
    const response = await get(app, "/v1/health", "2.5.0");
    expect(response.statusCode).toBe(200);
    expect(response.json().status).toBe("ok");
    expect(response.headers["sonny-deprecation"]).toBe("true");
    expect(response.headers["sonny-deprecation-info"]).toBe("https://sonny.test/download");
    await app.close();
  });

  it("gets them on a response no handler produced — a 401 and a 404", async () => {
    // §8.4 says "on every response". Set in onRequest rather than onSend so they reach a reply the
    // route handler never touches.
    const app = buildApp(armed());
    const unauthenticated = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { "sonny-client-version": "2.5.0" },
      payload: {},
    });
    expect(unauthenticated.statusCode).toBe(401);
    expect(unauthenticated.headers["sonny-deprecation"]).toBe("true");

    const missing = await get(app, "/v1/nothing-here", "2.5.0");
    expect(missing.statusCode).toBe(404);
    expect(missing.headers["sonny-deprecation-info"]).toBe("https://sonny.test/download");
    await app.close();
  });

  it("gets no deprecation headers at or above the recommended version", async () => {
    const app = buildApp(armed());
    for (const version of ["3.0.0", "3.0.1", "9.9.9"]) {
      const response = await get(app, "/v1/health", version);
      expect(response.statusCode, version).toBe(200);
      expect(response.headers["sonny-deprecation"], version).toBeUndefined();
      expect(response.headers["sonny-deprecation-info"], version).toBeUndefined();
    }
    await app.close();
  });

  it("gets none when the two bounds are equal, so there is no warning band at all", async () => {
    const app = buildApp(armed({ minimumSupportedClient: "2.0.0", recommendedClient: "2.0.0" }));
    const response = await get(app, "/v1/health", "2.0.0");
    expect(response.statusCode).toBe(200);
    expect(response.headers["sonny-deprecation"]).toBeUndefined();
    await app.close();
  });
});

describe("a caller that sends no usable version", () => {
  it("is served, with no deprecation headers and no refusal", async () => {
    // The callers this covers are real and named in §4.1 and in deploy.sh: a load balancer's
    // liveness probe, the payment provider's signed delivery, a founder with curl. Refusing them
    // would turn a version policy into an outage at the moment somebody first set a real minimum.
    const app = buildApp(armed());
    for (const version of [undefined, "banana", "   ", "v2.5.0"]) {
      const response = await get(app, "/v1/health", version);
      expect(response.statusCode, String(version)).toBe(200);
      expect(response.headers["sonny-deprecation"], String(version)).toBeUndefined();
    }
    await app.close();
  });

  it("is served when it sends the header twice, rather than having one of them believed", async () => {
    const app = buildApp(armed());
    const response = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { "sonny-client-version": ["1.0.0", "3.0.0"] },
    });
    expect(response.statusCode).toBe(200);
    expect(response.headers["sonny-deprecation"]).toBeUndefined();
    await app.close();
  });
});

describe("a deployment that has said nothing about versions", () => {
  it("refuses nobody and warns nobody, whatever the client claims to be", async () => {
    const app = buildApp(testConfig());
    for (const version of ["0.0+0", "0.0.1", "1.0+1", "99.0.0", undefined]) {
      const response = await get(app, "/v1/health", version);
      expect(response.statusCode, String(version)).toBe(200);
      expect(response.headers["sonny-deprecation"], String(version)).toBeUndefined();
      expect(response.headers["sonny-deprecation-info"], String(version)).toBeUndefined();
    }
    await app.close();
  });

  it("still leaves every other refusal exactly where it was", async () => {
    // The gate adds no hook at all when disarmed, so nothing about the auth gate, the not-found
    // handler or the error envelope moves.
    const app = buildApp(testConfig());
    const unauthenticated = await app.inject({ method: "POST", url: "/v1/plan", payload: {} });
    expect(unauthenticated.statusCode).toBe(401);
    expect(unauthenticated.json().error.code).toBe("auth.unauthenticated");
    const missing = await get(app, "/v1/nothing-here", "0.0.1");
    expect(missing.statusCode).toBe(404);
    expect(missing.json().error.code).toBe("resource.not_found");
    await app.close();
  });
});

describe("the error envelope's new field", () => {
  it("is absent from the object errorBody returns, not merely from the JSON it becomes", () => {
    // Asserted on the value rather than through a response, because a response cannot see it:
    // `JSON.stringify` drops an undefined value, so the HTTP-level assertion below passes whether
    // the key is written unconditionally or not. SONNY-204's battery proved that — the mutant that
    // writes it unconditionally survived a suite that had only the response-level test.
    const plain = errorBody("resource.not_found", "No such route.", "req-1");
    expect("upgrade_url" in plain.error).toBe(false);
    expect(Object.keys(plain.error).sort()).toEqual([
      "code",
      "message",
      "request_id",
      "retry_after_seconds",
      "retryable",
    ]);

    const refused = errorBody("version.unsupported", "Too old.", "req-2", {
      upgradeUrl: "https://sonny.test/download",
    });
    expect("upgrade_url" in refused.error).toBe(true);
    expect(refused.error.upgrade_url).toBe("https://sonny.test/download");
  });

  it("is absent from every error that is not version.unsupported", async () => {
    // §2.1 lets a client ignore fields it does not know, so adding one to a single code is additive
    // (§8.1). What would not be additive is a null on every other error, and this is the assertion
    // that the key is absent rather than present-and-undefined.
    const app = buildApp(armed());
    const missing = await get(app, "/v1/nothing-here", "3.0.0");
    expect(missing.statusCode).toBe(404);
    expect(Object.keys(missing.json().error).sort()).toEqual([
      "code",
      "message",
      "request_id",
      "retry_after_seconds",
      "retryable",
    ]);
    await app.close();
  });
});
