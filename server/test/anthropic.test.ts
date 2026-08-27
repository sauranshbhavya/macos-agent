import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ANTHROPIC_VERSION,
  makeAnthropicTextAdapter,
  prunedSchema,
  type AnthropicSettings,
} from "../src/model/anthropic.js";
import {
  ProviderRejected,
  ProviderTimedOut,
  ProviderUnavailable,
  type TextRequest,
} from "../src/model/upstream.js";

/**
 * The Anthropic adapter (SONNY-132) — the second real provider spec §16.5 asked for.
 *
 * **Against a stub, and the live half is a founder's.** `fetch` is stubbed at the boundary the same
 * way SONNY-130's OpenAI tests stub it, so what is asserted is what the *provider* receives and what
 * the *seam* returns. That covers the wire shape, the structured-output mapping, the schema pruning
 * and every failure translation. What it cannot cover is whether `api.anthropic.com` accepts the
 * body, which needs a real key: no key was exported in this session's shell, so the live round is
 * recorded as owed rather than claimed. `.invalid` resolves nowhere, so a stub that failed to
 * intercept would produce a DNS failure rather than a real request to a real vendor.
 */

const settings: AnthropicSettings = {
  keys: ["sk-ant-test-key", "sk-ant-test-older"],
  baseUrl: "https://anthropic.invalid/v1",
  textModel: "test-anthropic-model",
  maxOutputTokens: 4096,
};

interface StubbedCall {
  url: string;
  method: string | undefined;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

function stubUpstream(respond: () => Response | Promise<Response> | never): StubbedCall[] {
  const calls: StubbedCall[] = [];
  vi.stubGlobal("fetch", async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    calls.push({
      url: String(input),
      method: init?.method,
      headers,
      body: typeof init?.body === "string" ? JSON.parse(init.body) : {},
    });
    return respond();
  });
  return calls;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function request(overrides: Partial<TextRequest> = {}): TextRequest {
  return {
    messages: [
      { role: "system", text: "You plan a tiny macOS agent." },
      { role: "user", text: "Open Safari" },
    ],
    responseSchemaName: "agent_plan",
    responseSchema: { type: "object", additionalProperties: false, properties: {} },
    reasoningEffort: "medium",
    verbosity: "low",
    signal: new AbortController().signal,
    ...overrides,
  };
}

const reply = (text: string, extra: Record<string, unknown> = {}) =>
  jsonResponse({ content: [{ type: "text", text }], stop_reason: "end_turn", ...extra });

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("the request Anthropic receives", () => {
  it("posts to /messages with the gateway's own credential and the required version header", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(request());

    const call = calls[0]!;
    expect(call.url).toBe("https://anthropic.invalid/v1/messages");
    expect(call.method).toBe("POST");
    // `x-api-key`, not a bearer token — this vendor's own scheme. Index 0 of the credential list,
    // never a later one: the rotation in `config.ts` keeps older keys accepted, not sent.
    expect(call.headers["x-api-key"]).toBe("sk-ant-test-key");
    expect(call.headers["authorization"]).toBeUndefined();
    expect(call.headers["anthropic-version"]).toBe(ANTHROPIC_VERSION);
    expect(ANTHROPIC_VERSION).toBe("2023-06-01");
    expect(call.body["model"]).toBe("test-anthropic-model");
  });

  it("sends max_tokens, which this API requires and has no default for", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(request());
    expect(calls[0]!.body["max_tokens"]).toBe(4096);
  });

  it("puts system text in the system field and user text in messages, in order and unedited", async () => {
    // §4.2's hard requirement: the server forwards the text and never edits, re-wraps or re-orders
    // it, because it carries row I's TRUSTED_USER_INSTRUCTION / UNTRUSTED_OBSERVED_CONTENT
    // boundaries. This API takes system content in its own field, so the split is structural; every
    // byte of every message survives it and the user messages keep their order.
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(
      request({
        messages: [
          { role: "system", text: "SYSTEM ONE" },
          { role: "user", text: "UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END" },
          { role: "system", text: "SYSTEM TWO" },
          { role: "user", text: "Open Safari" },
        ],
      }),
    );
    const call = calls[0]!;
    expect(call.body["system"]).toBe("SYSTEM ONE\n\nSYSTEM TWO");
    expect(call.body["messages"]).toEqual([
      { role: "user", content: [{ type: "text", text: "UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END" }] },
      { role: "user", content: [{ type: "text", text: "Open Safari" }] },
    ]);
  });

