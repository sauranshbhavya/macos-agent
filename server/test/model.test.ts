import type pg from "pg";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import { BODY_LIMIT_BYTES, DEADLINE_MS, MAXIMUM_AUDIO_DURATION_SECONDS } from "../src/model/limits.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * The four credential-bearing routes SONNY-130 moved behind this gateway.
 *
 * **Every test here drives the real app through `inject`, with `fetch` stubbed at the boundary.**
 * That is deliberate and it is what makes these tests worth the reading: the thing being asserted is
 * mostly what the *provider* receives and what the *client* receives, and a test that called an
 * adapter function directly would skip the gate, the body limits, the deadline wrapper, the schema
 * and the error mapping — which is where all four of this ticket's requirements actually live.
 *
 * `https://openai.invalid` and `https://search.invalid` come from `testConfig`. `.invalid` is
 * reserved by RFC 2606 and resolves nowhere, so a stub that fails to intercept produces a DNS
 * failure rather than a real request to a real vendor — the difference between a test that breaks
 * and a test that spends money.
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

/**
 * A connection that answers the gate's one attribution query and nothing else.
 *
 * These routes touch no database of their own — metering is SONNY-133's and the content store is
 * SONNY-134's — so anything else reaching this is a route doing something this ticket did not build.
 * It throws rather than returning empty rows, so that would be a red test rather than a silent one.
 */
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

function build(overrides: Partial<Config> = {}) {
  return buildApp(
    testConfig({
      credentials: [
        { provider: "openai", keys: ["sk-test-openai-key", "sk-test-openai-older"] },
        { provider: "tavily", keys: ["tvly-test-search-key"] },
      ],
      ...overrides,
    }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
  );
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

/** The §4.2 body, complete. Individual tests drop or bend exactly one field. */
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
    verbosity: "low",
    ...overrides,
  };
}

interface StubbedCall {
  url: string;
  method: string | undefined;
  headers: Record<string, string>;
  body: unknown;
  rawBody: RequestInit["body"];
}

/**
 * Stub `fetch` and record every upstream call.
 *
 * The recorded `headers` are lower-cased, because a `Headers` object is case-insensitive and an
 * assertion that depended on the case the adapter happened to write would pass for the wrong reason.
 */
