import { randomUUID } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import type {
  ClaimOutcome,
  ClaimRequest,
  CompletedResponse,
  KeyStore,
} from "../src/idempotency/store.js";
import {
  METERED_ROUTES,
  UNMETERED_POST_ROUTES,
  meteredRoutes,
  meteringOutcomes,
  modelForRoute,
  outcomeFor,
  type MeteringEvent,
} from "../src/metering/event.js";
import type { MeteringStore, MeteringWriteOutcome } from "../src/metering/store.js";
import { BODY_LIMIT_BYTES } from "../src/model/limits.js";
import { parseUsageArguments } from "../src/usage.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { transcriptionBody } from "./support/multipart.js";
import { expectPopulationIsReal, registeredRoutes } from "./support/routes.js";
import { accessTokenFor } from "./support/tokens.js";
import { signedInConnectionTo } from "./support/connection.js";
import { WithoutOAuth } from "./support/without-oauth.js";

/**
 * Contract §11's metering event, driven through the whole real app (SONNY-133).
 *
 * **Every test here goes through `buildApp` and `inject`**, for the reason `model.test.ts` and
 * `idempotency.test.ts` both give: the decisions live in the hook's place in the chain — after the
 * gate has named the account, after the idempotency hook has decided whether this request holds the
 * key's claim, after the handler has deposited what it learned — and a test that built an event by
 * hand would skip all three. What is asserted is the event a *client's request* actually produced.
 *
 * **`POST /v1/transcriptions` is the one metered route now** (V2 plan phase 7): every other model
 * call is the gateway's own, inside a task, and is metered as an `agent_model_call` row instead. So
 * every request below is a recording, and the §4.4 multipart body is what carries it.
 *
 * The store behind them is a fake that models the claim the same way `writeMeteringEvent` does, so
 * these tests are about the decisions; `metering.db.test.ts` proves the SQL and the real
 * `metering_claimed_at` claim against a Postgres. The split is the one SONNY-300 made for the same
 * reason: a database-backed test runs only under `npm run test:db`, and the guarantee that stops a
 * retry double-billing a user should not be invisible to `npm test`.
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

/** Answers the gate's one attribution query. Anything else reaching it is a red test. */
const signedInConnection = signedInConnectionTo({ account: ACCOUNT, where: "from a metering test" });

/**
 * A `KeyStore` that behaves the way the real one does, rather than answering a value a test set.
 *
 * **The retry criterion needs the state machine, not a stub.** `idempotency.test.ts`' store answers
 * whatever `outcome` a test assigns, which is right for asserting what each outcome *produces*. What
 * this file has to assert is different: that a real second attempt with one key writes one event —
 * including the case §9.2 carves out, where a retryable failure releases the key so the retry
 * genuinely re-runs and calls the provider a second time. That path needs `complete`, `release` and
 * a re-claim to actually happen, so this models them.
 */
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
    // The fingerprint before every other branch, which is the ordering the real store documents.
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
    // The fencing token, for the same reason the real store has one: a superseded holder's write
    // must match nothing rather than land on its successor's claim.
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
}

/**
 * A `MeteringStore` that keeps the same one-event-per-key promise `writeMeteringEvent` keeps.
 *
 * `attempts` records every call including the ones that wrote nothing, so a test can tell "the hook
 * never asked" — a replay, a conflict — from "the hook asked and the claim was taken", which are the
 * two halves of the retry guarantee and produce the same empty table.
 */
class ClaimingMeteringStore implements MeteringStore {
  readonly events: MeteringEvent[] = [];
  readonly attempts: { event: MeteringEvent; key: string | null }[] = [];
  private readonly claimed = new Set<string>();
  failWrites = false;

  async write(event: MeteringEvent, key: string | null): Promise<MeteringWriteOutcome> {
    this.attempts.push({ event, key });
    if (this.failWrites) throw new Error("the metering store is down");
    if (key !== null) {
      const id = `${event.accountId} ${key}`;
      if (this.claimed.has(id)) return "already_claimed";
      this.claimed.add(id);
    }
    this.events.push(event);
    return "written";
  }
}

let metering: ClaimingMeteringStore;
let keys: StatefulKeyStore;
let upstreamCalls: number;

