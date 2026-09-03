import { randomUUID } from "node:crypto";
import type pg from "pg";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { creditBalance } from "../src/credit/balance.js";
import { catalogueOf, fakeCreditStore, TEST_CREDIT_PLANS_WITH_TOP_UP } from "./support/credit.js";
import type { CreditTopUpPack } from "../src/credit/catalogue.js";
import {
  attemptTopUp,
  type TopUpAttempt,
  type TopUpAttemptStore,
  type TopUpDeps,
} from "../src/credit/topup.js";
import type {
  BillingProvider,
  TopUpCharge,
  TopUpChargeRequest,
} from "../src/billing/provider.js";
import { polarProvider, readPolarDelivery, TOPUP_CHARGE_TIMEOUT_MS } from "../src/billing/polar.js";
import type { WithConnection } from "../src/db/connection.js";
import type { ClaimOutcome, KeyStore } from "../src/idempotency/store.js";
import { testConfig } from "./support/config.js";
import { fakeEntitlementStore } from "./support/entitlement.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * Topping up happens only if you asked (SONNY-215).
 *
 * **The whole suite is arranged around one negative**, because the ticket's hard requirement is a
 * negative: *no charge occurs without the explicit opt-in*. A test that only proved the happy path
 * would pass just as well against an implementation that charged everybody, so what is asserted
 * throughout is not merely the refusal's status but that **the provider was never called** and that
 * **no attempt row was claimed** — which are the two places a charge could have happened.
 *
 * The split with `topup.db.test.ts` is the same one every store in this repository makes: the
 * refusals and the mapping are proved here with no database, and the two properties a fake cannot
 * say anything about — that the per-period bound really is atomic under two concurrent claims, and
 * that a granted row really does raise the next read's allowance — are proved there against a real
 * Postgres.
 */

const SUPABASE_USER = "5a1f2e3d-4c5b-6a79-8b0c-1d2e3f4a5b6c";
const ACCOUNT = "7e8d9c0b-1a2b-3c4d-5e6f-7a8b9c0d1e2f";
const CUSTOMER = "cust_polar_1";
const AT = new Date("2026-08-15T12:00:00Z");

/** The pack `TEST_CREDIT_PLANS_WITH_TOP_UP` carries, as the decision function receives it. */
const PACK: CreditTopUpPack = { credits: 500, productId: "test-product-topup", maxPerPeriod: 3 };

/**
 * A provider that answers whatever it was built with and **counts every call**.
 *
 * The count is the point. Every refusal below asserts it is zero, which is the only way to state
 * "nothing was charged" — an outcome assertion alone passes just as well if the charge is made and
 * its answer discarded.
 */
function scriptedProvider(answer: TopUpCharge): BillingProvider & {
  readonly charges: TopUpChargeRequest[];
} {
  const charges: TopUpChargeRequest[] = [];
  return {
    charges,
    name: "test-provider",
    webhookKey: Buffer.alloc(0),
    read: () => ({ kind: "ignored", eventId: "x", eventType: "y" }),
    checkoutUrlFor: () => "https://checkout.invalid",
    portalUrlFor: async () => ({ kind: "noCustomer" }),
    chargeTopUp: async (request) => {
      charges.push(request);
      return answer;
    },
  };
}

/** An in-memory `TopUpAttemptStore` that records what it was asked to claim and to settle. */
function recordingAttempts(options: { readonly full?: boolean } = {}): TopUpAttemptStore & {
  readonly claims: Parameters<TopUpAttemptStore["claim"]>[0][];
  readonly settlements: Parameters<TopUpAttemptStore["settle"]>[0][];
} {
  const claims: Parameters<TopUpAttemptStore["claim"]>[0][] = [];
  const settlements: Parameters<TopUpAttemptStore["settle"]>[0][] = [];
  return {
    claims,
    settlements,
    claim: async (input): Promise<TopUpAttempt | undefined> => {
      claims.push(input);
      // `undefined` is what a full period answers, which is the only thing a fake can honestly model
      // about the bound — the atomicity is `topup.db.test.ts`'s.
      return options.full === true ? undefined : { topUpId: "topup-1" };
    },
    settle: async (input) => {
      settlements.push(input);
    },
  };
}

