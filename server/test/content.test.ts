import { randomUUID } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import { MAXIMUM_PROVIDER_ERROR_BODY } from "../src/content/hook.js";
import {
  contentExpiryFrom,
  isStorable,
  requestContentOf,
  type RetainedContent,
} from "../src/content/record.js";
import type { ContentStore } from "../src/content/store.js";
import type {
  ClaimOutcome,
  ClaimRequest,
  CompletedResponse,
  KeyStore,
} from "../src/idempotency/store.js";
import type { MeteringEvent } from "../src/metering/event.js";
import type { MeteringStore, MeteringWriteOutcome } from "../src/metering/store.js";
import { PROVIDER_ERROR_BODY_BYTES } from "../src/model/upstream.js";
import { parseSupportArguments } from "../src/support.js";
import { parseSnapshotArguments } from "../src/snapshots.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { expectPopulationIsReal, registeredRoutes } from "./support/routes.js";
import { accessTokenFor } from "./support/tokens.js";
import { signedInConnectionTo } from "./support/connection.js";
import type pg from "pg";
import type { WithConnection } from "../src/db/connection.js";
import { CONTENT_DELETION_DEADLINE_MS } from "../src/model/limits.js";
import { withDatabaseDeadline } from "../src/model/routing.js";
import { ProviderTimedOut } from "../src/model/upstream.js";

/**
 * Contract §10's content store, driven through the whole real app (SONNY-134).
 *
 * **Every test here goes through `buildApp` and `inject`**, for the reason `metering.test.ts`,
 * `model.test.ts` and `idempotency.test.ts` all give: the decisions live in the hook's place in the
 * chain — after the gate has named the account, after the idempotency hook has decided whether the
 * handler ran at all, after the route has deposited what only it could see — and a test that built
 * a content row by hand would skip all three. What is asserted is what a *client's request*
 * actually retained.
 *
 * The store behind them is a recording fake, so these tests are about the decisions;
 * `content.db.test.ts` proves the SQL, the two clocks, the deletion paths, and the structural
 * exclusions against a real Postgres. The split is SONNY-300's and SONNY-133's, made again for the
 * same reason: a database-backed test runs only under `npm run test:db`, and the guarantee that an
 * incognito run is never stored should not be invisible to the run this repository gates on.
 *
 * **Nothing here sleeps.** The content write happens after the response, and `app.inject` resolves
 * before an `onResponse` hook finishes, so every assertion is made after
 * `await app.contentWritesSettled()` — a signal the writer publishes, which is what `CLAUDE.md`
 * requires in place of a bet on a wall clock. Without it the negative assertions would pass whether
 * or not the guarantee held, which is the worst shape a privacy test can take.
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

/** Answers the gate's one attribution query. Anything else reaching it is a red test. */
const signedInConnection = signedInConnectionTo({ account: ACCOUNT, where: "from a content test" });

/** A `KeyStore` with the real state machine, copied in shape from `metering.test.ts`. */
class StatefulKeyStore implements KeyStore {
  private readonly rows = new Map<
    string,
    {
      fingerprint: string;
      state: "in_flight" | "completed" | "released";
      token: string;
      response?: CompletedResponse;
    }
  >();

  private id(scope: string, key: string): string {
    return `${scope} ${key}`;
  }

  async claim(request: ClaimRequest): Promise<ClaimOutcome> {
    const id = this.id(request.accountScope, request.key);
    const row = this.rows.get(id);
    if (row === undefined) {
      const token = randomUUID();
      this.rows.set(id, { fingerprint: request.fingerprint, state: "in_flight", token });
      return { kind: "claimed", token };
    }
    if (row.fingerprint !== request.fingerprint) return { kind: "conflict" };
    if (row.state === "in_flight") return { kind: "in_flight", retryAfterSeconds: 30 };
    if (row.state === "completed" && row.response !== undefined) {
      return { kind: "replay", response: { ...row.response } };
    }
    row.token = randomUUID();
    row.state = "in_flight";
    return { kind: "claimed", token: row.token };
  }

  async complete(
    request: { accountScope: string; key: string; token: string },
    response: CompletedResponse,
  ): Promise<void> {
    const row = this.rows.get(this.id(request.accountScope, request.key));
    if (row === undefined || row.token !== request.token) return;
    row.state = "completed";
    row.response = response;
  }

  async release(request: { accountScope: string; key: string; token: string }): Promise<void> {
    const row = this.rows.get(this.id(request.accountScope, request.key));
    if (row === undefined || row.token !== request.token) return;
    row.state = "released";
    delete row.response;
  }

  /**
   * What this key's row holds, for the tests that ask whether a response body was stored at all.
   *
   * **The row and the response are read separately on purpose** (PR #148's review, F1/F5). An
   * incognito call must leave the row — the claim, the fingerprint and the fencing token are what
   * keep §9.2's other three guarantees, including the at-most-once metering claim — and must leave
   * no body. "No row" and "a row with no body" are different answers and only one of them is right.
   */
  row(scope: string, key: string): { state: string; hasResponse: boolean } | undefined {
    const row = this.rows.get(this.id(scope, key));
    return row === undefined
      ? undefined
      : { state: row.state, hasResponse: row.response !== undefined };
  }
}

class RecordingContentStore implements ContentStore {
  readonly rows: RetainedContent[] = [];
  failWrites = false;