beforeEach(() => {
  metering = new ClaimingMeteringStore();
  keys = new StatefulKeyStore();
  upstreamCalls = 0;
});
afterEach(() => {
  vi.unstubAllGlobals();
});

const CREDENTIALS: Config["credentials"] = [
  { provider: "openai", keys: ["sk-test-openai-key"] },
  { provider: "tavily", keys: ["tvly-test-search-key"] },
];

function build(overrides: Partial<Config> = {}) {
  return buildApp(
    testConfig({ credentials: CREDENTIALS, ...overrides }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    { idempotencyStore: keys, meteringStore: metering, entitlementStore: fakeEntitlementStore() },
  );
}

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

/**
 * §2.2's headers. `null` means "send no `Idempotency-Key`", which is a case with its own behaviour.
 *
 * **`null` rather than `undefined` for the absent key**, because a defaulted parameter treats an
 * explicit `undefined` as absent and hands back the default — so `headers(null)` would have
 * sent a key while reading as if it did not, and the keyless test would have passed for the wrong
 * reason. It did, in the first draft.
 */
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

/** Stub `fetch`, counting the calls so "the provider really ran twice" is an assertion. */
function stubUpstream(respond: (call: number) => Response | Promise<Response> | never): void {
  vi.stubGlobal("fetch", async () => {
    upstreamCalls += 1;
    return respond(upstreamCalls);
  });
}

const TRANSCRIPTION_REPLY = {
  text: "Open Safari",
  usage: { type: "tokens", input_tokens: 42, output_tokens: 3, total_tokens: 45 },
};

const META = { task_id: "task-1", retention: "standard" };

/**
 * One `POST /v1/transcriptions`, ready for `inject`. The body is §4.4's two parts; the audio is the
 * one thing a test varies to make two bodies differ, since the idempotency fingerprint of a
 * multipart request is its declared length.
 */
function transcription(
  options: { key?: string | null; meta?: unknown; audio?: Buffer } = {},
) {
  const body = transcriptionBody(options.meta ?? META, options.audio ?? Buffer.from("fake-audio-bytes"));
  return {
    method: "POST" as const,
    url: "/v1/transcriptions",
    headers: {
      ...headers(options.key === undefined ? randomUUID() : options.key),
      "content-type": body.contentType,
    },
    payload: body.payload,
  };
}

/** The one event this request produced. Fails loudly rather than returning undefined. */
function onlyEvent(): MeteringEvent {
  expect(metering.events).toHaveLength(1);
  return metering.events[0]!;
}

describe("the transcription route writes a metering event", () => {
  it("records the account, the route, the provider, the model and the tokens", async () => {
    // The whole §11 row for one ordinary call, asserted on concrete values rather than on a row
    // having appeared. `provider` and `model` are the two the client is never told (§4.2) and the
    // two failover accounting needs, so they are the ones worth naming exactly. The task id and the
    // retention come from the meta part, which the handler deposits by hand: the body is multipart,
    // so the hook cannot read them off `request.body` the way it could a JSON body.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const key = randomUUID();

    const response = await app.inject(transcription({ key }));
    expect(response.statusCode).toBe(200);

    const event = onlyEvent();
    expect(event.route).toBe("transcription");
    expect(event.accountId).toBe(ACCOUNT);
    expect(event.idempotencyKey).toBe(key);
    expect(event.requestId).toBe(response.headers["sonny-request-id"]);
    expect(event.provider).toBe("openai");
    expect(event.failedOver).toEqual([]);
    // The transcription model, not the text one — `testConfig` names both for OpenAI, and §11 wants
    // the identifier that actually ran.
    expect(event.model).toBe("test-transcription-model");
    expect(event.inputTokens).toBe(42);
    expect(event.outputTokens).toBe(3);
    expect(event.totalTokens).toBe(45);
    expect(event.tokenSource).toBe("reported");
    expect(event.audioDurationSeconds).toBeNull();
    expect(event.outcome).toBe("ok");
    expect(event.taskId).toBe("task-1");
    expect(event.retention).toBe("standard");
    expect(event.clientVersion).toBe("1.0.0+412");
    expect(event.sessionId).toBeNull();
    expect(event.sessionIteration).toBeNull();
    expect(event.imageBytes).toBeNull();
    await app.close();
  });

  it("records the audio duration when the provider reports a duration instead of tokens", async () => {
    stubUpstream(() => jsonResponse({ text: "open safari", usage: { seconds: 4.8 } }));
    const app = build();

    const response = await app.inject(
      transcription({ meta: { task_id: "task-audio", retention: "standard" } }),
    );
    expect(response.statusCode).toBe(200);

    const event = onlyEvent();
    expect(event.audioDurationSeconds).toBe(4.8);
    // A duration is a measurement, so the source is `reported` — and the token counts stay empty
    // rather than being read as a measured zero.
    expect(event.tokenSource).toBe("reported");
    expect(event.totalTokens).toBeNull();
    expect(event.taskId).toBe("task-audio");
    await app.close();
  });

  it("records the tokens this server estimated as estimated, never as reported", async () => {
    // §4.2: "The server estimates only when the provider reported nothing, and says which it did."
    // Summing the two would erase exactly that, which is why the query path keeps them apart.
    stubUpstream(() => jsonResponse({ text: "Open Safari and find the migration guide" }));
    const app = build();

    await app.inject(transcription());

    const event = onlyEvent();
    expect(event.tokenSource).toBe("estimated");
    expect(event.outputTokens).toBeGreaterThan(0);
    // Nothing here can count the audio's input tokens, so that one is absent rather than guessed.
    expect(event.inputTokens).toBeNull();
    await app.close();
  });

  it("records a duration and a byte count for the request and the response", async () => {
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const request = transcription();

    const response = await app.inject(request);

    const event = onlyEvent();
    // §11's `request_bytes` is the decoded size, and nothing in this gateway decodes a
    // `Content-Encoding`, so the declared length is that size. `inject` sets it from the payload.
    expect(event.requestBytes).toBe(request.payload.byteLength);
    expect(event.responseBytes).toBe(Buffer.byteLength(response.body, "utf8"));
    expect(event.durationMs).toBeGreaterThanOrEqual(0);
    expect(event.upstreamDurationMs).toBeGreaterThanOrEqual(0);
    await app.close();
  });
});

describe("an incognito run is metered identically", () => {
  it("writes an event carrying retention none, with every cost field present", async () => {
    // §10.1: "Metering runs either way. Incognito changes what is stored, never what is billed. A
    // metering design that dropped these events would silently make those runs free, and it is the
    // case most likely to be dropped by accident."
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    const response = await app.inject(
      transcription({ meta: { task_id: "task-1", retention: "none" } }),
    );
    expect(response.statusCode).toBe(200);

    const event = onlyEvent();
    expect(event.retention).toBe("none");
    // Every cost field is present, which is the actual claim: this run is billed like any other.
    expect(event.provider).toBe("openai");
    expect(event.inputTokens).toBe(42);
    expect(event.totalTokens).toBe(45);
    expect(event.taskId).toBe("task-1");
    expect(event.outcome).toBe("ok");
    await app.close();
  });
});

describe("a retry produces one event, not two", () => {
  it("does not even ask the store when a repeat replays a stored response", async () => {
    // The ordinary retry: inside the twenty-four hours the handler never runs, so nothing was spent
    // and nothing must be recorded. `attempts` is what distinguishes this from the claim refusing —
    // both leave one event, and only one of them called the store twice.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const key = randomUUID();

    const first = await app.inject(transcription({ key }));
    const second = await app.inject(transcription({ key }));

    expect(first.statusCode).toBe(200);
    expect(second.statusCode).toBe(200);
    expect(second.headers["sonny-request-id"]).toBe(first.headers["sonny-request-id"]);
    expect(upstreamCalls).toBe(1);
    expect(metering.events).toHaveLength(1);
    expect(metering.attempts).toHaveLength(1);
    await app.close();
  });

  it("writes one event when a released retryable failure lets the retry genuinely re-run", async () => {
    // **The case the claim exists for**, and the one a replay cannot cover. §9.2's founder decision
    // of 2026-08-28 releases the key on a retryable failure so a `503` is not a twenty-four-hour ban
    // on that operation — so a second upstream call really does happen under one key, and it must go
    // unbilled. SONNY-300's hand-over states it as "that is the guarantee working, not a gap".
    stubUpstream((call) =>
      call === 1 ? jsonResponse({ error: "overloaded" }, 503) : jsonResponse(TRANSCRIPTION_REPLY),
    );
    const app = build();
    const key = randomUUID();

    const first = await app.inject(transcription({ key }));
    const second = await app.inject(transcription({ key }));

    // The retry really re-ran: a new request id, a second provider call, and a different answer.
    expect(first.statusCode).toBe(502);
    expect(second.statusCode).toBe(200);
    expect(second.headers["sonny-request-id"]).not.toBe(first.headers["sonny-request-id"]);
    expect(upstreamCalls).toBe(2);

    // And it was not billed. The store was asked twice and wrote once.
    expect(metering.attempts).toHaveLength(2);
    expect(metering.events).toHaveLength(1);
    // The event that survives is the first attempt's, recorded as a provider failure — which is the
    // direction §9.2 chooses deliberately, erring toward the user.
    expect(metering.events[0]!.outcome).toBe("provider_error");
    expect(metering.events[0]!.requestId).toBe(first.headers["sonny-request-id"]);
    await app.close();
  });

  it("never lets a conflicting request take the claim the request doing the work needs", async () => {
    // A `409 idempotency.conflict` did no work, so metering it would be wrong for the ordinary
    // reason. It would also be worse than free: taking this key's one claim would leave the request
    // that really ran with nothing to spend, and its real cost would go unrecorded. So the hook does
    // not ask the store at all.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const key = randomUUID();

    await app.inject(transcription({ key }));
    // A different recording under the same key: a different declared length, so a different
    // fingerprint.
    const conflicting = await app.inject(
      transcription({ key, audio: Buffer.from("a different, longer recording") }),
    );

    expect(conflicting.statusCode).toBe(409);
    expect(upstreamCalls).toBe(1);
    expect(metering.attempts).toHaveLength(1);
    expect(metering.events).toHaveLength(1);
    await app.close();
  });

  it("meters a POST carrying no Idempotency-Key, and records that it had none", async () => {
    // SONNY-300's stated trap, and the branch that avoids it: `claimMeteringEvent` answers `false`
    // for a key that has no row, which is the same value as "already taken". Inferring from that
    // `false` would make every keyless request free. The key's *presence* is checked instead, and a
    // keyless one is written unconditionally — it has no at-most-once guarantee available to it,
    // because there is no key for one to be about.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    const response = await app.inject(transcription({ key: null }));
    expect(response.statusCode).toBe(200);

    const event = onlyEvent();
    expect(event.idempotencyKey).toBeNull();
    expect(metering.attempts[0]!.key).toBeNull();
    expect(event.outcome).toBe("ok");
    await app.close();
  });

  it("meters two keyless requests separately, because neither has a guarantee to share", async () => {
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    await app.inject(transcription({ key: null }));
    await app.inject(transcription({ key: null }));

    expect(upstreamCalls).toBe(2);
    expect(metering.events).toHaveLength(2);
    await app.close();
  });
});

describe("which requests are metered at all", () => {
  it("writes nothing for a request refused at the gate", async () => {
    // §11's `user_id` comes "from the authenticated session", so there is no event to write. Nothing
    // was spent either: the gate's `onRequest` runs before the body is parsed, let alone forwarded.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const request = transcription();

    const response = await app.inject({
      ...request,
      headers: { "content-type": request.headers["content-type"] },
    });

    expect(response.statusCode).toBe(401);
    expect(upstreamCalls).toBe(0);
    expect(metering.attempts).toHaveLength(0);
    await app.close();
  });

  it("writes nothing for an unmetered route", async () => {
    const app = build();
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    expect(metering.attempts).toHaveLength(0);
    await app.close();
  });

  it("does not fail the response when the metering write throws", async () => {
    // **The write is on the response path since it moved to `onSend`, so this is no longer a
    // formality.** A metering write that failed loudly would turn a call the provider already served
    // into a 500 — the worst of both — so it is caught and logged, the same call
    // `idempotency/hook.ts` makes for its own write one hook earlier.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    metering.failWrites = true;
    const app = build();

    const response = await app.inject(transcription());

    expect(response.statusCode).toBe(200);
    expect(JSON.parse(response.body).text).toBe("Open Safari");
    expect(metering.attempts).toHaveLength(1);
    expect(metering.events).toHaveLength(0);
    await app.close();
  });

  it("never puts the provider or the model into the response the client reads", async () => {
    // §4.2: "The response names no provider and no model." The event carries both, so the check that
    // matters is on the bytes that leave — a field the app receives is a field that eventually gets
    // rendered, and SONNY-132's acceptance criteria include nothing in the app mentioning a provider.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    const response = await app.inject(transcription());

    expect(onlyEvent().provider).toBe("openai");
    expect(response.body).not.toContain("openai");
    expect(response.body).not.toContain("test-transcription-model");
    await app.close();
  });
});

describe("what the outcome says about where the money went", () => {
  it("records a refusal that never reached a provider as refused, with no provider named", async () => {
    // SONNY-131's proposal is emphatic about this one: "those refusals happen before any upstream
    // call, and an event that did not distinguish them would bill a user for a request that never
    // left the gateway." An empty recording is refused after the meta part was validated, so the
    // event is still attributable to its task.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    const response = await app.inject(transcription({ audio: Buffer.alloc(0) }));

    expect(response.statusCode).toBe(400);
    expect(upstreamCalls).toBe(0);
    const event = onlyEvent();
    expect(event.outcome).toBe("refused");
    expect(event.provider).toBeNull();
    expect(event.model).toBeNull();
    expect(event.upstreamDurationMs).toBeNull();
    expect(event.taskId).toBe("task-1");
    expect(event.retention).toBe("standard");
    await app.close();
  });

  it("records an oversize recording as refused, carrying the size that was refused", async () => {
    // §6.2 asks for the refusal to be diagnosable. The event is where that is answered a week later:
    // the declared length is the size the caller tried to send, and nothing was forwarded.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();
    const request = transcription({ audio: Buffer.alloc(BODY_LIMIT_BYTES.transcriptions + 1, 0x41) });

    const response = await app.inject(request);

    expect(response.statusCode).toBe(413);
    expect(upstreamCalls).toBe(0);
    const event = onlyEvent();
    expect(event.outcome).toBe("refused");
    expect(event.requestBytes).toBe(request.payload.byteLength);
    expect(event.requestBytes).toBeGreaterThan(BODY_LIMIT_BYTES.transcriptions);
    expect(event.provider).toBeNull();
    await app.close();
  });

  it("records a route with no configured provider as refused, not as a provider failure", async () => {
    // A `502 provider.unavailable` that no provider was ever asked for. Without the
    // `upstreamAttempted` gate, a deployment missing one credential would record a provider failure
    // per request against a provider it never called — and failover accounting would be a fiction.
    const app = build({ credentials: [{ provider: "tavily", keys: ["tvly-test-search-key"] }] });

    const response = await app.inject(transcription());

    expect(response.statusCode).toBe(502);
    expect(JSON.parse(response.body).error.code).toBe("provider.unavailable");
    const event = onlyEvent();
    expect(event.outcome).toBe("refused");
    expect(event.provider).toBeNull();
    await app.close();
  });

  it("records a provider that answered 500 as a provider failure, and the time it wasted", async () => {
    stubUpstream(() => jsonResponse({ error: "boom" }, 500));
    const app = build();

    const response = await app.inject(transcription());

    expect(response.statusCode).toBe(502);
    expect(upstreamCalls).toBe(1);
    const event = onlyEvent();
    expect(event.outcome).toBe("provider_error");
    expect(event.upstreamDurationMs).toBeGreaterThanOrEqual(0);
    // Nothing served, so nothing to attribute — `failedOver` is what says a provider was tried.
    expect(event.provider).toBeNull();
    await app.close();
  });

  it("records this gateway's own failure as server_error rather than as a provider's", async () => {
    // A `500 server.error` is §7.2 case 6 — this gateway's bug. Filing it as a provider failure
    // would make the vendor look bad for the gateway's own crash, which is the reason `outcomeFor`
    // checks the code before it checks anything about a status.
    // A provider that answers something this gateway did not anticipate — here, a `fetch` that
    // resolves to no response at all. The adapter reads `.ok` off it and raises a `TypeError`, which
    // is none of the seam's three typed failures, so the route rethrows it and the root handler
    // answers §7.2 case 6. A stub that *threw* would be the wrong shape: `fetch` throwing is a
    // transport failure and `upstreamTransportError` correctly calls that `provider.unavailable`.
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return undefined;
    });
    const app = build();

    const response = await app.inject(transcription());

    expect(response.statusCode).toBe(500);
    expect(JSON.parse(response.body).error.code).toBe("server.error");
    expect(onlyEvent().outcome).toBe("server_error");
    await app.close();
  });
});

