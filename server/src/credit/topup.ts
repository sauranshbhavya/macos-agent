import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import type { BillingProvider } from "../billing/provider.js";
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
  /** Record how the attempt ended, and what it bought. */
  readonly settle: (input: {
    readonly topUpId: string;
    readonly outcome: TopUpAttemptOutcome;
    readonly credits: number;
    readonly providerOrderId: string | undefined;
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

/** Provider answer → what the row records. Success is the only arm that grants anything. */
function outcomeFor(kind: Exclude<string, "charged">): TopUpAttemptOutcome {
  switch (kind) {
    case "declined":
      return "declined";
    case "unconfirmed":
      return "unconfirmed";
    default:
      return "provider_error";
  }
}

/**
 * Try to buy one top-up pack for this account, or say why not.
 *
 * The refusals are ordered by what each one costs to establish and by what it protects, and the
 * order is load-bearing rather than incidental — see this file's header for the consent check in
 * particular. Nothing below the consent check can run for an account that has not opted in.
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

  const charge = await deps.provider.chargeTopUp({ customerId, productId: pack.productId });
  if (charge.kind === "charged") {
    await deps.attempts.settle({
      topUpId: attempt.topUpId,
      outcome: "granted",
      credits: pack.credits,
      providerOrderId: charge.orderId,
      settledAt: input.now,
    });
    return { kind: "granted", credits: pack.credits };
  }
  await deps.attempts.settle({
    topUpId: attempt.topUpId,
    outcome: outcomeFor(charge.kind),
    credits: 0,
    // Only the unconfirmed arm carries one, and it is the arm where it matters most: an operator
    // resolving a charge whose answer was lost needs the order to look at.
    providerOrderId: charge.kind === "unconfirmed" ? charge.orderId : undefined,
    settledAt: input.now,
  });
  switch (charge.kind) {
    case "declined":
      return { kind: "refused", refusal: "declined" };
    case "noCustomer":
      return { kind: "refused", refusal: "no_customer" };
    case "timedOut":
      return { kind: "refused", refusal: "timed_out" };
    case "unavailable":
      return { kind: "refused", refusal: "unavailable" };
    case "rejected":
      return { kind: "refused", refusal: "rejected" };
    case "unconfirmed":
      return { kind: "refused", refusal: "unconfirmed" };
  }
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

export async function settleTopUpAttempt(
  client: pg.Client,
  input: Parameters<TopUpAttemptStore["settle"]>[0],
): Promise<void> {
  await client.query(
    `UPDATE sonny.credit_topup
        SET outcome = $2, credits = $3, provider_order_id = $4, settled_at = $5
      WHERE topup_id = $1`,
    [
      input.topUpId,
      input.outcome,
      input.credits,
      input.providerOrderId ?? null,
      input.settledAt,
    ],
  );
}

export function postgresTopUpAttemptStore(withConnection: WithConnection): TopUpAttemptStore {
  return {
    claim: (input) => withConnection((client) => claimTopUpAttempt(client, input)),
    settle: (input) => withConnection((client) => settleTopUpAttempt(client, input)),
  };
}