  async write(content: RetainedContent): Promise<void> {
    if (this.failWrites) throw new Error("the content store is down");
    this.rows.push(content);
  }
}

/** Records every event, so "metering ran for an incognito call" is an assertion and not a hope. */
class RecordingMeteringStore implements MeteringStore {
  readonly events: MeteringEvent[] = [];
  async write(event: MeteringEvent): Promise<MeteringWriteOutcome> {
    this.events.push(event);
    return "written";
  }
}

let content: RecordingContentStore;
let metering: RecordingMeteringStore;
let keys: StatefulKeyStore;
let upstreamCalls: number;

beforeEach(() => {
  content = new RecordingContentStore();
  metering = new RecordingMeteringStore();
  keys = new StatefulKeyStore();
  upstreamCalls = 0;
});
afterEach(() => {
  vi.unstubAllGlobals();
});

const CREDENTIALS: Config["credentials"] = [
  { provider: "openai", keys: ["sk-test-openai-key"] },
  { provider: "tavily", keys: ["tvly-test-search-key"] },
  { provider: "vision", keys: ["vk-test-vision-key"] },
];

function build(overrides: Partial<Config> = {}) {
  return buildApp(
    testConfig({ credentials: CREDENTIALS, ...overrides }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    {
      idempotencyStore: keys,
      meteringStore: metering,
      contentStore: content,
      // SONNY-135's check runs on every authenticated route and is Postgres-backed, so a suite
      // with no database injects the fake store `support/entitlement.ts` documents. It answers
      // "admitted" and records what it was asked; what the cap actually does is proved against a
      // real Postgres in `entitlement.db.test.ts`.
      entitlementStore: fakeEntitlementStore(),
    },
  );
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

function headers(key: string | null = randomUUID()): Record<string, string> {
  const built: Record<string, string> = {
    authorization: authorization(),
    "sonny-client-version": "1.0.0+412",
  };
  if (key !== null) built["idempotency-key"] = key;
  return built;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function stubUpstream(respond: (call: number) => Response | Promise<Response> | never): void {
  vi.stubGlobal("fetch", async () => {
    upstreamCalls += 1;
    return respond(upstreamCalls);
  });
}

const OPENAI_REPLY = {
  output_text: '{"steps":[]}',
  usage: { input_tokens: 4210, output_tokens: 318, total_tokens: 4528 },
};

function planBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    task_id: "task-1",
    retention: "standard",
    messages: [{ role: "user", text: "Open Safari and find the invoice" }],
    response_schema_name: "agent_plan",
    response_schema: { type: "object" },
    ...overrides,
  };
}

const SMALL_IMAGE = Buffer.alloc(12, 0x41).toString("base64");

function analyzeBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    task_id: "task-1",
    session_id: "session-1",
    session_iteration: 5,
    retention: "standard",
    prompt: "Decide the next action.",
    image: {
      media_type: "image/jpeg",
      encoding: "base64",
      data: SMALL_IMAGE,
      pixel_width: 2406,
      pixel_height: 1354,
    },
    ...overrides,
  };
}

function multipartBody(meta: unknown, audio: Buffer): { payload: Buffer; contentType: string } {
  const boundary = "SonnyContentBoundary-cbf29ce484222325";
  const head = Buffer.from(
    `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="meta"\r\n` +
      `Content-Type: application/json\r\n\r\n` +
      `${JSON.stringify(meta)}\r\n` +
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="audio"; filename="dictation.m4a"\r\n` +
      `Content-Type: audio/mp4\r\n\r\n`,
    "utf8",
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`, "utf8");
  return {
    payload: Buffer.concat([head, audio, tail]),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}

/** The one row this request retained. Fails loudly rather than returning undefined. */
function onlyRow(): RetainedContent {
  expect(content.rows).toHaveLength(1);
  return content.rows[0]!;
}

describe("what is retained, and what is not", () => {
  it("keeps a plan call's request text and served response, on the content clock", async () => {
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const before = Date.now();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(200);
    const row = onlyRow();
    expect(row.accountId).toBe(ACCOUNT);
    expect(row.route).toBe("plan");
    expect(row.taskId).toBe("task-1");
    expect(row.provider).toBe("openai");
    // The request as the client sent it, roles intact — which is what a training snapshot's
    // consumer needs and what a flattened string would have lost.
    expect(row.requestText).toEqual([{ role: "user", text: "Open Safari and find the invoice" }]);
    // The response as it left this gateway, bytes and status, with the model's reply inside it.
    expect(row.responseStatus).toBe(200);
    const served = JSON.parse(row.responseBody!.toString("utf8")) as { output_text: string };
    expect(served.output_text).toBe('{"steps":[]}');
    // Thirty days, computed from the call rather than read at query time.
    const days = (row.expiresAt.getTime() - before) / (24 * 60 * 60 * 1000);
    expect(days).toBeGreaterThan(29.9);
    expect(days).toBeLessThan(30.1);
    // Not a screen-control call: no capture, no recording.
    expect(row.screenshot).toBeNull();
    expect(row.voiceAudio).toBeNull();
  });

  it("keeps the screen capture and the prompt for a screen-control iteration", async () => {
    stubUpstream(() => jsonResponse({ output_text: '{"action":"click"}' }));
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: headers(),
      payload: analyzeBody(),
    });
    await app.contentWritesSettled();

    const row = onlyRow();
    expect(row.route).toBe("screen.analyze");
    expect(row.sessionId).toBe("session-1");
    expect(row.sessionIteration).toBe(5);
    expect(row.requestText).toBe("Decide the next action.");
    // Decoded from the base64 the client sent, and byte-identical to it.
    expect(row.screenshot).toEqual(Buffer.from(SMALL_IMAGE, "base64"));
    expect(row.screenshotMediaType).toBe("image/jpeg");
    expect(row.provider).toBe("vision");
  });

  it("keeps voice audio, which is the content type most easily forgotten", async () => {
    // §10.3 names it explicitly: "the most personally sensitive of the four types and the one most
    // likely to be overlooked because nobody listed it". It is also the one piece of request
    // content the hook cannot read for itself, because §4.4's body is multipart — so this asserts
    // the deposit as much as the storage.
    stubUpstream(() => jsonResponse({ text: "open the invoice" }));
    const recording = Buffer.from("fake-m4a-bytes-that-are-not-silence");
    const { payload, contentType } = multipartBody(
      { task_id: "task-1", retention: "standard" },
      recording,
    );
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { ...headers(), "content-type": contentType },
      payload,
    });
    await app.contentWritesSettled();

    const row = onlyRow();
    expect(row.route).toBe("transcription");
    expect(row.voiceAudio).toEqual(recording);
    expect(row.voiceAudioMediaType).toBe("audio/mp4");
    expect(row.voiceAudioFilename).toBe("dictation.m4a");
    // The transcript came back inside the served response.
    expect(row.responseBody!.toString("utf8")).toContain("open the invoice");
  });

  it("keeps a search query and its results", async () => {
    stubUpstream(() =>
      jsonResponse({ results: [{ title: "Invoice", url: "https://example.test/i", content: "x" }] }),
    );
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/search",
      headers: headers(),
      payload: { task_id: "task-1", retention: "standard", query: "quarterly invoice" },
    });
    await app.contentWritesSettled();

    const row = onlyRow();
    expect(row.route).toBe("search");
    expect(row.requestText).toBe("quarterly invoice");
    expect(row.responseBody!.toString("utf8")).toContain("https://example.test/i");
  });
});

