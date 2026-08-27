import type pg from "pg";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { ConfigError, loadConfig, providers, type Config } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import { describeRouting, modelProvidersFrom } from "../src/model/providers.js";
import {
  DEFAULT_ROUTE_CHAINS,
  meetsZeroRetentionBar,
  parseRouteChain,
  providerDataPolicies,
  withFailover,
} from "../src/model/provider-router.js";
import { ProviderRejected, ProviderTimedOut, ProviderUnavailable } from "../src/model/upstream.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * The provider-agnostic router: chains, failover, and per-provider data policy (SONNY-132).
 *
 * Three layers, tested at three depths on purpose. `parseRouteChain` and `withFailover` are pure and
 * are driven directly, because that is the only way to reach an aborted signal or a chain of three.
 * `modelProvidersFrom` is driven with real adapters and `fetch` stubbed at the boundary, because the
 * thing worth asserting is which vendor endpoint a *configuration* reaches. And the two acceptance
 * criteria that are about a running server — a provider swap with no client change, and a failover
 * the client cannot see — go through `app.inject`, so the gate, the deadlines and the response
 * shape are all in the picture.
 *
 * `.invalid` hostnames come from `testConfig`. RFC 2606 reserves the TLD and it resolves nowhere, so
 * a stub that fails to intercept produces a DNS failure rather than a real request to a real vendor.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";