function stubUpstream(
  respond: (call: StubbedCall) => Response | Promise<Response> | never,
): StubbedCall[] {
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
    const call: StubbedCall = {
      url: String(input),
      method: init?.method,
      headers,
      body,
      rawBody: init?.body,
    };
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

/** §4.4's two-part body, built the way the Mac builds it. */
function multipartBody(
  meta: unknown,
  audio: Buffer,
  options: { filename?: string; contentType?: string } = {},
): { payload: Buffer; contentType: string } {
  const boundary = "SonnyTestBoundary-cbf29ce484222325";
  const head = Buffer.from(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="meta"\r\n` +
      `Content-Type: application/json\r\n\r\n` +
      `${typeof meta === "string" ? meta : JSON.stringify(meta)}\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="audio"; filename="${options.filename ?? "voice.m4a"}"\r\n` +
      `Content-Type: ${options.contentType ?? "audio/mp4"}\r\n\r\n`,
    "utf8",
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`, "utf8");
  return {
    payload: Buffer.concat([head, audio, tail]),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("POST /v1/plan and POST /v1/research/synthesize", () => {
  it("forwards the client's messages verbatim, in order, with their roles", async () => {
    // §4.2's hard requirement: "The server forwards the text; it never edits, re-wraps or re-orders
    // it." The text carries row I's TRUSTED_USER_INSTRUCTION / UNTRUSTED_OBSERVED_CONTENT
    // boundaries, so a server that reflowed them would dissolve the prompt-injection defence a long
    // way from anywhere anyone would look for it.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody({
        messages: [
          { role: "system", text: "SYSTEM ONE" },
          { role: "user", text: "UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END" },
          { role: "user", text: "Open Safari" },
        ],
      }),
    });

    expect(response.statusCode).toBe(200);
    expect(calls).toHaveLength(1);
    const sent = calls[0]!.body as { input: { role: string; content: { text: string }[] }[] };
    expect(sent.input.map((message) => message.role)).toEqual(["system", "user", "user"]);
    expect(sent.input.map((message) => message.content[0]!.text)).toEqual([
      "SYSTEM ONE",
      "UNTRUSTED_OBSERVED_CONTENT_BEGIN ... END",
      "Open Safari",
    ]);
    await app.close();
  });

  it("sends the gateway's own credential and the configured model, and the client sends neither", async () => {
    // The ticket in one assertion: the credential and the model identifier are the server's, and
    // nothing the client sent could have named either.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    const call = calls[0]!;
    expect(call.url).toBe("https://openai.invalid/v1/responses");
    expect(call.method).toBe("POST");
    // Index 0 of the credential list, never a later one — §rotation in `config.ts`.
    expect(call.headers["authorization"]).toBe("Bearer sk-test-openai-key");
    expect((call.body as { model: string }).model).toBe("test-text-model");
    await app.close();
  });

  it("maps response_schema onto the provider's structured-output mechanism, strictly", async () => {
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody({
        response_schema_name: "agent_plan",
        response_schema: { type: "object", required: ["summary"] },
      }),
    });

    const format = (calls[0]!.body as { text: { format: Record<string, unknown> } }).text.format;
    expect(format).toEqual({
      type: "json_schema",
      name: "agent_plan",
      strict: true,
      schema: { type: "object", required: ["summary"] },
    });
    await app.close();
  });

  it("returns output_text and the provider's reported usage, naming no provider and no model", async () => {
    stubUpstream(() =>
      jsonResponse({
        output_text: "{\"summary\":\"Open Safari.\"}",
        usage: { input_tokens: 42, output_tokens: 18, total_tokens: 60 },
      }),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    const body = response.json() as Record<string, unknown>;
    // §4.2: "The response names no provider and no model." Asserted as an exact key set, in both
    // directions, so a field added later has to be a decision rather than a leak.
    expect(Object.keys(body).sort()).toEqual(["output_text", "request_id", "usage"]);
    expect(body["output_text"]).toBe("{\"summary\":\"Open Safari.\"}");
    expect(body["usage"]).toEqual({
      input_tokens: 42,
      output_tokens: 18,
      total_tokens: 60,
      audio_duration_seconds: null,
      source: "reported",
    });
    expect(JSON.stringify(body).toLowerCase()).not.toContain("openai");
    expect(JSON.stringify(body).toLowerCase()).not.toContain("test-text-model");
    await app.close();
  });

  it("estimates usage and says so when the provider reports none", async () => {
    // §4.2: "The server estimates only when the provider reported nothing, and says which it did."
    // The arithmetic is `AIUsageEstimator`'s — four characters to a token — so a user's local
    // summary does not step when their traffic moves behind the gateway.
    stubUpstream(() => jsonResponse({ output_text: "12345678", usage: null }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody({ messages: [{ role: "user", text: "1234" }] }),
    });

    expect(response.json()["usage"]).toEqual({
      input_tokens: 1,
      output_tokens: 2,
      total_tokens: 3,
      audio_duration_seconds: null,
      source: "estimated",
    });
    await app.close();
  });

  it("reads output_text out of the structured output array when the flat field is absent", async () => {
    stubUpstream(() =>
      jsonResponse({
        output: [{ content: [{ type: "output_text", text: "{\"summary\":\"from the array\"}" }] }],
      }),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.json()["output_text"]).toBe("{\"summary\":\"from the array\"}");
    await app.close();
  });

  it("gives /v1/research/synthesize its own 4 MiB limit, and /v1/plan does not get it", async () => {
    // **The registration line, not the constant** (PR #139, F3). `BODY_LIMIT_BYTES.synthesize` was
    // asserted by the numbers test above, but nothing asserted that the *synthesize route* was
    // registered with it — swapping `BODY_LIMIT_BYTES.synthesize` for `BODY_LIMIT_BYTES.plan` at
    // the `textRoute(...)` call survived the whole suite. §6.1 gives this route 4 MiB precisely
    // because it carries the full readable text of every fetched page, so a route silently
    // inheriting the 1 MiB default would fail exactly the research runs it exists for.
    //
    // One body, two routes, one accepted and one refused: that is the pair the constant cannot say.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    // Comfortably over `plan`'s 1 MiB and comfortably under `synthesize`'s 4 MiB.
    const big = planBody({ messages: [{ role: "user", text: "x".repeat(2_000_000) }] });

    const accepted = await app.inject({
      method: "POST",
      url: "/v1/research/synthesize",
      headers: { authorization: authorization() },
      payload: big,
    });
    expect(accepted.statusCode).toBe(200);

    const refused = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: big,
    });
    expect(refused.statusCode).toBe(413);
    expect(refused.json()["error"]["code"]).toBe("request.too_large");

    // Only the accepted one reached a provider.
    expect(calls).toHaveLength(1);
    await app.close();
  });

  it("lets /v1/transcriptions carry ten times what /v1/search may", async () => {
    // The same shape for the other route that carries an oversized body, so both routes with a
    // ceiling of their own are held by behaviour rather than by a constant.
    //
    // **The two ceilings are enforced by different mechanisms, and this test deliberately asserts
    // neither** (PR #139's G2). `/v1/search` is bounded by its route `bodyLimit`; `/v1/transcriptions`
    // is bounded by `@fastify/multipart`'s `limits.fileSize`, because registering that parser
    // replaces the body parser for its content type and the route's own `bodyLimit` is then not
    // consulted at all — measured, and recorded at the route. What a caller can observe is the pair
    // below: the same number of bytes refused on one route and served on the other.
    stubUpstream(() => jsonResponse({ results: [] }));
    const app = build();

    const refused = await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "x".repeat(2_000_000) },
    });
    expect(refused.statusCode).toBe(413);
    expect(refused.json()["error"]["code"]).toBe("request.too_large");

    // The same number of bytes goes through transcriptions, whose limit is ten times larger.
    vi.unstubAllGlobals();
    stubUpstream(() => jsonResponse({ text: "ok" }));
    const audio = multipartBody({ task_id: "t", retention: "standard" }, Buffer.alloc(2_000_000, 0x41));
    const accepted = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });
    expect(accepted.statusCode).toBe(200);
    await app.close();
  });

  it("serves /v1/research/synthesize with the same body shape and the same provider", async () => {
    const calls = stubUpstream(() => jsonResponse({ output_text: "{\"title\":\"Note\"}" }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/research/synthesize",
      headers: { authorization: authorization() },
      payload: planBody({ response_schema_name: "web_research_note" }),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()["output_text"]).toBe("{\"title\":\"Note\"}");
    expect(calls[0]!.url).toBe("https://openai.invalid/v1/responses");
    await app.close();
  });
});

