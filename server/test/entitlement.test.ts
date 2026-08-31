import { createPublicKey, generateKeyPairSync, verify as verifyBytes } from "node:crypto";
import type pg from "pg";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { ACCOUNT_REQUESTS } from "../src/auth/ratelimit.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { ConfigError, loadConfig } from "../src/config.js";
import {
  requireEntitlementSigningKey,
  requireSpendCapUnits,
} from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import type { KeyStore, StoredResponse } from "../src/idempotency/store.js";
import {
  ENTITLEMENT_GRACE_SECONDS,
  ENTITLEMENT_LIFETIME_SECONDS,
  ENTITLEMENT_REFRESH_AFTER_SECONDS,
  ENTITLEMENT_SKEW_TOLERANCE_SECONDS,
  EntitlementKeyError,
  entitlementSigningKeyFrom,
  mintEntitlementClaim,
  publicKeyMaterial,
  type EntitlementClaimPayload,
} from "../src/entitlement/claim.js";
import { CAPABILITY_REQUIRED } from "../src/entitlement/hook.js";
import {
  LONGEST_TOTAL_DEADLINE_MS,
  RESERVATION_TTL_SECONDS,
  periodStart,
  reservationExpiry,
} from "../src/entitlement/period.js";
import {
  claimFactsFor,
  effectiveCap,
  unitsForMeteredCall,
  unprovisioned,
} from "../src/entitlement/store.js";
import { parseEntitlementArguments } from "../src/entitlements.js";
import { readFile } from "node:fs/promises";
import { ALL_LIMITS } from "../src/auth/ratelimit.js";
import { METERED_ROUTES } from "../src/metering/event.js";
import type { MeteringStore } from "../src/metering/store.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore, testSigningKey } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";
import { testDatabaseUrl } from "./support/database.js";

