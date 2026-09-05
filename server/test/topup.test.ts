import { randomUUID } from "node:crypto";
import type pg from "pg";
import { describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import { creditBalance } from "../src/credit/balance.js";
import { catalogueOf, fakeCreditStore, TEST_CREDIT_PLANS_WITH_TOP_UP } from "./support/credit.js";
import {
  CreditCatalogueError,
  parseCreditCatalogue,
  type CreditTopUpPack,
} from "../src/credit/catalogue.js";
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
  TopUpOrder,
} from "../src/billing/provider.js";
import { polarProvider, readPolarDelivery, TOPUP_CHARGE_TIMEOUT_MS } from "../src/billing/polar.js";
import type { WithConnection } from "../src/db/connection.js";
import type { ClaimOutcome, KeyStore, StoredResponse } from "../src/idempotency/store.js";
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
const PACK: CreditTopUpPack = {
  credits: 500,
  productId: "test-product-topup",
  maxPerPeriod: 3,
  price: { amount: 500, currency: "usd" },
};

/**
 * A provider that answers whatever it was built with and **counts every call**.
 *
 * The count is the point. Every refusal below asserts it is zero, which is the only way to state
 * "nothing was charged" — an outcome assertion alone passes just as well if the charge is made and
 * its answer discarded.
 */
function scriptedProvider(
  answer: TopUpCharge,
  options: { readonly order?: TopUpOrder } = {},
): BillingProvider & {
  readonly charges: TopUpChargeRequest[];
  readonly finalized: string[];
} {
  const charges: TopUpChargeRequest[] = [];
  const finalized: string[] = [];
  let nextOrder = 0;
  return {
    charges,
    finalized,
    name: "test-provider",
    webhookKey: Buffer.alloc(0),
    read: () => ({ kind: "ignored", eventId: "x", eventType: "y" }),
    checkoutUrlFor: () => "https://checkout.invalid",
    portalUrlFor: async () => ({ kind: "noCustomer" }),
    createTopUpOrder: async (request) => {
      charges.push(request);
      nextOrder += 1;
      return options.order ?? { kind: "created", orderId: `order-${nextOrder}` };
    },
    finalizeTopUpOrder: async (orderId) => {
      finalized.push(orderId);
      return answer;
    },
  };
}

/** A `charged` answer, with the provider naming what it took. */
function charged(orderId: string, amount?: number, currency?: string): TopUpCharge {
  return { kind: "charged", orderId, amount, currency };
}