describe("the fields §2.4 requires on every content-bearing request", () => {
  it("refuses a request with no retention rather than defaulting it either way", async () => {
    // §2.4.2, and the reason it is a rule: default to "standard" and a client that forgets the
    // field silently stores content the user asked not to store; default to "none" and it silently
    // loses the retention the founder decided to have. An omitted privacy field is a loud error.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const body = planBody();
    delete body["retention"];

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: body,
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()["error"]["code"]).toBe("request.invalid");
    // And nothing was sent upstream, so the refusal costs nothing.
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("refuses a retention value that is neither standard nor none", async () => {
    stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody({ retention: "forever" }),
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()["error"]["code"]).toBe("request.invalid");
    await app.close();
  });

  it("refuses a request with no task_id, on all four routes", async () => {
    stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const withoutTaskId = planBody();
    delete withoutTaskId["task_id"];

    for (const url of ["/v1/plan", "/v1/research/synthesize"]) {
      const response = await app.inject({
        method: "POST",
        url,
        headers: { authorization: authorization() },
        payload: withoutTaskId,
      });
      expect(response.statusCode, url).toBe(400);
    }

    const search = await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { retention: "standard", query: "swift" },
    });
    expect(search.statusCode).toBe(400);

    const audio = multipartBody({ retention: "standard" }, Buffer.from("fake-audio"));
    const transcription = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });
    expect(transcription.statusCode).toBe(400);
    await app.close();
  });

  it("refuses an unknown field rather than silently dropping it", async () => {
    // The mirror of §2.1's tolerance rule, which is about *responses*. A request field this server
    // drops in silence is a client believing it asked for something.
    stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody({ model: "gpt-5.5" }),
    });

    expect(response.statusCode).toBe(400);
    await app.close();
  });
});

