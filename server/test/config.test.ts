import { describe, expect, it } from "vitest";
import {
  ConfigError,
  acceptedKeys,
  activeKey,
  loadConfig,
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
});