  it("omits the system field entirely when the client sent no system message", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(
      request({ messages: [{ role: "user", text: "Open Safari" }] }),
    );
    expect("system" in calls[0]!.body).toBe(false);
  });

  it("maps response_schema onto output_config.format, which is this provider's mechanism", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(
      request({ responseSchema: { type: "object", required: ["summary"] } }),
    );
    expect(calls[0]!.body["output_config"]).toEqual({
      effort: "medium",
      format: {
        type: "json_schema",
        schema: { type: "object", required: ["summary"], additionalProperties: false },
      },
    });
  });

  it("forwards a recognised reasoning_effort and drops one it does not recognise", async () => {
    // §4.2 makes both hints advisory. This provider has an equivalent for effort, so it is passed
    // through when it matches — and dropped rather than forwarded when it does not, because an
    // unrecognised value is a 400 on a request a user is waiting on.
    const calls = stubUpstream(() => reply("{}"));
    const adapter = makeAnthropicTextAdapter(settings);
    await adapter(request({ reasoningEffort: "xhigh" }));
    await adapter(request({ reasoningEffort: "ludicrous" }));
    await adapter(request({ reasoningEffort: undefined }));

    const effortOf = (index: number) =>
      (calls[index]!.body["output_config"] as Record<string, unknown>)["effort"];
    expect(effortOf(0)).toBe("xhigh");
    expect(effortOf(1)).toBeUndefined();
    expect(effortOf(2)).toBeUndefined();
  });

  it("sends no verbosity and no schema name, because this mechanism takes neither", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeAnthropicTextAdapter(settings)(request({ verbosity: "low" }));
    expect(JSON.stringify(calls[0]!.body)).not.toContain("verbosity");
    expect(JSON.stringify(calls[0]!.body)).not.toContain("agent_plan");
  });

  it("refuses a request with no user message rather than sending a body the API will reject", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await expect(
      makeAnthropicTextAdapter(settings)(
        request({ messages: [{ role: "system", text: "SYSTEM ONLY" }] }),
      ),
    ).rejects.toBeInstanceOf(ProviderRejected);
    expect(calls).toHaveLength(0);
  });
});

describe("prunedSchema", () => {
  it("removes the planner schema's own minItems, which would otherwise 400 every plan", () => {
    // Not a hypothetical: `AgentPlanSchema.schema()` puts `minItems: 1` on `steps`, and structured
    // outputs reject complex array constraints. Unpruned, every single plan request would fail.
    const pruned = prunedSchema({
      type: "object",
      additionalProperties: false,
      properties: {
        steps: { type: "array", minItems: 1, items: { type: "object", properties: {} } },
      },
    }) as Record<string, unknown>;
    const steps = (pruned["properties"] as Record<string, unknown>)["steps"] as Record<
      string,
      unknown
    >;
    expect("minItems" in steps).toBe(false);
    expect(steps["type"]).toBe("array");
  });

  it("removes every unsupported keyword, at any depth, inside arrays too", () => {
    const pruned = prunedSchema({
      type: "object",
      properties: {
        count: { type: "integer", minimum: 1, maximum: 9, multipleOf: 3 },
        name: { type: "string", minLength: 1, maxLength: 8, pattern: "^a" },
        tags: { type: "array", maxItems: 4, uniqueItems: true },
      },
      anyOf: [{ type: "object", minProperties: 1, properties: {} }],
    });
    const rendered = JSON.stringify(pruned);
    for (const keyword of [
      "minimum",
      "maximum",
      "multipleOf",
      "minLength",
      "maxLength",
      "pattern",
      "maxItems",
      "uniqueItems",
      "minProperties",
    ]) {
      expect(rendered).not.toContain(keyword);
    }
  });

  it("keeps the keywords this mechanism supports", () => {
    const pruned = prunedSchema({
      type: "object",
      required: ["operation"],
      properties: {
        operation: { type: "string", enum: ["open_url", "clarify"] },
        when: { type: "string", format: "date-time" },
        target: { anyOf: [{ type: "string" }, { type: "null" }] },
      },
    }) as Record<string, unknown>;
    const properties = pruned["properties"] as Record<string, Record<string, unknown>>;
    expect(pruned["required"]).toEqual(["operation"]);
    expect(properties["operation"]!["enum"]).toEqual(["open_url", "clarify"]);
    expect(properties["when"]!["format"]).toBe("date-time");
    expect(properties["target"]!["anyOf"]).toEqual([{ type: "string" }, { type: "null" }]);
  });

  it("forces additionalProperties false on every object node, which this mechanism requires", () => {
    const pruned = prunedSchema({
      type: "object",
      properties: { nested: { type: "object", additionalProperties: true, properties: {} } },
    }) as Record<string, unknown>;
    expect(pruned["additionalProperties"]).toBe(false);
    const nested = (pruned["properties"] as Record<string, Record<string, unknown>>)["nested"]!;
    expect(nested["additionalProperties"]).toBe(false);
  });

  it("leaves a non-object schema alone", () => {
    expect(prunedSchema("not a schema")).toBe("not a schema");
    expect(prunedSchema(null)).toBe(null);
    expect(prunedSchema([1, 2])).toEqual([1, 2]);
  });
});