/** The catalogue every decision test uses: ten credits a run, a thousand a month, one a iteration. */
function catalogue() {
  return catalogueOf({ runCredits: 10, monthlyCredits: [1000] });
}

/** A balance with `runsLeft` at zero — the state the gate would otherwise refuse on. */
function exhausted() {
  return creditBalance({
    catalogue: catalogue(),
    planKey: undefined,
    // 1000 iterations at one credit each is the whole allowance.
    draw: { sessions: 0, iterations: 1000, pixels: 0 },
    toppedUpCredits: 0,
    now: AT,
  });
}

/** A balance with runs still in hand. */
function comfortable() {
  return creditBalance({
    catalogue: catalogue(),
    planKey: undefined,
    draw: { sessions: 0, iterations: 10, pixels: 0 },
    toppedUpCredits: 0,
    now: AT,
  });
}

function depsFor(
  provider: ReturnType<typeof scriptedProvider>,
  attempts: ReturnType<typeof recordingAttempts>,
  options: { readonly pack?: CreditTopUpPack | undefined; readonly customer?: string | undefined } = {},
): TopUpDeps {
  return {
    pack: "pack" in options ? options.pack : PACK,
    provider,
    billingCustomerFor: async () => ("customer" in options ? options.customer : CUSTOMER),
    attempts,
  };
}

describe("no charge occurs without the explicit opt-in", () => {
  it("refuses an account that never opted in, and calls nobody and claims nothing", async () => {
    // **The ticket's one hard requirement, stated as the three things that did not happen.** The
    // refusal is the least of them: what makes this the guarantee rather than a status code is that
    // the provider was not asked and no row was written, so there is no path by which money moved.
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: null,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "not_opted_in" });
    expect(provider.charges).toEqual([]);
    expect(attempts.claims).toEqual([]);
    expect(attempts.settlements).toEqual([]);
  });

  it("checks the consent BEFORE anything else, which is what stops another refusal hiding it", async () => {
    // An account that is *both* not opted in and not low. If the order were reversed this would
    // answer `not_needed` — true, and it would leave the consent check unexercised on the one path a
    // reader is most likely to sample. The assertion is on the refusal's identity for that reason.
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: comfortable(),
      consentedAt: null,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "not_opted_in" });
    expect(provider.charges).toEqual([]);
  });

  it("carries the consent instant onto the row a charge is recorded in", async () => {
    // The schema half of the same requirement: `credit_topup.consented_at` is NOT NULL, so this
    // value is what makes the row writable at all. A charge that reached the provider with a `null`
    // here could not have been recorded, which is why the claim happens first.
    const consentedAt = new Date("2026-08-02T09:30:00Z");
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt,
      now: AT,
    });

    expect(attempts.claims).toHaveLength(1);
    expect(attempts.claims[0]?.consentedAt).toEqual(consentedAt);
  });
});

describe("what else has to be true before anybody is charged", () => {
  it("refuses when this deployment sells no pack, without asking the provider", async () => {
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts, { pack: undefined }), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "not_offered" });
    expect(provider.charges).toEqual([]);
    expect(attempts.claims).toEqual([]);
  });

  it("refuses an account that can still afford a run — a client does not get to say it is low", async () => {
    // The balance is recomputed by the route from the account's own metering rows, so this is the
    // check that stops a modified client buying credit it does not need. `runsLeft > 0` is the
    // weaker of the gate's two exhaustion conditions and therefore covers both of its moments.
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const balance = comfortable();
    expect(balance.runsLeft).toBe(99);

    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance,
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "not_needed" });
    expect(provider.charges).toEqual([]);
    expect(attempts.claims).toEqual([]);
  });

  it("refuses an account with no customer at the provider without spending one of its attempts", async () => {
    // The ordering that matters here is the other one: the customer lookup happens *before* the
    // claim, so an account that can never be charged does not burn the period's bound on a refusal
    // that costs nobody anything.
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts, { customer: undefined }), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "no_customer" });
    expect(attempts.claims).toEqual([]);
    expect(provider.charges).toEqual([]);
  });

  it("refuses once the period's attempts are spent, and still calls nobody", async () => {
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts({ full: true });
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "limit_reached" });
    // The claim was attempted — that is what discovered the period was full — and the charge was
    // not. A bound that refused after the charge would be no bound at all.
    expect(attempts.claims).toHaveLength(1);
    expect(provider.charges).toEqual([]);
    expect(attempts.settlements).toEqual([]);
  });
});

