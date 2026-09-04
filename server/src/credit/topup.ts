import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import type { BillingProvider, TopUpOrder } from "../billing/provider.js";
import type { CreditTopUpPack } from "./catalogue.js";
import type { CreditBalance } from "./balance.js";

/**
 * Buying more screen-control runs when the allowance runs out — **and only if the user asked**
 * (SONNY-215).
 *
 * Spec §16.4 names auto top-up as the mechanism that serves its own mid-task-lapse principle: a user
 * running low tops up rather than hitting a wall. SONNY-17 fixed its shape on 2026-08-16 — opt-in,
 * off by default — and this file is where that becomes a sequence of refusals a charge has to get
 * past.
 *
 * ## The hard requirement, and where it is actually held
 *
 * *No charge occurs without the explicit opt-in.* Three things hold it, and they are deliberately
 * not three copies of one check:
 *
 * 1. **Here.** `attempt` refuses on `consentedAt === null` **before it reads anything else** —
 *    before the balance, before the customer, before any row is written and long before the
 *    provider is named. Ordering it first is not cosmetic: it means no later condition can
 *    short-circuit past it, and a reader checking this property has one line to read.
 * 2. **In the schema.** `sonny.credit_topup.consented_at` is `NOT NULL`, so a charge with no consent
 *    behind it has nowhere to be recorded — and this file writes the row *before* it calls the
 *    provider, so an unrecordable charge is an unmade one.
 * 3. **In the absence of a default.** `CREDIT_PLANS.topUp` has no default in this repository, so a
 *    deployment that configured no pack cannot charge anybody at all, and the app does not render
 *    the control.
 *
 * The client knows the setting too and does not ask when it is off. **That is an optimisation and
 * never the enforcement** — the same relationship the checkout route's `hasLiveSubscription` guard
 * has with the entitlement-side refusal behind it. A modified client that asks anyway is refused
 * here.
 *
 * ## What "low" means, since the ticket says low and the gate says exhausted
 *
 * `runsLeft > 0` is the refusal: an account that can still afford a whole run is not topped up. That
 * is the weaker of the gate's two exhaustion conditions and therefore covers both of its moments —
 * `SonnyScreenControlGate` refuses a *new* session on `runsLeft <= 0` and halts a *running* one on
 * `creditsRemaining <= 0`, and the second implies the first. So every moment the gate would
 * otherwise block is a moment this route will consider, and no moment it would not block is.
 *
 * **It also means a client cannot buy credit it does not need.** The condition is recomputed here
 * from the account's own metering rows rather than taken from the request, so "I am low" is not
 * something a caller gets to assert.
 */

/** Why no top-up happened. Each case is a different status and a different thing to do about it. */
export type TopUpRefusal =
  /** This deployment sells no top-up pack, or takes no payments at all. */
  | "not_offered"
  /** **The account has not opted in.** The one refusal this whole mechanism exists to guarantee. */
  | "not_opted_in"
  /** The account can still afford a run. Nothing to buy. */
  | "not_needed"
  /** This period's attempts are used up. See 0019 for why the bound counts attempts, not grants. */
  | "limit_reached"
  /** Nothing at the provider to charge: no customer, or none this gateway ever recorded. */
  | "no_customer"
  /** The provider answered and did not charge. The user's payment method is what fixes it. */
  | "declined"
  /** The provider could not be reached or throttled us. Worth retrying. */
  | "unavailable"
  /** The provider did not answer inside this gateway's budget. Worth retrying. */
  | "timed_out"
  /** The provider refused this gateway. An operator's to fix; a retry fails identically. */
  | "rejected"
  /** The charge was attempted and its answer could not be read. Nothing is granted. */
  | "unconfirmed";

export type TopUpResult =
  | { readonly kind: "granted"; readonly credits: number }
  | { readonly kind: "refused"; readonly refusal: TopUpRefusal };

/** What `sonny.credit_topup` records about how one attempt ended. 0019 carries the vocabulary. */
export type TopUpAttemptOutcome = "granted" | "declined" | "provider_error" | "unconfirmed";