describe("the reply the seam returns", () => {
  it("returns the first text block and the provider's reported usage", async () => {
    stubUpstream(() =>
      reply('{"summary":"Open Safari."}', { usage: { input_tokens: 42, output_tokens: 18 } }),
    );
    const result = await makeAnthropicTextAdapter(settings)(request());
    expect(result.outputText).toBe('{"summary":"Open Safari."}');
    expect(result.usage).toEqual({
      inputTokens: 42,
      outputTokens: 18,
      // This provider reports no total. It stays null rather than being summed here: `source` says
      // "reported", and a number this server added is not one the provider reported.
      totalTokens: null,
      audioDurationSeconds: null,
      source: "reported",
    });
  });

  it("skips a thinking block and returns the text one", async () => {
    stubUpstream(() =>
      jsonResponse({
        content: [
          { type: "thinking", thinking: "The user wants Safari opened." },
          { type: "text", text: '{"summary":"Open Safari."}' },
        ],
        stop_reason: "end_turn",
      }),
    );
    const result = await makeAnthropicTextAdapter(settings)(request());
    expect(result.outputText).toBe('{"summary":"Open Safari."}');
  });

  it("estimates usage when the provider reported none, and labels it estimated", async () => {
    stubUpstream(() => reply("12345678"));
    const result = await makeAnthropicTextAdapter(settings)(request());
    expect(result.usage.source).toBe("estimated");
    // Four characters to a token, agreeing with `AIUsageEstimator.estimateTextTokens` on the Mac.
    expect(result.usage.outputTokens).toBe(2);
    expect(result.usage.inputTokens).toBe(
      Math.ceil("You plan a tiny macOS agent.".length / 4) + Math.ceil("Open Safari".length / 4),
    );
    expect(result.usage.totalTokens).toBe(result.usage.inputTokens! + result.usage.outputTokens!);
  });
});

describe("failure translation", () => {
  it("maps 429 and 5xx to unavailable, so the router fails over", async () => {
    for (const status of [429, 500, 503]) {
      stubUpstream(() => jsonResponse({ error: "nope" }, status));
      await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toBeInstanceOf(
        ProviderUnavailable,
      );
      vi.unstubAllGlobals();
    }
  });

  it("maps 400 and 401 to rejected, so the router does not fail over", async () => {
    for (const status of [400, 401, 403]) {
      stubUpstream(() => jsonResponse({ error: "nope" }, status));
      await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toBeInstanceOf(
        ProviderRejected,
      );
      vi.unstubAllGlobals();
    }
  });

  it("maps 408 and 504 to timed out", async () => {
    for (const status of [408, 504]) {
      stubUpstream(() => jsonResponse({ error: "slow" }, status));
      await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toBeInstanceOf(
        ProviderTimedOut,
      );
      vi.unstubAllGlobals();
    }
  });

  it("never puts the provider's own error body into the thrown message", async () => {
    // §7.1 makes `message` a field the support lookup reads, and a provider error body can carry
    // the request back verbatim — which on these routes is the user's own command.
    stubUpstream(() => jsonResponse({ error: { message: "Open Safari and delete my files" } }, 400));
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toThrow(
      /^anthropic answered 400$/,
    );
  });

  it("treats a refusal as rejected rather than as an outage", async () => {
    stubUpstream(() => jsonResponse({ content: [], stop_reason: "refusal" }));
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toThrow(
      "anthropic declined this request",
    );
  });

  it("treats hitting the output ceiling as rejected, not as a truncated answer to decode", async () => {
    // A body cut off at `max_tokens` is half a JSON object. Handing it on would fail the client's
    // strict decode with a parse error that says nothing about why, and a retry hits the same
    // ceiling — which is exactly what `rejected` means.
    stubUpstream(() => reply('{"summary":"Open Saf', { stop_reason: "max_tokens" }));
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toThrow(
      "anthropic stopped at the output ceiling",
    );
  });

  it("treats a 2xx with no text block as rejected", async () => {
    stubUpstream(() => jsonResponse({ content: [{ type: "thinking", thinking: "hm" }] }));
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toThrow(
      "anthropic answered without text output",
    );
  });

  it("maps an aborted fetch to timed out and a dead network to unavailable", async () => {
    vi.stubGlobal("fetch", async () => {
      throw new DOMException("aborted", "AbortError");
    });
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toBeInstanceOf(
      ProviderTimedOut,
    );
    vi.unstubAllGlobals();

    vi.stubGlobal("fetch", async () => {
      throw new TypeError("fetch failed");
    });
    await expect(makeAnthropicTextAdapter(settings)(request())).rejects.toBeInstanceOf(
      ProviderUnavailable,
    );
  });
});