describe("an incognito run is never stored, and is still billed", () => {
  it("stores nothing at all for a screen-control iteration marked retention none", async () => {
    stubUpstream(() => jsonResponse({ output_text: '{"action":"click"}' }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/screen/analyze",
      headers: headers(),
      payload: analyzeBody({ retention: "none" }),
    });
    await app.contentWritesSettled();

    // The call worked. This is not a refusal.
    expect(response.statusCode).toBe(200);
    // **Nothing, and this assertion is only worth anything because of the line above it.** The
    // write happens after the response, so without `contentWritesSettled` this would pass for a
    // `standard` request too.
    expect(content.rows).toEqual([]);
    // §10.1: "Metering runs either way. Incognito changes what is stored, never what is billed."
    expect(metering.events).toHaveLength(1);
    expect(metering.events[0]!.retention).toBe("none");
    expect(metering.events[0]!.outcome).toBe("ok");
  });

  it("stores no voice audio for an incognito transcription", async () => {
    // The route deposits the recording before the hook decides anything, so this is the case where
    // "deposited" and "stored" have to come apart. If they ever stop being separate, the most
    // sensitive of the four content types is the one that leaks.
    stubUpstream(() => jsonResponse({ text: "private note" }));
    const { payload, contentType } = multipartBody(
      { task_id: "task-2", retention: "none" },
      Buffer.from("fake-m4a-bytes"),
    );
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: { ...headers(), "content-type": contentType },
      payload,
    });
    await app.contentWritesSettled();

    expect(content.rows).toEqual([]);
    expect(metering.events).toHaveLength(1);
    expect(metering.events[0]!.route).toBe("transcription");
  });

  it("stores no response body in the idempotency store, and keeps that key's claim", async () => {
    // **PR #148's F1.** `sonny.idempotency_key` keeps the served response for twenty-four hours,
    // which makes it the second place in this gateway that stores response content — and it had no
    // notion of retention, so an incognito call's model reply was kept there verbatim. The three
    // layers in `content/hook.ts` all guard a different table.
    //
    // The assertion is deliberately two-sided. **No body**, because that is the promise; **and the
    // row is still there**, because the claim, the fingerprint and the fencing token are what keep
    // §9.2's other three guarantees — deleting the row would hand this key a second metering event.
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const key = randomUUID();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody({ retention: "none" }),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(200);
    expect(JSON.parse(response.body).output_text).toBe('{"steps":[]}');
    expect(content.rows).toEqual([]);
    expect(keys.row(ACCOUNT, key)).toEqual({ state: "released", hasResponse: false });
  });

  it("re-runs a repeated incognito call rather than replaying it, which is the deviation", async () => {
    // The cost of F1's fix, asserted rather than described. §9.2's second row says a repeat inside
    // the window returns the stored response; for an incognito call there is no stored response, so
    // the handler runs again and the provider is called a second time. The metering claim survives,
    // so that second call is unbilled — the same trade the released-retryable deviation already
    // makes. Contract §14 carries the row; this is the behaviour.
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const key = randomUUID();
    const first = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody({ retention: "none" }),
    });
    const repeat = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody({ retention: "none" }),
    });
    await app.contentWritesSettled();

    expect(first.statusCode).toBe(200);
    expect(repeat.statusCode).toBe(200);
    expect(upstreamCalls).toBe(2);
    expect(content.rows).toEqual([]);
  });

  it("still stores a standard call's response body, so the fix did not disable the feature", async () => {
    // The other side of F1, because a guard that withheld every body would pass the test above and
    // silently remove §9.2's replay from the whole gateway.
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const key = randomUUID();
    await app.inject({ method: "POST", url: "/v1/plan", headers: headers(key), payload: planBody() });
    await app.contentWritesSettled();

    expect(keys.row(ACCOUNT, key)).toEqual({ state: "completed", hasResponse: true });

    const repeat = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody(),
    });
    await app.contentWritesSettled();
    expect(repeat.statusCode).toBe(200);
    // Replayed, not re-run: one upstream call across both requests.
    expect(upstreamCalls).toBe(1);
  });

  it("keeps replay for an auth route, which declares no retention and carries no content", async () => {
    // **The reason the guard reads `=== "none"` and not `!== "standard"`.** Widening it would strip
    // §9.2's replay from the four auth routes, none of which has a retention field to declare.
    // `email/start` answers 400 on a malformed body, which is a stored response like any other.
    const app = build();
    const key = randomUUID();
    await app.inject({
      method: "POST",
      url: "/v1/auth/email/start",
      headers: { "idempotency-key": key },
      payload: { email: "not-an-email" },
    });
    await app.contentWritesSettled();

    expect(keys.row("00000000-0000-0000-0000-000000000000", key)).toEqual({
      state: "completed",
      hasResponse: true,
    });
  });

  it("stores no provider error body for an incognito call either", async () => {
    // The one a log line could never have promised: the body is read off the wire and deposited on
    // every failure, and the retention rule is what stops it being kept.
    stubUpstream(() =>
      new Response(JSON.stringify({ error: { message: "your prompt said: buy the flat" } }), {
        status: 400,
        headers: { "content-type": "application/json", "x-request-id": "openai-req-9" },
      }),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody({ retention: "none" }),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(502);
    expect(content.rows).toEqual([]);
  });
});

