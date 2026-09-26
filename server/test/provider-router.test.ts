import { Writable } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { ConfigError, loadConfig, providers, type Config } from "../src/config.js";
import { describeRouting, modelProvidersFrom } from "../src/model/providers.js";
import {
  DEFAULT_ROUTE_CHAINS,
  meetsZeroRetentionBar,
  modelRoutes,
  parseRouteChain,
  providerDataPolicies,
  withFailover,
} from "../src/model/provider-router.js";
import { ProviderRejected, ProviderTimedOut, ProviderUnavailable } from "../src/model/upstream.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { transcriptionBody } from "./support/multipart.js";
import { accessTokenFor } from "./support/tokens.js";
import { signedInConnectionTo } from "./support/connection.js";
import { WithoutOAuth } from "./support/without-oauth.js";

/**
 * The provider-agnostic router: chains, failover, and per-provider data policy (SONNY-132).
 *
 * Three layers, tested at three depths on purpose. `parseRouteChain` and `withFailover` are pure and
 * are driven directly, because that is the only way to reach an aborted signal or a chain of three.
 * `modelProvidersFrom` is driven with real adapters and `fetch` stubbed at the boundary, because the
 * thing worth asserting is which vendor endpoint a *configuration* reaches. And what is about a
 * running server — the response naming no provider, and the log line saying who served — goes
 * through `app.inject` on `POST /v1/transcriptions`, the one routed call the Mac still makes.
 *
 * **Every route now has exactly one provider with an adapter** (transcription: OpenAI; search:
 * Tavily), so no valid configuration can fail a served request over to a second vendor. The
 * combinator that would is still the one both routes go through, and it is held here directly.
 *
 * `.invalid` hostnames come from `testConfig`. RFC 2606 reserves the TLD and it resolves nowhere, so
 * a stub that fails to intercept produces a DNS failure rather than a real request to a real vendor.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";

class UnusedAuthProvider extends WithoutOAuth implements AuthProvider {
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

const signedInConnection = signedInConnectionTo({ account: ACCOUNT, where: "from a model route" });

/** Every provider credentialled, so a chain is only ever shortened by configuration. */
function allProviders(overrides: Partial<Config> = {}): Config {
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
  return buildApp(
    allProviders(overrides),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    // SONNY-135's check runs on every authenticated route and is Postgres-backed, so a suite
    // with no database injects the fake store `support/entitlement.ts` documents. It answers
    // "admitted" and records what it was asked; what the cap actually does is proved against a
    // real Postgres in `entitlement.db.test.ts`.
    { entitlementStore: fakeEntitlementStore() },
  );
}

/**
 * Every line this app logs, parsed (PR #143, F3).
 *
 * pino writes to fd 1 through `sonic-boom`, which `process.stdout.write` never sees, so reading a
 * log line needs the destination handed in. `buildApp`'s optional `logStream` is that, and its own
 * doc records why: three mutants on the recording half survived a twenty-mutant battery, and the
 * acceptance criterion those two behaviours serve had nothing asserting it.
 */
class CapturedLog extends Writable {
  readonly lines: Record<string, unknown>[] = [];

  override _write(chunk: Buffer | string, _encoding: unknown, done: () => void): void {
    for (const line of String(chunk).split("\n")) {
      if (line.trim() === "") continue;
      try {
        this.lines.push(JSON.parse(line) as Record<string, unknown>);
      } catch {
        // A non-JSON line is not a log record this test can read; the assertions below name the
        // record they want, so a line nobody can parse fails them rather than passing silently.
      }
    }
    done();
  }

  withMessage(message: string): Record<string, unknown>[] {
    return this.lines.filter((line) => line["msg"] === message);
  }
}