describe("a caller who goes away mid-call", () => {
  it("records it as client_cancelled once a provider had been reached", async () => {
    // §12's third rule: "A cancelled request may still have cost money. If the server observed the
    // upstream call complete, it writes a metering event with `outcome: client_cancelled`. Silently
    // free cancellations would be a hole in the spend cap."
    //
    // **A real socket, because `inject` has none.** `light-my-request` cannot be disconnected, so
    // this is the one test here that listens on a port: the whole point is that the caller's
    // connection goes away while the handler is still running, which is a property of the socket
    // rather than of the framework. It is also the only test that reaches the second writer — every
    // other request in this file is answered, so `onSend` writes it.
    //
    // **Nothing here sleeps, and that is deliberate.** Every step waits on a signal the other side
    // publishes — the stub says when the provider was reached, the store says when the event was
    // written — because a test that slept and then asserted would be betting on a wall clock, which
    // is the shape `CLAUDE.md` records as manufacturing false results. If a signal never arrives the
    // test hangs and vitest's own timeout ends it, which is a failure that cannot be mistaken for a
    // pass.
    let reachedProvider!: () => void;
    const providerReached = new Promise<void>((resolve) => {
      reachedProvider = resolve;
    });
    let letProviderAnswer!: () => void;
    const providerMayAnswer = new Promise<void>((resolve) => {
      letProviderAnswer = resolve;
    });

    // Kept before the stub replaces the global, because the client request below is a real `fetch`
    // and a stubbed one would call the provider stub instead of the server.
    const realFetch = globalThis.fetch;
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      reachedProvider();
      await providerMayAnswer;
      return jsonResponse(TRANSCRIPTION_REPLY);
    });

    let eventWritten!: (event: MeteringEvent) => void;
    const written = new Promise<MeteringEvent>((resolve) => {
      eventWritten = resolve;
    });
    const events: MeteringEvent[] = [];
    const store: MeteringStore = {
      async write(event) {
        events.push(event);
        eventWritten(event);
        return "written";
      },
    };

    const app = buildApp(
      testConfig({ credentials: CREDENTIALS }),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
      { idempotencyStore: keys, meteringStore: store, entitlementStore: fakeEntitlementStore() },
    );
    await app.listen({ port: 0, host: "127.0.0.1" });
    const address = app.server.address();
    if (address === null || typeof address === "string") throw new Error("no port to call");

    const controller = new AbortController();
    const request = transcription();
    const inflight = realFetch(`http://127.0.0.1:${address.port}${request.url}`, {
      method: "POST",
      headers: request.headers,
      body: request.payload,
      signal: controller.signal,
    }).catch(() => undefined);

    await providerReached;
    controller.abort();

    // **The provider is deliberately still held here.** The handler cannot finish, so `onSend`
    // cannot run, so the only thing that can resolve `written` is the `close` listener — which is
    // exactly the path being asserted. Releasing first would let the two race, and the test would
    // pass or fail on which won.
    const event = await written;
    expect(event.outcome).toBe("client_cancelled");
    expect(event.route).toBe("transcription");
    expect(event.accountId).toBe(ACCOUNT);
    // The call really was made, which is the whole reason this is not free.
    expect(upstreamCalls).toBe(1);
    // And exactly one event: the handler finishing afterwards must not write a second.
    letProviderAnswer();
    await inflight;
    expect(events).toHaveLength(1);
    await app.close();
  });

  it("records a request that ends before any provider was reached as refused", async () => {
    // The other half of §12's sentence, and the reason `outcomeFor` takes `upstreamAttempted`: a
    // request that ended before anything was spent is an ordinary refusal. Driven here through a
    // meta part this route refuses, so no provider is ever opened.
    stubUpstream(() => jsonResponse(TRANSCRIPTION_REPLY));
    const app = build();

    const response = await app.inject(transcription({ meta: { task_id: "task-1" } }));

    expect(response.statusCode).toBe(400);
    expect(upstreamCalls).toBe(0);
    expect(onlyEvent().outcome).toBe("refused");
    await app.close();
  });
});