/** A claimed slot: the row that exists before the provider has been called. */
export interface TopUpAttempt {
  readonly topUpId: string;
}

/**
 * An order this gateway created at the provider and has not resolved (PR #196's F1).
 *
 * **Both fields, and the id is why this type exists.** A row without an order id is one that never
 * reached the provider's charge and needs no resolving; a row with one names an object whose state
 * only the provider knows.
 */
export interface OutstandingTopUp {
  readonly topUpId: string;
  readonly orderId: string;
}

/**
 * The write half, as the request path uses it.
 *
 * A seam of the same shape and for the same reason as `CreditStore` and `BillingStore`: the flagged
 * `npm test` runs with no database, so without it every refusal above would be verified only under
 * `npm run test:db`. What it does **not** stand in for is the bound itself — `topup.db.test.ts`
 * proves `attempt_no`'s uniqueness against a real Postgres, because a fake that appears to refuse a
 * concurrent second attempt is how a suite comes to believe a cap is enforced.
 */
export interface TopUpAttemptStore {
  /**
   * Claim this period's next attempt slot, or answer `undefined` when the period is full.
   *
   * **Written before the provider is called**, which is what makes `maxPerPeriod` a bound rather
   * than a hope: a crash between here and `settle` leaves a row reading `attempted`, and that row
   * keeps its slot.
   */
  readonly claim: (input: {
    readonly accountId: string;
    readonly provider: string;
    readonly periodStart: Date;
    readonly consentedAt: Date;
    readonly runsLeftAtTrigger: number;
    readonly creditsRemainingAtTrigger: number;
    readonly maxPerPeriod: number;
  }) => Promise<TopUpAttempt | undefined>;
  /**
   * Write the provider's order id onto a claimed row — **before anything charges it** (PR #196's F1).
   *
   * Its own method rather than a field on `settle`, because the two happen at different moments and
   * the whole point is the gap between them: this runs while the order is a draft that has cost
   * nobody anything, and `settle` runs after the only call that can take money.
   */
  readonly recordOrder: (input: {
    readonly topUpId: string;
    readonly providerOrderId: string;
  }) => Promise<void>;
  /**
   * The one order this account has outstanding for this period, if any (PR #196's F1).
   *
   * **A row is outstanding when it names an order and has not been closed** — `attempted`, which is
   * a process that died between the record and the answer, or `unconfirmed`, which is an answer this
   * gateway could not read. Both mean the same thing operationally: an object exists at the provider
   * and only the provider knows what happened to it.
   *
   * `granted`, `declined` and `provider_error` are closed: the first two say what happened to the
   * money and the third says no order was ever created.
   */
  readonly outstanding: (input: {
    readonly accountId: string;
    /**
     * **Scoped to the provider that created the order** (PR #196's G4). `finalizeTopUpOrder` takes
     * an id and nothing else, so an order created at one provider would otherwise be finalized
     * against another's API on a deployment that changed `BILLING_PROVIDER` mid-period. The column
     * has always been written by `claim`; nothing was reading it.
     */
    readonly provider: string;
    readonly periodStart: Date;
  }) => Promise<OutstandingTopUp | undefined>;
  /** Record how the attempt ended, what it bought, and what it cost. */
  readonly settle: (input: {
    readonly topUpId: string;
    readonly outcome: TopUpAttemptOutcome;
    readonly credits: number;
    readonly providerOrderId: string | undefined;
    /** What the provider took, in the currency's smallest unit. Only ever set on a grant. */
    readonly chargedAmount: number | undefined;
    readonly chargedCurrency: string | undefined;
    readonly settledAt: Date;
  }) => Promise<void>;
}

export interface TopUpDeps {
  /** What one top-up buys, from `CREDIT_PLANS`. `undefined` means this deployment sells none. */
  readonly pack: CreditTopUpPack | undefined;
  readonly provider: BillingProvider;
  /** Where the provider's own customer id for an account is kept. `BillingStore` supplies it. */
  readonly billingCustomerFor: (
    provider: string,
    accountId: string,
  ) => Promise<string | undefined>;
  readonly attempts: TopUpAttemptStore;
}