describe("a request that declared no retention stores nothing", () => {
  it("keeps nothing when the body is rejected before retention could be read", async () => {
    // §2.4.2's rule arriving at the storage layer. An omitted `retention` is a loud 400 on the wire
    // precisely because neither default is safe, and the store takes the same line rather than
    // guessing `standard` for a body it could not parse.
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: { task_id: "task-1", messages: [{ role: "user", text: "Open Safari" }] },
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(400);
    expect(content.rows).toEqual([]);
    // The metering event is still written, because a refusal is still a call that has to be
    // attributable — the same asymmetry as incognito, reached by a different road.
    expect(metering.events).toHaveLength(1);
    expect(metering.events[0]!.outcome).toBe("refused");
    expect(metering.events[0]!.retention).toBeNull();
  });

  it("keeps a request that failed validation but did declare standard retention", async () => {
    // The other half, and the reason the rule is about the declared value rather than about
    // validation passing: this body is refused, and what it sent is still content the user's Mac
    // transmitted under a `standard` declaration.
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: { task_id: "task-1", retention: "standard", messages: [] },
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(400);
    const row = onlyRow();
    expect(row.route).toBe("plan");
    expect(row.responseStatus).toBe(400);
    // `messages` failed `.min(1)`, so the tolerant read keeps the empty array it actually sent.
    expect(row.requestText).toEqual([]);
  });
});

describe("who else gets no content row", () => {
  it("stores nothing for a request the gate refused", async () => {
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { "idempotency-key": randomUUID() },
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(401);
    expect(content.rows).toEqual([]);
  });

  it("stores nothing a second time when a retry replays the stored response", async () => {
    // The original stored its own content; a replay ran no handler and produced no new content.
    // Storing again would double the corpus for every client retry.
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const key = randomUUID();
    await app.inject({ method: "POST", url: "/v1/plan", headers: headers(key), payload: planBody() });
    await app.contentWritesSettled();
    expect(content.rows).toHaveLength(1);

    const replay = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(replay.statusCode).toBe(200);
    expect(content.rows).toHaveLength(1);
    expect(upstreamCalls).toBe(1);
  });

  it("stores nothing for a key reused with a different body", async () => {
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    const key = randomUUID();
    await app.inject({ method: "POST", url: "/v1/plan", headers: headers(key), payload: planBody() });
    await app.contentWritesSettled();

    const conflict = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(key),
      payload: planBody({ task_id: "a-different-task" }),
    });
    await app.contentWritesSettled();

    expect(conflict.statusCode).toBe(409);
    // Still one: the conflicting request never reached a handler, so there is nothing it produced.
    expect(content.rows).toHaveLength(1);
    expect(content.rows[0]!.taskId).toBe("task-1");
  });

  it("stores content for a POST that carried no idempotency key at all", async () => {
    // Served by founder decision of 2026-08-28 without §9.2's guarantees, and it still ran a
    // handler and still produced content. Dropping it would lose content for exactly the requests
    // with the least protection.
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(null),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(onlyRow().route).toBe("plan");
  });
});

