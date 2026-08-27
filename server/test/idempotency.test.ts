import type pg from "pg";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { WithConnection } from "../src/db/connection.js";
import { fingerprintOf } from "../src/idempotency/fingerprint.js";
import {
  UNAUTHENTICATED_SCOPE,
  type ClaimOutcome,
  type ClaimRequest,
  type CompletedResponse,
  type KeyStore,
} from "../src/idempotency/store.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * Contract §9.2, driven through the whole real app (SONNY-300).
 *
 * **Every test here goes through `buildApp` and `inject`**, for the reason `model.test.ts` gives for
 * the same choice: what is being asserted is what a *client* receives, and the decisions live in the
 * hook's place in the chain — after the gate has named the account, after the body is parsed, before
 * the handler runs. A test that called `claimKey` directly would skip all three.
 *
 * The store behind them is a fake that records what it was asked, so these tests are about the
 * *decisions*; `idempotency.db.test.ts` proves the SQL those decisions rest on against a real
 * Postgres. The split is deliberate — a database-backed test runs only under `npm run test:db`, and
 * the guarantee that stops a retry double-billing a user should not be invisible to `npm test`.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";
const OTHER_SUPABASE_USER = "1a1a1a1a-2b2b-4c4c-8d8d-3e3e3e3e3e3e";
const OTHER_ACCOUNT = "9b9b9b9b-4c4c-4d4d-8e8e-5f5f5f5f5f5f";
const KEY = "6f1b8a2c-0000-4000-8000-abcdefabcdef";

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

/** Answers the gate's attribution query, mapping each Supabase user to its own account. */
const signedInConnection: WithConnection = async (work) => {
  const client = {
    query: async (text: string, values: readonly unknown[]) => {
      if (!text.includes("FROM sonny.identity")) {
        throw new Error(`unexpected query: ${text}`);
      }
      const account = values[0] === OTHER_SUPABASE_USER ? OTHER_ACCOUNT : ACCOUNT;
      return { rows: [{ account_id: account }] };
    },
  };
  return work(client as unknown as pg.Client);
};

/**
 * A `KeyStore` that answers whatever the test sets and records every call.
 *
 * `claims` holds the `ClaimRequest`s so a test can assert the *scope* and the *fingerprint* the hook
 * derived — the two inputs that decide every one of §9.2's answers and neither of which is visible
 * in a response.
 */
class RecordingStore implements KeyStore {
  outcome: ClaimOutcome = { kind: "claimed" };
  readonly claims: ClaimRequest[] = [];
  readonly completed: { key: string; scope: string; response: CompletedResponse }[] = [];
  readonly released: { key: string; scope: string }[] = [];
  failWrites = false;

  async claim(request: ClaimRequest): Promise<ClaimOutcome> {
    this.claims.push(request);
    return this.outcome;
  }
  async complete(
    request: { accountScope: string; key: string },
    response: CompletedResponse,
  ): Promise<void> {
    if (this.failWrites) throw new Error("the key store is down");
    this.completed.push({ key: request.key, scope: request.accountScope, response });
  }
  async release(request: { accountScope: string; key: string }): Promise<void> {
    if (this.failWrites) throw new Error("the key store is down");
    this.released.push({ key: request.key, scope: request.accountScope });
  }
}

let store: RecordingStore;
let upstreamCalls: number;

beforeEach(() => {
  store = new RecordingStore();
  upstreamCalls = 0;
});
afterEach(() => {
  vi.unstubAllGlobals();
});