/** An in-memory `TopUpAttemptStore` that records what it was asked to claim and to settle. */
function recordingAttempts(
  options: {
    readonly full?: boolean;
    /** An order this account already has outstanding — PR #196's F1 recovery path. */
    readonly outstanding?: { topUpId: string; orderId: string };
    /** Make the first `settle` throw, which is the window F1 is about. */
    readonly settleThrowsOnce?: boolean;
  } = {},
): TopUpAttemptStore & {
  readonly claims: Parameters<TopUpAttemptStore["claim"]>[0][];
  readonly settlements: Parameters<TopUpAttemptStore["settle"]>[0][];
  readonly recorded: Parameters<TopUpAttemptStore["recordOrder"]>[0][];
  readonly asked: Parameters<TopUpAttemptStore["outstanding"]>[0][];
} {
  const claims: Parameters<TopUpAttemptStore["claim"]>[0][] = [];
  const settlements: Parameters<TopUpAttemptStore["settle"]>[0][] = [];
  const recorded: Parameters<TopUpAttemptStore["recordOrder"]>[0][] = [];
  const asked: Parameters<TopUpAttemptStore["outstanding"]>[0][] = [];
  let settleThrowsLeft = options.settleThrowsOnce === true ? 1 : 0;
  return {
    claims,
    settlements,
    recorded,
    asked,
    claim: async (input): Promise<TopUpAttempt | undefined> => {
      claims.push(input);
      // `undefined` is what a full period answers, which is the only thing a fake can honestly model
      // about the bound — the atomicity is `topup.db.test.ts`'s.
      return options.full === true ? undefined : { topUpId: "topup-1" };
    },
    recordOrder: async (input) => {
      recorded.push(input);
    },
    outstanding: async (input) => {
      asked.push(input);
      return options.outstanding;
    },
    settle: async (input) => {
      if (settleThrowsLeft > 0) {
        settleThrowsLeft -= 1;
        // The shape PR #196's F1 measured: a pool blip, a failover, a statement timeout — anything
        // that makes the write after the charge fail.
        throw new Error("connection terminated unexpectedly");
      }
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

describe("a pack that cannot buy a run is a deployment that will not start (PR #196's F4)", () => {
  /** The catalogue document, with the top-up block a test wants to try. */
  const withPack = (topUp: Record<string, unknown>) =>
    JSON.stringify({
      runCredits: 10,
      defaultPlan: "a",
      weights: { perSession: 0, perIteration: 1, perMegapixel: 0 },
      plans: [{ key: "a", monthlyCredits: 1000 }],
      topUp,
    });

  it("refuses a pack worth less than one run, naming what every purchase would be", () => {
    // **The charge that provably cannot help.** The gate triggers on being unable to afford a run,
    // buys, is still unable to afford one, and refuses — after the card was charged, once per
    // session start up to `maxPerPeriod`. The refusal in the product is correct and tested
    // (`aPurchaseThatDoesNotClearTheDebtStillRefuses`); what was missing was anything stopping the
    // charge, and `catalogue.ts`'s standing answer to an unsafe configuration is a startup failure.
    const raw = withPack({
      credits: 9,
      productId: "p",
      maxPerPeriod: 3,
      price: { amount: 500, currency: "usd" },
    });

    expect(() => parseCreditCatalogue(raw)).toThrow(CreditCatalogueError);
    expect(() => parseCreditCatalogue(raw)).toThrow(/could not buy a single run/);
  });

  it("accepts a pack worth exactly one run, which is the boundary", () => {
    // Asserted as a value at the boundary rather than as "some large pack is fine": exactly one run
    // is the smallest pack that can clear the wall it was bought to clear.
    const catalogue = parseCreditCatalogue(
      withPack({ credits: 10, productId: "p", maxPerPeriod: 1, price: { amount: 1, currency: "usd" } }),
    );

    expect(catalogue.topUp?.credits).toBe(10);
  });

  it("refuses a price that is not a whole amount in a real currency", () => {
    // The price reaches a user, so a typo here is a number on a switch that authorises a charge.
    for (const price of [
      { amount: 4.5, currency: "usd" },
      { amount: 500, currency: "dollars" },
      { amount: -1, currency: "usd" },
      // **Zero is refused too** (PR #196's G6): it would render "($0.00)" on a switch that then
      // charges whatever the provider's product really costs.
      { amount: 0, currency: "usd" },
    ]) {
      expect(() =>
        parseCreditCatalogue(withPack({ credits: 100, productId: "p", maxPerPeriod: 1, price })),
      ).toThrow(CreditCatalogueError);
    }
  });

  it("refuses a top-up block with no price at all", () => {
    // **No default, which is this file's standing rule reaching one more number.** A pack with no
    // price would put a switch on screen with nothing to say about what pressing it costs.
    expect(() =>
      parseCreditCatalogue(withPack({ credits: 100, productId: "p", maxPerPeriod: 1 })),
    ).toThrow(CreditCatalogueError);
  });
});

describe("no charge occurs without the explicit opt-in", () => {
  it("refuses an account that never opted in, and calls nobody and claims nothing", async () => {
    // **The ticket's one hard requirement, stated as the three things that did not happen.** The
    // refusal is the least of them: what makes this the guarantee rather than a status code is that
    // the provider was not asked and no row was written, so there is no path by which money moved.
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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

  it("checks the consent before the PACK refusal, which is the hop the first battery left unheld", async () => {
    // **PR #196's F3.** The battery's own S2 claimed to move the consent guard below this refusal
    // and in fact *deleted* it, so it was S1 twice and the first hop was never tested — the
    // reviewer's own mutant, moving the guard below `pack === undefined`, survived the whole suite.
    // An account that is both un-consented and on a deployment that sells nothing answers
    // `not_opted_in` only if the consent is asked first.
    const provider = scriptedProvider(charged("order-1"));
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts, { pack: undefined }), {
      accountId: ACCOUNT,
      balance: exhausted(),
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    // **The order id is written down before the charge** (PR #196's F1), and it is the same id the
    // finalize is then addressed to.
    expect(attempts.recorded).toEqual([{ topUpId: "topup-1", providerOrderId: "order-1" }]);
    expect(provider.finalized).toEqual(["order-1"]);
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome: "granted",
        credits: 500,
        providerOrderId: "order-1",
        // Nothing was said about the amount, so the configured price is what is recorded.
        chargedAmount: 500,
        chargedCurrency: "usd",
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
    ["no_customer" as const, { kind: "noCustomer" } as TopUpOrder],
    ["unavailable" as const, { kind: "unavailable", reason: "down" } as TopUpOrder],
    ["timed_out" as const, { kind: "timedOut", reason: "slow" } as TopUpOrder],
    ["rejected" as const, { kind: "rejected", reason: "bad token" } as TopUpOrder],
  ])("closes the row and charges nothing when the ORDER could not be created (%s)", async (refusal, order) => {
    // **The half of the pair that cannot have moved money** (PR #196's F1): a draft that was never
    // created leaves nothing at the provider, so the row is closed rather than left resolvable —
    // there is no object for a later attempt to ask about — and it carries no order id.
    const provider = scriptedProvider(charged("unused"), { order });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal });
    // Nothing was finalized, which is what "charges nothing" means here.
    expect(provider.finalized).toEqual([]);
    expect(attempts.recorded).toEqual([]);
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome: "provider_error",
        credits: 0,
        providerOrderId: undefined,
        chargedAmount: undefined,
        chargedCurrency: undefined,
        settledAt: AT,
      },
    ]);
  });

  it("closes the row on a decline, because a decline says what happened to the money", async () => {
    // **Every arm asserts `credits: 0`**, which is the property `credit_topup`'s own CHECK enforces
    // in both directions: a row that granted nothing may not read `granted`, and a granted row may
    // not grant nothing. A mapping that credited a decline would be free product on a failed charge.
    const provider = scriptedProvider({ kind: "declined", reason: "provider answered 402" });
    const attempts = recordingAttempts();
    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "declined" });
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome: "declined",
        credits: 0,
        // The order id stays on the row — the order exists and was not paid — but the row is closed,
        // so no later attempt resolves it.
        providerOrderId: "order-1",
        chargedAmount: undefined,
        chargedCurrency: undefined,
        settledAt: AT,
      },
    ]);
  });

  it.each([
    ["unavailable" as const, { kind: "unavailable", reason: "down" } as TopUpCharge],
    ["rejected" as const, { kind: "rejected", reason: "revoked" } as TopUpCharge],
    ["unconfirmed" as const, { kind: "unconfirmed", reason: "finalize did not answer" } as TopUpCharge],
  ])("leaves the row RESOLVABLE when the charge's answer is not one about the money (%s)", async (refusal, answer) => {
    // **The recovery's other half** (PR #196's F1). None of these says what happened to the money,
    // so every one settles `unconfirmed` **with the order id** — which is what the next attempt
    // finds instead of buying a second pack. A `429` charged nothing and is recorded this way
    // anyway: over-recording costs one question to the provider, and under-recording costs a charge
    // nobody ever finds.
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
        outcome: "unconfirmed",
        credits: 0,
        providerOrderId: "order-1",
        chargedAmount: undefined,
        chargedCurrency: undefined,
        settledAt: AT,
      },
    ]);
  });

  it("records what the provider says it took, over the price a deployment configured", async () => {
    // SONNY-215's F6: the record the product shows is about money that moved, so the provider's own
    // figure wins over a number a deployment wrote down — the two can disagree and only one of them
    // was charged.
    const provider = scriptedProvider(charged("order-1", 700, "eur"));
    const attempts = recordingAttempts();
    await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(attempts.settlements[0]).toMatchObject({ chargedAmount: 700, chargedCurrency: "eur" });
  });
});

