import { afterEach, describe, expect, it, vi } from "vitest";
import {
  makeCerebrasTextAdapter,
  messagesWithSchemaSuffix,
  normalizedPlanText,
  schemaPromptSuffix,
  stableSchemaText,
  type CerebrasSettings,
} from "../src/model/cerebras.js";
import {
  ProviderRejected,
  ProviderUnavailable,
  type TextRequest,
} from "../src/model/upstream.js";

/**
 * The Cerebras adapter (SONNY-132) — the open-weights planner, moved off the Mac.
 *
 * What is being pinned is the *port*: `CerebrasPlanner` and `CerebrasChatResponseParser` in
 * `MacAgentCore` are deleted in the same change, and everything they did that mattered has to keep
 * happening on this side. Three things did: the schema goes in the system prompt (native structured
 * output cannot carry ours — the 5,000-character cap was re-verified live on 2026-08-13), a wrapping
 * markdown fence is stripped before the text reaches the client, and Chat Completions' own
 * `prompt_tokens` / `completion_tokens` spelling is read as usage.
 */

const settings: CerebrasSettings = {
  keys: ["csk-test-key", "csk-test-older"],
  baseUrl: "https://cerebras.invalid/v1",
  textModel: "test-cerebras-model",
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
    responseSchema: { type: "object", additionalProperties: false },
    reasoningEffort: "medium",
    verbosity: "low",
    signal: new AbortController().signal,
    ...overrides,
  };
}

const reply = (content: string, extra: Record<string, unknown> = {}) =>
  jsonResponse({ choices: [{ message: { content } }], ...extra });

const sentMessages = (call: StubbedCall) =>
  call.body["messages"] as { role: string; content: string }[];

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("the request Cerebras receives", () => {
  it("posts Chat Completions with the gateway's own credential and the configured model", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeCerebrasTextAdapter(settings)(request());
    const call = calls[0]!;
    expect(call.url).toBe("https://cerebras.invalid/v1/chat/completions");
    expect(call.method).toBe("POST");
    expect(call.headers["authorization"]).toBe("Bearer csk-test-key");
    expect(call.body["model"]).toBe("test-cerebras-model");
  });

  it("sends no response_format — the schema goes in the prompt, which is the measured answer", async () => {
    // `CerebrasPlanner`'s doc recorded the live re-check: the native schema cap is 5,000 characters,
    // ours serializes past it, and since 2026-07-21 the limits are strictly enforced, so sending
    // one is a validation error rather than a silent degradation.
    const calls = stubUpstream(() => reply("{}"));
    await makeCerebrasTextAdapter(settings)(request());
    expect("response_format" in calls[0]!.body).toBe(false);
  });

  it("appends the schema to the first system message and leaves every user message alone", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeCerebrasTextAdapter(settings)(
      request({
        messages: [
          { role: "system", text: "SYSTEM ONE" },
          { role: "user", text: "UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END" },
          { role: "system", text: "SYSTEM TWO" },
          { role: "user", text: "Open Safari" },
        ],
        responseSchema: { type: "object" },
      }),
    );
    const messages = sentMessages(calls[0]!);
    expect(messages.map((message) => message.role)).toEqual(["system", "user", "system", "user"]);
    expect(messages[0]!.content).toBe("SYSTEM ONE" + schemaPromptSuffix({ type: "object" }));
    // The second system message and both user messages are byte-identical to what arrived. §4.2's
    // "never edits, re-wraps or re-orders" is about the text carrying row I's boundaries, and every
    // one of those is a user message.
    expect(messages[1]!.content).toBe("UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END");
    expect(messages[2]!.content).toBe("SYSTEM TWO");
    expect(messages[3]!.content).toBe("Open Safari");
  });

  it("prepends a system message when the client sent none, rather than dropping the schema", async () => {
    const calls = stubUpstream(() => reply("{}"));
    await makeCerebrasTextAdapter(settings)(
      request({ messages: [{ role: "user", text: "Open Safari" }], responseSchema: { a: 1 } }),
    );
    const messages = sentMessages(calls[0]!);
    expect(messages).toHaveLength(2);
    expect(messages[0]!.role).toBe("system");
    expect(messages[0]!.content).toBe(schemaPromptSuffix({ a: 1 }).trimStart());
    expect(messages[1]!).toEqual({ role: "user", content: "Open Safari" });
  });

  it("forwards reasoning_effort when the client sent one, and nothing when it did not", async () => {
    const calls = stubUpstream(() => reply("{}"));
    const adapter = makeCerebrasTextAdapter(settings);
    await adapter(request({ reasoningEffort: "high" }));
    await adapter(request({ reasoningEffort: undefined }));
    expect(calls[0]!.body["reasoning_effort"]).toBe("high");
    expect("reasoning_effort" in calls[1]!.body).toBe(false);
  });
});