describe("POST /v1/search", () => {
  it("clamps max_results to §4.3's 1–20 in both directions", async () => {
    const calls = stubUpstream(() => jsonResponse({ results: [] }));
    const app = build();
    for (const requested of [5, 500, 0]) {
      await app.inject({
        method: "POST",
        url: "/v1/search",
        headers: { authorization: authorization() },
        payload: { task_id: "t", retention: "standard", query: "swift", max_results: requested },
      });
    }
    // And the default when the field is absent.
    await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "swift" },
    });

    expect(calls.map((call) => (call.body as { max_results: number }).max_results)).toEqual([
      5, 20, 1, 5,
    ]);
    await app.close();
  });

  it("returns title, url and snippet, and drops entries whose URL is not http(s)", async () => {
    stubUpstream(() =>
      jsonResponse({
        results: [
          { title: "Good", url: "https://example.com/good", content: "kept", score: 0.9 },
          { title: "No snippet", url: "http://example.com/two" },
          { title: "Empty", url: "", content: "dropped" },
          { title: "Not a web URL", url: "ftp://example.com/file", content: "dropped" },
          { title: "Schemeless", url: "just some text", content: "dropped" },
        ],
      }),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "swift", max_results: 5 },
    });

    const body = response.json() as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["request_id", "results"]);
    expect(body["results"]).toEqual([
      { title: "Good", url: "https://example.com/good", snippet: "kept" },
      { title: "No snippet", url: "http://example.com/two", snippet: null },
    ]);
    await app.close();
  });

  it("sends the gateway's search credential to the configured search host", async () => {
    const calls = stubUpstream(() => jsonResponse({ results: [] }));
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "swift" },
    });

    expect(calls[0]!.url).toBe("https://search.invalid/search");
    expect(calls[0]!.headers["authorization"]).toBe("Bearer tvly-test-search-key");
    await app.close();
  });

  it("answers an unreadable provider body with no results rather than a failed task", async () => {
    stubUpstream(() => new Response("<html>not json</html>", { status: 200 }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "swift" },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()["results"]).toEqual([]);
    await app.close();
  });
});