describe("a provider's error body lands in the store, on the content clock", () => {
  it("keeps the body and the provider's request id, and keeps neither in the response", async () => {
    // §10.3: an error body echoing the input is content arriving in a field nobody classified. The
    // body here is exactly that shape — it quotes the user's own command back.
    const echoed = { error: { message: "rejected prompt: Open Safari and find the invoice" } };
    stubUpstream(() =>
      new Response(JSON.stringify(echoed), {
        status: 400,
        headers: { "content-type": "application/json", "x-request-id": "req_openai_7781" },
      }),
    );
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(502);
    const row = onlyRow();
    expect(row.providerErrorStatus).toBe(400);
    expect(row.providerErrorBody).toBe(JSON.stringify(echoed));
    expect(row.providerRequestId).toBe("req_openai_7781");
    // **And it did not reach the client**, which is the half that would be a leak rather than a
    // gap: §7.1's `message` names the status and nothing the provider said.
    expect(response.body).not.toContain("Open Safari");
    expect(response.body).not.toContain("rejected prompt");
  });

  it("reads Anthropic's request-id header as well as OpenAI's", async () => {
    stubUpstream(() =>
      new Response(JSON.stringify({ type: "error" }), {
        status: 529,
        headers: { "content-type": "application/json", "request-id": "req_anthropic_22" },
      }),
    );
    const app = build({
      credentials: [{ provider: "anthropic", keys: ["sk-ant-test"] }],
      routeChains: { plan: ["anthropic"], synthesize: ["anthropic"], transcriptions: [], search: [] },
    });
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(onlyRow().providerRequestId).toBe("req_anthropic_22");
  });

  it("keeps the request id even when the body could not be read", async () => {
    // The half that survives independently: the id is a header, so a body that never finishes
    // arriving still leaves something to quote at the vendor.
    stubUpstream(
      () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.error(new Error("the connection went away mid-body"));
            },
          }),
          { status: 503, headers: { "x-request-id": "req_openai_dead" } },
        ),
    );
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    const row = onlyRow();
    expect(row.providerRequestId).toBe("req_openai_dead");
    expect(row.providerErrorStatus).toBe(503);
    expect(row.providerErrorBody).toBeNull();
  });

  it("bounds an enormous error body rather than storing all of it", async () => {
    stubUpstream(
      () =>
        new Response("x".repeat(PROVIDER_ERROR_BODY_BYTES * 4), {
          status: 500,
          headers: { "content-type": "text/plain" },
        }),
    );
    const app = build();
    await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(onlyRow().providerErrorBody).toHaveLength(MAXIMUM_PROVIDER_ERROR_BODY);
  });

  it("records no provider error for a refusal this gateway decided by itself", async () => {
    // A 2xx whose body holds no usable text is the adapter's own refusal, not the provider saying
    // anything. `detailOf` answering `undefined` is what keeps a content row from claiming a
    // provider said something it did not.
    stubUpstream(() => jsonResponse({ nothing: "usable" }));
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(502);
    const row = onlyRow();
    expect(row.providerErrorStatus).toBeNull();
    expect(row.providerErrorBody).toBeNull();
  });
});

describe("the store never fails a response", () => {
  it("answers the caller normally when the content write throws", async () => {
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    content.failWrites = true;
    const app = build();
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(200);
    expect(JSON.parse(response.body).output_text).toBe('{"steps":[]}');
    expect(content.rows).toEqual([]);
    // The call is still billed. A lost content row must not become a lost bill.
    expect(metering.events).toHaveLength(1);
  });

  it("serves and meters a deployment with no content store at all", async () => {
    stubUpstream(() => jsonResponse(OPENAI_REPLY));
    const app = buildApp(
      testConfig({ credentials: CREDENTIALS }),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
      { idempotencyStore: keys, meteringStore: metering, entitlementStore: fakeEntitlementStore() },
    );
    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: headers(),
      payload: planBody(),
    });
    await app.contentWritesSettled();

    expect(response.statusCode).toBe(200);
    expect(metering.events).toHaveLength(1);
  });
});

describe("the route table", () => {
  it("serves DELETE /v1/tasks/:task_id, and it is not a POST anything meters", async () => {
    const app = build();
    const routes = await registeredRoutes(app);
    expectPopulationIsReal(routes);
    const pairs = routes.map((route) => `${route.method} ${route.url}`);
    expect(pairs).toContain("DELETE /v1/tasks/:task_id");
    // **Metering's shape is untouched by this branch, and this is what says so.** A `DELETE` never
    // reaches the metering hook or the idempotency hook — both are POST-only — so adding this route
    // added no metered route and no unmetered-POST declaration.
    expect(pairs.filter((pair) => pair.startsWith("POST /v1/tasks"))).toEqual([]);
  });

  it("refuses an unauthenticated delete, like every other non-public route", async () => {
    const app = build();
    const response = await app.inject({ method: "DELETE", url: "/v1/tasks/task-1" });
    expect(response.statusCode).toBe(401);
  });
});