describe("the schema suffix", () => {
  it("carries the instruction the Swift planner sent, word for word", () => {
    const suffix = schemaPromptSuffix({ type: "object" });
    expect(suffix).toBe(
      "\n\nYour reply must be exactly one JSON object conforming to this JSON Schema — " +
        "no markdown fences, no commentary, nothing before or after it:\n" +
        '{"type":"object"}',
    );
  });

  it("serializes deterministically, so the same schema is the same prompt every run", () => {
    // Sorted keys at every depth, for `CerebrasPlanner.schemaJSONText`'s own reason: a prompt that
    // reordered itself between processes would defeat prompt caching and make a golden untestable.
    const one = stableSchemaText({ b: 1, a: { d: 2, c: 3 } });
    const two = stableSchemaText({ a: { c: 3, d: 2 }, b: 1 });
    expect(one).toBe(two);
    expect(one).toBe('{"a":{"c":3,"d":2},"b":1}');
  });

  it("falls back to an empty object rather than throwing on a schema it cannot serialize", () => {
    const cyclic: Record<string, unknown> = {};
    cyclic["self"] = cyclic;
    expect(stableSchemaText(cyclic)).toBe("{}");
  });

  it("touches exactly one message and returns the rest by identity", () => {
    const messages = [
      { role: "system", text: "S" },
      { role: "user", text: "U" },
    ] as const;
    const result = messagesWithSchemaSuffix(messages, { type: "object" });
    expect(result[1]).toBe(messages[1]);
  });
});

describe("normalizedPlanText", () => {
  it("unwraps a fenced object, with or without a language tag", () => {
    expect(normalizedPlanText('```json\n{"summary":"Open Safari."}\n```')).toBe(
      '{"summary":"Open Safari."}',
    );
    expect(normalizedPlanText('```\n{"summary":"Open Safari."}\n```')).toBe(
      '{"summary":"Open Safari."}',
    );
    expect(normalizedPlanText('  ```json\n{"a":1}\n```  ')).toBe('{"a":1}');
  });

  it("leaves an unfenced object exactly as it arrived", () => {
    expect(normalizedPlanText('{"summary":"Open Safari."}')).toBe('{"summary":"Open Safari."}');
    expect(normalizedPlanText('  {"a":1}  ')).toBe('{"a":1}');
  });

  it("hands a lone fence line on unmodified, for the client's decoder to reject", () => {
    expect(normalizedPlanText("```")).toBe("```");
    expect(normalizedPlanText("```json")).toBe("```json");
  });

  it("strips only the wrapper — anything else malformed still reaches the decoder", () => {
    expect(normalizedPlanText("```json\nnot json at all\n```")).toBe("not json at all");
  });

  it("is applied to the reply, so the client sees the same JSON whichever provider served", async () => {
    stubUpstream(() => reply('```json\n{"summary":"Open Safari."}\n```'));
    const result = await makeCerebrasTextAdapter(settings)(request());
    expect(result.outputText).toBe('{"summary":"Open Safari."}');
  });
});

describe("the reply the seam returns", () => {
  it("reads Chat Completions' own usage spelling", async () => {
    // `prompt_tokens` / `completion_tokens`, not `input_tokens` / `output_tokens`. The shared reader
    // in `upstream.ts` accepts both, matching `AIUsagePayloadParser.tokenCounts` on the Mac.
    stubUpstream(() =>
      reply('{"summary":"ok"}', {
        usage: { prompt_tokens: 120, completion_tokens: 30, total_tokens: 150 },
      }),
    );
    const result = await makeCerebrasTextAdapter(settings)(request());
    expect(result.usage).toEqual({
      inputTokens: 120,
      outputTokens: 30,
      totalTokens: 150,
      audioDurationSeconds: null,
      source: "reported",
    });
  });

  it("estimates from the messages actually sent, suffix included", async () => {
    stubUpstream(() => reply("12345678"));
    const result = await makeCerebrasTextAdapter(settings)(request());
    expect(result.usage.source).toBe("estimated");
    expect(result.usage.outputTokens).toBe(2);
    // The suffix is real bytes the provider was charged for, so the estimate counts it: the input
    // estimate exceeds what the client's own two messages alone would produce.
    const clientOnly =
      Math.ceil("You plan a tiny macOS agent.".length / 4) + Math.ceil("Open Safari".length / 4);
    expect(result.usage.inputTokens!).toBeGreaterThan(clientOnly);
  });

  it("rejects a body with no message content, and an empty one, without a raw parse error", async () => {
    for (const body of [{}, { choices: [] }, { choices: [{ message: {} }] }]) {
      stubUpstream(() => jsonResponse(body));
      await expect(makeCerebrasTextAdapter(settings)(request())).rejects.toThrow(
        "cerebras answered without message content",
      );
      vi.unstubAllGlobals();
    }
  });

  it("rejects a reply that is nothing but a fence, once the wrapper is gone", async () => {
    stubUpstream(() => reply("```json\n\n```"));
    await expect(makeCerebrasTextAdapter(settings)(request())).rejects.toBeInstanceOf(
      ProviderRejected,
    );
  });

  it("maps 5xx to unavailable so the router can fail over, and 4xx to rejected", async () => {
    stubUpstream(() => jsonResponse({ error: "overloaded" }, 503));
    await expect(makeCerebrasTextAdapter(settings)(request())).rejects.toBeInstanceOf(
      ProviderUnavailable,
    );
    vi.unstubAllGlobals();
    stubUpstream(() => jsonResponse({ error: "bad key" }, 401));
    await expect(makeCerebrasTextAdapter(settings)(request())).rejects.toBeInstanceOf(
      ProviderRejected,
    );
  });
});