describe("POST /v1/transcriptions", () => {
  it("forwards the audio bytes verbatim and returns the transcript with duration usage", async () => {
    const calls = stubUpstream(() => jsonResponse({ text: " Open Notes ", usage: { type: "duration", seconds: 2.5 } }));
    const app = build();
    const audio = multipartBody(
      { task_id: "task-9", retention: "standard" },
      Buffer.from("fake-audio-bytes"),
    );

    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });

    expect(response.statusCode).toBe(200);
    const body = response.json() as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["request_id", "text", "usage"]);
    expect(body["text"]).toBe("Open Notes");
    expect(body["usage"]).toEqual({
      input_tokens: null,
      output_tokens: null,
      total_tokens: null,
      audio_duration_seconds: 2.5,
      source: "reported",
    });

    expect(calls[0]!.url).toBe("https://openai.invalid/v1/audio/transcriptions");
    expect(calls[0]!.headers["authorization"]).toBe("Bearer sk-test-openai-key");
    const form = calls[0]!.rawBody as FormData;
    expect(form.get("model")).toBe("test-transcription-model");
    const file = form.get("file") as File;
    expect(Buffer.from(await file.arrayBuffer()).toString("utf8")).toBe("fake-audio-bytes");
    await app.close();
  });

  it("returns token usage when the provider reports tokens instead of a duration", async () => {
    stubUpstream(() =>
      jsonResponse({
        text: "Open Safari",
        usage: { type: "tokens", input_tokens: 12, output_tokens: 4, total_tokens: 16 },
      }),
    );
    const app = build();
    const audio = multipartBody({ task_id: "t", retention: "standard" }, Buffer.from("bytes"));
    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });

    expect(response.json()["usage"]).toEqual({
      input_tokens: 12,
      output_tokens: 4,
      total_tokens: 16,
      audio_duration_seconds: null,
      source: "reported",
    });
    await app.close();
  });

  it("refuses a recording over the route's byte ceiling with 413 request.too_large", async () => {
    // The server half of SONNY-130's audio limit. The client's half is a *duration* and refuses
    // long before this — `model/limits.ts` says why the two sides measure different units — so this
    // is the backstop for a client that is not ours, or is broken.
    //
    // **The outcome is what is pinned, not the mechanism.** The guard that actually fires is
    // `@fastify/multipart`'s `limits.fileSize`, raising `FST_REQ_FILE_TOO_LARGE` while the part
    // streams, which `errors.ts` maps on its `status === 413` arm. Two comments at the route have
    // been wrong about that in opposite directions, so this test stays on what a caller sees: the
    // code, the retryability, and that nothing was sent upstream.
    const calls = stubUpstream(() => jsonResponse({ text: "should never be reached" }));
    const app = build();
    const oversized = Buffer.alloc(BODY_LIMIT_BYTES.transcriptions + 1, 0x41);
    const audio = multipartBody({ task_id: "t", retention: "standard" }, oversized);

    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });

    expect(response.statusCode).toBe(413);
    expect(response.json()["error"]["code"]).toBe("request.too_large");
    expect(response.json()["error"]["retryable"]).toBe(false);
    expect(calls).toHaveLength(0);
    await app.close();
  });

  it("refuses a body with no audio part, and one with no meta part", async () => {
    stubUpstream(() => jsonResponse({ text: "should never be reached" }));
    const app = build();

    const noAudio = multipartBody({ task_id: "t", retention: "standard" }, Buffer.alloc(0));
    const withoutAudio = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": noAudio.contentType },
      payload: noAudio.payload,
    });
    expect(withoutAudio.statusCode).toBe(400);
    // The message is asserted, not just the code, because every way this route can fail to read a
    // body answers `400 request.invalid` — so a code-only assertion would pass just as happily if
    // the multipart parse had collapsed and the meta part were never seen at all. It did exactly
    // that once during this ticket's own work.
    expect(withoutAudio.json()["error"]["message"]).toBe(
      "The audio part is required and must not be empty.",
    );

    const boundary = "SonnyTestBoundary-onlyaudio";
    const onlyAudio = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="v.m4a"\r\n` +
          `Content-Type: audio/mp4\r\n\r\n`,
        "utf8",
      ),
      Buffer.from("bytes"),
      Buffer.from(`\r\n--${boundary}--\r\n`, "utf8"),
    ]);
    const withoutMeta = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: {
        authorization: authorization(),
        "content-type": `multipart/form-data; boundary=${boundary}`,
      },
      payload: onlyAudio,
    });
    expect(withoutMeta.statusCode).toBe(400);
    expect(withoutMeta.json()["error"]["code"]).toBe("request.invalid");
    expect(withoutMeta.json()["error"]["message"]).toBe("The meta part is required.");
    await app.close();
  });

  it("refuses a meta part that is not JSON, in either spelling", async () => {
    stubUpstream(() => jsonResponse({ text: "should never be reached" }));
    const app = build();

    // Declared `application/json`, which is what §4.4 specifies: `@fastify/multipart` parses the
    // field itself and throws when it cannot, so the refusal comes from the parser and names the
    // body. **The message differs from the other spelling's and that is asserted rather than
    // smoothed over** — a code-only assertion here passed while the multipart parse was collapsing
    // entirely and this branch was never reached, which is how the defect below was found.
    const declared = multipartBody("not json at all", Buffer.from("bytes"));
    const asDeclaredJSON = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": declared.contentType },
      payload: declared.payload,
    });
    expect(asDeclaredJSON.statusCode).toBe(400);
    expect(asDeclaredJSON.json()["error"]["code"]).toBe("request.invalid");
    expect(asDeclaredJSON.json()["error"]["message"]).toBe(
      "Request body could not be read as multipart/form-data.",
    );

    // Undeclared, so the field arrives as a string and this route parses it. The route's own
    // sentinel branch is what answers, and this is the test that keeps it from rotting unused.
    const boundary = "SonnyTestBoundary-badplainstring";
    const payload = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n` +
          `not json at all\r\n` +
          `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="v.m4a"\r\n` +
          `Content-Type: audio/mp4\r\n\r\n`,
        "utf8",
      ),
      Buffer.from("bytes"),
      Buffer.from(`\r\n--${boundary}--\r\n`, "utf8"),
    ]);
    const asPlainString = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: {
        authorization: authorization(),
        "content-type": `multipart/form-data; boundary=${boundary}`,
      },
      payload,
    });
    expect(asPlainString.statusCode).toBe(400);
    expect(asPlainString.json()["error"]["message"]).toBe("The meta part is not JSON.");
    await app.close();
  });

  it("refuses a meta part whose fields are wrong, distinguishably from one that is not JSON", async () => {
    stubUpstream(() => jsonResponse({ text: "should never be reached" }));
    const app = build();
    const audio = multipartBody({ task_id: "t", retention: "forever" }, Buffer.from("bytes"));
    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()["error"]["message"]).toBe("The meta part failed validation.");
    await app.close();
  });

  it("accepts a meta part sent as a plain string rather than as declared JSON", async () => {
    // `@fastify/multipart` parses a field that declares `application/json` and hands back a string
    // when it does not. Both spellings are the client's to choose and neither is wrong, so both are
    // accepted — and this test is what stops the tolerant branch rotting unused.
    stubUpstream(() => jsonResponse({ text: "Open Notes" }));
    const app = build();
    const boundary = "SonnyTestBoundary-plainstring";
    const payload = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n` +
          `{"task_id":"t","retention":"none"}\r\n` +
          `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="v.m4a"\r\n` +
          `Content-Type: audio/mp4\r\n\r\n`,
        "utf8",
      ),
      Buffer.from("bytes"),
      Buffer.from(`\r\n--${boundary}--\r\n`, "utf8"),
    ]);
    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: {
        authorization: authorization(),
        "content-type": `multipart/form-data; boundary=${boundary}`,
      },
      payload,
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()["text"]).toBe("Open Notes");
    await app.close();
  });

  it("treats an empty transcript as no transcript", async () => {
    stubUpstream(() => jsonResponse({ text: "   \n  " }));
    const app = build();
    const audio = multipartBody({ task_id: "t", retention: "standard" }, Buffer.from("bytes"));
    const response = await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { authorization: authorization(), "content-type": audio.contentType },
      payload: audio.payload,
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.rejected");
    await app.close();
  });
});

describe("how an upstream failure reaches the client", () => {
  it("maps a provider 5xx to 502 provider.unavailable, retryable", async () => {
    stubUpstream(() => new Response("upstream exploded", { status: 500 }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.unavailable");
    expect(response.json()["error"]["retryable"]).toBe(true);
    await app.close();
  });

  it("maps a provider 4xx to 502 provider.rejected, not retryable", async () => {
    // §9.3: retrying `provider.rejected` produces the identical failure and burns a round trip.
    // Same status as `provider.unavailable` and the opposite behaviour, which is why the taxonomy
    // keys off `code` rather than status.
    stubUpstream(() => new Response("bad request", { status: 400 }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.rejected");
    expect(response.json()["error"]["retryable"]).toBe(false);
    await app.close();
  });

  it("maps a provider 429 to provider.unavailable, never to the user's own limit.rate", async () => {
    // A 429 from the provider is *our* account being throttled, not the user's budget. Rendering it
    // as `limit.rate` would tell a user in their own app that they are out of allowance when they
    // are not — a lie the app repeats in its own words.
    stubUpstream(() => new Response("slow down", { status: 429 }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: { authorization: authorization() },
      payload: { task_id: "t", retention: "standard", query: "swift" },
    });

    expect(response.json()["error"]["code"]).toBe("provider.unavailable");
    await app.close();
  });

  it("maps an aborted upstream call to 504 provider.timeout", async () => {
    stubUpstream(() => {
      throw new DOMException("The operation was aborted.", "AbortError");
    });
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(504);
    expect(response.json()["error"]["code"]).toBe("provider.timeout");
    expect(response.json()["error"]["retryable"]).toBe(true);
    await app.close();
  });

  it("maps an unreachable provider to 502 provider.unavailable", async () => {
    stubUpstream(() => {
      throw new TypeError("fetch failed");
    });
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.unavailable");
    await app.close();
  });

  it("never returns the provider's own words to the client", async () => {
    // §7.1's rule with the reason that matters on these four routes: a provider error body can
    // carry the request back verbatim, and on these routes the request is the user's own command.
    stubUpstream(() =>
      new Response(
        JSON.stringify({ error: { message: "Invalid prompt: 'delete my tax returns folder'" } }),
        { status: 400 },
      ),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.body).not.toContain("tax returns");
    expect(response.body).not.toContain("Invalid prompt");
    await app.close();
  });

  it("answers 502 provider.unavailable when this deployment holds no credential for the route", async () => {
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build({ credentials: [] });
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    // Not a 404: the route exists, and `resource.not_found` would tell the client "no such route",
    // which it does not retry and cannot explain.
    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.unavailable");
    expect(calls).toHaveLength(0);
    await app.close();
  });
});

describe("the four routes are authenticated", () => {
  it("refuses every one of them with 401 when no token is presented", async () => {
    // The gate's own population test covers classification; this is the behaviour, per route,
    // because these four carry the user's command, their voice and their research.
    const calls = stubUpstream(() => jsonResponse({ output_text: "{}" }));
    const app = build();
    for (const url of ["/v1/plan", "/v1/research/synthesize", "/v1/search", "/v1/transcriptions"]) {
      const response = await app.inject({ method: "POST", url, payload: {} });
      expect(response.statusCode, url).toBe(401);
      expect(response.json()["error"]["code"], url).toBe("auth.unauthenticated");
    }
    expect(calls).toHaveLength(0);
    await app.close();
  });
});

describe("the numbers this ticket is held to", () => {
  it("carries contract §6.1's body limits", () => {
    // Written as literals rather than derived, so a change to either is a change someone made on
    // purpose — and so this file fails when the contract and the code disagree.
    expect(BODY_LIMIT_BYTES).toEqual({
      plan: 1_048_576,
      synthesize: 4_194_304,
      transcriptions: 10_485_760,
      search: 1_048_576,
      // SONNY-131's row. The table is asserted whole, so a fifth route has to be written here as
      // well as beside its own route — which is the point of asserting it whole. Its derivation
      // from the client's image ceiling is `test/screen.test.ts`', because that is where the
      // ceiling's own behaviour lives.
      screenAnalyze: 4_200_000,
    });
  });

  it("carries §12's deadlines, and the ordering that makes them a rule", () => {
    // **Five of §12's ten numbers, and the invariant that ties them to the other five** (PR #139,
    // F2; the fifth row is SONNY-131's). Nothing read `DEADLINE_MS` before this: a mutant moving any
    // of them survived the whole suite, because the values reach `withDeadlines` and nothing else
    // looks at them.
    expect(DEADLINE_MS).toEqual({
      plan: { upstream: 60_000, total: 75_000 },
      synthesize: { upstream: 90_000, total: 105_000 },
      transcriptions: { upstream: 60_000, total: 75_000 },
      search: { upstream: 20_000, total: 25_000 },
      screenAnalyze: { upstream: 90_000, total: 105_000 },
    });
    // **The invariant is the ordering, not a fixed gap** — a first draft of this test asserted
    // fifteen seconds on every row and went red on `search`, whose margin is five. §12's table has
    // both, and two of this branch's own doc comments claimed the constant until that failure.
    // What must hold on every row is that the server leaves itself room beyond the upstream call to
    // answer with a typed failure rather than being cut off mid-request.
    for (const [route, deadlines] of Object.entries(DEADLINE_MS)) {
      expect(deadlines.upstream, route).toBeGreaterThan(0);
      expect(deadlines.total, route).toBeGreaterThan(deadlines.upstream);
    }
    // The other five numbers live in `SonnyBackendTimeouts` on the Swift side, each above the
    // matching `total` here. `ModelRouteNumbersTests` asserts them against these same literals, so
    // the two halves of §12's table cannot move independently without one of the two failing.
  });

  it("caps a recording at three minutes, which is the number the Mac's refusal is built from", () => {
    expect(MAXIMUM_AUDIO_DURATION_SECONDS).toBe(180);
  });
});