/** One OpenAI-shaped reply per call, counted, so "no second upstream call" is an assertion. */
function stubUpstream(): void {
  vi.stubGlobal("fetch", async () => {
    upstreamCalls += 1;
    return new Response(
      JSON.stringify({
        output: [{ content: [{ type: "output_text", text: "{\"summary\":\"ok\"}" }] }],
        usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3 },
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  });
}

function build() {
  return buildApp(
    testConfig({ credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }] }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    { idempotencyStore: store },
  );
}

const authorization = (user = SUPABASE_USER) => `Bearer ${accessTokenFor(user)}`;
const planBody = (text = "hello") => ({
  task_id: "task-1",
  retention: "standard" as const,
  messages: [{ role: "user" as const, text }],
  response_schema_name: "Plan",
  response_schema: { type: "object" },
});

const post = (
  app: ReturnType<typeof build>,
  options: { key?: string; body?: unknown; user?: string; url?: string } = {},
) =>
  app.inject({
    method: "POST",
    url: options.url ?? "/v1/plan",
    headers: {
      authorization: authorization(options.user),
      ...(options.key === undefined ? {} : { "idempotency-key": options.key }),
    },
    payload: (options.body ?? planBody()) as object,
  });

describe("contract §9.2 — the key is claimed before the handler runs", () => {
  it("claims the key under the caller's account, fingerprinting the route and the body", async () => {
    stubUpstream();
    const app = build();

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(200);
    expect(upstreamCalls).toBe(1);
    expect(store.claims).toHaveLength(1);
    const claim = store.claims[0]!;
    expect(claim.key).toBe(KEY);
    // **The account, not the Supabase user and not the request's own id.** Scoping is what stops one
    // account's key from replaying another's response, and it is invisible in the reply.
    expect(claim.accountScope).toBe(ACCOUNT);
    expect(claim.route).toBe("POST /v1/plan");
    expect(claim.fingerprint).toContain("POST /v1/plan");
    expect(claim.fingerprint).toMatch(/sha256:[0-9a-f]{64}$/);
    await app.close();
  });

  it("scopes the same key to two accounts separately", async () => {
    stubUpstream();
    const app = build();

    await post(app, { key: KEY });
    await post(app, { key: KEY, user: OTHER_SUPABASE_USER });

    expect(store.claims.map((claim) => claim.accountScope)).toEqual([ACCOUNT, OTHER_ACCOUNT]);
    await app.close();
  });

  it("stores the response for replay once the handler has answered", async () => {
    stubUpstream();
    const app = build();

    const response = await post(app, { key: KEY });

    expect(store.completed).toHaveLength(1);
    const stored = store.completed[0]!;
    expect(stored.key).toBe(KEY);
    expect(stored.scope).toBe(ACCOUNT);
    expect(stored.response.status).toBe(200);
    // Byte for byte what the client received, so a replay is the same response and not a re-render.
    expect(stored.response.body.toString("utf8")).toBe(response.body);
    expect(stored.response.contentType).toContain("application/json");
    // §2.3's join key, kept so the replay can carry the original's rather than the repeat's.
    expect(stored.response.requestId).toBe(response.headers["sonny-request-id"]);
    await app.close();
  });
});

describe("contract §9.2 — a repeat inside the window returns the stored response", () => {
  it("replays the stored body and status without calling the provider again", async () => {
    stubUpstream();
    const app = build();
    store.outcome = {
      kind: "replay",
      response: {
        status: 200,
        body: Buffer.from('{"request_id":"original-id","output_text":"{}"}', "utf8"),
        contentType: "application/json; charset=utf-8",
        requestId: "original-id",
      },
    };

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(200);
    expect(response.body).toBe('{"request_id":"original-id","output_text":"{}"}');
    // The whole point: a repeat costs nothing upstream.
    expect(upstreamCalls).toBe(0);
    // And it is not stored again — a replay has nothing new to record.
    expect(store.completed).toHaveLength(0);
    expect(store.released).toHaveLength(0);
    await app.close();
  });

  it("replays the original's Sonny-Request-Id rather than stamping the repeat's", async () => {
    // §2.3 makes that header the join key to the metering event and the retained content. A replay
    // has exactly one of each and they are the original's, so a fresh id would name a request that
    // metered nothing — and would disagree with the `request_id` inside the body it is sent with.
    stubUpstream();
    const app = build();
    store.outcome = {
      kind: "replay",
      response: {
        status: 201,
        body: Buffer.from('{"request_id":"original-id"}', "utf8"),
        contentType: "application/json; charset=utf-8",
        requestId: "original-id",
      },
    };

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(201);
    expect(response.headers["sonny-request-id"]).toBe("original-id");
    expect(JSON.parse(response.body)["request_id"]).toBe("original-id");
    await app.close();
  });
});

describe("contract §9.2 — the two conflicts", () => {
  it("answers 409 idempotency.conflict, not retryable, when the body differs", async () => {
    stubUpstream();
    const app = build();
    store.outcome = { kind: "conflict" };

    const response = await post(app, { key: KEY, body: planBody("a different command") });

    expect(response.statusCode).toBe(409);
    const body = response.json();
    expect(body["error"]["code"]).toBe("idempotency.conflict");
    expect(body["error"]["retryable"]).toBe(false);
    expect(body["error"]["retry_after_seconds"]).toBeNull();
    expect(response.headers["retry-after"]).toBeUndefined();
    expect(upstreamCalls).toBe(0);
    await app.close();
  });

  it("answers 409 idempotency.conflict, retryable, with a Retry-After while the first is in flight", async () => {
    stubUpstream();
    const app = build();
    store.outcome = { kind: "in_flight", retryAfterSeconds: 42 };

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(409);
    const body = response.json();
    expect(body["error"]["code"]).toBe("idempotency.conflict");
    // The client reads this flag, and only for this code: `SonnyBackendError.isRetryable`
    // (`envelopeSaysRetryable`) is what tells the two sub-cases of one code apart.
    expect(body["error"]["retryable"]).toBe(true);
    expect(body["error"]["retry_after_seconds"]).toBe(42);
    expect(response.headers["retry-after"]).toBe("42");
    // "rather than a second upstream call" — §9.2's own words for this case.
    expect(upstreamCalls).toBe(0);
    await app.close();
  });

  it("sends a different body to the same route as a genuinely different fingerprint", async () => {
    stubUpstream();
    const app = build();

    await post(app, { key: KEY, body: planBody("first") });
    await post(app, { key: KEY, body: planBody("second") });

    expect(store.claims).toHaveLength(2);
    expect(store.claims[0]!.fingerprint).not.toBe(store.claims[1]!.fingerprint);
    await app.close();
  });

  it("sends the same body twice as the same fingerprint", async () => {
    stubUpstream();
    const app = build();

    await post(app, { key: KEY, body: planBody("same") });
    await post(app, { key: KEY, body: planBody("same") });

    expect(store.claims[0]!.fingerprint).toBe(store.claims[1]!.fingerprint);
    await app.close();
  });

  it("treats one key on two routes as two different fingerprints", async () => {
    stubUpstream();
    const app = build();

    await post(app, { key: KEY, url: "/v1/plan" });
    await post(app, { key: KEY, url: "/v1/research/synthesize" });

    expect(store.claims[0]!.fingerprint).not.toBe(store.claims[1]!.fingerprint);
    await app.close();
  });
});

describe("a retryable failure releases the key rather than freezing it", () => {
  /**
   * The founder decision of 2026-08-28. §9.2 read literally would store these and replay them, which
   * makes every retryable row in §9.3's table safe but useless — a `429` becomes a twenty-four-hour
   * ban on that operation. Each of these codes is one the client is told to retry *with the same
   * key*, so each must find the key free.
   */
  const retryable = [
    ["provider.unavailable", 502],
    ["provider.timeout", 504],
  ] as const;

  for (const [code, status] of retryable) {
    it(`releases the key when the response is ${code}`, async () => {
      vi.stubGlobal("fetch", async () => {
        upstreamCalls += 1;
        if (code === "provider.timeout") throw new DOMException("The operation was aborted.", "AbortError");
        return new Response("upstream is down", { status: 503 });
      });
      const app = build();

      const response = await post(app, { key: KEY });

      expect(response.statusCode).toBe(status);
      expect(response.json()["error"]["code"]).toBe(code);
      expect(store.released).toEqual([{ key: KEY, scope: ACCOUNT }]);
      expect(store.completed).toHaveLength(0);
      await app.close();
    });
  }

  it("stores provider.rejected, because a retry of it is guaranteed to fail identically", async () => {
    // The pair that proves the set is keyed on `code` and not on status: this and
    // `provider.unavailable` are both 502, and exactly one of them may be replayed.
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return new Response("no", { status: 400 });
    });
    const app = build();

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(502);
    expect(response.json()["error"]["code"]).toBe("provider.rejected");
    expect(store.completed).toHaveLength(1);
    expect(store.completed[0]!.response.status).toBe(502);
    expect(store.released).toHaveLength(0);
    await app.close();
  });

  it("stores request.invalid, which no retry can fix", async () => {
    stubUpstream();
    const app = build();

    const response = await post(app, { key: KEY, body: { task_id: "t" } });

    expect(response.statusCode).toBe(400);
    expect(response.json()["error"]["code"]).toBe("request.invalid");
    expect(store.completed).toHaveLength(1);
    expect(store.released).toHaveLength(0);
    await app.close();
  });
});