export interface TopUpInput {
  readonly accountId: string;
  /** Recomputed by the caller from this account's own rows. Never anything a request declared. */
  readonly balance: CreditBalance;
  /** When this account opted in, or `null`. `CreditFacts.autoTopUpOptedInAt` supplies it. */
  readonly consentedAt: Date | null;
  readonly now: Date;
}

/**
 * A create failure → what the row records. **None of these left an order behind**, so every one is
 * terminal and none carries an id.
 *
 * `noCustomer` records as `provider_error` and that is an imprecision rather than a mistake
 * (PR #196's F9): a customer the provider does not have is not an outage, and 0019's outcome set has
 * no better arm for it today. Adding one is a migration and a vocabulary change for a state the
 * route already refuses precisely; it is named here so the table's reader knows the two are merged.
 */
function outcomeForFailedOrder(kind: Exclude<TopUpOrder["kind"], "created">): TopUpAttemptOutcome {
  switch (kind) {
    case "noCustomer":
    case "unavailable":
    case "timedOut":
    case "rejected":
      return "provider_error";
  }
}

/** A create failure → what the caller is told. */
function refusalForFailedOrder(kind: Exclude<TopUpOrder["kind"], "created">): TopUpRefusal {
  switch (kind) {
    case "noCustomer":
      return "no_customer";
    case "unavailable":
      return "unavailable";
    case "timedOut":
      return "timed_out";
    case "rejected":
      return "rejected";
  }
}

/**
 * Charge an order this gateway has already written down, and record what happened.
 *
 * **One function for both the fresh order and the resolution of an outstanding one**, because they
 * are the same act: the order exists, its id is on the row, and the only question left is what the
 * provider says about it. A second copy of this for the recovery path is how the two would come to
 * settle the same answer differently.
 *
 * **A non-terminal answer settles `unconfirmed` and keeps the order id**, which is what leaves the
 * row resolvable. Only `charged` and `declined` close a row, because they are the only two answers
 * that say what happened to the money.
 */
async function chargeAndSettle(
  deps: TopUpDeps,
  input: TopUpInput,
  pack: CreditTopUpPack,
  attempt: { readonly topUpId: string; readonly orderId: string },
): Promise<TopUpResult> {
  /**
   * **Every settle after a charge is guarded, and a failed one is `unconfirmed` rather than a throw**
   * (PR #196's F1's cheap half).
   *
   * The row keeps the order id it was given before the charge, so it stays resolvable and the
   * account's next attempt finds it. What the guard adds is what the *caller* is told: a throw here
   * became a `500 server.error`, and `idempotency/hook.ts`'s `RELEASE_ON_CODES` releases that claim
   * — so even a same-key repeat re-ran the whole route. `topup.unconfirmed` is stored instead, and
   * it is marked not retryable for the same reason.
   *
   * A failure is swallowed rather than logged here because this module holds no logger; the route
   * logs every refusal it returns, and `unconfirmed` is the one it names for an operator.
   */
  const settleOrReportUnconfirmed = async (
    row: Parameters<TopUpAttemptStore["settle"]>[0],
    onSettled: TopUpResult,
  ): Promise<TopUpResult> => {
    try {
      await deps.attempts.settle(row);
    } catch {
      return { kind: "refused", refusal: "unconfirmed" };
    }
    return onSettled;
  };

  const charge = await deps.provider.finalizeTopUpOrder(attempt.orderId);
  if (charge.kind === "charged") {
    return await settleOrReportUnconfirmed({
      topUpId: attempt.topUpId,
      outcome: "granted",
      credits: pack.credits,
      providerOrderId: attempt.orderId,
      // **What the provider says it took, and the configured price only when it says nothing.** The
      // record the product shows is about money that moved, so the provider's own figure wins over
      // a number a deployment wrote down — the two can disagree, and only one of them was charged.
      chargedAmount: charge.amount ?? pack.price.amount,
      chargedCurrency: charge.currency ?? pack.price.currency,
      settledAt: input.now,
    }, { kind: "granted", credits: pack.credits });
  }
  if (charge.kind === "declined") {
    return await settleOrReportUnconfirmed({
      topUpId: attempt.topUpId,
      outcome: "declined",
      credits: 0,
      providerOrderId: attempt.orderId,
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: input.now,
    }, { kind: "refused", refusal: "declined" });
  }
  // **Everything else keeps the row resolvable**, including a `429` that certainly charged nothing.
  // Over-recording costs the account's next attempt one question to the provider; under-recording
  // costs a charge nobody ever finds, which is the defect this whole shape exists to close.
  const refusal: TopUpRefusal =
    charge.kind === "unavailable"
      ? "unavailable"
      : charge.kind === "rejected"
        ? "rejected"
        : "unconfirmed";
  return await settleOrReportUnconfirmed({
    topUpId: attempt.topUpId,
    outcome: "unconfirmed",
    credits: 0,
    providerOrderId: attempt.orderId,
    chargedAmount: undefined,
    chargedCurrency: undefined,
    settledAt: input.now,
  }, { kind: "refused", refusal });
}

