import type pg from "pg";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { parseBillingPlans, billingDepsFrom } from "../src/billing/deps.js";
import { POLAR, polarProvider, readPolarDelivery } from "../src/billing/polar.js";
import type { BillingApplyInput, BillingStore } from "../src/billing/store.js";
import {
  WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS,
  signatureFor,
  verifyWebhookSignature,
} from "../src/billing/webhook-signature.js";
import { ConfigError } from "../src/config.js";
import type { WithConnection } from "../src/db/connection.js";
import { claimFactsFor, unprovisioned } from "../src/entitlement/store.js";
import { isPublicRoute } from "../src/auth/gate.js";
import { expectPopulationIsReal, registeredRoutes } from "./support/routes.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * The subscription webhook and the checkout link, driven through the whole real app (SONNY-211).
 *
 * **The split with `billing.db.test.ts` is the same one SONNY-135 made and is here for the same
 * reason.** What lives in *that* file is the SQL: the replay bound being a primary key, the
 * out-of-order refusal being an `ON CONFLICT … WHERE`, and the entitlement columns a delivery
 * actually writes — all against a real Postgres, because a fake that appeared to dedupe would be how
 * this suite came to believe it had a replay bound. What lives *here* is everything around it, and
 * in particular the one thing that decides whether this route is safe at all: the signature.
 *
 * **The route this file is about grants paid entitlements to anyone whose delivery it accepts.** So
 * the tests that matter most are the negative ones — a tampered body, a forged signature, a missing
 * header, a stale timestamp — and each of them asserts that the store was **never asked**, not
 * merely that the status was 401. A refusal that still writes a row is a refusal an attacker can use
 * to fill a table.
 */

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";
const SECRET = "a-webhook-secret-that-is-not-a-real-one";
const CHECKOUT = "https://buy.example.test/checkout/abc";
const PRODUCT = "prod_screen_control";
const SUBSCRIPTION = "sub_123";
const NOW = new Date("2026-08-30T12:00:00Z");

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
        throw new Error(`unexpected query outside the billing store: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

/**
 * A `BillingStore` that records what it was asked and grants nothing.
 *
 * It deliberately does **not** model the entitlement: what this file proves is which deliveries
 * reach the store at all and what neutral event they arrive as. The state a delivery produces is
 * `billing.db.test.ts`'s, against the real statements.
 */
function recordingStore(
  live = false,
): BillingStore & { readonly calls: BillingApplyInput[] } {
  const calls: BillingApplyInput[] = [];
  return {
    calls,
    apply: async (input) => {
      calls.push(input);
      return { outcome: "applied", accountId: ACCOUNT };
    },
    // The checkout guard's one question. `billing.db.test.ts` proves the SQL that answers it.
    hasLiveSubscription: async () => live,
  };
}

const BILLING_ENV = {
  billingProvider: "polar" as const,
  billingWebhookSecret: SECRET,
  billingCheckoutUrl: CHECKOUT,
  billingPlans: `${PRODUCT}=paid:screen_control`,
  billingGraceDays: 14,
};

function build(store: BillingStore) {
  return buildApp(testConfig(BILLING_ENV), {
    provider: new UnusedAuthProvider(),
    withConnection: signedInConnection,
    now: () => NOW,
  }, { billingStore: store, entitlementStore: fakeEntitlementStore() });
}

/** A Polar subscription payload. `status` is the field the adapter maps on; the type is recorded. */
function subscriptionPayload(
  type: string,
  status: string,
  extra: Record<string, unknown> = {},
): string {
  return JSON.stringify({
    type,
    data: {
      id: SUBSCRIPTION,
      status,
      product_id: PRODUCT,
      modified_at: "2026-08-30T11:59:00Z",
      customer: { id: "cus_1", external_id: ACCOUNT },
      ...extra,
    },
  });
}

/** A delivery signed the way the provider signs one, with the headers it sends. */
function deliveryHeaders(body: string, at: Date = NOW, id = "msg_1", secret = SECRET) {
  const timestamp = String(Math.floor(at.getTime() / 1000));
  return {
    "content-type": "application/json",
    "webhook-id": id,
    "webhook-timestamp": timestamp,
    "webhook-signature": `v1,${signatureFor(Buffer.from(secret, "utf8"), id, timestamp, Buffer.from(body, "utf8"))}`,
  };
}

async function post(app: ReturnType<typeof build>, body: string, headers: Record<string, string>) {
  return app.inject({ method: "POST", url: "/v1/billing/webhook", payload: body, headers });
}

describe("the webhook signature is the authentication", () => {
  it("accepts a delivery signed with the endpoint secret", async () => {
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");

    const response = await post(app, body, deliveryHeaders(body));

    expect(response.statusCode).toBe(200);
    expect(store.calls).toHaveLength(1);
    await app.close();
  });

  it("refuses a body changed after signing, and asks the store nothing", async () => {
    // **The test the whole route exists to pass.** An attacker who can replay a genuine delivery and
    // edit one field is an attacker who can name their own account or their own product. The
    // assertion that the store was never asked is as load-bearing as the status: a refusal that
    // still wrote a row would let anyone fill `sonny.billing_event`.
    const store = recordingStore();
    const app = build(store);
    const honest = subscriptionPayload("subscription.active", "active");
    const headers = deliveryHeaders(honest);
    const tampered = honest.replace(ACCOUNT, "11111111-2222-3333-4444-555555555555");
    expect(tampered).not.toBe(honest);

    const response = await post(app, tampered, headers);

    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.required");
    expect(store.calls).toEqual([]);
    await app.close();
  });

  it("refuses a delivery signed with a different secret", async () => {
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");

    const response = await post(app, body, deliveryHeaders(body, NOW, "msg_1", "not-the-secret"));

    expect(response.statusCode).toBe(401);
    expect(store.calls).toEqual([]);
    await app.close();
  });

  it("refuses a v1 entry that decodes to the wrong number of bytes, with a 401 and not a 500", async () => {
    // **The guard in front of `timingSafeEqual`, which nothing held** (PR #178 review, F2; mutant R1
    // survived). That function throws a `RangeError` on a length mismatch, and a throw inside a route
    // handler is a 500 where a refusal is meant — the mistake `auth/token.ts:209` records this
    // repository having made once already. Every `v1,` entry that reaches the comparison in any other
    // test is a real HMAC-SHA256 and therefore exactly 32 bytes, so the wrong-secret and tampered-body
    // cases all present the *right* length and never reach the throw; the two short literals elsewhere
    // in this file are refused earlier, at the header and timestamp checks, and never reach the loop.
    // This is the only shape that gets a wrong-length buffer to the compare: valid id, in-tolerance
    // timestamp, and a `v1,` value that decodes to six bytes.
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");
    const timestamp = String(Math.floor(NOW.getTime() / 1000));

    const response = await post(app, body, {
      "content-type": "application/json",
      "webhook-id": "msg_1",
      "webhook-timestamp": timestamp,
      "webhook-signature": "v1,anything",
    });

    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.required");
    expect(store.calls).toEqual([]);
    await app.close();
  });

  it("refuses a timestamp that is in range for the regex and out of range for a Date", async () => {
    // **The tolerance check failed OPEN for these** (PR #178 review, F3). A 13-to-15-digit second
    // count overflows the ECMAScript `Date` range, so `getTime()` is `NaN`, `drift` is `NaN`, and
    // `NaN > tolerance` is `false` — the comparison that exists to refuse said accept, and the
    // `Invalid Date` then travelled on to Postgres and threw. Not an authentication bypass: the
    // timestamp is inside the signed content, so only the provider or a holder of the secret reaches
    // it at all. Signed honestly here for exactly that reason — the point is what a VALID delivery
    // carrying such a value does.
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");

    for (const timestamp of ["8640000000001", "999999999999999", "-999999999999999"]) {
      const response = await post(app, body, {
        "content-type": "application/json",
        "webhook-id": "msg_1",
        "webhook-timestamp": timestamp,
        "webhook-signature": `v1,${signatureFor(Buffer.from(SECRET, "utf8"), "msg_1", timestamp, Buffer.from(body, "utf8"))}`,
      });
      expect(response.statusCode).toBe(401);
      expect(store.calls).toEqual([]);
    }
    await app.close();
  });

  it("never returns a verdict carrying an Invalid Date", () => {
    // The half of F3 that is about what travels onward rather than what is refused: `sentAt` becomes
    // `occurredAt`'s fallback, so an `ok: true` verdict holding an unrepresentable instant is what
    // reached the database as `0NaN-NaN-NaNTNaN:NaN:NaN.NaN+NaN:NaN`.
    const timestamp = "8640000000001";
    const body = Buffer.from("{}", "utf8");
    const verdict = verifyWebhookSignature({
      key: Buffer.from(SECRET, "utf8"),
      headers: {
        "webhook-id": "msg_1",
        "webhook-timestamp": timestamp,
        "webhook-signature": `v1,${signatureFor(Buffer.from(SECRET, "utf8"), "msg_1", timestamp, body)}`,
      },
      body,
      now: NOW,
    });

    expect(verdict).toEqual({ ok: false, refusal: "timestamp_malformed" });
  });

  it("refuses a delivery with no signature headers at all", async () => {
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");

    const response = await post(app, body, { "content-type": "application/json" });

    expect(response.statusCode).toBe(401);
    expect(store.calls).toEqual([]);
    await app.close();
  });

  it("refuses a correctly signed delivery whose timestamp is outside the tolerance", async () => {
    // A signature never expires on its own, so without this a delivery captured once is replayable
    // for as long as the secret lives. The unbounded guard is the event id being a primary key,
    // which is `billing.db.test.ts`'s; this is the bound on what is worth storing.
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");
    const stale = new Date(NOW.getTime() - (WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS + 1) * 1000);

    const response = await post(app, body, deliveryHeaders(body, stale));

    expect(response.statusCode).toBe(401);
    expect(store.calls).toEqual([]);
    await app.close();
  });

  it("tells a refused caller nothing about which half was wrong", async () => {
    const store = recordingStore();
    const app = build(store);
    const body = subscriptionPayload("subscription.active", "active");

    const badSignature = await post(app, body, deliveryHeaders(body, NOW, "msg_1", "wrong"));
    const badTimestamp = await post(
      app,
      body,
      deliveryHeaders(body, new Date(NOW.getTime() - 3_600_000)),
    );

    // Everything but the request id, which is per-request by construction: a caller probing this
    // endpoint must not be able to tell a wrong signature from a stale timestamp, because that tells
    // it which half to fix.
    expect(badSignature.statusCode).toBe(badTimestamp.statusCode);
    expect(badSignature.json().error.code).toBe(badTimestamp.json().error.code);
    expect(badSignature.json().error.message).toBe(badTimestamp.json().error.message);
    expect(badSignature.json().error.retryable).toBe(badTimestamp.json().error.retryable);
    await app.close();
  });

  it("verifies against the raw bytes, not a re-serialisation of them", async () => {
    // The reason this route has a content-type parser of its own. The two bodies below are the same
    // JSON *value* and different bytes; a handler that verified a re-serialised object would accept
    // both, and would then be verifying something other than what it interprets.
    const store = recordingStore();
    const app = build(store);
    const signed = '{"type":"subscription.active","data":{"id":"sub_123","status":"active","product_id":"prod_screen_control"}}';
    const headers = deliveryHeaders(signed);
    const respaced = JSON.stringify(JSON.parse(signed), null, 2);
    expect(respaced).not.toBe(signed);
    expect(JSON.parse(respaced)).toEqual(JSON.parse(signed));

    expect((await post(app, signed, headers)).statusCode).toBe(200);
    expect((await post(app, respaced, headers)).statusCode).toBe(401);
    await app.close();
  });

  it("honours every signature in a rotating endpoint's header, not only the first", () => {
    // A rotation means a window during which the sender signs with both secrets and sends both.
    // Verifying only the first entry would break every rotation, silently, at the worst moment.
    const body = Buffer.from("{}", "utf8");
    const timestamp = String(Math.floor(NOW.getTime() / 1000));
    const mine = signatureFor(Buffer.from(SECRET, "utf8"), "msg_1", timestamp, body);
    const theirs = signatureFor(Buffer.from("the-other-secret", "utf8"), "msg_1", timestamp, body);

    const verdict = verifyWebhookSignature({
      key: Buffer.from(SECRET, "utf8"),
      headers: {
        "webhook-id": "msg_1",
        "webhook-timestamp": timestamp,
        "webhook-signature": `v1,${theirs} v1,${mine}`,
      },
      body,
      now: NOW,
    });

    expect(verdict).toEqual({ ok: true, eventId: "msg_1", sentAt: new Date(Number(timestamp) * 1000) });
  });

  it("refuses a duplicated header rather than picking one", () => {
    const verdict = verifyWebhookSignature({
      key: Buffer.from(SECRET, "utf8"),
      headers: {
        "webhook-id": ["msg_1", "msg_2"],
        "webhook-timestamp": String(Math.floor(NOW.getTime() / 1000)),
        "webhook-signature": "v1,anything",
      },
      body: Buffer.alloc(0),
      now: NOW,
    });

    expect(verdict).toEqual({ ok: false, refusal: "headers" });
  });

  it("refuses a signature list carrying no v1 entry", () => {
    const timestamp = String(Math.floor(NOW.getTime() / 1000));
    const verdict = verifyWebhookSignature({
      key: Buffer.from(SECRET, "utf8"),
      headers: {
        "webhook-id": "msg_1",
        "webhook-timestamp": timestamp,
        "webhook-signature": "v2,something",
      },
      body: Buffer.alloc(0),
      now: NOW,
    });

    expect(verdict).toEqual({ ok: false, refusal: "signature_malformed" });
  });

  it("refuses a timestamp that is not an integer number of seconds", () => {
    for (const timestamp of ["", " ", "1e9", "0x10", "12.5", "not-a-number"]) {
      const verdict = verifyWebhookSignature({
        key: Buffer.from(SECRET, "utf8"),
        headers: {
          "webhook-id": "msg_1",
          "webhook-timestamp": timestamp,
          "webhook-signature": "v1,anything",
        },
        body: Buffer.alloc(0),
        now: NOW,
      });
      expect(verdict.ok).toBe(false);
    }
  });

  it("tolerates a clock in either direction, which the token gate deliberately does not", () => {
    // `auth/clock.ts` grants tolerance only to a token that looks expired, because a token from the
    // future is a forgery or the server's own clock. Neither holds here: the timestamp is inside the
    // signed content, so a sender cannot choose it without the secret, and the disagreement is two
    // real clocks.
    const body = Buffer.from("{}", "utf8");
    for (const offset of [-WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS, WEBHOOK_TIMESTAMP_TOLERANCE_SECONDS]) {
      const at = new Date(NOW.getTime() + offset * 1000);
      const timestamp = String(Math.floor(at.getTime() / 1000));
      const verdict = verifyWebhookSignature({
        key: Buffer.from(SECRET, "utf8"),
        headers: {
          "webhook-id": "msg_1",
          "webhook-timestamp": timestamp,
          "webhook-signature": `v1,${signatureFor(Buffer.from(SECRET, "utf8"), "msg_1", timestamp, body)}`,
        },
        body,
        now: NOW,
      });
      expect(verdict.ok).toBe(true);
    }
  });
});

describe("what the provider says maps onto a neutral event", () => {
  const read = (body: string) =>
    readPolarDelivery({ eventId: "msg_1", sentAt: NOW, body: Buffer.from(body, "utf8") });

  it("maps each status this gateway acts on, and each of the four the ticket names", () => {
    const cases: readonly (readonly [string, string, string])[] = [
      ["subscription.created", "active", "active"],
      ["subscription.active", "active", "active"],
      ["subscription.updated", "trialing", "active"],
      ["subscription.past_due", "past_due", "past_due"],
      ["subscription.revoked", "canceled", "ended"],
      ["subscription.revoked", "revoked", "ended"],
      ["subscription.updated", "unpaid", "ended"],
      ["subscription.paused", "paused", "paused"],
    ];
    for (const [type, status, expected] of cases) {
      const reading = read(subscriptionPayload(type, status));
      expect(reading.kind).toBe("event");
      if (reading.kind !== "event") throw new Error("unreachable");
      expect(reading.event.state).toBe(expected);
      // The provider's own verb survives verbatim, because an operator asking "why did this stop"
      // needs the provider's word rather than this adapter's reading of it.
      expect(reading.event.eventType).toBe(type);
    }
  });

  it("keeps a user who cancelled at period end ENTITLED until the provider revokes", () => {
    // The case an adapter switching on the verb gets exactly backwards. Polar's
    // `subscription.canceled` fires when the user clicks cancel; access continues to the end of the
    // period they already paid for, and the payload still says `active`. Mapping on the verb would
    // cut them off immediately.
    const cancelled = read(
      subscriptionPayload("subscription.canceled", "active", { cancel_at_period_end: true }),
    );
    expect(cancelled.kind).toBe("event");
    if (cancelled.kind !== "event") throw new Error("unreachable");
    expect(cancelled.event.state).toBe("active");

    const revoked = read(subscriptionPayload("subscription.revoked", "revoked"));
    if (revoked.kind !== "event") throw new Error("unreachable");
    expect(revoked.event.state).toBe("ended");
  });

  it("treats an inherited Object key as unreadable, not as a status", () => {
    // **`STATUS[status]` reached `Object.prototype`** (PR #178 review, F4), so `constructor` and its
    // five siblings produced a truthy `state` that is not a `SubscriptionState` at all. `writeFor`'s
    // exhaustive switch then matched nothing, returned `undefined`, and the delivery became a
    // `TypeError` and a 500 rather than the recorded `unreadable` row the table's own doc comment
    // promises. Same reachability as F3 — it needs the signing secret — so this is the table's "no
    // default arm" claim being made true rather than an exploit being closed.
    for (const status of [
      "constructor",
      "toString",
      "valueOf",
      "__proto__",
      "hasOwnProperty",
      "isPrototypeOf",
    ]) {
      const reading = read(subscriptionPayload("subscription.updated", status));
      expect(reading.kind).toBe("unreadable");
      if (reading.kind !== "unreadable") throw new Error("unreachable");
      expect(reading.reason).toContain(status);
    }
    // The control: an ordinary unknown status behaves the same way, which is what says the guard did
    // not simply move the failure somewhere else.
    expect(read(subscriptionPayload("subscription.updated", "zzz")).kind).toBe("unreadable");
  });

  it("ignores a delivery that is not about a subscription", () => {
    const reading = read(JSON.stringify({ type: "order.paid", data: { id: "ord_1" } }));
    expect(reading).toEqual({ kind: "ignored", eventId: "msg_1", eventType: "order.paid" });
  });

  it("refuses to guess at a status it has no mapping for, and names it", () => {
    // Guessing "active" grants a subscription nobody paid for; guessing "ended" revokes one somebody
    // did. Neither is available, so the delivery is recorded unreadable and a human reads the word.
    const reading = read(subscriptionPayload("subscription.updated", "something_new"));
    expect(reading.kind).toBe("unreadable");
    if (reading.kind !== "unreadable") throw new Error("unreachable");
    expect(reading.reason).toContain("something_new");
  });

  it("reads the account from either place the payload can carry it", () => {
    const embedded = read(subscriptionPayload("subscription.active", "active"));
    const flattened = read(
      JSON.stringify({
        type: "subscription.active",
        data: {
          id: SUBSCRIPTION,
          status: "active",
          product_id: PRODUCT,
          customer_external_id: ACCOUNT,
        },
      }),
    );
    for (const reading of [embedded, flattened]) {
      if (reading.kind !== "event") throw new Error("unreachable");
      expect(reading.event.accountId).toBe(ACCOUNT);
    }
  });

  it("orders on the subscription's own instant, falling back to the signed timestamp", () => {
    const dated = read(subscriptionPayload("subscription.active", "active"));
    if (dated.kind !== "event") throw new Error("unreachable");
    expect(dated.event.occurredAt.toISOString()).toBe("2026-08-30T11:59:00.000Z");

    const undated = read(
      JSON.stringify({
        type: "subscription.active",
        data: { id: SUBSCRIPTION, status: "active", product_id: PRODUCT },
      }),
    );
    if (undated.kind !== "event") throw new Error("unreachable");
    // The signed header rather than this gateway's clock: the value decides whether a delivery may
    // overwrite existing state, so it must not be one a sender can choose.
    expect(undated.event.occurredAt).toEqual(NOW);
  });

  it("refuses a body that is not JSON, and one that names no subscription", () => {
    expect(read("not json at all").kind).toBe("unreadable");
    expect(read(JSON.stringify({ type: "subscription.active", data: {} })).kind).toBe("unreadable");
  });
});

describe("the grace window a payment failure opens", () => {
  const paid = {
    ...unprovisioned(ACCOUNT),
    plan: "paid",
    capabilities: ["screen_control"] as readonly string[],
  };

  it("keeps every capability while the window is open — section 16.4's whole point", () => {
    const inGrace = {
      ...paid,
      pastDueSince: new Date("2026-08-30T00:00:00Z"),
      graceUntil: new Date("2026-09-13T00:00:00Z"),
    };
    expect(claimFactsFor(inGrace, NOW)).toEqual({ plan: "paid", capabilities: ["screen_control"] });
  });

  it("drops them the instant it closes, and keeps the plan key", () => {
    const closed = {
      ...paid,
      pastDueSince: new Date("2026-08-01T00:00:00Z"),
      graceUntil: new Date("2026-08-30T12:00:00Z"),
    };
    // The boundary is inclusive: `graceUntil` is when the window has closed, not the last instant it
    // is open. Asserted at exactly that instant rather than a second past it, because an off-by-one
    // here is a paying user refused a second early or a lapsed one served a second late, and only
    // one of those is visible.
    expect(claimFactsFor(closed, NOW)).toEqual({ plan: "paid", capabilities: [] });
    expect(claimFactsFor(closed, new Date(NOW.getTime() - 1))).toEqual({
      plan: "paid",
      capabilities: ["screen_control"],
    });
  });

  it("revokes ahead of grace, so a cancelled account in an open window is still refused", () => {
    const both = {
      ...paid,
      revokedAt: new Date("2026-08-29T00:00:00Z"),
      pastDueSince: new Date("2026-08-30T00:00:00Z"),
      graceUntil: new Date("2026-09-13T00:00:00Z"),
    };
    expect(claimFactsFor(both, NOW)).toEqual({ plan: "paid", capabilities: [] });
  });
});

describe("what a deployment has to configure", () => {
  it("mounts no webhook route at all when no provider is named", async () => {
    const app = buildApp(testConfig(), {
      provider: new UnusedAuthProvider(),
      withConnection: signedInConnection,
    }, { entitlementStore: fakeEntitlementStore() });
    await app.ready();

    const response = await app.inject({ method: "POST", url: "/v1/billing/webhook", payload: "{}" });

    // 404 and not 401: the route does not exist on a deployment that takes no payments, which is
    // the opposite call from the model routes and `app.ts` says why.
    expect(response.statusCode).toBe(404);
    await app.close();
  });

  it("mounts exactly two billing routes, one challenged and one carried by its signature", async () => {
    // **The gate's own population scan cannot see either of these** (PR #178 review, F6):
    // `gate.test.ts` builds from `testConfig()`, which names no provider, so `app.ts` mounts neither
    // route and the scan that exists to catch a route added without thought is blind to anything
    // behind a config flag. `gate.test.ts` now scans a billing-configured app too; this is the same
    // property from the billing side, so a third route added inside that scope fails here as well as
    // there. Asserted as an exact list rather than a membership check, because what the scan is for
    // is noticing an addition.
    const app = build(recordingStore());
    await app.ready();
    const all = await registeredRoutes(app);
    // The same guard `gate.test.ts` uses: proves the parse really parsed, so a filter that answers
    // nothing cannot pass as "no billing routes were mounted".
    expectPopulationIsReal(all);
    const routes = all
      .map((route) => `${route.method} ${route.url}`)
      .filter((route) => route.includes("/v1/billing/"));

    expect(routes.sort()).toEqual(["POST /v1/billing/checkout", "POST /v1/billing/webhook"]);
    expect(isPublicRoute("POST", "/v1/billing/webhook")).toBe(true);
    expect(isPublicRoute("POST", "/v1/billing/checkout")).toBe(false);
    await app.close();
  });

  it("refuses to start when a provider is named and its secret is not", () => {
    expect(() => billingDepsFrom(testConfig({ billingProvider: "polar" }))).toThrow(ConfigError);
    try {
      billingDepsFrom(testConfig({ billingProvider: "polar" }));
    } catch (error) {
      const message = (error as Error).message;
      // Every missing name at once, so an operator fixes them in one pass rather than three starts.
      expect(message).toContain("BILLING_WEBHOOK_SECRET");
      expect(message).toContain("BILLING_CHECKOUT_URL");
      expect(message).toContain("BILLING_PLANS");
      expect(message).not.toContain(SECRET);
    }
  });

  it("parses a plan map, and refuses one it cannot read rather than dropping the entry", () => {
    const plans = parseBillingPlans("prod_a=paid:screen_control|power, prod_b=trial:screen_control");
    expect(plans.get("prod_a")).toEqual({ plan: "paid", capabilities: ["screen_control", "power"] });
    expect(plans.get("prod_b")).toEqual({ plan: "trial", capabilities: ["screen_control"] });
    expect(plans.size).toBe(2);

    // A dropped entry is a product that grants nothing, which presents as one customer's
    // subscription not working and nothing else. Each refusal names the entry.
    expect(() => parseBillingPlans("prod_a")).toThrow(ConfigError);
    expect(() => parseBillingPlans("prod_a=paid")).toThrow(ConfigError);
    expect(() => parseBillingPlans("prod_a=paid:")).toThrow(ConfigError);
    expect(() => parseBillingPlans("prod_a=paid:x,prod_a=other:y")).toThrow(ConfigError);
  });

  it("derives the HMAC key as the raw bytes of the secret, which is what the provider signs with", () => {
    // The one Polar-specific detail with teeth, and it is asserted rather than left in prose: Polar's
    // SDK base64-encodes the secret into a standard-webhooks verifier that base64-decodes it, so the
    // key is the secret's own UTF-8 bytes. A wrong derivation here refuses every genuine delivery.
    expect(polarProvider({ webhookSecret: SECRET, checkoutUrl: CHECKOUT }).webhookKey).toEqual(
      Buffer.from(SECRET, "utf8"),
    );
    expect(polarProvider({ webhookSecret: SECRET, checkoutUrl: CHECKOUT }).name).toBe(POLAR);
  });
});

describe("where a user is sent to subscribe", () => {
  it("hands an authenticated caller a checkout link carrying its own account", async () => {
    const app = build(recordingStore());

    const response = await app.inject({
      method: "POST",
      url: "/v1/billing/checkout",
      headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
    });

    expect(response.statusCode).toBe(200);
    // The account id on this URL is the only reason a later webhook can be attributed at all.
    expect(response.json().checkout_url).toBe(`${CHECKOUT}?customer_external_id=${ACCOUNT}`);
    await app.close();
  });

  it("refuses a second checkout while the account is already live on a subscription", async () => {
    // **The second defence beside F1's** (founder direction, 2026-08-30). This route had no guard at
    // all — three lines that read the caller and returned a link — so a second checkout on one
    // account was an ordinary user action rather than a contrivance. What this closes is the
    // sequential door; the concurrent races are not closed by any check here, because the link is
    // static and both tabs hold theirs from before the first subscription existed.
    const store = recordingStore(true);
    const app = build(store);

    const response = await app.inject({
      method: "POST",
      url: "/v1/billing/checkout",
      headers: { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("entitlement.already_subscribed");
    expect(response.json().error.retryable).toBe(false);
    // And no link is handed out, which is the whole point — a body carrying one beside a 409 would
    // be a refusal a client could ignore by reading the field it wanted.
    expect(response.json().checkout_url).toBeUndefined();
    await app.close();
  });

  it("challenges an unauthenticated caller, because it is not in PUBLIC_ROUTES", async () => {
    const app = build(recordingStore());

    const response = await app.inject({ method: "POST", url: "/v1/billing/checkout" });

    expect(response.statusCode).toBe(401);
    await app.close();
  });

  it("keeps a query parameter the configured link already carried", () => {
    const provider = polarProvider({
      webhookSecret: SECRET,
      checkoutUrl: "https://buy.example.test/checkout/abc?theme=dark",
    });
    const url = new URL(provider.checkoutUrlFor(ACCOUNT));
    expect(url.searchParams.get("theme")).toBe("dark");
    expect(url.searchParams.get("customer_external_id")).toBe(ACCOUNT);
  });
});
