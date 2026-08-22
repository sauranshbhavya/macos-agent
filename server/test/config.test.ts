import { describe, expect, it } from "vitest";
import {
  ConfigError,
  acceptedKeys,
  activeKey,
  loadConfig,
  parseTrustedProxies,
  providerCredentials,
} from "../src/config.js";

const base = { SONNY_ENV: "local" } as NodeJS.ProcessEnv;

describe("configuration", () => {
  it("refuses to start on an unknown environment rather than guessing one", () => {
    expect(() => loadConfig({ SONNY_ENV: "prod" })).toThrow(ConfigError);
  });

  it("refuses to start with no environment at all", () => {
    expect(() => loadConfig({})).toThrow(ConfigError);
  });

  it("names the offending variable and never echoes a value", () => {
    // An invalid-config error that printed the environment back would put credentials into
    // whatever collects this server's logs.
    try {
      loadConfig({ SONNY_ENV: "local", PORT: "not-a-port", OPENAI_API_KEY: "sk-secret-value" });
      expect.unreachable("should have thrown");
    } catch (error) {
      const message = (error as Error).message;
      expect(message).toContain("PORT");
      expect(message).not.toContain("sk-secret-value");
    }
  });

  it("defaults the port and build id so a bare local run works", () => {
    const config = loadConfig({ ...base });
    expect(config.port).toBe(8080);
    expect(config.buildId).toBe("dev");
    expect(config.environment).toBe("local");
  });
});