/**
 * Try to buy one top-up pack for this account, or say why not.
 *
 * The refusals are ordered by what each one costs to establish and by what it protects, and the
 * order is load-bearing rather than incidental — see this file's header for the consent check in
 * particular. Nothing below the consent check can run for an account that has not opted in.
 *
 * **Resolving comes before buying, and that ordering is PR #196's F1.** An order this gateway
 * created and never resolved may already be paid; asking about it is what stops the account's next
 * attempt buying a second pack for a charge it has already made.
 */
export async function attemptTopUp(deps: TopUpDeps, input: TopUpInput): Promise<TopUpResult> {
  // **First, and before anything else is read.** The whole of this ticket's hard requirement.
  if (input.consentedAt === null) return { kind: "refused", refusal: "not_opted_in" };
  const pack = deps.pack;
  if (pack === undefined) return { kind: "refused", refusal: "not_offered" };
  // Recomputed from the account's own rows by the caller. A client does not get to declare that it
  // is low, and a client that can still afford a run is not charged for one it has not spent.
  if (input.balance.runsLeft > 0) return { kind: "refused", refusal: "not_needed" };

  // Before the slot is claimed: an account with nothing to charge can never succeed, and burning one
  // of the period's attempts on it would spend the bound on a refusal that costs nobody anything.
  const customerId = await deps.billingCustomerFor(deps.provider.name, input.accountId);
  if (customerId === undefined) return { kind: "refused", refusal: "no_customer" };

  /**
   * **An order this gateway made and never resolved, if there is one** (PR #196's F1).
   *
   * It consumes no new slot and creates no new order: this attempt *is* the resolution of that one.
   * A paid order answers `charged` and the account is granted what it already paid for; an order
   * still in draft is finalized, which is the ordinary charge arriving late; anything else keeps the
   * row resolvable and refuses.
   *
   * **What this ordering closes is the SEQUENTIAL window, which is F1's, and it closes nothing
   * else** (PR #196's G2, measured by the reviewer rather than reasoned about). An account that
   * comes *back* after a lost record — the user hits the wall again, a later session asks again —
   * finds the outstanding order and buys nothing more. **Two attempts genuinely in flight together
   * are a different case and are bounded by `maxPerPeriod`, not by this**: there is no lock between
   * the read above and the `recordOrder` write below, and the gap contains a provider round trip, so
   * a second attempt starting inside it sees nothing outstanding, claims the next slot and creates
   * its own order. Measured at 400 ms of provider latency with the second attempt 100 ms behind:
   * two orders created, two charged, **both credited** — which is two clients each legitimately
   * asking, not a lost charge, and is what the per-period bound is for.
   *
   * **Closing that would mean holding `outstanding`, `claim` and `recordOrder` in one transaction
   * with `SELECT … FOR UPDATE` over the account's period rows, and the lock would span a provider
   * call.** That is the trade, and it is not taken: the sequential case is the one where money is
   * lost, and the concurrent case costs a bounded number of packs that are all delivered. The
   * sentence here used to promise the stronger property without qualification, which is worse than
   * either — a reader who trusts it stops looking for the lock.
   */
  const outstanding = await deps.attempts.outstanding({
    accountId: input.accountId,
    provider: deps.provider.name,
    periodStart: input.balance.periodStart,
  });
  if (outstanding !== undefined) {
    return await chargeAndSettle(deps, input, pack, outstanding);
  }

  const attempt = await deps.attempts.claim({
    accountId: input.accountId,
    provider: deps.provider.name,
    periodStart: input.balance.periodStart,
    consentedAt: input.consentedAt,
    runsLeftAtTrigger: input.balance.runsLeft,
    creditsRemainingAtTrigger: input.balance.credits.remaining,
    maxPerPeriod: pack.maxPerPeriod,
  });
  if (attempt === undefined) return { kind: "refused", refusal: "limit_reached" };

  const order = await deps.provider.createTopUpOrder({ customerId, productId: pack.productId });
  if (order.kind !== "created") {
    // Nothing exists at the provider, so this row is closed rather than left resolvable — there is
    // no object for a later attempt to ask about.
    await deps.attempts.settle({
      topUpId: attempt.topUpId,
      outcome: outcomeForFailedOrder(order.kind),
      credits: 0,
      providerOrderId: undefined,
      chargedAmount: undefined,
      chargedCurrency: undefined,
      settledAt: input.now,
    });
    return { kind: "refused", refusal: refusalForFailedOrder(order.kind) };
  }

  // **The order id goes down before anything can charge, and before anything else can throw.** This
  // one line is the whole of PR #196's F1: with it, every state this account can be left in names an
  // object at the provider and the resolve above finds it. Without it — and there was no way to
  // write it while the two provider calls sat inside one seam method — a grant lost after the charge
  // left a row 0019 documents as the harmless case and a user who had paid for nothing.
  await deps.attempts.recordOrder({ topUpId: attempt.topUpId, providerOrderId: order.orderId });

  return await chargeAndSettle(deps, input, pack, {
    topUpId: attempt.topUpId,
    orderId: order.orderId,
  });
}