describe("outcomeFor", () => {
  // The pure decision, apart from the wiring — every branch above reaches this function through a
  // real request, and these pin the corners those requests do not naturally produce.
  it("is ok for any success whatever else was going on", () => {
    expect(outcomeFor({ status: 200, errorCode: undefined, upstreamAttempted: true, clientGone: false })).toBe("ok");
    expect(outcomeFor({ status: 204, errorCode: undefined, upstreamAttempted: false, clientGone: false })).toBe("ok");
  });

  it("is client_cancelled only when an upstream call was actually opened", () => {
    // §12: "A cancelled request may still have cost money." A cancellation before the provider was
    // reached spent nothing, so it is a refusal like any other.
    expect(outcomeFor({ status: 200, errorCode: undefined, upstreamAttempted: true, clientGone: true })).toBe("client_cancelled");
    expect(outcomeFor({ status: 400, errorCode: "request.invalid", upstreamAttempted: false, clientGone: true })).toBe("refused");
    // **The status carries no information when the caller is gone**, which is why the cancellation
    // branch comes first: a reply that was never sent leaves `reply.statusCode` at Fastify's default
    // 200, so a status test would call an abandoned request a success.
    expect(outcomeFor({ status: 200, errorCode: undefined, upstreamAttempted: false, clientGone: true })).toBe("refused");
  });

  it("keys a provider failure on the code and never on the status", () => {
    // §9.3's rule. 502 carries two codes with opposite meanings and 500 is this gateway's own.
    expect(outcomeFor({ status: 502, errorCode: "provider.unavailable", upstreamAttempted: true, clientGone: false })).toBe("provider_error");
    expect(outcomeFor({ status: 502, errorCode: "provider.rejected", upstreamAttempted: true, clientGone: false })).toBe("provider_error");
    expect(outcomeFor({ status: 504, errorCode: "provider.timeout", upstreamAttempted: true, clientGone: false })).toBe("provider_error");
    expect(outcomeFor({ status: 500, errorCode: "server.error", upstreamAttempted: true, clientGone: false })).toBe("server_error");
  });

  it("calls a 5xx with no readable envelope this gateway's own", () => {
    // Every provider failure this server produces carries a §7.2 code, so a body that could not be
    // parsed for one did not come from `errorBody`.
    expect(outcomeFor({ status: 500, errorCode: undefined, upstreamAttempted: true, clientGone: false })).toBe("server_error");
  });

  it("is refused for every 4xx a client can provoke", () => {
    for (const code of ["request.invalid", "request.too_large", "idempotency.conflict", "limit.rate"]) {
      expect(outcomeFor({ status: 409, errorCode: code, upstreamAttempted: false, clientGone: false })).toBe("refused");
    }
  });

  it("answers one of §11's five values for every input", () => {
    for (const status of [200, 400, 409, 413, 500, 502, 504]) {
      for (const code of [undefined, "request.invalid", "provider.unavailable", "server.error"]) {
        for (const upstreamAttempted of [true, false]) {
          for (const clientGone of [true, false]) {
            expect(meteringOutcomes).toContain(
              outcomeFor({ status, errorCode: code, upstreamAttempted, clientGone }),
            );
          }
        }
      }
    }
  });
});