describe("the decisions, apart from the wiring", () => {
  it("stores only an explicit standard, and treats a missing value as not storable", () => {
    // The whole of §10.1's first rule and §2.4.2's, as one predicate.
    expect(isStorable("standard")).toBe(true);
    expect(isStorable("none")).toBe(false);
    expect(isStorable(undefined)).toBe(false);
  });

  it("computes the expiry from the call's own instant and the configured window", () => {
    const occurred = new Date("2026-08-28T09:00:00.000Z");
    expect(contentExpiryFrom(occurred, 30).toISOString()).toBe("2026-09-27T09:00:00.000Z");
    // A different window is a different answer for the same instant, which is what makes the
    // stored value rather than a computed one the thing that carries the promise.
    expect(contentExpiryFrom(occurred, 90).toISOString()).toBe("2026-11-26T09:00:00.000Z");
  });

  it("pulls nothing out of a body whose fields are the wrong types", () => {
    // Tolerance in the safe direction: a hostile or broken body contributes nothing rather than a
    // surprise, and never throws on a path that runs after the response has gone.
    expect(requestContentOf("plan", { messages: "not an array" })).toEqual({
      requestText: null,
      screenshot: null,
      screenshotMediaType: null,
    });
    expect(requestContentOf("search", { query: 12 })).toEqual({
      requestText: null,
      screenshot: null,
      screenshotMediaType: null,
    });
    expect(requestContentOf("screen.analyze", { prompt: "p", image: { data: 5 } })).toEqual({
      requestText: "p",
      screenshot: null,
      screenshotMediaType: null,
    });
    expect(requestContentOf("plan", null)).toEqual({
      requestText: null,
      screenshot: null,
      screenshotMediaType: null,
    });
  });

  it("reads no audio off a transcription body, because it is never there", () => {
    // Stated as a test rather than as a comment, because the day someone "fixes" this to read
    // `request.body` is the day voice audio stops being stored with no test failing.
    expect(requestContentOf("transcription", { audio: "would be a lie" })).toEqual({
      requestText: null,
      screenshot: null,
      screenshotMediaType: null,
    });
  });
});

describe("the support command refuses to read content without a name and a reason", () => {
  it("refuses each missing flag by name, before any connection is opened", () => {
    expect(parseSupportArguments(["content"])).toEqual({
      kind: "error",
      message: "content needs --request",
    });
    expect(parseSupportArguments(["content", "--request", "r1"])).toEqual({
      kind: "error",
      message: "content needs --operator: who is looking",
    });
    expect(
      parseSupportArguments(["content", "--request", "r1", "--operator", "sauransh"]),
    ).toEqual({ kind: "error", message: "content needs --reason: why, recorded verbatim" });
    expect(
      parseSupportArguments([
        "content",
        "--request",
        "r1",
        "--operator",
        "  sauransh  ",
        "--reason",
        " a user reported a wrong click ",
      ]),
    ).toEqual({
      kind: "run",
      command: "content",
      requestId: "r1",
      operator: "sauransh",
      reason: "a user reported a wrong click",
    });
  });

  it("reads account state with no ceremony at all, which is the other half of the decision", () => {
    expect(parseSupportArguments(["account", ACCOUNT])).toEqual({
      kind: "run",
      command: "account",
      accountId: ACCOUNT,
    });
    expect(parseSupportArguments(["deletions", "--limit", "5"])).toEqual({
      kind: "run",
      command: "deletions",
      limit: 5,
      accountId: undefined,
    });
    expect(parseSupportArguments(["accesses"])).toEqual({
      kind: "run",
      command: "accesses",
      limit: 20,
    });
  });

  it("names a bad argument rather than answering a question nobody asked", () => {
    expect(parseSupportArguments(["deletions", "--limit", "many"])).toEqual({
      kind: "error",
      message: '--limit is not a number: "many"',
    });
    expect(parseSupportArguments(["accesses", "--limit"])).toEqual({
      kind: "error",
      message: "--limit needs a value",
    });
  });
});

describe("the snapshot command", () => {
  it("requires a label and leaves the snapshot clock unset unless asked", () => {
    expect(parseSnapshotArguments(["build"])).toEqual({
      kind: "error",
      message: "build needs --label",
    });
    const parsed = parseSnapshotArguments(["build", "--label", "corpus-2026-08"]);
    expect(parsed).toEqual({
      kind: "run",
      command: "build",
      request: { label: "corpus-2026-08" },
    });
  });

  it("refuses a route name it does not know rather than silently widening the window", () => {
    expect(parseSnapshotArguments(["build", "--label", "x", "--routes", "plan,not-a-route"])).toEqual(
      { kind: "error", message: "--routes names no known route: plan,not-a-route" },
    );
    expect(parseSnapshotArguments(["build", "--label", "x", "--since", "yesterday"])).toEqual({
      kind: "error",
      message: '--since is not a date: "yesterday"',
    });
  });
});

/**
 * §12's deadline on the four content-deletion routes (SONNY-428).
 *
 * **The fake below is a Postgres that honours `statement_timeout`, and that is what makes these
 * tests about the wiring rather than about the mapping.** `CLAUDE.md`'s held-sample gotcha is the
 * shape to avoid: a test that hands the route a ready-made `57014` proves the error mapper and
 * nothing else, and stays green against a route that never bounded anything. Here the cancellation
 * is *caused* by the timeout the route itself set — with no `SET statement_timeout` in force the
 * stalled statement never returns at all, so an unwired route fails by reaching the hang backstop
 * rather than by passing.
 */
/** The milliseconds out of a `SET statement_timeout TO <n>`, refusing anything else. */
function budgetOf(statement: string): number {
  const value = statement.toUpperCase().split(" TO ")[1];
  if (value === undefined) throw new Error(`not a statement_timeout: ${statement}`);
  return Number(value);
}