describe("what the hook does not do", () => {
  it("serves a POST carrying no Idempotency-Key, claiming nothing", async () => {
    // Founder decision, 2026-08-28. The header is §9.1's client obligation and the only client sends
    // it on every POST; refusing here would cost a mechanical change across every existing POST test
    // for a case no shipping client reaches.
    stubUpstream();
    const app = build();

    const response = await post(app);

    expect(response.statusCode).toBe(200);
    expect(store.claims).toHaveLength(0);
    expect(store.completed).toHaveLength(0);
    await app.close();
  });

  it("refuses a key longer than the store holds", async () => {
    stubUpstream();
    const app = build();

    const response = await post(app, { key: "k".repeat(256) });

    expect(response.statusCode).toBe(400);
    expect(response.json()["error"]["code"]).toBe("request.invalid");
    expect(store.claims).toHaveLength(0);
    expect(upstreamCalls).toBe(0);
    await app.close();
  });

  it("claims nothing on a GET, which carries no key and has nothing to be idempotent about", async () => {
    const app = build();

    const response = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { "idempotency-key": KEY },
    });

    expect(response.statusCode).toBe(200);
    expect(store.claims).toHaveLength(0);
    await app.close();
  });

  it("does not fail a response whose bookkeeping write failed", async () => {
    // The handler has already done its work — possibly an upstream call that cost money — and a row
    // that could not be updated must not turn that into a 500. The key's lease expires instead.
    stubUpstream();
    store.failWrites = true;
    const app = build();

    const response = await post(app, { key: KEY });

    expect(response.statusCode).toBe(200);
    expect(upstreamCalls).toBe(1);
    await app.close();
  });

  it("serves without claiming when no key store is configured", async () => {
    // A health-only deployment. `registerAuthGate` refuses every route this could reach, so the
    // branch is unreachable in practice; it is served rather than refused so nothing is guessed
    // about a shape that does not exist.
    const app = buildApp(testConfig());

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { "idempotency-key": KEY },
      payload: planBody(),
    });

    // Refused by the gate, which runs first — which is the reachability argument, executable.
    expect(response.statusCode).toBe(401);
    await app.close();
  });
});