describe("the route map", () => {
  it("meters exactly the transcription route, under a name §11's enum still carries", () => {
    // Written out as literals rather than derived from the map, so changing the production list
    // fails here instead of agreeing with itself — the same shape `gate.test.ts` uses on
    // `PUBLIC_ROUTES`, and for the same reason.
    expect([...METERED_ROUTES.entries()]).toEqual([["POST /v1/transcriptions", "transcription"]]);
    // The enum is exactly what the map writes: V2 keeps no readers for V1's other route names.
    expect([...meteredRoutes]).toEqual(["transcription"]);
    for (const route of METERED_ROUTES.values()) expect(meteredRoutes).toContain(route);
  });

  it("every POST route the app serves is either metered or declared unmetered", async () => {
    // The scan that makes a new `POST` someone's decision rather than a silent free one. Read off the built app, so a route added by a later ticket appears here whoever
    // registered it — the property `gate.test.ts`' own scan exists for.
    const app = build();
    const routes = await registeredRoutes(app);
    expectPopulationIsReal(routes);

    const posts = routes
      .filter((route) => route.method === "POST")
      .map((route) => `${route.method} ${route.url}`)
      .sort();
    expect(posts.length).toBeGreaterThan(0);
    const unclassified = posts.filter(
      (route) => !METERED_ROUTES.has(route) && !UNMETERED_POST_ROUTES.has(route),
    );
    expect(unclassified).toEqual([]);
    await app.close();
  });

  it("names no route the app does not serve", async () => {
    // The other direction: a map entry for a path that does not exist matches nothing and would
    // leave a real route unmetered while looking classified.
    const app = build();
    await app.ready();
    for (const route of METERED_ROUTES.keys()) {
      const url = route.slice("POST ".length);
      expect(`${route} exists: ${app.hasRoute({ method: "POST", url })}`).toBe(`${route} exists: true`);
    }
    await app.close();
  });
});