function stallingConnection(record: string[]): WithConnection {
  return async (work) => {
    let timeoutMs: number | undefined;
    const client = {
      query: async (text: string, values: readonly unknown[] = []) => {
        record.push(text.trim());
        const statement = text.trim().toUpperCase();
        if (statement.startsWith("SET STATEMENT_TIMEOUT")) {
          timeoutMs = Number(statement.split(" TO ")[1]);
          return { rows: [] };
        }
        if (statement === "RESET STATEMENT_TIMEOUT") {
          timeoutMs = undefined;
          return { rows: [] };
        }
        // Transaction control, which `withDatabaseDeadline` exempts. Answered rather than stalled:
        // a `ROLLBACK` is what the store issues on the way out of a cancelled transaction.
        if (statement === "BEGIN" || statement === "COMMIT" || statement === "ROLLBACK") {
          return { rows: [] };
        }
        // The gate's own two reads, answered exactly as `support/connection.ts` answers them —
        // this fake cannot delegate to it, because what it exists to control is the statements
        // *after* the gate.
        if (text.includes("INSERT INTO sonny.revoked_provider_session")) return { rows: [] };
        if (text.includes("FROM sonny.revoked_provider_session")) return { rows: [] };
        if (text.includes("FROM sonny.identity")) {
          void values;
          return { rows: [{ account_id: ACCOUNT }] };
        }
        // **The route's own work, and this is where the wiring is pinned.** A statement under a
        // `statement_timeout` is the one a real backend cancels; a statement under none runs to
        // completion however long it takes. So an unwired route reaches the second branch, answers
        // its ordinary 200, and fails the assertion below on a status — loudly and attributably,
        // rather than by hanging. That matters beyond tidiness: a test whose only failure signal is
        // a backstop timeout can never be counted a mutation kill, because every wording that type
        // emits is declared untrusted, so the mutant would come back UNATTRIBUTED on a run where
        // the test failed for exactly the right reason (`CLAUDE.md`, SONNY-259).
        if (timeoutMs === undefined) return { rows: [], rowCount: 0 };
        throw Object.assign(new Error("canceling statement due to statement timeout"), {
          code: "57014",
        });
      },
    };
    return work(client as unknown as pg.Client);
  };
}

function buildWithStall(record: string[]) {
  return buildApp(
    testConfig({ credentials: CREDENTIALS }),
    { provider: new UnusedAuthProvider(), withConnection: stallingConnection(record) },
    {
      idempotencyStore: keys,
      meteringStore: metering,
      contentStore: content,
      entitlementStore: fakeEntitlementStore(),
    },
  );
}

describe("§12's deadline on the four content-deletion routes", () => {
  /**
   * Every route in `routes/tasks.ts`, by the request that reaches it. **The population is the
   * point**: §12's row names these four together, and a fifth deletion route arriving without a
   * deadline is what this list is here to fail on.
   */
  const ROUTES = [
    { name: "DELETE /v1/tasks/:task_id", method: "DELETE" as const, url: "/v1/tasks/task-1" },
    {
      name: "DELETE /v1/tasks",
      method: "DELETE" as const,
      url: "/v1/tasks",
      payload: { task_ids: ["task-1", "task-2"] },
    },
    {
      name: "DELETE /v1/tasks/:task_id/screenshots",
      method: "DELETE" as const,
      url: "/v1/tasks/task-1/screenshots",
    },
    { name: "DELETE /v1/account/content", method: "DELETE" as const, url: "/v1/account/content" },
  ];

  for (const route of ROUTES) {
    it(
      `${route.name} answers §7.2's 504 when its store is cancelled inside §12's budget`,
      async () => {
        const record: string[] = [];
        const app = buildWithStall(record);
        const response = await app.inject({
          method: route.method,
          url: route.url,
          headers: { authorization: authorization() },
          ...(route.payload ? { payload: route.payload } : {}),
        });

        // §7.2 case 5a's envelope, and it is the shared one rather than a fifth copy: the same
        // status, code and flag the model routes send for the same condition.
        expect(response.statusCode).toBe(504);
        expect(response.json().error.code).toBe("provider.timeout");
        expect(response.json().error.retryable).toBe(true);

        // **The budget it handed Postgres is §12's number**, which is the half a stalled fake can
        // establish and the half a mutant moving the constant has to survive. It is the remaining
        // budget rather than the constant, so it is at most the total and within a wide band of it
        // — a band rather than an equality because the elapsed time is real, and wide enough that
        // no ordinary machine load can reach it.
        const [firstSet] = record.filter((statement) =>
          statement.toUpperCase().startsWith("SET STATEMENT_TIMEOUT"),
        );
        // Thrown rather than expected, so an unwired route ends this test here instead of running
        // on into an assertion about `undefined` — the reason `CLAUDE.md` asks for `try #require`
        // after a count on the Swift side.
        if (firstSet === undefined) throw new Error("the route set no statement_timeout at all");
        const first = budgetOf(firstSet);
        expect(first).toBeLessThanOrEqual(CONTENT_DELETION_DEADLINE_MS.total);
        expect(first).toBeGreaterThan(CONTENT_DELETION_DEADLINE_MS.total - 5_000);

        // **And it left the connection clean.** A session-level `statement_timeout` outlives the
        // lease, so a pooled connection returned still carrying one bounds a route that never
        // asked for a bound.
        expect(record).toContain("RESET statement_timeout");
      },
    );
  }
});