describe("a charge whose record is lost is resolved, not paid for twice (PR #196's F1)", () => {
  it("writes the order id down before anything can charge it", async () => {
    // The ordering the whole recovery rests on, asserted as a *sequence* rather than as two facts:
    // the id is recorded, and only then is the order finalized.
    const provider = scriptedProvider(charged("order-1"));
    const attempts = recordingAttempts();
    await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(attempts.recorded).toEqual([{ topUpId: "topup-1", providerOrderId: "order-1" }]);
    expect(provider.finalized).toEqual(["order-1"]);
  });

  it("answers unconfirmed rather than throwing when the grant cannot be written", async () => {
    // **The window itself.** Before the fix this threw out of the route as a `500 server.error`,
    // which `idempotency/hook.ts`'s `RELEASE_ON_CODES` releases — so even a same-key repeat re-ran
    // and bought a second pack. A typed refusal is stored instead, and it is the not-retryable one.
    const provider = scriptedProvider(charged("order-1"));
    const attempts = recordingAttempts({ settleThrowsOnce: true });

    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "unconfirmed" });
    // One charge, and the order id is on the row the settle failed to close — which is what the
    // next attempt finds.
    expect(provider.charges).toHaveLength(1);
    expect(attempts.recorded).toEqual([{ topUpId: "topup-1", providerOrderId: "order-1" }]);
  });

  it("resolves an outstanding order instead of buying another, and grants what was already paid", async () => {
    // **The measurement that made F1 a finding, inverted.** The reviewer drove the shipped code with
    // a throwing settle and got *two paid orders and zero granted rows*; this drives the same second
    // attempt and asserts the two things that were wrong: no new order is created, and the account
    // is granted the pack it already paid for.
    const provider = scriptedProvider(charged("order-1", 500, "usd"));
    const attempts = recordingAttempts({ outstanding: { topUpId: "topup-1", orderId: "order-1" } });

    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "granted", credits: 500 });
    // **The order is looked for under the provider that created it** (PR #196's G4). An order made
    // at one provider must not be finalized against another's API, and `finalizeTopUpOrder` takes an
    // id and nothing else — so the scoping has to happen here or nowhere.
    expect(attempts.asked).toEqual([
      { accountId: ACCOUNT, provider: "test-provider", periodStart: exhausted().periodStart },
    ]);
    // **Nothing was created and no slot was claimed** — this attempt *is* the resolution of the
    // first one, not a second purchase.
    expect(provider.charges).toEqual([]);
    expect(attempts.claims).toEqual([]);
    expect(provider.finalized).toEqual(["order-1"]);
    expect(attempts.settlements).toEqual([
      {
        topUpId: "topup-1",
        outcome: "granted",
        credits: 500,
        providerOrderId: "order-1",
        chargedAmount: 500,
        chargedCurrency: "usd",
        settledAt: AT,
      },
    ]);
  });

  it("resolves before it claims, so a full period does not stop a paid order being granted", async () => {
    // The ordering matters in this direction too: an account whose attempts are spent has, by
    // construction, already paid for the outstanding order — refusing it `limit_reached` would keep
    // the money and withhold the credit.
    const provider = scriptedProvider(charged("order-1"));
    const attempts = recordingAttempts({
      full: true,
      outstanding: { topUpId: "topup-1", orderId: "order-1" },
    });

    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: AT,
      now: AT,
    });

    expect(result).toEqual({ kind: "granted", credits: 500 });
  });

  it("still refuses an outstanding order for an account that never opted in", async () => {
    // The consent is checked before the resolve, like everything else. An account that withdrew
    // consent between the charge and its resolution is not charged again — nothing here charges —
    // but neither is it quietly granted through a path the guard does not cover.
    const provider = scriptedProvider(charged("order-1"));
    const attempts = recordingAttempts({ outstanding: { topUpId: "topup-1", orderId: "order-1" } });

    const result = await attemptTopUp(depsFor(provider, attempts), {
      accountId: ACCOUNT,
      balance: exhausted(),
      consentedAt: null,
      now: AT,
    });

    expect(result).toEqual({ kind: "refused", refusal: "not_opted_in" });
    expect(provider.finalized).toEqual([]);
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

/**
 * A `KeyStore` that really models §9.2 — claim, replay, conflict, complete and release (PR #196's
 * F5).
 *
 * **`alwaysClaims` above cannot see the one thing that matters on this route.** It grants every
 * claim and remembers nothing, so a repeat is a fresh request, and `routes/credits.ts` and the
 * contract both promise the opposite: that a retry "replays the stored answer rather than buying a
 * second pack". That promise is true for the codes the hook stores and **false** for the codes it
 * releases, which is the seam PR #196's F1 travelled through, and no test in this suite could tell
 * the two apart.
 *
 * `idempotency.db.test.ts` proves the SQL underneath; this is the smallest faithful model of the
 * decisions the route depends on, and it is deliberately not a second model of the *storage*.
 */
function realisticKeys(): KeyStore & { readonly stored: Map<string, StoredResponse> } {
  const stored = new Map<string, StoredResponse>();
  const inFlight = new Map<string, { token: string; fingerprint: string }>();
  const fingerprints = new Map<string, string>();
  const id = (scope: string, key: string) => `${scope}\u0000${key}`;
  return {
    stored,
    claim: async (request): Promise<ClaimOutcome> => {
      const at = id(request.accountScope, request.key);
      const known = fingerprints.get(at);
      // §9.2 bullet 3: the same key with a different body is a client bug a retry cannot fix.
      if (known !== undefined && known !== request.fingerprint) return { kind: "conflict" };
      const response = stored.get(at);
      if (response !== undefined) return { kind: "replay", response };
      if (inFlight.has(at)) return { kind: "in_flight", retryAfterSeconds: 1 };
      const token = randomUUID();
      fingerprints.set(at, request.fingerprint);
      inFlight.set(at, { token, fingerprint: request.fingerprint });
      return { kind: "claimed", token };
    },
    complete: async (request, response) => {
      const at = id(request.accountScope, request.key);
      if (inFlight.get(at)?.token !== request.token) return;
      inFlight.delete(at);
      stored.set(at, {
        status: response.status,
        body: response.body,
        contentType: response.contentType,
        requestId: response.requestId,
      });
    },
    release: async (request) => {
      const at = id(request.accountScope, request.key);
      if (inFlight.get(at)?.token !== request.token) return;
      inFlight.delete(at);
      // **The release forgets the fingerprint too**, which is what makes a released key reusable —
      // the behaviour that let PR #196's F1 charge twice on one key.
      fingerprints.delete(at);
    },
  };
}

const AUTH = { authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}` };

function buildTopUpApp(input: {
  readonly store: ReturnType<typeof fakeCreditStore>;
  readonly provider?: ReturnType<typeof scriptedProvider>;
  readonly attempts?: ReturnType<typeof recordingAttempts>;
  readonly customer?: string | undefined;
  readonly plans?: string;
  /** A `KeyStore` that really models §9.2, for the two tests that are about §9.2 (PR #196's F5). */
  readonly keys?: KeyStore;
}) {
  const provider = input.provider ?? scriptedProvider(charged("order-1"));
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
      idempotencyStore: input.keys ?? alwaysClaims,
      topUpAttemptStore: input.attempts ?? recordingAttempts(),
      billingStore: {
        apply: async () => ({ outcome: "ignored", accountId: undefined }),
        hasLiveSubscription: async () => false,
        hasSubscriptionRecord: async () => false,
        billingCustomerFor: async () => ("customer" in input ? input.customer : CUSTOMER),
        // Nothing on the top-up path reads this (SONNY-380). Present because `BillingStore` requires
        // it, and answering `"current"` is what an account with no recorded failure answers.
        paymentState: async () => "current",
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
      // **The price the switch says out loud** (SONNY-215's F6, founder decision option B).
      price: { amount: 500, currency: "usd" },
    });
    // And no charge has ever happened on this account, so there is no record to show.
    expect(response.json().last_top_up).toBeNull();
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
      // **No price for a thing that cannot be bought.** A number with nothing behind it is worse
      // than none, and the app renders no control here anyway.
      price: null,
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
    const provider = scriptedProvider(charged("order-1"));
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
    const provider = scriptedProvider(charged("order-1"));
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
    expect(body.auto_top_up).toEqual({
      offered: true,
      opted_in: true,
      attempts_left: 2,
      price: { amount: 500, currency: "usd" },
    });
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
    [{ kind: "unavailable", reason: "down" } as TopUpOrder, 502, "provider.unavailable", true],
    [{ kind: "timedOut", reason: "slow" } as TopUpOrder, 504, "provider.timeout", true],
    [{ kind: "rejected", reason: "revoked" } as TopUpOrder, 502, "provider.rejected", false],
  ])("maps a provider fault onto 7.2 rather than inventing a status", async (order, status, code, retryable) => {
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      // The *order* fails, which is the half with no unconfirmed case: these three statuses reach
      // 7.2 unchanged only because nothing was charged.
      provider: scriptedProvider(charged("unused"), { order }),
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

  it("shows what this account was last charged, and nothing when it never has been", async () => {
    // SONNY-215's F6, founder decision option B: a record of the charge, read from `credit_topup`.
    // Outside `auto_top_up` because it is not the setting — it stays true after the switch is turned
    // off — and outside `credits` because it is money in a currency rather than a credit in a pool.
    const charged = new Date("2026-08-14T09:15:00.000Z");
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        lastTopUp: { amount: 500, currency: "usd", at: charged },
      }),
    });
    const response = await app.inject({ method: "GET", url: "/v1/account/credits", headers: AUTH });

    expect(response.json().last_top_up).toEqual({
      amount: 500,
      currency: "usd",
      at: "2026-08-14T09:15:00.000Z",
    });
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

  it("replays a stored refusal rather than charging again on the same key", async () => {
    // **PR #196's F5, and the half the contract's promise is true of.** A declined charge is stored,
    // so a repeat on the same key answers from the store and the provider is not asked twice.
    const provider = scriptedProvider({ kind: "declined", reason: "provider answered 402" });
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      provider,
      keys: realisticKeys(),
    });
    const key = randomUUID();
    const send = () =>
      app.inject({
        method: "POST",
        url: "/v1/account/credits/top-up",
        headers: { ...AUTH, "idempotency-key": key },
      });

    const first = await send();
    const second = await send();

    expect(first.statusCode).toBe(402);
    expect(second.statusCode).toBe(402);
    expect(second.json().error.code).toBe("topup.declined");
    // One charge for two requests, which is the whole of what §9.2 buys on this route.
    expect(provider.finalized).toHaveLength(1);
    await app.close();
  });

  it("does NOT replay a 500, which is the seam the lost-grant defect travelled through", async () => {
    // **The half the promise is false of** (PR #196's F5). `server.error` is in
    // `idempotency/hook.ts`'s `RELEASE_ON_CODES`, so a throw out of this route releases the claim
    // and the same key runs again — which is why F1 could charge twice even without the Mac minting
    // a fresh key per attempt. It is asserted rather than argued so that the contract's sentence and
    // the hook's list cannot drift apart unnoticed.
    //
    // **The route no longer produces a 500 for that case** — a settle failure is a stored
    // `topup.unconfirmed` now — so this drives the one thing that still can: a provider whose
    // `finalizeTopUpOrder` throws outright.
    const throwing = scriptedProvider(charged("order-1"));
    const provider: typeof throwing = {
      ...throwing,
      finalizeTopUpOrder: async () => {
        throw new Error("boom");
      },
    };
    const app = buildTopUpApp({
      store: fakeCreditStore({
        planKey: "test-plan-a",
        draw: drawn,
        autoTopUpOptedInAt: new Date("2026-08-01T00:00:00Z"),
      }),
      provider,
      keys: realisticKeys(),
    });
    const key = randomUUID();
    const send = () =>
      app.inject({
        method: "POST",
        url: "/v1/account/credits/top-up",
        headers: { ...AUTH, "idempotency-key": key },
      });

    const first = await send();
    const second = await send();

    expect(first.statusCode).toBe(500);
    // **Not a replay**: the claim was released, so the second request ran the handler again. The two
    // statuses are what carry that — a replay would return the *stored* response and could not have
    // re-entered the handler at all.
    expect(second.statusCode).toBe(500);
    // **This count is the fixture's shape, not the system's** (PR #196's G6). `recordingAttempts`
    // answers `undefined` to `outstanding` unless a test says otherwise, so the second run creates a
    // second order here; against the real store it would find the first order and resolve it, and
    // the count would be 1. It is kept as evidence that the handler really re-ran — which is the
    // release — and named so that nobody reads it as "a released key buys twice", because since
    // PR #196's F1 it does not.
    expect(provider.charges).toHaveLength(2);
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
    const scripted = scriptedFetch(json(201, { id: "order-1", status: "draft" }));
    const order = await polar(scripted.call).createTopUpOrder(CHARGE);

    expect(order).toEqual({ kind: "created", orderId: "order-1" });
    expect(scripted.calls.map((made) => made.url)).toEqual(["https://api.invalid/v1/orders/"]);
    // The draft names the provider's own customer and the configured product, and nothing else —
    // no amount and no currency, because the product's price at the provider is the price.
    expect(JSON.parse(scripted.calls[0]?.body ?? "{}")).toEqual({
      customer_id: CUSTOMER,
      product_id: "prod_topup",
    });

    const finalizing = scriptedFetch(json(200, { id: "order-1", status: "paid", total_amount: 500, currency: "usd" }));
    const charge = await polar(finalizing.call).finalizeTopUpOrder("order-1");

    expect(charge).toEqual({ kind: "charged", orderId: "order-1", amount: 500, currency: "usd" });
    expect(finalizing.calls.map((made) => made.url)).toEqual([
      "https://api.invalid/v1/orders/order-1/finalize",
    ]);
    expect(finalizing.calls[0]?.body).toBe("{}");
  });

  it("has no unconfirmed case at all on the half that creates the order", async () => {
    // **The whole reason the seam is two methods** (PR #196's F1): a draft charges nothing, so
    // however this call ends there is no money to be unsure about — and the caller has a moment in
    // which the order id exists and nothing has been charged.
    const scripted = scriptedFetch(json(503, { detail: "down" }));
    const order = await polar(scripted.call).createTopUpOrder(CHARGE);

    expect(order).toEqual({ kind: "unavailable", reason: "provider answered 503" });
    expect(scripted.calls).toHaveLength(1);
  });

  it("reads a 404 with the provider's own body as a missing customer and anything else as a fault", async () => {
    // The portal's rule, for its reason: a wrong origin or a dropped path prefix is answered by a
    // proxy with HTML, and mapping that to "no customer" would tell a paying subscriber they have no
    // payment method when the deployment is misconfigured.
    const provider = polar(scriptedFetch(json(404, { detail: "no such customer" })).call);
    expect(await provider.createTopUpOrder(CHARGE)).toEqual({ kind: "noCustomer" });

    const html = new Response("<html>404</html>", { status: 404 });
    const other = polar(scriptedFetch(html).call);
    expect(await other.createTopUpOrder(CHARGE)).toEqual({
      kind: "rejected",
      reason: "provider answered 404",
    });
  });

  it("rejects a draft that answers 200 naming no order, because there is nothing to finalize", async () => {
    const scripted = scriptedFetch(json(201, { status: "draft" }));
    expect(await polar(scripted.call).createTopUpOrder(CHARGE)).toEqual({
      kind: "rejected",
      reason: "provider created an order naming no id",
    });
    expect(scripted.calls).toHaveLength(1);
  });

  it("calls a 402 a decline rather than an outage, because a retry fails identically", async () => {
    const scripted = scriptedFetch(json(402, { detail: "card_declined" }));
    expect(await polar(scripted.call).finalizeTopUpOrder("order-2")).toEqual({
      kind: "declined",
      reason: "provider answered 402",
    });
  });

  it("asks about an order that is no longer a draft, and answers charged when it is paid", async () => {
    // **The recovery, and the reason a second finalize is a question rather than a second charge**
    // (PR #196's F1). A grant lost between the charge and the record leaves the order paid; the
    // account's next attempt finalizes the same order, Polar refuses with 412 because it is not a
    // draft, and reading it back is what turns that into the credit the user already paid for.
    const scripted = scriptedFetch(
      json(412, { detail: "not a draft" }),
      json(200, { id: "order-3", status: "paid", total_amount: 500, currency: "usd" }),
    );
    expect(await polar(scripted.call).finalizeTopUpOrder("order-3")).toEqual({
      kind: "charged",
      orderId: "order-3",
      amount: 500,
      currency: "usd",
    });
    expect(scripted.calls.map((made) => made.url)).toEqual([
      "https://api.invalid/v1/orders/order-3/finalize",
      "https://api.invalid/v1/orders/order-3",
    ]);
  });

  it("keeps an order that is no longer a draft and is not paid resolvable rather than closing it", async () => {
    // The other direction of the same read: an order in some third state is not a charge this
    // gateway can grant, and it is not one it can close either — `unconfirmed` leaves the account's
    // next attempt free to ask again.
    const scripted = scriptedFetch(
      json(412, { detail: "not a draft" }),
      json(200, { id: "order-4", status: "refunded" }),
    );
    expect(await polar(scripted.call).finalizeTopUpOrder("order-4")).toEqual({
      kind: "unconfirmed",
      reason: 'the order said status "refunded"',
    });
  });

  it("stays unconfirmed when the order will not read back at all", async () => {
    const scripted = scriptedFetch(json(412, { detail: "not a draft" }), json(500, {}));
    expect(await polar(scripted.call).finalizeTopUpOrder("order-5")).toEqual({
      kind: "unconfirmed",
      reason: "order was no longer a draft and read back 500",
    });
  });

  it("splits the two 5xx cases by whether money could have moved, which is the whole axis", async () => {
    // The same status on the two calls means two different things: nothing was charged on the draft,
    // and a charge may have failed after taking the money on the finalize.
    const onDraft = scriptedFetch(json(500, { detail: "boom" }));
    expect(await polar(onDraft.call).createTopUpOrder(CHARGE)).toMatchObject({ kind: "unavailable" });

    const onFinalize = scriptedFetch(json(500, { detail: "boom" }));
    expect(await polar(onFinalize.call).finalizeTopUpOrder("order-6")).toEqual({
      kind: "unconfirmed",
      reason: "provider answered 500",
    });
  });

  it("refuses to read a 200 that does not say paid as a success", async () => {
    // Interpreting an unexpected status generously is how credit gets granted for a charge that
    // never happened.
    const scripted = scriptedFetch(json(200, { id: "order-7", status: "pending" }));
    expect(await polar(scripted.call).finalizeTopUpOrder("order-7")).toEqual({
      kind: "unconfirmed",
      reason: 'finalize said status "pending"',
    });
  });

  it("refuses a 200 that says nothing at all, which is not the same shape as a wrong status", async () => {
    // **The gap the first battery found (S9), and it is the more dangerous half of the same
    // check.** The test above sends a status this gateway does not recognise; these send *no*
    // status — a body with the field missing, and a body that is not JSON. Both leave `status`
    // undefined, and a mutant that let `undefined` through was killed by nothing: an unreadable
    // answer would have granted a pack, which is the one direction `TopUpCharge`'s whole
    // classification exists to refuse.
    for (const body of [json(200, { id: "order-8" }), new Response("not json", { status: 200 })]) {
      const scripted = scriptedFetch(body);
      expect(await polar(scripted.call).finalizeTopUpOrder("order-8")).toEqual({
        kind: "unconfirmed",
        reason: "finalize said status null",
      });
    }
  });

  it("takes the amount the provider names under either field, and neither is required", async () => {
    // SONNY-215's F6. `accountIdFrom`'s own rule applied to a number: the payload has carried it
    // under both names across API versions, and both being absent is not a failure — the caller
    // falls back to the configured price, which is what the product had shown anyway.
    const under = scriptedFetch(json(200, { status: "paid", amount: 700, currency: "eur" }));
    expect(await polar(under.call).finalizeTopUpOrder("order-9")).toMatchObject({
      amount: 700,
      currency: "eur",
    });

    const silent = scriptedFetch(json(200, { status: "paid" }));
    expect(await polar(silent.call).finalizeTopUpOrder("order-9")).toEqual({
      kind: "charged",
      orderId: "order-9",
      amount: undefined,
      currency: undefined,
    });
  });

  it("never puts the access token in a reason", async () => {
    // Every `reason` this adapter produces is built from a status or an error name. The token is on
    // a header and the refusals are what a log line carries, so this is the assertion that keeps the
    // two apart.
    const answers: unknown[] = [];
    for (const response of [json(500, {}), json(404, { detail: "x" }), json(403, {})]) {
      answers.push(await polar(scriptedFetch(response).call).createTopUpOrder(CHARGE));
    }
    for (const response of [json(500, {}), json(403, {}), json(402, {})]) {
      answers.push(await polar(scriptedFetch(response).call).finalizeTopUpOrder("order-1"));
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