describe("provider credentials — two live keys per provider", () => {
  it("reads the primary key alone", () => {
    const found = providerCredentials({ OPENAI_API_KEY: "one" });
    expect(found).toEqual([{ provider: "openai", keys: ["one"] }]);
  });

  it("reads a second live key so one can be retired while the other serves", () => {
    const found = providerCredentials({ OPENAI_API_KEY: "one", OPENAI_API_KEY_2: "two" });
    expect(found[0]?.keys).toEqual(["one", "two"]);
  });

  it("reads beyond two, because the ceiling is the rotation's, not the format's", () => {
    const found = providerCredentials({
      ANTHROPIC_API_KEY: "a",
      ANTHROPIC_API_KEY_2: "b",
      ANTHROPIC_API_KEY_3: "c",
    });
    expect(found[0]?.keys).toEqual(["a", "b", "c"]);
  });

  it("stops at the first gap rather than skipping it", () => {
    // A typo'd _4 with no _3 must not silently become the second credential — that would make a
    // rotation promote a key nobody meant to promote.
    const found = providerCredentials({ TAVILY_API_KEY: "a", TAVILY_API_KEY_4: "typo" });
    expect(found[0]?.keys).toEqual(["a"]);
  });

  it("ignores blank and whitespace-only values", () => {
    const found = providerCredentials({ CEREBRAS_API_KEY: "a", CEREBRAS_API_KEY_2: "   " });
    expect(found[0]?.keys).toEqual(["a"]);
  });

  it("omits a provider entirely when it has no credential", () => {
    expect(providerCredentials({ OPENAI_API_KEY: "a" }).map((c) => c.provider)).toEqual(["openai"]);
  });

  it("survives every step of a zero-downtime rotation with a usable key throughout", () => {
    // The property the ticket actually asks for, walked end to end. Each step is one deploy and
    // each is valid on its own; at no point is there no active key, and the retiring key stays
    // accepted until it is removed.
    const steps: Array<[string, NodeJS.ProcessEnv]> = [
      ["before", { ...base, OPENAI_API_KEY: "old" }],
      ["add new as secondary", { ...base, OPENAI_API_KEY: "old", OPENAI_API_KEY_2: "new" }],
      ["promote new", { ...base, OPENAI_API_KEY: "new", OPENAI_API_KEY_2: "old" }],
      ["retire old", { ...base, OPENAI_API_KEY: "new" }],
    ];
    const active = steps.map(([, env]) => activeKey(loadConfig(env), "openai"));
    expect(active).toEqual(["old", "old", "new", "new"]);
    expect(active.every((key) => key !== undefined)).toBe(true);

    // The old key is still honoured through the overlap, which is what makes the retirement safe.
    expect(acceptedKeys(loadConfig(steps[2]![1]), "openai")).toContain("old");
    expect(acceptedKeys(loadConfig(steps[3]![1]), "openai")).not.toContain("old");
  });

  it("returns undefined rather than throwing for a provider with no credential", () => {
    expect(activeKey(loadConfig({ ...base }), "vision")).toBeUndefined();
    expect(acceptedKeys(loadConfig({ ...base }), "vision")).toEqual([]);
  });

  describe("ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE — the production gate", () => {
    // **PR #87 fifth round, F4: this control had no test at all.** `grep -rn` across `test/` returned
    // nothing, and replacing the refusal's condition with `false` left the suite green at 145/145.
    // It is the control that keeps an unauthenticated destructive route off the one host where it
    // would matter, and it is the fix for this branch's original CRITICAL.
    //
    // The gate does work — a reviewer drove eleven env-value variants and a real compiled-process
    // launch at it. **That is exactly the shape the founder made this round fix for the race
    // battery** (F7 of the third round): headline safety evidence living only as a number in a
    // ticket comment with no command left to run. Same shape, different artifact.

    it("REFUSES to start when the flag is on in production", () => {
      expect(() => loadConfig({ SONNY_ENV: "production", ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE: "true" }))
        .toThrow(ConfigError);
      // Refused rather than silently forced off: a deployment believing a route is mounted that is
      // not is its own confusion. The message has to name the variable, or the operator is guessing.
      expect(() => loadConfig({ SONNY_ENV: "production", ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE: "true" }))
        .toThrow(/ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE/);
    });

    it("allows it outside production, which is what makes it a gate and not a ban", () => {
      for (const environment of ["local", "staging"]) {
        const config = loadConfig({ SONNY_ENV: environment, ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE: "true" });
        expect(config.allowUnauthenticatedAccountDelete).toBe(true);
      }
      expect(loadConfig({ SONNY_ENV: "production" }).allowUnauthenticatedAccountDelete).toBe(false);
    });

    it("defaults to off when the variable is absent", () => {
      // The safe direction has to be the default, because the dangerous one is a deployment away.
      expect(loadConfig({ SONNY_ENV: "local" }).allowUnauthenticatedAccountDelete).toBe(false);
    });

    it("refuses every near-miss spelling of true rather than guessing at it", () => {
      // A gate that accepted `TRUE` in production while refusing `true` would be worse than no gate:
      // it would be a gate somebody had tested. The enum is what makes the refusal total.
      for (const value of ["TRUE", "True", " true", "1", "yes", "on", ""]) {
        expect(() => loadConfig({ SONNY_ENV: "production", ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE: value }))
          .toThrow(ConfigError);
        expect(() => loadConfig({ SONNY_ENV: "local", ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE: value }))
          .toThrow(ConfigError);
      }
    });
  });

  describe("TRUSTED_PROXIES", () => {
    // **PR #87 third round, F5.** Nothing validated these entries, so a typo reached
    // `@fastify/proxy-addr`'s `compile()` and threw a raw third-party `TypeError` **inside the
    // `Fastify(...)` constructor** — before `app.ready()`, before this server's logger exists, and
    // naming library internals rather than the variable that is wrong. The gateway would not start
    // and the log did not say why, which is the exact opposite of what this file exists to
    // guarantee: a bad environment is a named `ConfigError` identifying the variable.

    it("accepts addresses, CIDR ranges and Fastify's named sets", () => {
      expect(parseTrustedProxies("10.0.0.0/8, 172.16.0.0/12")).toEqual(["10.0.0.0/8", "172.16.0.0/12"]);
      expect(parseTrustedProxies("192.168.1.1")).toEqual(["192.168.1.1"]);
      expect(parseTrustedProxies("::1")).toEqual(["::1"]);
      expect(parseTrustedProxies("2001:db8::/32")).toEqual(["2001:db8::/32"]);
      // Named sets are `proxy-addr`'s own documented shorthand; refusing them would make this
      // validation narrower than the thing it validates for.
      expect(parseTrustedProxies("loopback,uniquelocal")).toEqual(["loopback", "uniquelocal"]);
    });

    it("still means trust-nothing when empty, as `false` rather than an empty array", () => {
      expect(parseTrustedProxies("")).toBe(false);
      expect(parseTrustedProxies("   ")).toBe(false);
      expect(loadConfig({ ...base }).trustProxy).toBe(false);
    });

    it("refuses a malformed entry with a ConfigError that NAMES it", () => {
      // Naming the entry is the point: there is no fixing a list without knowing which element is
      // bad, and a proxy address — unlike every other value this file refuses to echo — is not a
      // secret.
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(/not-an-ip/);
      expect(() => parseTrustedProxies("10.0.0.0/8,not-an-ip")).toThrow(/TRUSTED_PROXIES/);
    });

    it("refuses a prefix that is not a prefix for that address family", () => {
      // `10.0.0.0/64` is not a v4 network, and `proxy-addr` would say so at a moment nobody is
      // watching. Both families are checked against their own width rather than one shared bound.
      expect(() => parseTrustedProxies("10.0.0.0/64")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/abc")).toThrow(ConfigError);
      expect(() => parseTrustedProxies("10.0.0.0/")).toThrow(ConfigError);
      expect(parseTrustedProxies("2001:db8::/64")).toEqual(["2001:db8::/64"]);
    });

    it("fails at loadConfig, so a bad value is a startup refusal rather than a crash later", () => {
      expect(() => loadConfig({ ...base, TRUSTED_PROXIES: "10.0.0.0/8,garbage" })).toThrow(ConfigError);
      // The whole hazard was the failure arriving from somewhere else entirely. This asserts the
      // error is ours, by type and by the variable it names.
      expect(() => loadConfig({ ...base, TRUSTED_PROXIES: "garbage" })).toThrow(/TRUSTED_PROXIES/);
    });
  });
});