/** `build`, with the log captured and the level low enough to carry a `debug` line. */
function buildLogging(overrides: Partial<Config> = {}): {
  app: ReturnType<typeof buildApp>;
  log: CapturedLog;
} {
  const log = new CapturedLog();
  const app = buildApp(
    allProviders({ logLevel: "debug", ...overrides }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    { logStream: log, entitlementStore: fakeEntitlementStore() },
  );
  return { app, log };
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

/** One recording, sent to `/v1/transcriptions` the way the Mac sends it. */
function transcribe(app: ReturnType<typeof buildApp>) {
  const body = transcriptionBody(
    { task_id: "task-1", retention: "standard" },
    Buffer.from("fake-audio-bytes"),
  );
  return app.inject({
    method: "POST",
    url: "/v1/transcriptions",
    headers: { authorization: authorization(), "content-type": body.contentType },
    payload: body.payload,
  });
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

/** An OpenAI transcription reply and a Tavily search reply, each shaped as its vendor answers. */
const transcriptionReply = (text: string) => jsonResponse({ text });
const searchReply = () =>
  jsonResponse({ results: [{ title: "Swift", url: "https://swift.org", content: "The language" }] });

const transcriptionRequest = () => ({
  audio: Buffer.from("fake-audio-bytes"),
  filename: "voice.m4a",
  contentType: "audio/mp4",
  signal: new AbortController().signal,
});
const searchRequest = () => ({
  query: "swift",
  maxResults: 5,
  signal: new AbortController().signal,
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("MODEL_ROUTE_* chains", () => {
  it("names exactly the two routes whose provider is configuration", () => {
    // Written out, so a route added or removed has to be written here too. Planning, research and
    // screen steps are the agents' own model calls inside a task, chosen by `AGENT_MODEL_*`.
    expect([...modelRoutes]).toEqual(["transcriptions", "search"]);
    expect(Object.keys(DEFAULT_ROUTE_CHAINS).sort()).toEqual(["search", "transcriptions"]);
  });

  it("defaults every route to the shipped chain when the variable is unset, empty or blank", () => {
    for (const raw of [undefined, "", "   "]) {
      expect(parseRouteChain("transcriptions", raw)).toEqual(["openai"]);
      expect(parseRouteChain("search", raw)).toEqual(["tavily"]);
    }
  });

  it("parses a value case-insensitively and trimmed, ignoring empty entries", () => {
    expect(parseRouteChain("transcriptions", " OpenAI ")).toEqual(["openai"]);
    expect(parseRouteChain("search", "TAVILY ,")).toEqual(["tavily"]);
  });

  it("refuses a provider this gateway does not know, naming the variable and the entry", () => {
    expect(() => parseRouteChain("transcriptions", "openai,mistral")).toThrow(ConfigError);
    try {
      parseRouteChain("transcriptions", "openai,mistral");
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect((error as Error).message).toContain("MODEL_ROUTE_TRANSCRIPTIONS");
      expect((error as Error).message).toContain('"mistral"');
      expect((error as Error).message).toContain("openai, anthropic, cerebras, tavily.");
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
    expect(() => parseRouteChain("transcriptions", "tavily")).toThrow(ConfigError);
  });

  it("refuses a repeated entry", () => {
    try {
      parseRouteChain("transcriptions", "openai,OpenAI");
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect((error as Error).message).toContain("MODEL_ROUTE_TRANSCRIPTIONS");
      expect((error as Error).message).toContain("more than once");
    }
  });

  it("reaches Config through loadConfig, and a bad value is a startup failure", () => {
    const config = loadConfig({ SONNY_ENV: "local", MODEL_ROUTE_TRANSCRIPTIONS: " OPENAI " });
    expect(config.routeChains.transcriptions).toEqual(["openai"]);
    // Untouched variables keep the shipped default rather than inheriting the one that was set.
    expect(config.routeChains.search).toEqual(["tavily"]);
    expect(() => loadConfig({ SONNY_ENV: "local", MODEL_ROUTE_SEARCH: "openai" })).toThrow(
      ConfigError,
    );
  });

  it("starts a deployment whose environment still sets V1's deleted variables", () => {
    // An operator's environment written for V1 still carries the text-route chains, the vision
    // provider's settings and the content clock. Nothing reads them now, so they must neither stop
    // the gateway starting nor reach a chain, a credential or a data policy.
    const config = loadConfig({
      SONNY_ENV: "local",
      MODEL_ROUTE_PLAN: "cerebras,openai",
      MODEL_ROUTE_SYNTHESIZE: "anthropic",
      VISION_API_KEY: "not-a-real-key",
      VISION_DATA_RETENTION: "30 days",
      VISION_BASE_URL: "https://vision.invalid/v1",
      CONTENT_RETENTION_DAYS: "0",
      OPENAI_TEXT_MODEL: "a-v1-model",
    });
    expect(Object.keys(config.routeChains).sort()).toEqual(["search", "transcriptions"]);
    expect(config.routeChains).toEqual(DEFAULT_ROUTE_CHAINS);
    expect(config.credentials).toEqual([]);
    expect(Object.keys(config.dataPolicies).sort()).toEqual(["anthropic", "cerebras", "openai", "tavily"]);
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
  it("sends a transcription to the vendor endpoint its chain names, and says who served", async () => {
    const calls = stubUpstream(() => transcriptionReply("Open Safari"));
    const result = await modelProvidersFrom(allProviders()).transcription!(transcriptionRequest());
    expect(calls.map((call) => call.url)).toEqual(["https://openai.invalid/v1/audio/transcriptions"]);
    expect(result.text).toBe("Open Safari");
    expect(result.served).toEqual({ provider: "openai", failedOver: [] });
  });

  it("routes search on its own chain, independently of transcription", async () => {
    // The agent's `web_search` tool reaches Tavily through this, with the gateway's key; the same
    // configuration's transcription call reaches OpenAI. Neither route borrows the other's chain.
    const calls = stubUpstream((call) =>
      call.url.includes("search") ? searchReply() : transcriptionReply("Open Safari"),
    );
    const providersFor = modelProvidersFrom(allProviders());
    const found = await providersFor.search!(searchRequest());
    await providersFor.transcription!(transcriptionRequest());
    expect(calls.map((call) => call.url)).toEqual([
      "https://search.invalid/search",
      "https://openai.invalid/v1/audio/transcriptions",
    ]);
    expect(calls[0]!.headers["authorization"]).toBe("Bearer tvly-test-search-key");
    expect(found.items).toEqual([{ title: "Swift", url: "https://swift.org", snippet: "The language" }]);
    expect(found.served).toEqual({ provider: "tavily", failedOver: [] });
  });

  it("drops a chain entry this deployment holds no credential for, route by route", async () => {
    // Search's only entry has a key and transcription's does not, so one route is served and the
    // other is absent — it is not "tried and failed", and nothing is sent for it.
    const calls = stubUpstream(() => searchReply());
    const providersFor = modelProvidersFrom(
      testConfig({ credentials: [{ provider: "tavily", keys: ["tvly-test-search-key"] }] }),
    );
    expect(providersFor.transcription).toBeUndefined();
    const found = await providersFor.search!(searchRequest());
    expect(calls).toHaveLength(1);
    expect(found.served).toEqual({ provider: "tavily", failedOver: [] });
  });

  it("is undefined for a route whose every chain entry lacks a credential", () => {
    const providersFor = modelProvidersFrom(testConfig({ credentials: [] }));
    expect(providersFor.transcription).toBeUndefined();
    expect(providersFor.search).toBeUndefined();
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
      providerDataPolicies({ TAVILY_DATA_RETENTION: "30 days" });
      expect.unreachable("expected a ConfigError");
    } catch (error) {
      expect(error).toBeInstanceOf(ConfigError);
      expect((error as Error).message).toContain("TAVILY_DATA_RETENTION");
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
    expect(description.routes).toEqual({
      transcriptions: ["openai"],
      search: ["tavily (no credential)"],
    });
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
        allProviders({
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

describe("through a running server", () => {
  it("answers a routed request with no provider and no model in the response", async () => {
    // §4.2: "The response names no provider and no model." Asserted on the raw payload rather than
    // on named fields, because a field nobody thought to check would carry it just as far.
    const calls = stubUpstream(() => transcriptionReply("Open Safari"));
    const app = build();
    const response = await transcribe(app);

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(1);
    expect(response.json().text).toBe("Open Safari");
    const raw = response.body.toLowerCase();
    for (const vendor of [
      "openai",
      "anthropic",
      "cerebras",
      "tavily",
      "whisper",
      "gpt-",
      "claude",
      "test-transcription-model",
    ]) {
      expect(raw).not.toContain(vendor);
    }
    await app.close();
  });
});

describe("what the server records about who served (SONNY-132's third acceptance criterion)", () => {
  /**
   * **Three mutants survived a twenty-mutant battery and all three were here** (PR #143, F3):
   * `recordServingProvider`'s body removed, the provider it records hard-coded, and `app.ts`'s
   * `model routing` line deleted. `result.served` was pinned six ways; the two places it becomes
   * visible to a human were pinned zero ways — the half of the acceptance criterion that says "the
   * recorded metering says which provider actually served it", and the line every `deploy.sh`
   * demonstration reads.
   */
  it("records the provider that served an ordinary request, at debug, under the route's name", async () => {
    stubUpstream(() => transcriptionReply("Open Safari"));
    const { app, log } = buildLogging();
    await transcribe(app);

    const served = log.withMessage("model route served");
    expect(served).toHaveLength(1);
    expect(served[0]!["route"]).toBe("transcription");
    expect(served[0]!["provider"]).toBe("openai");
    expect(served[0]!["failedOver"]).toEqual([]);
    // `debug`, not `warn`: the ordinary path is every request that has ever worked.
    expect(served[0]!["level"]).toBe(20);
    expect(log.withMessage("model route served after failover")).toHaveLength(0);
    // §2.3 makes `Sonny-Request-Id` the one string a user can be asked to quote for support, and
    // §11 joins the metering event on it. A record naming the provider but not the request is not
    // a record SONNY-133 can use, so the line has to carry the request id it was logged under.
    expect(typeof served[0]!["reqId"]).toBe("string");
    await app.close();
  });

  /**
   * The startup line, which is the only surface the retention/training field is observable on and
   * the line every `deploy.sh` demonstration reads. Deleting it survived the suite.
   */
  it("says what this deployment's routing resolved to, once, at startup", async () => {
    const { app, log } = buildLogging({
      // No search key, so the line has to read the credentials rather than restate the defaults.
      credentials: [
        { provider: "openai", keys: ["sk-test-openai-key"] },
        { provider: "anthropic", keys: ["sk-ant-test-key"] },
        { provider: "cerebras", keys: ["csk-test-key"] },
      ],
      dataPolicies: {
        ...providerDataPolicies({}),
        openai: { retention: "none", training: "none" },
      },
    });
    await app.ready();

    const routing = log.withMessage("model routing");
    expect(routing).toHaveLength(1);
    expect(routing[0]!["routes"]).toEqual({
      transcriptions: ["openai"],
      search: ["tavily (no credential)"],
    });
    const openai = (routing[0]!["providers"] as Record<string, unknown>[]).find(
      (entry) => entry["provider"] === "openai",
    );
    expect(openai).toMatchObject({
      configured: true,
      retention: "none",
      training: "none",
      meetsZeroRetentionBar: true,
    });
    // The same no-credential assertion `describeRouting`'s own test makes, on the bytes that
    // actually reach a log collector.
    const rendered = JSON.stringify(routing[0]);
    expect(rendered).not.toContain("sk-");
    expect(rendered).not.toContain("tvly-");
    expect(rendered).not.toContain("csk-");
    await app.close();
  });
});