/** Postgres' unique-violation code. A concurrent claim losing the race on `attempt_no`. */
const UNIQUE_VIOLATION = "23505";

export async function claimTopUpAttempt(
  client: pg.Client,
  input: Parameters<TopUpAttemptStore["claim"]>[0],
): Promise<TopUpAttempt | undefined> {
  try {
    // **One statement, and `HAVING` is what makes the bound part of it.** The aggregate runs over
    // this account's rows for this period, so `count(*) < $7` refuses to produce a row at all once
    // the period is full — and `max(attempt_no) + 1` is what two concurrent claims collide on,
    // which a `count` check alone cannot prevent under READ COMMITTED.
    const { rows } = await client.query<{ topup_id: string }>(
      `INSERT INTO sonny.credit_topup
              (account_id, provider, period_start, attempt_no, outcome, credits, consented_at,
               runs_left_at_trigger, credits_remaining_at_trigger)
       SELECT $1, $2, $3, coalesce(max(attempt_no), 0) + 1, 'attempted', 0, $4, $5, $6
         FROM sonny.credit_topup
        WHERE account_id = $1 AND period_start = $3
       HAVING count(*) < $7
    RETURNING topup_id`,
      [
        input.accountId,
        input.provider,
        input.periodStart,
        input.consentedAt,
        input.runsLeftAtTrigger,
        input.creditsRemainingAtTrigger,
        input.maxPerPeriod,
      ],
    );
    const row = rows[0];
    return row === undefined ? undefined : { topUpId: row.topup_id };
  } catch (error) {
    // The loser of a concurrent claim. Answered as a full period rather than as a fault: from the
    // caller's side the two are the same fact — another attempt already holds this slot — and the
    // honest reading of a race this narrow is that one of the two is the period's Nth attempt.
    if ((error as { code?: unknown }).code === UNIQUE_VIOLATION) return undefined;
    throw error;
  }
}