describe("what a charge grants, and what every other answer does not", () => {
  it("grants the pack's credits and records the order that paid for them", async () => {
    const provider = scriptedProvider({ kind: "charged", orderId: "order-7" });
    const attempts = recordingAttempts();
    const balance = exhausted();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance,
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "granted", credits: 500 });
    // The charge is addressed to the provider's own customer and names the configured product.
    expect(provider.charges).toEqual([{ customerId: CUSTOMER, productId: "test-product-topup" }]);
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome: "granted",
        credits: 500,
        providerOrderId: "order-7",
        settledAt: AT,
      },
    ]);
    // The justification for the trigger, recorded beside the charge because the catalogue that
    // priced it lives in an environment variable and no row can reconstruct it (SONNY-394).
    expect(attempts.claims[0]).toMatchObject({
      runsLeftAtTrigger: 0,
      creditsRemainingAtTrigger: balance.credits.remaining,
      maxPerPeriod: 3,
      periodStart: balance.periodStart,
    });
  });

  it.each([
    ["declined" as const, { kind: "declined", reason: "provider answered 402" } as TopUpCharge, "declined"],
    ["unavailable" as const, { kind: "unavailable", reason: "down" } as TopUpCharge, "provider_error"],
    ["timed_out" as const, { kind: "timedOut", reason: "slow" } as TopUpCharge, "provider_error"],
    ["rejected" as const, { kind: "rejected", reason: "bad token" } as TopUpCharge, "provider_error"],
    ["no_customer" as const, { kind: "noCustomer" } as TopUpCharge, "provider_error"],
  ])("grants nothing when the provider answers %s, and records why", async (refusal, answer, outcome) => {
    // **Every arm asserts `credits: 0`**, which is the property `credit_topup`'s own CHECK enforces
    // in both directions: a row that granted nothing may not read `granted`, and a granted row may
    // not grant nothing. A mapping that credited a decline would be free product on a failed charge.
    const provider = scriptedProvider(answer);
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal });
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome,
        credits: 0,
        // No order id on any of these: none of them is an answer where money may have moved, so
        // there is nothing for an operator to go and look at.
        providerOrderId: undefined,
        settledAt: AT,
      },
    ]);
  });

  it("keeps the order id when the answer could not be read, because that is the one to go and look at", async () => {
    // The only arm where doing nothing is not obviously safe: the charge may have gone through and
    // nothing was granted for it. Nothing here resolves that — what it does is leave a queryable row
    // naming the object at the provider, which is what makes the resolution possible at all.
    const provider = scriptedProvider({
      kind: "unconfirmed",
      reason: "finalize did not answer: TimeoutError",
      orderId: "order-9",
    });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "unconfirmed" });
    expect(attempts.settlements[0]).toMatchObject({
      outcome: "unconfirmed",
      credits: 0,
      providerOrderId: "order-9",
    });
  });
});

describe("a top-up raises the allowance rather than lowering the draw", () => {
  it("moves the denominator too, so the user is not shown ten runs arriving from nowhere", () => {
    const plans = catalogue();
    const before = creditBalance({
      catalogue: plans,
      planKey: undefined,
      draw: { sessions: 0, iterations: 1000, pixels: 0 },
      toppedUpCredits: 0,
      now: AT,
    });
    const after = creditBalance({
      catalogue: plans,
      planKey: undefined,
      draw: { sessions: 0, iterations: 1000, pixels: 0 },
      toppedUpCredits: 500,
      now: AT,
    });

    expect(before.runsLeft).toBe(0);
    expect(before.runsIncluded).toBe(100);
    expect(after.runsLeft).toBe(50);
    // The denominator moves with it: "50 of 150 left", not fifty runs appearing inside a hundred.
    expect(after.runsIncluded).toBe(150);
    // The draw is untouched. That is the half `balance.ts` refuses to ledger, and a top-up is a
    // grant rather than a second writer of it.
    expect(after.credits.drawn).toBe(before.credits.drawn);
    expect(after.credits.toppedUp).toBe(500);
  });
});

