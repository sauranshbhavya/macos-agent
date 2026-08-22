import { describe, expect, it } from "vitest";
import {
  ConfigError,
  MIN_JWT_SECRET_LENGTH,
  acceptedKeys,
  activeKey,
  loadConfig,
  parseTrustedProxies,
  providerCredentials,
  requireSupabaseJwtPolicy,
} from "../src/config.js";

const base = { SONNY_ENV: "local" } as NodeJS.ProcessEnv;

// Bound to names rather than written inline at each call site, so that no line in this file spells a
// known-secret variable followed by a long literal -- which is the shape `npm run check:secrets`
// refuses, correctly, wherever it appears.
const secret = "a-signing-key-long-enough-to-clear-the-floor";
const issuer = "https://project-ref.supabase.co/auth/v1";

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

  describe("the Supabase JWT policy", () => {
    // **What replaced `ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE`** (SONNY-203). That flag, its production
    // refusal and the four tests that pinned them are gone with the reason they existed: nothing
    // verified a token, so a destructive route had to be kept off by default. Verification exists
    // now, and these are the variables it needs. The flag's tests are not ported — there is no flag
    // to keep off, which is the outcome that ticket was for.

    it("carries the three values through, defaulting the audience to Supabase's own", () => {
      const config = loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: issuer });
      expect(config.supabaseJwtSecret).toBe(secret);
      expect(config.supabaseJwtIssuer).toBe(issuer);
      expect(config.supabaseJwtAudience).toBe("authenticated");
      expect(requireSupabaseJwtPolicy(config))
        .toEqual({ secret, issuer, audience: "authenticated" });
    });

    it("takes a non-default audience when the project uses one", () => {
      const config = loadConfig({
        ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: issuer,
        SUPABASE_JWT_AUDIENCE: "sonny-users",
      });
      expect(requireSupabaseJwtPolicy(config).audience).toBe("sonny-users");
    });

    it("LOADS without them, because a deployment mounting no authenticated route needs neither", () => {
      // Same split as RATE_LIMIT_SALT: absent is fine at load, and refused at the point of use.
      const config = loadConfig({ ...base });
      expect(config.supabaseJwtSecret).toBeUndefined();
      expect(() => requireSupabaseJwtPolicy(config)).toThrow(ConfigError);
    });

    it("names EVERY missing variable, not the first one", () => {
      // An operator who fixes the named one and restarts to find a second failure has spent a deploy
      // learning something one message could have said.
      try {
        requireSupabaseJwtPolicy(loadConfig({ ...base }));
        expect.unreachable("should have thrown");
      } catch (error) {
        expect((error as Error).message).toContain("SUPABASE_JWT_SECRET");
        expect((error as Error).message).toContain("SUPABASE_JWT_ISSUER");
      }
      expect(() => requireSupabaseJwtPolicy(loadConfig({ ...base, SUPABASE_JWT_ISSUER: issuer })))
        .toThrow(/SUPABASE_JWT_SECRET/);
    });

    it("refuses a secret short enough to guess, and reports the length without the value", () => {
      // Anyone holding this secret can MINT a token for any user, so a guessable one is a forgery
      // key rather than a weak password. Supabase's own is far longer than the floor.
      const short = "0123456789abcdef";
      try {
        requireSupabaseJwtPolicy(
          loadConfig({ ...base, SUPABASE_JWT_SECRET: short, SUPABASE_JWT_ISSUER: issuer }),
        );
        expect.unreachable("should have thrown");
      } catch (error) {
        const message = (error as Error).message;
        expect(message).toContain(String(MIN_JWT_SECRET_LENGTH));
        expect(message).toContain("16 characters");
        expect(message).not.toContain(short);
      }
      // One character under the floor is refused; the floor itself is not.
      const floor = "x".repeat(MIN_JWT_SECRET_LENGTH);
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: floor.slice(1), SUPABASE_JWT_ISSUER: issuer }),
      )).toThrow(ConfigError);
      expect(requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: floor, SUPABASE_JWT_ISSUER: issuer }),
      ).secret).toBe(floor);
    });

    it("refuses an issuer that is not a URL, and says so with the value", () => {
      // The issuer is a public URL naming the project, not a secret — and a mismatch is otherwise
      // invisible, since every token verifies against the secret and is then refused. That reads as
      // "all my users are signed out" rather than as a typo in one variable.
      for (const bad of ["project-ref", "project-ref.supabase.co", "/auth/v1", "ftp://x/auth"]) {
        expect(() => requireSupabaseJwtPolicy(
          loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: bad }),
        )).toThrow(ConfigError);
      }
      expect(() => requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: "project-ref" }),
      )).toThrow(/project-ref/);
    });

    it("accepts the local Supabase's http issuer, so development is not forced onto https", () => {
      const local = "http://127.0.0.1:54321/auth/v1";
      expect(requireSupabaseJwtPolicy(
        loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_ISSUER: local }),
      ).issuer).toBe(local);
    });

    it("refuses an empty or whitespace-only value rather than treating it as absent", () => {
      for (const blank of ["", "   "]) {
        expect(() => loadConfig({ ...base, SUPABASE_JWT_SECRET: blank, SUPABASE_JWT_ISSUER: issuer }))
          .toThrow(ConfigError);
        expect(() => loadConfig({ ...base, SUPABASE_JWT_SECRET: secret, SUPABASE_JWT_AUDIENCE: blank }))
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

    it("refuses a /0 prefix, which is how someone writes trust-everything", () => {
      // **PR #87 sixth round.** `@fastify/proxy-addr` refuses a full-range prefix, so `/0` passed
      // this validator and then threw `TypeError: invalid range on address: 0.0.0.0/0` inside the
      // `Fastify(...)` constructor — the exact failure this validator exists to prevent, reached
      // through the validator itself. And it is not an exotic typo: `/0` is what an operator writes
      // when they are looking for the old boolean `true`.
      for (const entry of ["0.0.0.0/0", "10.0.0.0/0", "1.2.3.4/0", "::/0", "::1/0", "fe80::/0", "0.0.0.0/00"]) {
        expect(() => parseTrustedProxies(entry), entry).toThrow(ConfigError);
      }
      // The message has to say why, or the operator retries the same idea in another spelling.
      expect(() => parseTrustedProxies("0.0.0.0/0")).toThrow(/trust every proxy/);
      // Everything adjacent still compiles — this is a refusal of /0, not of small prefixes.
      expect(parseTrustedProxies("0.0.0.0/1")).toEqual(["0.0.0.0/1"]);
      expect(parseTrustedProxies("::/1")).toEqual(["::/1"]);
      expect(parseTrustedProxies("10.0.0.0/008")).toEqual(["10.0.0.0/008"]);
    });

    it("accepts NOTHING that Fastify itself cannot compile", async () => {
      // **The assertion that catches this class without knowing which entry is the problem.** The
      // `/0` test above pins the case we now know about; this one pins the *property* — whatever
      // this validator lets through, `proxy-addr`'s `compile()` must accept, and that runs inside
      // the `Fastify(...)` constructor where a throw is unreachable by any error handler.
      //
      // Written as "for each candidate: if the validator accepts it, the app must build" rather
      // than as a list of known-good values. That is the difference between a test that confirms
      // what we already fixed and one that would have found it: relaxing the validator makes a
      // candidate below start passing, and then the build throws and this fails.
      const { buildApp } = await import("../src/app.js");
      const candidates = [
        "10.0.0.0/8,172.16.0.0/12", "192.168.1.1", "::1", "2001:db8::/32", "loopback,uniquelocal",
        "0.0.0.0/1", "10.0.0.0/008",
        // The shapes a looser validator would start admitting. Each is currently refused; if any
        // stops being refused, it has to be one Fastify can compile.
        "0.0.0.0/0", "10.0.0.0/0", "::/0", "fe80::/0", "0.0.0.0/00",
        "10.0.0.0/64", "10.0.0.0/abc", "not-an-ip", "10.0.0.0/",
      ];
      let accepted = 0;
      for (const raw of candidates) {
        let parsed;
        try {
          parsed = loadConfig({ SONNY_ENV: "local", TRUSTED_PROXIES: raw });
        } catch {
          continue;                       // refused by the validator, which is a fine outcome
        }
        accepted += 1;
        expect(() => buildApp(parsed), raw).not.toThrow();
      }
      // And the loop is not vacuous: some of them really do get through.
      expect(accepted).toBe(7);
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