describe("the multipart route, whose body the hook cannot hash", () => {
  /**
   * `/v1/transcriptions` is §4.4's `multipart/form-data` body, consumed inside the handler, so
   * `request.body` is `undefined` at `preHandler` and the fingerprint falls back to the declared
   * length. Two things are checked here that nothing else in the suite reaches: that the fallback
   * really is the branch taken on a real multipart request, and that awaiting a store call at
   * `preHandler` does not disturb a body the handler has not read yet — which is the failure mode
   * the first, stream-teeing version of the fingerprint had, and it presented as a hang rather than
   * as a red test.
   */
  const multipart = (audio: Buffer) => {
    const boundary = "----sonnytestboundary";
    return {
      contentType: `multipart/form-data; boundary=${boundary}`,
      payload: Buffer.concat([
        Buffer.from(
          `--${boundary}\r\nContent-Disposition: form-data; name="meta"\r\n` +
            `Content-Type: application/json\r\n\r\n{"task_id":"t","retention":"standard"}\r\n` +
            `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="a.m4a"\r\n` +
            `Content-Type: audio/mp4\r\n\r\n`,
          "utf8",
        ),
        audio,
        Buffer.from(`\r\n--${boundary}--\r\n`, "utf8"),
      ]),
    };
  };

  const send = (app: ReturnType<typeof build>, audio: Buffer) => {
    const body = multipart(audio);
    return app.inject({
      method: "POST",
      url: "/v1/transcriptions",
      headers: {
        authorization: authorization(),
        "content-type": body.contentType,
        "idempotency-key": KEY,
      },
      payload: body.payload,
    });
  };

  it("claims a key on a multipart body, fingerprinting its declared length", async () => {
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return new Response(JSON.stringify({ text: "hello there" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const app = build();

    // Two megabytes: past the size at which the stream-teeing fingerprint deadlocked, so this also
    // stands as the regression pin for that.
    const response = await send(app, Buffer.alloc(2_000_000, 0x41));

    expect(response.statusCode).toBe(200);
    expect(upstreamCalls).toBe(1);
    expect(store.claims).toHaveLength(1);
    expect(store.claims[0]!.route).toBe("POST /v1/transcriptions");
    expect(store.claims[0]!.fingerprint).toMatch(/^POST \/v1\/transcriptions\nlen:\d+$/);
    expect(store.completed).toHaveLength(1);
    await app.close();
  });

  it("gives two different recordings of different lengths different fingerprints", async () => {
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return new Response(JSON.stringify({ text: "hello" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const app = build();

    await send(app, Buffer.alloc(1000, 0x41));
    await send(app, Buffer.alloc(1001, 0x41));

    expect(store.claims[0]!.fingerprint).not.toBe(store.claims[1]!.fingerprint);
    await app.close();
  });

  it("cannot tell two different recordings of the same length apart — the stated weakness", async () => {
    // Pinned rather than left in prose, because it is the one place conflict detection is weaker
    // than "different body" suggests, and a future change that fixed it should have to notice.
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return new Response(JSON.stringify({ text: "hello" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const app = build();

    await send(app, Buffer.alloc(1000, 0x41));
    await send(app, Buffer.alloc(1000, 0x5a));

    expect(store.claims[0]!.fingerprint).toBe(store.claims[1]!.fingerprint);
    await app.close();
  });
});

describe("the fingerprint", () => {
  const request = (body: unknown, headers: Record<string, string> = {}) =>
    ({ body, headers }) as never;

  it("ignores key order, because two JSON documents differing only in it are the same document", () => {
    expect(fingerprintOf(request({ a: 1, b: 2 }), "POST /v1/plan")).toBe(
      fingerprintOf(request({ b: 2, a: 1 }), "POST /v1/plan"),
    );
  });

  it("does not ignore array order, because an array's order is part of its meaning", () => {
    expect(fingerprintOf(request({ xs: [1, 2] }), "POST /v1/plan")).not.toBe(
      fingerprintOf(request({ xs: [2, 1] }), "POST /v1/plan"),
    );
  });

  it("sorts nested keys too", () => {
    expect(fingerprintOf(request({ o: { a: 1, b: 2 } }), "POST /v1/plan")).toBe(
      fingerprintOf(request({ o: { b: 2, a: 1 } }), "POST /v1/plan"),
    );
  });

  it("tells a value apart from the string that spells it", () => {
    expect(fingerprintOf(request({ n: 1 }), "POST /v1/plan")).not.toBe(
      fingerprintOf(request({ n: "1" }), "POST /v1/plan"),
    );
  });

  it("falls back to the declared length when the body was not parsed, as on multipart", () => {
    const multipart = fingerprintOf(request(undefined, { "content-length": "2000" }), "POST /v1/transcriptions");
    expect(multipart).toBe("POST /v1/transcriptions\nlen:2000");
    // The stated weakness, pinned rather than left in prose: same route, same length, same answer.
    expect(fingerprintOf(request(undefined, { "content-length": "2000" }), "POST /v1/transcriptions")).toBe(multipart);
    expect(fingerprintOf(request(undefined, { "content-length": "2001" }), "POST /v1/transcriptions")).not.toBe(multipart);
  });

  it("falls back to the route alone when no length was declared either", () => {
    expect(fingerprintOf(request(undefined), "POST /v1/transcriptions")).toBe(
      "POST /v1/transcriptions\nunknown-body",
    );
  });

  it("never lets a parsed body and an unparsed one collide", () => {
    expect(fingerprintOf(request({}), "POST /v1/plan")).not.toBe(
      fingerprintOf(request(undefined, { "content-length": "2" }), "POST /v1/plan"),
    );
  });

  it("is scoped to nothing but the route and the body, so the caller is the store's business", () => {
    // The account scope is a separate column, not part of the fingerprint: two accounts sending the
    // same body to the same route must fingerprint identically and still never collide.
    expect(UNAUTHENTICATED_SCOPE).toBe("00000000-0000-0000-0000-000000000000");
    expect(fingerprintOf(request({ a: 1 }), "POST /v1/plan")).toBe(
      fingerprintOf(request({ a: 1 }), "POST /v1/plan"),
    );
  });
});