// ── The routes ────────────────────────────────────────────────────────────────────────────────

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
        throw new Error(`unexpected query outside the credit store: ${text}`);
      }
      return { rows: [{ account_id: ACCOUNT }] };
    },
  };
  return work(client as unknown as pg.Client);
};

/** Grants every claim and remembers nothing — `credit.test.ts`'s, and for its stated reason. */
const alwaysClaims: KeyStore = {
  claim: async (): Promise<ClaimOutcome> => ({ kind: "claimed", token: randomUUID() }),
  complete: async () => {},
  release: async () => {},
};

const AUTH = { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` };

function buildTopUpApp(input: {
  readonly store: ReturnType<typeof fakeCreditStore>;
  readonly provider?: ReturnType<typeof scriptedProvider>;
  readonly attempts?: ReturnType<typeof recordingAttempts>;
  readonly customer?: string | undefined;
  readonly plans?: string;
}) {
  const provider = input.provider ?? scriptedProvider({ kind: "charged", orderId: "order-1" });
  return buildApp(
    testConfig({
      creditPlans: input.plans ?? TEST_CREDIT_PLANS_WITH_TOP_UP,
      // The billing block is what mounts a chargeable deployment. The provider below is a fake, so
      // none of these values reaches a network.
      billingProvider: "polar",
      billingWebhookSecret: "test-webhook-secret",
      billingCheckoutUrl: "https://checkout.invalid/x",
      billingProviderAccessToken: "test-access-token",
      billingPlans: "prod_1=plan-a:cap",
    }),
    { provider: new UnusedAuthProvider(), withConnection: signedInConnection, now: () => AT },
    {
      creditStore: input.store,
      entitlementStore: fakeEntitlementStore(),
      idempotencyStore: alwaysClaims,
      topUpAttemptStore: input.attempts ?? recordingAttempts(),
      billingStore: {
        apply: async () => ({ outcome: "ignored", accountId: undefined }),
        hasLiveSubscription: async () => false,
        hasSubscriptionRecord: async () => false,
        billingCustomerFor: async () => ("customer" in input ? input.customer : CUSTOMER),
      },
      // The fake provider reaches the route through the same door the real one does; `app.ts` builds
      // the provider from config, so this override is the credit route's own.
      topUpProvider: provider,
    },
  );
}

describe("the routes a user reaches the setting and the charge through", () => {
  const drawn = { sessions: 0, iterations: 1000, pixels: 0 };

  it("says the setting is off for an account that has never touched it", async () => {
    // **Off by default, read off the wire.** The store's `autoTopUpOptedInAt` defaults to `null`,
    // which is what an absent `sonny.auto_topup_consent` row answers.
    const app = buildTopUpApp({ store: fakeCreditStore({ planKey: "test-plan-a" }) });
    const response = await app.inject({ method: "GET", url: "/v1/account/credits", headers: AUTH });

    expect(response.statusCode).toBe(200);
    expect(response.json().auto_top_up).toEqual({
      offered: true,
      opted_in: false,
      attempts_left: 3,
    });
    await app.close();
  });

  it("says nothing is offered on a deployment that configured no pack", async () => {
    // A control that only fails when pressed is a broken control (founder direction, 2026-08-31), so
    // the app is told there is nothing to offer rather than being left to discover it on a press.
    const app = buildTopUpApp({
      store: fakeCreditStore({ planKey: "test-plan-a" }),
      plans: JSON.stringify({
        runCredits: 10,
        defaultPlan: "test-plan-a",
        weights: { perSession: 0, perIteration: 1, perMegapixel: 0 },
        plans: [{ key: "test-plan-a", monthlyCredits: 1000 }],
      }),
    });
    const response = await app.inject({ method: "GET", url: "/v1/account/credits", headers: AUTH });

    expect(response.json().auto_top_up).toEqual({
      offered: false,
      opted_in: false,
      attempts_left: 0,
    });
    await app.close();
  });

  it("turns the setting on and off, and answers the whole position each time", async () => {
    const store = fakeCreditStore({ planKey: "test-plan-a" });
    const app = buildTopUpApp({ store });

    const on = await app.inject({
      method: "PUT",
      url: "/v1/account/credits/auto-top-up",
      headers: AUTH,
      payload: { enabled: true },
    });
    expect(on.statusCode).toBe(200);
    expect(on.json().auto_top_up.opted_in).toBe(true);
    // Answered with the balance beside the setting, so the surface that shows both cannot be one
    // request apart from itself.
    expect(on.json().screen_control_runs_left).toBe(100);

    const off = await app.inject({
      method: "PUT",
      url: "/v1/account/credits/auto-top-up",
      headers: AUTH,
      payload: { enabled: false },
    });
    expect(off.statusCode).toBe(200);
    expect(off.json().auto_top_up.opted_in).toBe(false);
    expect(store.settings).toEqual([
      { accountId: ACCOUNT, enabled: true },
      { accountId: ACCOUNT, enabled: false },
    ]);
    await app.close();
  });

  it("refuses a body that is not a setting rather than guessing at one", async () => {
    const app = buildTopUpApp({ store: fakeCreditStore({ planKey: "test-plan-a" }) });
    const response = await app.inject({
      method: "PUT",
      url: "/v1/account/credits/auto-top-up",
      headers: AUTH,
      payload: { enabled: "yes" },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("request.invalid");
    await app.close();
  });

  it("refuses the charge for an account that never opted in, and the provider is never called", async () => {
    // **The hard requirement, through the real route.** The store's consent defaults to `null`, so
    // this is the request a modified client would make — and it is answered without a charge.
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    const attempts = recordingAttempts();
    const app = buildTopUpApp({
      store: fakeCreditStore({ planKey: "test-plan-a", draw: drawn }),
      provider,
      attempts,
    });

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("topup.not_permitted");
    expect(response.json().error.retryable).toBe(false);
    expect(provider.charges).toEqual([]);
    expect(attempts.claims).toEqual([]);
    await app.close();
  });

  it("charges an opted-in account that has run out, and answers the allowance it bought", async () => {
    const provider = scriptedProvider({ kind: "charged", orderId: "order-1" });
    // The store models the grant landing: the second read reports the topped-up credits, which is
    // what the real route re-reads after the charge.
    const store = fakeCreditStore({
      planKey: "test-plan-a",
      draw: drawn,
      autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
    });
    const granted = fakeCreditStore({
      planKey: "test-plan-a",
      draw: drawn,
      toppedUpCredits: 500,
      topUpAttemptsThisPeriod: 1,
      autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
    });
    let reads = 0;
    const staged = {
      ...store,
      factsFor: (accountId: string, now: Date) => {
        reads += 1;
        return reads === 1 ? store.factsFor(accountId, now) : granted.factsFor(accountId, now);
      },
    };
    const app = buildTopUpApp({ store: staged, provider });

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(200);
    expect(provider.charges).toHaveLength(1);
    const body = response.json();
    expect(body.screen_control_runs_left).toBe(50);
    expect(body.screen_control_runs_included).toBe(150);
    expect(body.credits.topped_up).toBe(500);
    expect(body.auto_top_up).toEqual({ offered: true, opted_in: true, attempts_left: 2 });
    await app.close();
  });

  it("answers 402 when the provider declined, which is a different fact from a refusal to try", async () => {
    // The one refusal with its own status: "your card" and "your settings" are different problems
    // with different fixes, and collapsing them here is what a later surface could not recover.
    const provider = scriptedProvider({ kind: "declined", reason: "provider answered 402" });
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      provider,
    });

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(402);
    expect(response.json().error.code).toBe("topup.declined");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it("marks an unreadable answer NOT retryable, because a retry would buy a second pack", async () => {
    const provider = scriptedProvider({
      kind: "unconfirmed",
      reason: "finalize answered 200 with status null",
      orderId: "order-3",
    });
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      provider,
    });

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(502);
    expect(response.json().error.code).toBe("topup.unconfirmed");
    // **The assertion the whole case exists for.** `provider.unavailable` would have been the
    // obvious code and it is marked retryable, which is advice to charge the user again to recover
    // from a charge nobody can see.
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  it.each([
    [{ kind: "unavailable", reason: "down" } as TopUpCharge, 502, "provider.unavailable", true],
    [{ kind: "timedOut", reason: "slow" } as TopUpCharge, 504, "provider.timeout", true],
    [{ kind: "rejected", reason: "revoked" } as TopUpCharge, 502, "provider.rejected", false],
  ])("maps a provider fault onto 7.2 rather than inventing a status", async (answer, status, code, retryable) => {
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      provider: scriptedProvider(answer),
    });

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(status);
    expect(response.json().error.code).toBe(code);
    expect(response.json().error.retryable).toBe(retryable);
    await app.close();
  });

  it("refuses the charge on a deployment that takes no payments, rather than 404ing the route", async () => {
    // The route is mounted either way. A `404` tells a client there is no such route, which it reads
    // as a version problem; this deployment simply sells nothing.
    const app = buildApp(
      testConfig({ creditPlans: TEST_CREDIT_PLANS_WITH_TOP_UP }),
      { provider: new UnusedAuthProvider(), withConnection: signedInConnection, now: () => AT },
      {
        creditStore: fakeCreditStore({
          planKey: "test-plan-a",
          draw: drawn,
          autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
        }),
        entitlementStore: fakeEntitlementStore(),
        idempotencyStore: alwaysClaims,
      },
    );

    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { ...AUTH, "idempotency-key": randomUUID() },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("topup.not_permitted");
    // And the `GET` says so up front, so nothing renders a control that would land here.
    const read = await app.inject({ method: "GET", url: "/v1/account/credits", headers: AUTH });
    expect(read.json().auto_top_up.offered).toBe(false);
    await app.close();
  });

  it("serves the caller's own account and nobody else's", async () => {
    // PR #182's F6, applied to the two routes it did not exist for: a charge made against a fixed
    // account id would be one user buying another user a top-up.
    const store = fakeCreditStore({ planKey: "test-plan-a" });
    const app = buildTopUpApp({ store });
    await app.inject({
      method: "PUT",
      url: "/v1/account/credits/auto-top-up",
      headers: AUTH,
      payload: { enabled: true },
    });

    expect(store.settings.map((setting) => setting.accountId)).toEqual([ACCOUNT]);
    expect(new Set(store.askedAbout)).toEqual(new Set([ACCOUNT]));
    await app.close();
  });
});

// ── The Polar adapter ─────────────────────────────────────────────────────────────────────────

/** A `fetch` that answers the scripted responses in order and records every request. */
function scriptedFetch(...responses: Response[]) {
  const calls: { url: string; body: string | undefined }[] = [];
  const queue = [...responses];
  const call: typeof fetch = async (input, init) => {
    calls.push({
      url: String(input),
      body: typeof init?.body === "string" ? init.body : undefined,
    });
    const next = queue.shift();
    if (next === undefined) throw new Error("no scripted response left");
    return next;
  };
  return { call, calls };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function polar(call: typeof fetch): BillingProvider {
  return polarProvider({
    webhookSecret: "secret",
    checkoutUrl: "https://checkout.invalid/x",
    accessToken: "polar-access-token",
    apiBaseUrl: "https://api.invalid",
    fetchImplementation: call,
  });
}

const CHARGE: TopUpChargeRequest = { customerId: CUSTOMER, productId: "prod_topup" };

describe("the provider adapter's off-session charge", () => {
  it("creates a draft and then finalizes it, and only the second one moves money", async () => {
    const scripted = scriptedFetch(
      json(201, { id: "order-1", status: "draft" }),
      json(200, { id: "order-1", status: "paid" }),
    );
    const charge = await polar(scripted.call).chargeTopUp(CHARGE);

    expect(charge).toEqual({ kind: "charged", orderId: "order-1" });
    expect(scripted.calls.map((made) => made.url)).toEqual([
      "https://api.invalid/v1/orders/",
      "https://api.invalid/v1/orders/order-1/finalize",
    ]);
    // The draft names the provider's own customer and the configured product, and nothing else —
    // no amount and no currency, because the product's price at the provider is the price.
    expect(JSON.parse(scripted.calls[0]?.body ?? "{}")).toEqual({
      customer_id: CUSTOMER,
      product_id: "prod_topup",
    });
    expect(scripted.calls[1]?.body).toBe("{}");
  });

  it("does not finalize when the draft could not be created", async () => {
    // The half of the two-call shape that makes a failed draft free: nothing has been charged, so
    // the answer is an ordinary outage rather than an unresolved charge.
    const scripted = scriptedFetch(json(503, { detail: "down" }));
    const charge = await polar(scripted.call).chargeTopUp(CHARGE);

    expect(charge).toEqual({ kind: "unavailable", reason: "provider answered 503" });
    expect(scripted.calls).toHaveLength(1);
  });

  it("reads a 404 with the provider's own body as a missing customer and anything else as a fault", async () => {
    // The portal's rule, for its reason: a wrong origin or a dropped path prefix is answered by a
    // proxy with HTML, and mapping that to "no customer" would tell a paying subscriber they have no
    // payment method when the deployment is misconfigured.
    const provider = polar(scriptedFetch(json(404, { detail: "no such customer" })).call);
    expect(await provider.chargeTopUp(CHARGE)).toEqual({ kind: "noCustomer" });

    const html = new Response("<html>404</html>", { status: 404 });
    const other = polar(scriptedFetch(html).call);
    expect(await other.chargeTopUp(CHARGE)).toEqual({
      kind: "rejected",
      reason: "provider answered 404",
    });
  });

  it("calls a 402 a decline rather than an outage, because a retry fails identically", async () => {
    const scripted = scriptedFetch(
      json(201, { id: "order-2", status: "draft" }),
      json(402, { detail: "card_declined" }),
    );
    expect(await polar(scripted.call).chargeTopUp(CHARGE)).toEqual({
      kind: "declined",
      reason: "provider answered 402",
    });
  });

  it("treats an order that is no longer a draft as a charge that may have happened", async () => {
    // **412 is the case this classification exists for.** It is a plain 4xx, and reading it as a
    // refusal would be reading "already paid" as "not paid" — so it is `unconfirmed`, with the order
    // an operator has to look at.
    const scripted = scriptedFetch(
      json(201, { id: "order-3", status: "draft" }),
      json(412, { detail: "not a draft" }),
    );
    expect(await polar(scripted.call).chargeTopUp(CHARGE)).toEqual({
      kind: "unconfirmed",
      reason: "order was no longer a draft",
      orderId: "order-3",
    });
  });

  it("splits the two 5xx cases by whether money could have moved, which is the whole axis", async () => {
    // The same status on the two calls means two different things: nothing was charged on the draft,
    // and a charge may have failed after taking the money on the finalize.
    const onDraft = scriptedFetch(json(500, { detail: "boom" }));
    expect(await polar(onDraft.call).chargeTopUp(CHARGE)).toMatchObject({ kind: "unavailable" });

    const onFinalize = scriptedFetch(
      json(201, { id: "order-4", status: "draft" }),
      json(500, { detail: "boom" }),
    );
    expect(await polar(onFinalize.call).chargeTopUp(CHARGE)).toEqual({
      kind: "unconfirmed",
      reason: "provider answered 500",
      orderId: "order-4",
    });
  });

  it("refuses to read a 200 that does not say paid as a success", async () => {
    // Interpreting an unexpected status generously is how credit gets granted for a charge that
    // never happened.
    const scripted = scriptedFetch(
      json(201, { id: "order-5", status: "draft" }),
      json(200, { id: "order-5", status: "pending" }),
    );
    expect(await polar(scripted.call).chargeTopUp(CHARGE)).toEqual({
      kind: "unconfirmed",
      reason: 'finalize answered 200 with status "pending"',
      orderId: "order-5",
    });
  });

  it("refuses a 200 that says nothing at all, which is not the same shape as a wrong status", async () => {
    // **The gap the first battery found (S9), and it is the more dangerous half of the same
    // check.** The test above sends a status this gateway does not recognise; these send *no*
    // status — a body with the field missing, and a body that is not JSON. Both leave `status`
    // undefined, and a mutant that let `undefined` through was killed by nothing: an unreadable
    // answer would have granted a pack, which is the one direction `TopUpCharge`'s whole
    // classification exists to refuse. `null` in the reason rather than a quoted word is what says
    // which of the two cases it was.
    for (const body of [json(200, { id: "order-6" }), new Response("not json", { status: 200 })]) {
      const scripted = scriptedFetch(json(201, { id: "order-6", status: "draft" }), body);
      expect(await polar(scripted.call).chargeTopUp(CHARGE)).toEqual({
        kind: "unconfirmed",
        reason: "finalize answered 200 with status null",
        orderId: "order-6",
      });
    }
  });

  it("rejects a draft that answers 200 naming no order, because there is nothing to finalize", async () => {
    const scripted = scriptedFetch(json(201, { status: "draft" }));
    expect(await polar(scripted.call).chargeTopUp(CHARGE)).toEqual({
      kind: "rejected",
      reason: "provider created an order naming no id",
    });
    expect(scripted.calls).toHaveLength(1);
  });

  it("never puts the access token in a reason", async () => {
    // Every `reason` this adapter produces is built from a status or an error name. The token is on
    // a header and the refusals are what a log line carries, so this is the assertion that keeps the
    // two apart.
    const answers: TopUpCharge[] = [];
    for (const response of [json(500, {}), json(404, { detail: "x" }), json(403, {})]) {
      answers.push(await polar(scriptedFetch(response).call).chargeTopUp(CHARGE));
    }
    for (const answer of answers) {
      expect(JSON.stringify(answer)).not.toContain("polar-access-token");
    }
  });

  it("keeps its outbound budget under the Mac's own, across BOTH of its calls", async () => {
    // `PORTAL_SESSION_TIMEOUT_MS`'s pin, and the reason this one differs: a top-up makes two
    // sequential calls, so what has to clear the Mac's budget is twice this number. Both literals
    // are written here for that test's stated reason — the rule is a relation *between* the halves
    // and neither side can read the other's code. The Mac's number is `SonnyBackendTimeouts.topUp`,
    // asserted as 40 on its own side.
    const macTopUpTimeoutMs = 40_000;
    expect(TOPUP_CHARGE_TIMEOUT_MS).toBe(12_000);
    expect(TOPUP_CHARGE_TIMEOUT_MS * 2).toBeLessThan(macTopUpTimeoutMs);
  });

  it("reads the provider's own customer id off a delivery, not the external one", async () => {
    // **The two are different identifiers for one person and only one of them can be charged.** The
    // external id is the account id checkout travels on and is what attributes the webhook; the
    // `id` is Polar's own, and an order addressed to the external one 404s on a perfectly well
    // provisioned account.
    const body = Buffer.from(
      JSON.stringify({
        type: "subscription.active",
        data: {
          id: "sub_1",
          status: "active",
          product_id: "prod_1",
          modified_at: "2026-08-15T12:00:00Z",
          customer: { id: "cus_polar_9", external_id: ACCOUNT },
        },
      }),
    );
    const reading = readPolarDelivery({ eventId: "evt_1", sentAt: AT, body });

    expect(reading.kind).toBe("event");
    const event = (reading as { event: { accountId?: string; customerId?: string } }).event;
    expect(event.accountId).toBe(ACCOUNT);
    expect(event.customerId).toBe("cus_polar_9");
  });
});