/**
 * Contract §5.3's entitlement claim and §7.2's `entitlement.*` and `limit.*` refusals, driven
 * through the whole real app (SONNY-135).
 *
 * **The split with `entitlement.db.test.ts` is deliberate and is the same one SONNY-133 and
 * SONNY-300 made.** The spend cap's correctness is a property of one Postgres statement under
 * concurrency, and it is proved *there*, against a real Postgres, under forced interleavings — a
 * race against a fake proves nothing. What is proved *here* is everything around it: which requests
 * reach the check at all, what each refusal tells a client, whether a hold is charged or released,
 * and that the claim a client is handed is one it can verify offline. Those are decisions in the
 * hook's place in the chain, and a test that called the store directly would skip all of it.
 *
 * **Nothing here asserts a price, a plan or an allowance**, because there is none to assert: the
 * numbers below are test fixtures, and `theCommandRefusesToInventAPlan` is the assertion that this
 * half of the system cannot acquire one by accident.
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

/** Answers the gate's attribution query and refuses everything else, as the other suites' does. */
const signedInConnection: WithConnection = async (work) => {
  const client = {
    query: async (text: string) => {
      if (!text.includes("FROM sonny.identity")) {
        throw new Error(`unexpected query outside the entitlement store: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

function build(store = fakeEntitlementStore(), overrides: Record<string, unknown> = {}) {
  return buildApp(
    testConfig({
      credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }],
      ...overrides,
    }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
    { entitlementStore: store },
  );
}

const planBody = () => ({
  task_id: "task-1",
  retention: "standard" as const,
  messages: [{ role: "user" as const, text: "hello" }],
  response_schema_name: "Plan",
  response_schema: { type: "object" },
});

/**
 * A `KeyStore` that claims once and replays afterwards.
 *
 * The smallest thing that produces §9.2's replay through the real hook. It models nothing else —
 * `idempotency.test.ts` and `idempotency.db.test.ts` own the key's own behaviour; what is needed
 * here is only that a second request with the same key never reaches the handler.
 */
function replayingKeyStore(): KeyStore {
  let stored: StoredResponse | undefined;
  return {
    claim: () =>
      Promise.resolve(
        stored === undefined
          ? ({ kind: "claimed", token: "token-1" } as const)
          : ({ kind: "replay", response: stored } as const),
      ),
    complete: (_request, response) => {
      stored = {
        status: response.status,
        body: response.body,
        contentType: response.contentType,
        requestId: response.requestId,
      };
      return Promise.resolve();
    },
    release: () => Promise.resolve(),
  };
}

/** The claim's payload, decoded — what a client reads after the signature has passed. */
function payloadOf(compact: string): EntitlementClaimPayload {
  const [, encodedPayload] = compact.split(".") as [string, string, string];
  return JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8")) as EntitlementClaimPayload;
}

function headerOf(compact: string): Record<string, unknown> {
  const [encodedHeader] = compact.split(".") as [string];
  return JSON.parse(Buffer.from(encodedHeader, "base64url").toString("utf8")) as Record<string, unknown>;
}

describe("the signed entitlement claim (contract §5.3)", () => {
  it("signs a claim a holder of the public key alone can verify — no network, no secret", () => {
    const key = testSigningKey("k1");
    const claim = mintEntitlementClaim(
      { subject: ACCOUNT, plan: "test-plan", capabilities: ["cap.a", "cap.b"] },
      key,
      new Date("2026-08-28T09:00:00Z"),
    );

    // Verification the way a client does it: the raw 32 public bytes, and nothing else.
    const raw = Buffer.from(publicKeyMaterial(key), "base64url");
    const publicKey = createPublicKey({
      key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
      format: "der",
      type: "spki",
    });
    const [header, payload, signature] = claim.entitlement.split(".") as [string, string, string];
    expect(
      verifyBytes(null, Buffer.from(`${header}.${payload}`, "utf8"), publicKey, Buffer.from(signature, "base64url")),
    ).toBe(true);
  });

  it("carries §5.3's payload exactly, with the four durations this ticket sets", () => {
    const issuedAt = new Date("2026-08-28T09:00:00Z");
    const claim = mintEntitlementClaim(
      { subject: ACCOUNT, plan: "test-plan", capabilities: ["cap.a"] },
      testSigningKey("k1"),
      issuedAt,
    );
    const payload = payloadOf(claim.entitlement);

    expect(payload).toEqual({
      v: 1,
      sub: ACCOUNT,
      plan: "test-plan",
      capabilities: ["cap.a"],
      issued_at: "2026-08-28T09:00:00Z",
      expires_at: "2026-08-29T09:00:00Z",
      grace_seconds: 259200,
      skew_tolerance_seconds: 300,
    });
    // The envelope's `expires_at` is the payload's, and `refresh_after` is a third of the lifetime
    // in — so a client gets two refresh opportunities before its claim expires.
    expect(claim.expires_at).toBe(payload.expires_at);
    expect(claim.refresh_after).toBe("2026-08-28T17:00:00Z");
  });

  it("holds the four durations against each other, which is what the numbers mean", () => {
    // A day, refreshing every eight hours, honoured for three days past expiry, judged to five
    // minutes of clock disagreement. The relations matter more than the values and are what the
    // revocation bound is computed from, so they are asserted rather than left to the prose:
    expect(ENTITLEMENT_LIFETIME_SECONDS).toBe(86_400);
    expect(ENTITLEMENT_REFRESH_AFTER_SECONDS).toBe(28_800);
    expect(ENTITLEMENT_GRACE_SECONDS).toBe(259_200);
    expect(ENTITLEMENT_SKEW_TOLERANCE_SECONDS).toBe(300);

    // Two refresh opportunities inside one lifetime, so a single missed refresh does not spend the
    // grace window that exists for being genuinely offline.
    expect(ENTITLEMENT_LIFETIME_SECONDS / ENTITLEMENT_REFRESH_AFTER_SECONDS).toBeGreaterThanOrEqual(3);
    // The offline revocation bound: four days, and it is lifetime plus grace rather than lifetime
    // alone. §5.3's sentence is true of an online client and understates this one.
    expect(ENTITLEMENT_LIFETIME_SECONDS + ENTITLEMENT_GRACE_SECONDS).toBe(345_600);
    // The tolerance cannot meaningfully extend that bound: a tenth of a percent of the grace.
    expect(ENTITLEMENT_SKEW_TOLERANCE_SECONDS / ENTITLEMENT_GRACE_SECONDS).toBeLessThan(0.002);
  });

  it("names the key in the header and pins EdDSA there, so a client selects rather than tries", () => {
    const claim = mintEntitlementClaim(
      { subject: ACCOUNT, plan: "p", capabilities: [] },
      testSigningKey("rotation-2"),
      new Date(),
    );
    expect(headerOf(claim.entitlement)).toEqual({ alg: "EdDSA", typ: "JWT", kid: "rotation-2" });
  });

  it("refuses a signing key that is not Ed25519, rather than signing with the wrong algorithm", () => {
    // A P-256 key parses perfectly and would then sign with something other than the `EdDSA` this
    // gateway writes into every header — so every client would reject every claim, and the
    // deployment error would present as a product bug.
    const p256 = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
      .privateKey.export({ type: "pkcs8", format: "der" })
      .toString("base64");
    expect(() => entitlementSigningKeyFrom(p256, "k")).toThrow(EntitlementKeyError);
    expect(() => entitlementSigningKeyFrom(p256, "k")).toThrow(/Ed25519/);
  });

  it("refuses a key that is not base64 PKCS#8 DER, and never echoes the value", () => {
    const nonsense = "this-is-not-a-key-at-all-but-it-is-long-enough-to-look-like-one";
    let message = "";
    try {
      entitlementSigningKeyFrom(nonsense, "k");
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toContain("ENTITLEMENT_SIGNING_KEY");
    // The value never reaches the message: a parse error that quoted it would put a signing key in
    // whatever collects this server's logs, which is `config.ts`'s own rule about `loadConfig`.
    expect(message).not.toContain(nonsense);
  });
});

describe("GET /v1/account/entitlements", () => {
  it("answers the account's plan and capabilities, signed, for the verified caller", async () => {
    const store = fakeEntitlementStore();
    store.setRecord(ACCOUNT, { plan: "test-plan", capabilities: ["cap.screen"] });
    const app = build(store);

    const response = await app.inject({
      method: "GET",
      url: "/v1/account/entitlements",
      headers: { authorization: authorization() },
    });

    expect(response.statusCode).toBe(200);
    const body = response.json() as { entitlement: string; expires_at: string; refresh_after: string };
    const payload = payloadOf(body.entitlement);
    expect(payload.plan).toBe("test-plan");
    expect(payload.capabilities).toEqual(["cap.screen"]);
    // **`sub` is the identity that asked, and the claim's content is the account's.** The Mac has
    // to be able to check that a cached claim belongs to the session it holds — otherwise one
    // cached before a sign-out keeps granting capabilities to whoever signs in next — and the only
    // identifier the Mac ever learns is `user.id` from §3.2's token response. The plan and the
    // capabilities come from the account row regardless, which the fixture's account-keyed record
    // is what demonstrates.
    expect(payload.sub).toBe(SUPABASE_USER);
    expect(payload.sub).not.toBe(ACCOUNT);
    await app.close();
  });

  it("answers an unprovisioned account with a plan of none and no capabilities", async () => {
    // Fail-closed, and it is the *absence* of a plan rather than a plan called none. Every gated
    // capability is refused for this account, and nothing here invented a tier to put it on.
    const app = build();
    const response = await app.inject({
      method: "GET",
      url: "/v1/account/entitlements",
      headers: { authorization: authorization() },
    });
    const payload = payloadOf((response.json() as { entitlement: string }).entitlement);
    expect(payload.plan).toBe("none");
    expect(payload.capabilities).toEqual([]);
    await app.close();
  });

  it("strips every capability from a revoked entitlement while keeping the plan key", async () => {
    // **Revocation reaches a live client as a fresh signed claim carrying nothing**, not as an
    // error: a client handed an error keeps the claim it already has until that one expires, which
    // is the slower of the two answers and the wrong one for a cancellation.
    const store = fakeEntitlementStore();
    store.setRecord(ACCOUNT, {
      plan: "test-plan",
      capabilities: ["cap.screen"],
      revokedAt: new Date("2026-08-28T08:00:00Z"),
    });
    const app = build(store);

    const response = await app.inject({
      method: "GET",
      url: "/v1/account/entitlements",
      headers: { authorization: authorization() },
    });
    const payload = payloadOf((response.json() as { entitlement: string }).entitlement);
    expect(payload.capabilities).toEqual([]);
    expect(payload.plan).toBe("test-plan");
    await app.close();
  });

  it("is refused without a token, like every other authenticated route", async () => {
    const app = build();
    const response = await app.inject({ method: "GET", url: "/v1/account/entitlements" });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.unauthenticated");
    await app.close();
  });

  it("takes no hold against the spend cap: asking what you are allowed is not spending", async () => {
    const store = fakeEntitlementStore();
    const app = build(store);
    await app.inject({
      method: "GET",
      url: "/v1/account/entitlements",
      headers: { authorization: authorization() },
    });
    // It is admitted — so it is rate limited like everything else — and the admission asks for no
    // hold, because the route is not metered.
    expect(store.calls.admitted.map((call) => call.metered)).toEqual([false]);
    expect(store.calls.settled).toEqual([]);
    await app.close();
  });
});

describe("what each refusal tells the client (contract §7.2)", () => {
  it("answers 429 limit.rate WITH a Retry-After, because waiting fixes it", async () => {
    const store = fakeEntitlementStore();
    store.answerWith({ kind: "rate_limited", retryAfterSeconds: 42 });
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(429);
    expect(response.json().error.code).toBe("limit.rate");
    expect(response.json().error.retryable).toBe(true);
    expect(response.json().error.retry_after_seconds).toBe(42);
    expect(response.headers["retry-after"]).toBe("42");
    await app.close();
  });

  it("answers 429 limit.spend with NO Retry-After, because waiting does not", async () => {
    // §7.2 case 3a is explicit: no `Retry-After`, "because waiting seconds does not fix it". The two
    // 429s are told apart by `code` and by this header, which is the whole reason both exist.
    const store = fakeEntitlementStore();
    store.answerWith({ kind: "over_cap", capUnits: 1000 });
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(429);
    expect(response.json().error.code).toBe("limit.spend");
    expect(response.json().error.retryable).toBe(false);
    expect(response.json().error.retry_after_seconds).toBeNull();
    expect(response.headers["retry-after"]).toBeUndefined();
    await app.close();
  });

  it("answers 403 entitlement.required for a gated capability the account does not hold", async () => {
    const store = fakeEntitlementStore();
    store.answerWith({ kind: "not_entitled", capability: "cap.gated" });
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(403);
    expect(response.json().error.code).toBe("entitlement.required");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it("gives the four states four different codes, which is what the client acts on", async () => {
    // Not signed in, not entitled, over a rate limit, over a spend cap. §7.2 gives them 401, 403,
    // 429 and 429 — two of which share a status, which is exactly why the client decides on `code`.
    const codes: string[] = [];
    const unauthenticated = build();
    codes.push(
      (await unauthenticated.inject({ method: "POST", url: "/v1/plan", payload: planBody() }))
        .json().error.code,
    );
    await unauthenticated.close();

    for (const outcome of [
      { kind: "not_entitled", capability: "cap.gated" },
      { kind: "rate_limited", retryAfterSeconds: 1 },
      { kind: "over_cap", capUnits: 1 },
    ] as const) {
      const store = fakeEntitlementStore();
      store.answerWith(outcome);
      const app = build(store);
      codes.push(
        (
          await app.inject({
            method: "POST",
            url: "/v1/plan",
            headers: { authorization: authorization() },
            payload: planBody(),
          })
        ).json().error.code,
      );
      await app.close();
    }

    expect(codes).toEqual([
      "auth.unauthenticated",
      "entitlement.required",
      "limit.rate",
      "limit.spend",
    ]);
    expect(new Set(codes).size).toBe(4);
  });

  it("refuses before the provider is called, which is the whole point of reserving first", async () => {
    // A cap refusal that happened after the upstream call would have cost the founder the money the
    // cap exists to bound. The provider here is a URL that does not resolve; reaching it would be a
    // failed fetch and a 502, not a 429.
    const store = fakeEntitlementStore();
    store.answerWith({ kind: "over_cap", capUnits: 0 });
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(429);
    expect(response.json().error.code).toBe("limit.spend");
    await app.close();
  });
});

describe("which requests spend against the cap", () => {
  it("takes a hold on a metered route and charges it once the provider was reached", async () => {
    const store = fakeEntitlementStore();
    const app = build(store, {
      // A provider that answers, so `meteredUpstreamCall` really opens a call.
      openAIBaseUrl: "https://openai.invalid/v1",
    });
    const original = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ output_text: "{}", usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof globalThis.fetch;
    try {
      const response = await app.inject({
        method: "POST",
        url: "/v1/plan",
        headers: { authorization: authorization() },
        payload: planBody(),
      });
      expect(response.statusCode).toBe(200);
    } finally {
      globalThis.fetch = original;
    }

    expect(store.calls.admitted).toHaveLength(1);
    expect(store.calls.admitted[0]!.metered).toBe(true);
    expect(store.calls.settled).toEqual([{ reservationId: "reservation-1", charge: true }]);
    await app.close();
  });

  it("releases the hold when the request never reached a provider", async () => {
    // A body that fails validation is refused inside the handler, after the hold was taken and
    // before any provider call. The user must not spend a unit on it.
    const store = fakeEntitlementStore();
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: { task_id: "task-1" },
    });

    expect(response.statusCode).toBe(400);
    expect(store.calls.settled).toEqual([{ reservationId: "reservation-1", charge: false }]);
    await app.close();
  });

  it("charges a request whose provider call failed, because the vendor may still have billed it", async () => {
    const store = fakeEntitlementStore();
    const app = build(store);
    const original = globalThis.fetch;
    globalThis.fetch = (async () => new Response("nope", { status: 500 })) as typeof globalThis.fetch;
    try {
      const response = await app.inject({
        method: "POST",
        url: "/v1/plan",
        headers: { authorization: authorization() },
        payload: planBody(),
      });
      expect(response.statusCode).toBe(502);
    } finally {
      globalThis.fetch = original;
    }
    expect(store.calls.settled).toEqual([{ reservationId: "reservation-1", charge: true }]);
    await app.close();
  });

  it("releases the hold when the route has no configured provider at all", async () => {
    // A `502 provider.unavailable` raised because this deployment holds no credential looks
    // identical to one raised after a real call failed — from the status alone. It is told apart by
    // whether an upstream call was ever opened, which is why the settle reads that and not the code.
    const store = fakeEntitlementStore();
    const app = build(store, { credentials: [] });

    const response = await app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: { authorization: authorization() },
      payload: planBody(),
    });

    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("provider.unavailable");
    expect(store.calls.settled).toEqual([{ reservationId: "reservation-1", charge: false }]);
    await app.close();
  });

  it("asks for no hold on a route that is not metered", async () => {
    const store = fakeEntitlementStore();
    const app = build(store);
    await app.inject({
      method: "POST",
      url: "/v1/auth/signout",
      headers: { authorization: authorization() },
    });
    expect(store.calls.admitted.every((call) => call.metered === false)).toBe(true);
    expect(store.calls.settled).toEqual([]);
    await app.close();
  });

  it("aReplayedRequestTakesNoHoldAgainstTheCap", async () => {
    // **The ordering that makes this true is `app.ts`'s**, and this is what holds it. A repeat
    // inside §9.2's window never runs the handler and costs nothing, so charging it would bill a
    // user twice for one call. The idempotency hook answers it from its own `preHandler` with
    // `reply.send`, which ends the chain — so the cap hook does not run for it at all, which is why
    // there is no guard in that hook saying so.
    const store = fakeEntitlementStore();
    const app = buildApp(
      testConfig({ credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }] }),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
      { entitlementStore: store, idempotencyStore: replayingKeyStore() },
    );

    const send = () =>
      app.inject({
        method: "POST",
        url: "/v1/plan",
        headers: { authorization: authorization(), "idempotency-key": "key-1" },
        payload: planBody(),
      });

    const original = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ output_text: "{}" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof globalThis.fetch;
    try {
      expect((await send()).statusCode).toBe(200);
      // The repeat: the same key, replayed from the store, handler never run.
      expect((await send()).statusCode).toBe(200);
    } finally {
      globalThis.fetch = original;
    }

    // One admission and one hold across the two requests, not two of either.
    expect(store.calls.admitted).toHaveLength(1);
    expect(store.calls.settled).toEqual([{ reservationId: "reservation-1", charge: true }]);
    await app.close();
  });

  it("asks nothing at all on a public route, which has no account to ask about", async () => {
    const store = fakeEntitlementStore();
    const app = build(store);
    await app.inject({ method: "GET", url: "/v1/health" });
    expect(store.calls.admitted).toEqual([]);
    await app.close();
  });

  it("spends against the cap on exactly the routes §11 meters, and no others", async () => {
    // **The population, driven rather than described** (PR #152's review, F6). This asserted that
    // `METERED_ROUTES` contained the one route it had sent, which is a claim about a map rather than
    // about the hook — four of the five were never driven and no unmetered route was checked at all.
    // It now sends a request to every metered route and asserts the hook asked for a hold on each,
    // then sends an authenticated *unmetered* route and asserts it asked for none.
    const store = fakeEntitlementStore();
    const app = build(store);
    const bodies: Record<string, Record<string, unknown>> = {
      "POST /v1/plan": planBody(),
      "POST /v1/research/synthesize": planBody(),
      "POST /v1/search": { task_id: "task-1", retention: "standard", query: "sonny" },
      "POST /v1/screen/analyze": {
        task_id: "task-1",
        retention: "standard",
        session_id: "session-1",
        session_iteration: 1,
        prompt: "what is on screen",
        image: { media_type: "image/png", data: Buffer.from("not-a-real-png").toString("base64") },
      },
    };

    for (const key of METERED_ROUTES.keys()) {
      // **`POST /v1/transcriptions` is excluded and is therefore uncovered, which is the honest
      // wording** (cycle 3, F6's residual). This said it was "exercised by `model.test.ts`", and
      // that file injects the fake store but never reads `store.calls` — so **no test anywhere
      // asserts that route takes a hold**. It is multipart, so driving it here means building a
      // form body for a property every other route states in one line. The implementation is
      // population-driven (`meteredRouteFor` reads the map), so the route is covered by the code
      // and not by this test; the assertion below is `size - 1` for exactly that reason.
      if (key === "POST /v1/transcriptions") continue;
      const [, url] = key.split(" ") as [string, string];
      await app.inject({
        method: "POST",
        url,
        headers: { authorization: authorization() },
        payload: bodies[key]!,
      });
    }
    // Every admission so far asked for a hold, because every route driven is metered.
    expect(store.calls.admitted.map((call) => call.metered)).toEqual(
      store.calls.admitted.map(() => true),
    );
    expect(store.calls.admitted).toHaveLength(METERED_ROUTES.size - 1);

    // And an authenticated route that is *not* metered asks for none, which is the half a
    // one-route test could not say anything about.
    const before = store.calls.admitted.length;
    await app.inject({
      method: "GET",
      url: "/v1/account/entitlements",
      headers: { authorization: authorization() },
    });
    expect(store.calls.admitted.slice(before).map((call) => call.metered)).toEqual([false]);
    await app.close();
  });

  it("writes §11's metering event before it charges the hold that cites it", async () => {
    // **§9's "same transaction as the metering event" is reached by ordering here, and until now
    // nothing held it** (PR #152's review, F3). `app.ts` argues the position at length — the two
    // stores lease their own connections, so the transactions cannot be merged, and registering the
    // entitlement hook after the metering one buys the property that matters: *a charge cannot exist
    // without its audit row*. That is an argument about hook registration order, and a rebase that
    // moved one `register…` call above the other would invert it with every test still green. This
    // is the test that goes red instead. `server/src/app.ts` is one of the files that conflicted on
    // the rebase this branch actually did.
    const order: string[] = [];
    const entitlements = fakeEntitlementStore();
    const settle = entitlements.settle.bind(entitlements);
    const recordingEntitlements = {
      ...entitlements,
      settle: async (reservationId: string, charge: boolean) => {
        order.push("settle");
        return settle(reservationId, charge);
      },
    };
    const metering: MeteringStore = {
      write: async () => {
        order.push("metering");
        return "written";
      },
    };

    const app = buildApp(
      testConfig({ credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }] }),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection },
      { entitlementStore: recordingEntitlements, meteringStore: metering },
    );
    const original = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ output_text: "{}" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof globalThis.fetch;
    try {
      const response = await app.inject({
        method: "POST",
        url: "/v1/plan",
        headers: { authorization: authorization() },
        payload: planBody(),
      });
      expect(response.statusCode).toBe(200);
    } finally {
      globalThis.fetch = original;
    }

    // Both happened — a test asserting only the order would pass if neither did — and the event is
    // on disk before the charge that cites it.
    expect(order).toEqual(["metering", "settle"]);
    await app.close();
  });

});

describe("what this ticket deliberately does not decide", () => {
  it("theGatedRouteSetIsEmptyAndBelongsToRowEighteen", () => {
    // Row 18 (SONNY-23) owns which capability keys gate which features. This ticket builds the gate
    // and leaves it holding nothing — an entry here is a product decision, and the 403 path above is
    // driven through the injectable override rather than by gating a real route.
    expect([...CAPABILITY_REQUIRED.entries()]).toEqual([]);
  });

  it("counts one metered call as one unit, and holds no price of any kind", () => {
    // The unit is a call because a credit weight is SONNY-212's. `unitsForMeteredCall` is the seam
    // those weights land in; until they do, the estimate and the actual are the same number, which
    // is why a settle takes a boolean rather than an amount.
    expect(unitsForMeteredCall()).toEqual({ units: 1 });
  });

  it("theSweepsCutOffCoversEveryDeclaredLimit", async () => {
    // **The population, read off the source rather than off the array that claims to be it** (cycle
    // 3's N3). `ALL_LIMITS`' own doc says "a sixth limit is covered by existing", and nothing held
    // that: the test named for it read `ALL_LIMITS` on both sides, so a limit declared and left out
    // of the array was invisible — the reviewer added one with a day-long window and the whole suite
    // stayed green. A window the sweep does not know about is a window it deletes while something is
    // still counting against it.
    //
    // The same shape `test/support/routes.ts` uses: ask the source, not the list.
    const source = await readFile(
      new URL("../src/auth/ratelimit.ts", import.meta.url),
      "utf8",
    );
    const declared = [...source.matchAll(/^export const ([A-Z_]+): Limit = /gm)].map((m) => m[1]!);

    // The scan really scanned: a regex that matched nothing would pass every assertion below.
    expect(declared.length).toBeGreaterThanOrEqual(5);
    expect(declared).toContain("ACCOUNT_REQUESTS");
    expect(ALL_LIMITS).toHaveLength(declared.length);
  });

  it("theCommandRefusesToInventAPlan", () => {
    // `grant` with no `--plan` is an error rather than a default, because a plan key this command
    // chose would be a tier this repository invented.
    expect(parseEntitlementArguments(["grant", ACCOUNT])).toEqual({
      kind: "error",
      message: "grant needs --plan",
    });
    expect(parseEntitlementArguments(["grant", ACCOUNT, "--plan", "p", "--cap", "not-a-number"]))
      .toEqual({ kind: "error", message: "--cap is not a whole number of units: not-a-number" });
    expect(parseEntitlementArguments(["grant", ACCOUNT, "--plan", "p", "--capability", "c.a", "--cap", "10"]))
      .toEqual({ kind: "grant", accountId: ACCOUNT, plan: "p", capabilities: ["c.a"], capUnits: 10 });
    // No `--cap` means the deployment's default rather than zero, which is a different account state.
    expect(parseEntitlementArguments(["grant", ACCOUNT, "--plan", "p"]))
      .toEqual({ kind: "grant", accountId: ACCOUNT, plan: "p", capabilities: [], capUnits: null });
  });

  it("distinguishes an account capped at zero from one with no cap of its own", () => {
    // `0` is an operator saying "this account spends nothing", which is a real answer; `null` is
    // "take the deployment's". A falsiness test would silently turn the first into the second.
    expect(effectiveCap(0, 1000)).toBe(0);
    expect(effectiveCap(null, 1000)).toBe(1000);
    expect(effectiveCap(7, 1000)).toBe(7);
  });

  it("treats an unprovisioned account as no plan, no capabilities and the deployment's cap", () => {
    const record = unprovisioned(ACCOUNT);
    expect(record.plan).toBe("none");
    expect(record.capabilities).toEqual([]);
    expect(record.capUnits).toBeNull();
    expect(claimFactsFor(record, new Date("2026-08-30T00:00:00Z")))
      .toEqual({ plan: "none", capabilities: [] });
  });
});

describe("the period and the sweep window", () => {
  it("starts a period at the UTC month boundary, whatever the instant inside it", () => {
    expect(periodStart(new Date("2026-08-28T09:41:07.512Z")).toISOString())
      .toBe("2026-08-01T00:00:00.000Z");
    expect(periodStart(new Date("2026-08-01T00:00:00.000Z")).toISOString())
      .toBe("2026-08-01T00:00:00.000Z");
    // The last instant of a month and the first of the next are different periods, which is the
    // only boundary behaviour anything depends on.
    expect(periodStart(new Date("2026-08-31T23:59:59.999Z")).toISOString())
      .toBe("2026-08-01T00:00:00.000Z");
    expect(periodStart(new Date("2026-09-01T00:00:00.000Z")).toISOString())
      .toBe("2026-09-01T00:00:00.000Z");
  });

  it("theSweepWindowClearsTheLongestRouteDeadline", () => {
    // **The direction that matters is the floor.** A window shorter than a request's own deadline
    // would let the sweep reclaim a hold belonging to a request still running, and that request
    // would then settle against a reservation already given back — a double spend, in the direction
    // that costs the founder money. Read off `DEADLINE_MS` rather than written as a literal, so a
    // route whose deadline grows past the window fails here.
    expect(LONGEST_TOTAL_DEADLINE_MS).toBe(105_000);
    expect(RESERVATION_TTL_SECONDS * 1000).toBeGreaterThan(LONGEST_TOTAL_DEADLINE_MS);
    expect(reservationExpiry(new Date("2026-08-28T09:00:00Z")).toISOString())
      .toBe("2026-08-28T09:05:00.000Z");
  });
});

/**
 * Bound to names rather than written inline, exactly as `authdeps.test.ts` and `config.test.ts` do
 * and for their stated reason: a line spelling a known-secret variable followed by a long literal is
 * the shape `npm run check:secrets` refuses, correctly, wherever it appears — and it refuses a
 * synthetic value the same way it would refuse a real one, because the scanner reads the source. The
 * first spelling of the two lines below was a finding. **It scans TRACKED files**, so a clean run
 * before these were committed said nothing about them; the run that matters is the one after
 * `git add`, which is how this was caught.
 */
const salt = "a-salt-that-is-not-a-real-one";
const jwtSecret = "a-signing-key-long-enough-to-clear-the-floor";

describe("startup refuses rather than serving a gateway that cannot check", () => {
  const AUTH_ENV = {
    SONNY_ENV: "local",
    // SONNY-352: one knob for the port, not a literal per file. `support/database.ts` has why.
    DATABASE_URL: testDatabaseUrl(),
    RATE_LIMIT_SALT: salt,
    SUPABASE_JWT_SECRET: jwtSecret,
    SUPABASE_JWT_ISSUER: "https://project-ref.supabase.co/auth/v1",
    SUPABASE_ANON_KEY: "an-anon-key",
  } as NodeJS.ProcessEnv;

  it("refuses a missing SPEND_CAP_UNITS rather than treating it as uncapped", () => {
    // The failure this requirement exists to prevent: SONNY-16 recorded a leaked token billing the
    // founder as an accepted cost, and a cap that quietly does not apply is that cost with a
    // mechanism in front of it doing nothing.
    expect(() => requireSpendCapUnits(loadConfig(AUTH_ENV))).toThrow(ConfigError);
    expect(() => requireSpendCapUnits(loadConfig(AUTH_ENV))).toThrow(/SPEND_CAP_UNITS/);
  });

  it("accepts a SPEND_CAP_UNITS of zero, which is an answer and not an absence", () => {
    expect(requireSpendCapUnits(loadConfig({ ...AUTH_ENV, SPEND_CAP_UNITS: "0" }))).toBe(0);
  });

  it("refuses a missing signing key or key id, naming both when both are gone", () => {
    let message = "";
    try {
      requireEntitlementSigningKey(loadConfig(AUTH_ENV));
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toContain("ENTITLEMENT_SIGNING_KEY");
    expect(message).toContain("ENTITLEMENT_SIGNING_KEY_ID");
    expect(message).toContain("are required");
  });

  it("names the rate limit it enforces, so the number is not only in prose", () => {
    expect(ACCOUNT_REQUESTS).toEqual({ max: 120, windowSeconds: 60 });
  });
});