class UnusedAuthProvider implements AuthProvider {
  async sendEmailCode() {
    return { providerRequestId: undefined };
  }
  async verifyEmailCode(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async refresh(): Promise<VerifiedSession> {
    throw new Error("not used here");
  }
  async signOut() {}
  async userFromAccessToken(): Promise<string> {
    throw new Error("not used here");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

const signedInConnection: WithConnection = async (work) => {
  const client = {
    query: async (text: string) => {
      if (!text.includes("FROM sonny.identity")) {
        throw new Error(`unexpected query from a model route: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

/** Both text providers credentialled, so a chain is only ever shortened by configuration. */
function bothProviders(overrides: Partial<Config> = {}): Config {
  return testConfig({
    credentials: [
      { provider: "openai", keys: ["sk-test-openai-key"] },
      { provider: "anthropic", keys: ["sk-ant-test-key"] },
      { provider: "cerebras", keys: ["csk-test-key"] },
      { provider: "tavily", keys: ["tvly-test-search-key"] },
    ],
    ...overrides,
  });
}

function build(overrides: Partial<Config> = {}) {
  return buildApp(bothProviders(overrides), {
    provider: new UnusedAuthProvider(),
    withConnection: signedInConnection,
  });
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

function planBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    task_id: "task-1",
    retention: "standard",
    messages: [
      { role: "system", text: "You plan a tiny macOS agent." },
      { role: "user", text: "Open Safari" },
    ],
    response_schema_name: "agent_plan",
    response_schema: { type: "object", additionalProperties: false },
    reasoning_effort: "medium",
    ...overrides,
  };
}

interface StubbedCall {
  url: string;
  headers: Record<string, string>;
  body: unknown;
}

function stubUpstream(respond: (call: StubbedCall) => Response | Promise<Response>): StubbedCall[] {
  const calls: StubbedCall[] = [];
  vi.stubGlobal("fetch", async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    let body: unknown = undefined;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body);
      } catch {
        body = init.body;
      }
    }
    const call: StubbedCall = { url: String(input), headers, body };
    calls.push(call);
    return respond(call);
  });
  return calls;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** An OpenAI Responses reply and an Anthropic Messages reply, each shaped as its vendor answers. */
const openAIReply = (text: string) => jsonResponse({ output_text: text });
const anthropicReply = (text: string) =>
  jsonResponse({ content: [{ type: "text", text }], stop_reason: "end_turn" });

const textRequest = {
  messages: [{ role: "user", text: "Open Safari" }] as const,
  responseSchemaName: "agent_plan",
  responseSchema: { type: "object" },
  reasoningEffort: undefined,
  verbosity: undefined,
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("MODEL_ROUTE_* chains", () => {
  it("defaults every route to the shipped chain when the variable is unset, empty or blank", () => {
    for (const raw of [undefined, "", "   "]) {
      expect(parseRouteChain("plan", raw)).toEqual(["openai", "anthropic"]);
      expect(parseRouteChain("synthesize", raw)).toEqual(["openai", "anthropic"]);
      expect(parseRouteChain("transcriptions", raw)).toEqual(["openai"]);
      expect(parseRouteChain("search", raw)).toEqual(["tavily"]);
    }
  });

  it("keeps OpenAI first on the shipped text chains, which is what 'no flip logic' means here", () => {
    // The ticket's never-touch list keeps the default planner a founder decision. Failover reaches
    // the second entry only after the first has failed *this* request, so the primary is OpenAI on
    // every request and nothing in the code can change that — only configuration can.
    expect(DEFAULT_ROUTE_CHAINS.plan[0]).toBe("openai");
    expect(DEFAULT_ROUTE_CHAINS.synthesize[0]).toBe("openai");
  });

  it("parses an ordered list, case-insensitively and trimmed", () => {
    expect(parseRouteChain("plan", " Anthropic , OPENAI ,cerebras ")).toEqual([
      "anthropic",
      "openai",
      "cerebras",
    ]);
  });

  it("refuses a provider this gateway does not know, naming the variable and the entry", () => {
    expect(() => parseRouteChain("plan", "openai,mistral")).toThrow(ConfigError);
    try {
      parseRouteChain("plan", "openai,mistral");
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect((error as Error).message).toContain("MODEL_ROUTE_PLAN");
      expect((error as Error).message).toContain('"mistral"');
      expect((error as Error).message).toContain("openai, anthropic, cerebras, tavily, vision");
    }
  });

  it("refuses a known provider that has no adapter for that route rather than dropping it", () => {
    // Anthropic serves no transcription API. Dropping the entry silently would leave an operator
    // believing they had configured a failover candidate they do not have.
    try {
      parseRouteChain("transcriptions", "openai,anthropic");
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect((error as Error).message).toContain("MODEL_ROUTE_TRANSCRIPTIONS");
      expect((error as Error).message).toContain('"anthropic"');
      expect((error as Error).message).toContain("Providers that can serve it: openai");
    }
    expect(() => parseRouteChain("search", "tavily,openai")).toThrow(ConfigError);
    expect(() => parseRouteChain("plan", "openai,tavily")).toThrow(ConfigError);
  });

  it("refuses a repeated entry", () => {
    try {
      parseRouteChain("plan", "openai,anthropic,openai");
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect((error as Error).message).toContain("more than once");
    }
  });

  it("reaches Config through loadConfig, and a bad value is a startup failure", () => {
    const config = loadConfig({ SONNY_ENV: "local", MODEL_ROUTE_PLAN: "cerebras,openai" });
    expect(config.routeChains.plan).toEqual(["cerebras", "openai"]);
    // Untouched variables keep the shipped default rather than inheriting the one that was set.
    expect(config.routeChains.synthesize).toEqual(["openai", "anthropic"]);
    expect(() => loadConfig({ SONNY_ENV: "local", MODEL_ROUTE_SEARCH: "openai" })).toThrow(
      ConfigError,
    );
  });
});

describe("withFailover", () => {
  const signal = () => new AbortController().signal;

  it("is undefined for an empty chain, so the route answers 502 provider.unavailable", () => {
    expect(withFailover([])).toBeUndefined();
  });

  it("returns the first candidate's result and names it, with nothing failed over", async () => {
    const routed = withFailover([
      { provider: "openai", call: async () => ({ value: "first" }) },
      { provider: "anthropic", call: async () => ({ value: "second" }) },
    ]);
    const result = await routed!({ signal: signal() });
    expect(result.value).toBe("first");
    expect(result.served).toEqual({ provider: "openai", failedOver: [] });
  });

  it("falls over on ProviderUnavailable and records the order it tried", async () => {
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          throw new ProviderUnavailable("openai answered 503");
        },
      },
      {
        provider: "anthropic",
        call: async () => {
          throw new ProviderUnavailable("anthropic answered 429");
        },
      },
      { provider: "cerebras", call: async () => ({ value: "third" }) },
    ]);
    const result = await routed!({ signal: signal() });
    expect(result.value).toBe("third");
    expect(result.served).toEqual({
      provider: "cerebras",
      failedOver: ["openai", "anthropic"],
    });
  });

  it("does NOT fail over on ProviderRejected — a refusal is about the request, not the provider", async () => {
    let secondCalled = false;
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          throw new ProviderRejected("openai refused");
        },
      },
      {
        provider: "anthropic",
        call: async () => {
          secondCalled = true;
          return { value: "second" };
        },
      },
    ]);
    await expect(routed!({ signal: signal() })).rejects.toBeInstanceOf(ProviderRejected);
    expect(secondCalled).toBe(false);
  });

  it("does NOT fail over on ProviderTimedOut — the chain shares one deadline", async () => {
    let secondCalled = false;
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          throw new ProviderTimedOut("openai ran out of time");
        },
      },
      {
        provider: "anthropic",
        call: async () => {
          secondCalled = true;
          return { value: "second" };
        },
      },
    ]);
    await expect(routed!({ signal: signal() })).rejects.toBeInstanceOf(ProviderTimedOut);
    expect(secondCalled).toBe(false);
  });

  it("rethrows anything untyped untouched, so the route still answers a 500 with a stack", async () => {
    const bug = new TypeError("undefined is not a function");
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          throw bug;
        },
      },
      { provider: "anthropic", call: async () => ({ value: "second" }) },
    ]);
    await expect(routed!({ signal: signal() })).rejects.toBe(bug);
  });

  it("stops when the shared signal has already aborted rather than opening another request", async () => {
    // The route's deadline aborted mid-chain. A second attempt would fail before it opened a
    // socket, and starting one would push the handler past §12's total deadline.
    const controller = new AbortController();
    let secondCalled = false;
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          controller.abort();
          throw new ProviderUnavailable("openai answered 503");
        },
      },
      {
        provider: "anthropic",
        call: async () => {
          secondCalled = true;
          return { value: "second" };
        },
      },
    ]);
    await expect(routed!({ signal: controller.signal })).rejects.toBeInstanceOf(ProviderUnavailable);
    expect(secondCalled).toBe(false);
  });

  it("throws the LAST error when every candidate fails, not the first", async () => {
    const last = new ProviderUnavailable("anthropic answered 500");
    const routed = withFailover([
      {
        provider: "openai",
        call: async () => {
          throw new ProviderUnavailable("openai answered 503");
        },
      },
      {
        provider: "anthropic",
        call: async () => {
          throw last;
        },
      },
    ]);
    await expect(routed!({ signal: signal() })).rejects.toBe(last);
  });
});

describe("modelProvidersFrom", () => {
  it("sends a plan to whichever vendor endpoint the chain names first", async () => {
    const openAICalls = stubUpstream(() => openAIReply("{}"));
    const openAIFirst = modelProvidersFrom(bothProviders());
    const first = await openAIFirst.plan!({ ...textRequest, signal: new AbortController().signal });
    expect(openAICalls[0]!.url).toBe("https://openai.invalid/v1/responses");
    expect(first.served).toEqual({ provider: "openai", failedOver: [] });
    vi.unstubAllGlobals();

    const anthropicCalls = stubUpstream(() => anthropicReply("{}"));
    const anthropicFirst = modelProvidersFrom(
      bothProviders({ routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["anthropic", "openai"] } }),
    );
    const second = await anthropicFirst.plan!({
      ...textRequest,
      signal: new AbortController().signal,
    });
    expect(anthropicCalls[0]!.url).toBe("https://anthropic.invalid/v1/messages");
    expect(second.served).toEqual({ provider: "anthropic", failedOver: [] });
  });

  it("routes the two text routes independently", async () => {
    const calls = stubUpstream((call) =>
      call.url.includes("anthropic") ? anthropicReply("{}") : openAIReply("{}"),
    );
    const providersFor = modelProvidersFrom(
      bothProviders({
        routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["openai"], synthesize: ["anthropic"] },
      }),
    );
    await providersFor.plan!({ ...textRequest, signal: new AbortController().signal });
    await providersFor.synthesize!({ ...textRequest, signal: new AbortController().signal });
    expect(calls.map((call) => call.url)).toEqual([
      "https://openai.invalid/v1/responses",
      "https://anthropic.invalid/v1/messages",
    ]);
  });

  it("drops a chain entry this deployment holds no credential for", async () => {
    const calls = stubUpstream(() => anthropicReply("{}"));
    const providersFor = modelProvidersFrom(
      testConfig({
        credentials: [{ provider: "anthropic", keys: ["sk-ant-test-key"] }],
        routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["openai", "anthropic"] },
      }),
    );
    const result = await providersFor.plan!({
      ...textRequest,
      signal: new AbortController().signal,
    });
    // OpenAI is first in the chain and has no key, so it is not a candidate at all — it is not
    // "tried and failed", and `failedOver` says so.
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://anthropic.invalid/v1/messages");
    expect(result.served).toEqual({ provider: "anthropic", failedOver: [] });
  });

  it("is undefined for a route whose every chain entry lacks a credential", () => {
    const providersFor = modelProvidersFrom(testConfig({ credentials: [] }));
    expect(providersFor.plan).toBeUndefined();
    expect(providersFor.synthesize).toBeUndefined();
    expect(providersFor.transcription).toBeUndefined();
    expect(providersFor.search).toBeUndefined();
  });

  it("falls over from a 503 primary to the second provider and says who served", async () => {
    // The acceptance criterion, at the layer that composes real adapters: the primary fails, the
    // request still succeeds, and what is recorded names the provider that actually served it.
    const calls = stubUpstream((call) =>
      call.url.includes("openai")
        ? jsonResponse({ error: "overloaded" }, 503)
        : anthropicReply('{"summary":"Open Safari."}'),
    );
    const providersFor = modelProvidersFrom(bothProviders());
    const result = await providersFor.plan!({
      ...textRequest,
      signal: new AbortController().signal,
    });
    expect(calls.map((call) => call.url)).toEqual([
      "https://openai.invalid/v1/responses",
      "https://anthropic.invalid/v1/messages",
    ]);
    expect(result.outputText).toBe('{"summary":"Open Safari."}');
    expect(result.served).toEqual({ provider: "anthropic", failedOver: ["openai"] });
  });
});

describe("per-provider retention and training configuration", () => {
  it("defaults every provider to unknown on both axes", () => {
    const policies = providerDataPolicies({});
    for (const provider of providers) {
      expect(policies[provider]).toEqual({ retention: "unknown", training: "unknown" });
    }
  });

  it("reads a declared value per provider, case-insensitively", () => {
    const policies = providerDataPolicies({
      OPENAI_DATA_RETENTION: "None",
      OPENAI_TRAINING: "none",
      ANTHROPIC_DATA_RETENTION: "retains",
      CEREBRAS_TRAINING: "RESERVED",
    });
    expect(policies.openai).toEqual({ retention: "none", training: "none" });
    expect(policies.anthropic).toEqual({ retention: "retains", training: "unknown" });
    expect(policies.cerebras).toEqual({ retention: "unknown", training: "reserved" });
    expect(policies.tavily).toEqual({ retention: "unknown", training: "unknown" });
  });

  it("refuses a value outside the set, naming the variable", () => {
    try {
      providerDataPolicies({ VISION_DATA_RETENTION: "30 days" });
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect(error).toBeInstanceOf(ConfigError);
      expect((error as Error).message).toContain("VISION_DATA_RETENTION");
      expect((error as Error).message).toContain("unknown, none, retains");
    }
  });

  it("needs BOTH halves to clear SONNY-110's bar, and unknown is never none", () => {
    expect(meetsZeroRetentionBar({ retention: "none", training: "none" })).toBe(true);
    // Retains nothing but may train on it: training is one of retention's own named purposes, so
    // this does not protect the content. SONNY-110's requirement widened on 2026-08-16 for this.
    expect(meetsZeroRetentionBar({ retention: "none", training: "reserved" })).toBe(false);
    expect(meetsZeroRetentionBar({ retention: "retains", training: "none" })).toBe(false);
    // Unverified fails, which is the safe direction and why `unknown` is the default.
    expect(meetsZeroRetentionBar({ retention: "unknown", training: "none" })).toBe(false);
    expect(meetsZeroRetentionBar({ retention: "none", training: "unknown" })).toBe(false);
  });

  it("reaches Config, so the values a deployment sets are the values the router reports", () => {
    const config = loadConfig({
      SONNY_ENV: "local",
      ANTHROPIC_DATA_RETENTION: "none",
      ANTHROPIC_TRAINING: "none",
    });
    expect(config.dataPolicies.anthropic).toEqual({ retention: "none", training: "none" });
    expect(config.dataPolicies.openai).toEqual({ retention: "unknown", training: "unknown" });
  });
});

describe("describeRouting", () => {
  it("reports the chains, marks entries with no credential, and carries the policies", () => {
    const description = describeRouting(
      testConfig({
        credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }],
        dataPolicies: {
          ...providerDataPolicies({}),
          openai: { retention: "none", training: "none" },
        },
      }),
    );
    expect(description.routes.plan).toEqual(["openai", "anthropic (no credential)"]);
    expect(description.routes.search).toEqual(["tavily (no credential)"]);
    const openai = description.providers.find((entry) => entry.provider === "openai");
    expect(openai).toEqual({
      provider: "openai",
      configured: true,
      retention: "none",
      training: "none",
      meetsZeroRetentionBar: true,
    });
    const anthropic = description.providers.find((entry) => entry.provider === "anthropic");
    expect(anthropic?.configured).toBe(false);
    expect(anthropic?.meetsZeroRetentionBar).toBe(false);
  });

  it("carries no credential and no fragment of one", () => {
    // This is logged at startup, so the assertion is on the rendered bytes rather than on the
    // fields: a key that reached it through a field nobody thought about would still be a leak.
    const rendered = JSON.stringify(
      describeRouting(
        bothProviders({
          credentials: [
            { provider: "openai", keys: ["sk-test-openai-key", "sk-test-openai-older"] },
            { provider: "anthropic", keys: ["sk-ant-test-key"] },
          ],
        }),
      ),
    );
    expect(rendered).not.toContain("sk-test-openai-key");
    expect(rendered).not.toContain("sk-test-openai-older");
    expect(rendered).not.toContain("sk-ant-test-key");
    expect(rendered).not.toContain("sk-");
  });
});

describe("the acceptance criteria, through a running server", () => {
  it("serves the same plan request from OpenAI or from Anthropic by configuration alone", async () => {
    // The first acceptance criterion. One request body, sent twice, byte-identical. Nothing about
    // the client changes; only `MODEL_ROUTE_PLAN` does.
    const body = planBody();

    const openAICalls = stubUpstream(() => openAIReply('{"summary":"Planned by the first."}'));
    const openAIApp = build({ routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["openai"] } });
    const openAIResponse = await openAIApp.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: body,
    });
    expect(openAIResponse.statusCode).toBe(200);
    expect(openAIResponse.json().output_text).toBe('{"summary":"Planned by the first."}');
    expect(openAICalls.map((call) => call.url)).toEqual(["https://openai.invalid/v1/responses"]);
    await openAIApp.close();
    vi.unstubAllGlobals();

    const anthropicCalls = stubUpstream(() =>
      anthropicReply('{"summary":"Planned by the second."}'),
    );
    const anthropicApp = build({ routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["anthropic"] } });
    const anthropicResponse = await anthropicApp.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: body,
    });
    expect(anthropicResponse.statusCode).toBe(200);
    expect(anthropicResponse.json().output_text).toBe('{"summary":"Planned by the second."}');
    expect(anthropicCalls.map((call) => call.url)).toEqual([
      "https://anthropic.invalid/v1/messages",
    ]);
    await anthropicApp.close();
  });

  it("succeeds through a failover, and the response names no provider and no model", async () => {
    const calls = stubUpstream((call) =>
      call.url.includes("openai")
        ? jsonResponse({ error: "overloaded" }, 503)
        : anthropicReply('{"summary":"Open Safari."}'),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(2);
    expect(response.json().output_text).toBe('{"summary":"Open Safari."}');

    // §4.2: "The response names no provider and no model." Asserted on the raw payload rather than
    // on named fields, because a field nobody thought to check would carry it just as far.
    const raw = response.body.toLowerCase();
    for (const vendor of ["openai", "anthropic", "cerebras", "tavily", "gpt-", "claude"]) {
      expect(raw).not.toContain(vendor);
    }
    await app.close();
  });

  it("answers 502 provider.unavailable when every provider in the chain fails", async () => {
    stubUpstream(() => jsonResponse({ error: "overloaded" }, 503));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });
    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.unavailable");
    expect(response.json().error.retryable).toBe(true);
    await app.close();
  });

  it("does not try the second provider when the first refuses the request", async () => {
    const calls = stubUpstream(() => jsonResponse({ error: "bad request" }, 400));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });
    expect(calls).toHaveLength(1);
    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.rejected");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it("serves a plan from Cerebras when the chain names it, with no client change", async () => {
    // The ticket's second acceptance criterion, server half: Cerebras is reachable the same way
    // every other provider is, as a configuration entry rather than an environment variable on the
    // user's own Mac.
    const calls = stubUpstream(() =>
      jsonResponse({ choices: [{ message: { content: '{"summary":"Open Safari."}' } }] }),
    );
    const app = build({ routeChains: { ...DEFAULT_ROUTE_CHAINS, plan: ["cerebras"] } });
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });
    expect(response.statusCode).toBe(200);
    expect(calls[0]!.url).toBe("https://cerebras.invalid/v1/chat/completions");
    expect(response.json().output_text).toBe('{"summary":"Open Safari."}');
    await app.close();
  });
});