/**
 * Write the order id onto a claimed row (PR #196's F1).
 *
 * **`provider_order_id IS NULL` in the `WHERE`, so this can only ever fill an empty column.** An
 * order id is written once and never replaced: overwriting one would be losing the object a
 * resolution is about, which is the whole thing this column exists to keep.
 */
export async function recordTopUpOrder(
  client: pg.Client,
  input: Parameters<TopUpAttemptStore["recordOrder"]>[0],
): Promise<void> {
  const { rowCount } = await client.query(
    `UPDATE sonny.credit_topup
        SET provider_order_id = $2
      WHERE topup_id = $1 AND provider_order_id IS NULL`,
    [input.topUpId, input.providerOrderId],
  );
  // **The line above is called the whole of F1, so it checks that it happened** (PR #196's G3). A
  // statement that matched nothing leaves the row with no order id and the caller charges anyway,
  // which is precisely the state F1 was — and `await client.query(…)` on its own cannot tell the two
  // apart. Reachability is very low, since the row was created microseconds earlier by this same
  // request; what the throw buys is that the guarantee is structural rather than probable. Throwing
  // is also the fail-safe direction: nothing has been charged yet, so the attempt ends with an
  // unpaid draft at the provider and a row that correctly names no order.
  if (rowCount !== 1) {
    throw new Error(
      `credit_topup ${input.topUpId} did not take its provider order id (matched ${rowCount} rows)`,
    );
  }
}

/**
 * The one unresolved order this account has for this period (PR #196's F1).
 *
 * **Oldest first, so a resolution takes the earliest unresolved order** rather than whichever the
 * planner happened to return. In practice there is at most one — `attemptTopUp` resolves before it
 * claims, so a second cannot be created while a first is outstanding — and the ordering is what
 * makes that true of the past as well as of the future, for rows a run of this code before the fix
 * could have left behind.
 */
export async function readOutstandingTopUp(
  client: pg.Client,
  input: Parameters<TopUpAttemptStore["outstanding"]>[0],
): Promise<OutstandingTopUp | undefined> {
  const { rows } = await client.query<{ topup_id: string; provider_order_id: string }>(
    `SELECT topup_id, provider_order_id
       FROM sonny.credit_topup
      WHERE account_id = $1
        AND provider = $3
        AND period_start = $2
        AND provider_order_id IS NOT NULL
        AND outcome IN ('attempted', 'unconfirmed')
      ORDER BY attempt_no
      LIMIT 1`,
    [input.accountId, input.periodStart, input.provider],
  );
  const row = rows[0];
  return row === undefined
    ? undefined
    : { topUpId: row.topup_id, orderId: row.provider_order_id };
}

export async function settleTopUpAttempt(
  client: pg.Client,
  input: Parameters<TopUpAttemptStore["settle"]>[0],
): Promise<void> {
  await client.query(
    `UPDATE sonny.credit_topup
        SET outcome = $2, credits = $3, provider_order_id = coalesce($4, provider_order_id),
            charged_amount = $6, charged_currency = $7, settled_at = $5
      WHERE topup_id = $1`,
    [
      input.topUpId,
      input.outcome,
      input.credits,
      input.providerOrderId ?? null,
      input.settledAt,
      input.chargedAmount ?? null,
      input.chargedCurrency ?? null,
    ],
  );
}

export function postgresTopUpAttemptStore(withConnection: WithConnection): TopUpAttemptStore {
  return {
    claim: (input) => withConnection((client) => claimTopUpAttempt(client, input)),
    recordOrder: (input) => withConnection((client) => recordTopUpOrder(client, input)),
    outstanding: (input) => withConnection((client) => readOutstandingTopUp(client, input)),
    settle: (input) => withConnection((client) => settleTopUpAttempt(client, input)),
  };
}