describe("withDatabaseDeadline, apart from the routes", () => {
  /** A client that records what it was asked and answers everything. */
  function recorder(record: string[]): { client: pg.Client; record: string[] } {
    const client = {
      query: async (text: string) => {
        record.push(text.trim());
        return { rows: [] };
      },
    };
    return { client: client as unknown as pg.Client, record };
  }

  it("bounds the WHOLE handler, by shrinking the budget rather than repeating it", async () => {
    // **A per-statement timeout of 15 s over a six-statement handler is a 90-second bound wearing
    // §12's number.** What makes this §12's *total* is that each statement gets what is left, so
    // the numbers must fall.
    const record: string[] = [];
    const { client } = recorder(record);
    await withDatabaseDeadline({ total: 15_000 }, client, async (db) => {
      await db.query("SELECT 1");
      await new Promise((resolve) => setTimeout(resolve, 25));
      await db.query("SELECT 2");
    });
    const budgets = record
      .filter((statement) => statement.toUpperCase().startsWith("SET STATEMENT_TIMEOUT"))
      .map(budgetOf);
    expect(budgets).toHaveLength(2);
    const [firstBudget, secondBudget] = budgets;
    if (firstBudget === undefined || secondBudget === undefined) {
      throw new Error(`expected two budgets, got ${budgets.length}`);
    }
    expect(secondBudget).toBeLessThan(firstBudget);
    expect(firstBudget).toBeLessThanOrEqual(15_000);
  });

  it("refuses a remainder of exactly zero, the one value that would set no bound at all", async () => {
    // **PR #221's review, F1 — the one character between this deadline and no deadline.** The guard
    // is `remaining <= 0`, and loosening it to `< 0` survived the entire suite: a remainder of
    // exactly zero would then be handed to Postgres as `SET statement_timeout TO 0`, which is that
    // server's spelling of *no timeout at all* (measured against Postgres 17: under `TO 0` a
    // sixty-million-row scan completed, and the byte-identical control at `TO 1` was cancelled). The
    // route would run its delete unbounded, answer its ordinary 200, and still emit the `RESET`, so
    // none of the four route tests could see it either.
    //
    // **The clock is frozen rather than raced.** `{ total: 0 }` with `Date.now` held at one instant
    // puts `remaining` on exactly zero at the guard, deterministically; a tiny `total` plus a sleep
    // would be the wall-clock bet `CLAUDE.md` warns about, and it would race the very mutant this
    // exists to catch instead of catching it. `Date.now` alone rather than vitest's fake timers,
    // because that is the only clock this helper reads and replacing the timers would reach `pg` and
    // the hang backstop, which `auth.db.test.ts` records as a run that hangs with no output at all.
    const record: string[] = [];
    const { client } = recorder(record);
    const frozen = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(frozen);
    try {
      await expect(
        withDatabaseDeadline({ total: 0 }, client, async (db) => {
          await db.query("DELETE FROM sonny.retained_content");
        }),
      ).rejects.toThrow(ProviderTimedOut);
    } finally {
      clock.mockRestore();
    }
    // **The empty list is the half that distinguishes a refusal from a `TO 0`**, and it is empty
    // rather than merely free of the delete: nothing was set, so nothing needed resetting either.
    expect(record).toEqual([]);
  });

  it("refuses a statement once the budget is gone, without a round trip", async () => {
    // The sequence-level half of the bound: work that ran out of budget between statements is
    // stopped here rather than handed to Postgres with a one-millisecond timeout.
    const record: string[] = [];
    const { client } = recorder(record);
    await expect(
      withDatabaseDeadline({ total: 20 }, client, async (db) => {
        await new Promise((resolve) => setTimeout(resolve, 40));
        await db.query("SELECT 1");
      }),
    ).rejects.toThrow(ProviderTimedOut);
    expect(record.filter((statement) => statement === "SELECT 1")).toEqual([]);
  });

  it("lets ROLLBACK through unbounded, so a cancelled transaction cannot poison the connection", async () => {
    // **This ticket's own defect reached through its own fix.** A `ROLLBACK` refused for want of
    // budget leaves the connection in an aborted-transaction state, and `withConnection` returns it
    // to the pool that way: the next request's first statement fails with `current transaction is
    // aborted`. So transaction control is exempt from the refusal above and from the bound.
    const record: string[] = [];
    const { client } = recorder(record);
    await withDatabaseDeadline({ total: 20 }, client, async (db) => {
      await new Promise((resolve) => setTimeout(resolve, 40));
      await db.query("ROLLBACK");
    });
    expect(record).toContain("ROLLBACK");
    // And it was not preceded by a budget of its own.
    expect(record.filter((s) => s.toUpperCase().startsWith("SET STATEMENT_TIMEOUT"))).toEqual([]);
  });

  it("maps Postgres's cancellation to the timeout the mapper already answers", async () => {
    const { client } = recorder([]);
    await expect(
      withDatabaseDeadline({ total: 15_000 }, client, async (db) => {
        await db.query("SELECT 1");
        throw Object.assign(new Error("canceling statement due to statement timeout"), {
          code: "57014",
        });
      }),
    ).rejects.toThrow(ProviderTimedOut);
  });

  it("rethrows anything that is not a cancellation, so a real fault stays a real fault", async () => {
    // A bug in a deletion must not be dressed up as a timeout the client is told to retry.
    const { client } = recorder([]);
    await expect(
      withDatabaseDeadline({ total: 15_000 }, client, async (db) => {
        await db.query("SELECT 1");
        throw Object.assign(new Error("null value in column violates not-null constraint"), {
          code: "23502",
        });
      }),
    ).rejects.toThrow("null value in column");
  });
});