describe("modelForRoute", () => {
  const config = testConfig();

  it("answers the configured transcription model when OpenAI served", () => {
    expect(modelForRoute(config, "transcription", "openai")).toBe("test-transcription-model");
  });

  it("answers nothing for another provider and for no provider at all", () => {
    expect(modelForRoute(config, "transcription", "tavily")).toBeUndefined();
    expect(modelForRoute(config, "transcription", undefined)).toBeUndefined();
    expect(modelForRoute(config, "transcription", "a-provider-this-gateway-does-not-know")).toBeUndefined();
  });
});

describe("parseUsageArguments", () => {
  // The founder query path is a command, so its argument parsing is the part that can be wrong in a
  // way nobody notices — a `--since` silently treated as absent answers a different question with a
  // number that looks right.
  it("parses a command and a window", () => {
    const parsed = parseUsageArguments([
      "routes",
      "--account",
      "acct-1",
      "--since",
      "2026-08-01T00:00:00Z",
    ]);
    expect(parsed.kind).toBe("run");
    if (parsed.kind !== "run") throw new Error("unreachable");
    expect(parsed.command).toBe("routes");
    expect(parsed.window.accountId).toBe("acct-1");
    expect(parsed.window.since?.toISOString()).toBe("2026-08-01T00:00:00.000Z");
    expect(parsed.window.until).toBeUndefined();
  });

  it("refuses a date it cannot read rather than dropping the bound", () => {
    expect(parseUsageArguments(["routes", "--since", "last tuesday"])).toEqual({
      kind: "error",
      message: '--since is not a date: "last tuesday"',
    });
  });

  it("refuses an unknown command, an unknown option and a flag with no value", () => {
    expect(parseUsageArguments(["cost"]).kind).toBe("error");
    // The per-session report went with V1's vision route, and is refused by name rather than
    // answered with an empty table.
    expect(parseUsageArguments(["sessions"])).toEqual({
      kind: "error",
      message: 'unknown command "sessions"',
    });
    expect(parseUsageArguments(["routes", "--price"]).kind).toBe("error");
    expect(parseUsageArguments(["routes", "--account"]).kind).toBe("error");
    expect(parseUsageArguments(["routes", "--account", "--since"]).kind).toBe("error");
  });

  it("prints help for no arguments", () => {
    expect(parseUsageArguments([]).kind).toBe("help");
    expect(parseUsageArguments(["--help"]).kind).toBe("help");
  });
});
