import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import type { SubscriptionEvent, WebhookReading } from "./provider.js";

/**
 * Where a subscription reaches the entitlement (SONNY-211).
 *
 * **The provider is the source of truth for "is this user paid", and this file is the whole of what
 * that sentence means in code**: it does not decide anything, it records what the provider said and
 * derives `sonny.entitlement` from it. What a plan is worth in capabilities is deployment
 * configuration (`BILLING_PLANS`); what it costs is SONNY-212's; which capabilities gate which
 * feature is row 18's. Nothing here.
 *
 * ## Three things a webhook path has to survive, and where each is handled
 *
 * **A replay.** A valid signature stays valid forever, so the signature cannot be the only thing
 * between a captured `active` delivery and a resurrected subscription. `webhook-signature.ts` bounds
 * that to five minutes with the signed timestamp; this file closes it entirely by making the
 * provider's own event id the primary key of `sonny.billing_event`. The insert is the **first**
 * statement in the transaction, so it is a claim rather than a record: a second copy — including one
 * arriving concurrently, which blocks on the speculative-insertion lock and then takes its
 * `DO NOTHING` branch — finds the row taken and changes nothing. The same reasoning
 * `entitlement/store.ts` gives for its insert-then-update pair, in the same shape.
 *
 * **Deliveries out of order.** Webhooks are retried, and a retry of an older event can land after a
 * newer one. `sonny.entitlement.billing_event_at` carries the `occurred_at` of the delivery the
 * current state came from, and the upsert's `WHERE` refuses anything not strictly newer — so a
 * retried `cancelled` cannot revoke a subscription that has since been reactivated. It returns no
 * row when it refuses, which is how `stale` is detected rather than assumed.
 *
 * **A customer this gateway cannot place.** The account id travels to the provider at checkout and
 * comes back on the customer; a payload that carries none is resolved by subscription id, because
 * the first delivery for a subscription recorded it. When neither works the delivery is recorded
 * `unmatched` and nothing is granted — a paying customer with no entitlement is a support ticket,
 * and a guess would be a paid entitlement handed to the wrong account.
 *
 * ## Why the grace window is written here and evaluated in `entitlement/store.ts`
 *
 * Spec §16.4 requires that billing never cuts a user off mid-task, so a failed payment does not take
 * capabilities away when it arrives: it sets a deadline. This file writes that deadline;
 * `claimFactsFor` is what decides, at read time, whether it has passed. A sweeper would have to run
 * before the window closed for anyone to notice it had, and until it ran the signed claim and the
 * per-request capability check would each disagree with the row in front of them.
 */

/** What a delivery did. Every value is stored on `sonny.billing_event` except `duplicate`. */
export type BillingOutcome =
  | "applied"
  | "ignored"
  | "stale"
  | "unmatched"
  | "unmapped"
  | "unreadable"
  /** The event id was already recorded. Nothing was read and nothing was written. */
  | "duplicate";

/**
 * A provider plan key, and what it is worth.
 *
 * **`plan` is not a tier this repository names.** It is whatever `BILLING_PLANS` maps the provider's
 * product to, so a deployment chooses its own key and 0013's "opaque plan key, provisioned from
 * outside this repository" stays true.
 */
export interface BillingPlan {
  readonly plan: string;
  readonly capabilities: readonly string[];
}

/** Provider product id → what it grants. Deployment configuration; see `config.ts`. */
export type BillingPlans = ReadonlyMap<string, BillingPlan>;

export interface BillingApplyInput {
  readonly provider: string;
  readonly reading: WebhookReading;
  readonly plans: BillingPlans;
  /** How long a payment failure's grace window runs, in milliseconds. */
  readonly graceMilliseconds: number;
}

export interface BillingApplyResult {
  readonly outcome: BillingOutcome;
  /** The account the delivery reached, when it reached one. For the log line and nothing else. */
  readonly accountId: string | undefined;
}

/** The state a subscription puts on the entitlement row, before the database sees it. */
interface EntitlementWrite {
  readonly plan: string;
  readonly capabilities: readonly string[];
  readonly revokedAt: Date | null;
  readonly pastDueSince: Date | null;
  readonly graceUntil: Date | null;
}

/**
 * Neutral state → what the entitlement row says.
 *
 * **`past_due` keeps the capabilities**, which is the one line of this function that is a product
 * requirement rather than bookkeeping: §16.4's grace period exists so that a payment failure does
 * not interrupt someone mid-task. The capabilities go when `grace_until` passes, decided at read
 * time by `claimFactsFor`.
 *
 * **`paused` is revoked exactly as `ended` is.** Polar pauses a subscription by stopping billing
 * *and* withdrawing the benefits, so a paused subscriber is not entitled — and treating it as a
 * softer `past_due` would hand out an unpaid grace window on every pause.
 */
function writeFor(
  event: SubscriptionEvent,
  plan: BillingPlan,
  graceMilliseconds: number,
): EntitlementWrite {
  switch (event.state) {
    case "active":
      return {
        plan: plan.plan,
        capabilities: plan.capabilities,
        revokedAt: null,
        pastDueSince: null,
        graceUntil: null,
      };
    case "past_due":
      return {
        plan: plan.plan,
        capabilities: plan.capabilities,
        revokedAt: null,
        pastDueSince: event.occurredAt,
        graceUntil: new Date(event.occurredAt.getTime() + graceMilliseconds),
      };
    case "ended":
    case "paused":
      return {
        plan: plan.plan,
        // Kept on the row rather than emptied. `claimFactsFor` answers no capabilities for a revoked
        // entitlement, so the claim is already right; keeping the list is what lets a resubscription
        // restore without re-deriving it, and what lets an operator see what the account had.
        capabilities: plan.capabilities,
        revokedAt: event.occurredAt,
        pastDueSince: null,
        graceUntil: null,
      };
  }
}

/**
 * The account this delivery is about: the one the provider echoed back, or the one that owns this
 * subscription already.
 *
 * **An account id from the payload is checked against `sonny.account` before it is used**, and that
 * check is not a formality. The value is a string the payment provider hands over, and the provider
 * got it from a URL — so it is caller-influenced, and without this an attacker who can start a
 * checkout could name any account id they like and have a subscription applied to somebody else's.
 * A closed account (`deleted_at`) is refused for the same reason every other path refuses one.
 */
async function accountFor(
  client: pg.Client,
  provider: string,
  event: SubscriptionEvent,
): Promise<string | undefined> {
  if (event.accountId !== undefined) {
    const named = await client.query<{ id: string }>(
      "SELECT id FROM sonny.account WHERE id::text = $1 AND deleted_at IS NULL",
      [event.accountId],
    );
    const row = named.rows[0];
    if (row !== undefined) return row.id;
    // Falls through rather than returning: a payload naming an account this gateway does not have
    // may still be a later delivery for a subscription it does know, and the subscription id is the
    // stronger key of the two — it was recorded by a delivery this gateway already accepted.
  }
  const known = await client.query<{ account_id: string }>(
    `SELECT account_id FROM sonny.entitlement
      WHERE billing_provider = $1 AND billing_subscription_id = $2`,
    [provider, event.subscriptionId],
  );
  return known.rows[0]?.account_id;
}

/**
 * Record one delivery and, if it says anything this gateway acts on, move the entitlement.
 *
 * One transaction, because the record and the state have to agree: a `sonny.billing_event` row
 * saying `applied` beside an entitlement that did not move would be a lie in the one table an
 * operator consults, and an entitlement moved with no row saying why is a change nobody can trace.
 */
export async function applyBillingDelivery(
  client: pg.Client,
  input: BillingApplyInput,
): Promise<BillingApplyResult> {
  const { reading } = input;
  const eventId = reading.kind === "event" ? reading.event.eventId : reading.eventId;
  const eventType =
    reading.kind === "event"
      ? reading.event.eventType
      : reading.kind === "ignored"
        ? reading.eventType
        : "(unreadable)";

  await client.query("BEGIN");
  try {
    // **The claim.** `ON CONFLICT DO NOTHING` returning no row is the replay, and it is decided
    // before anything is read or written. The outcome is provisional and is corrected below; a
    // transaction that fails between here and the correction rolls the whole row back, so a delivery
    // is never recorded as having done something it did not.
    const claimed = await client.query<{ event_id: string }>(
      `INSERT INTO sonny.billing_event (provider, event_id, event_type, outcome, occurred_at)
            VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (provider, event_id) DO NOTHING
         RETURNING event_id`,
      [
        input.provider,
        // An unreadable body still gets a row: the delivery id is a signed header, so it is known
        // whatever the payload turned out to be, and a replayed unreadable delivery is a replay too.
        eventId,
        eventType,
        reading.kind === "event" ? "unmatched" : reading.kind,
        reading.kind === "event" ? reading.event.occurredAt : null,
      ],
    );
    if (claimed.rows.length === 0) {
      await client.query("ROLLBACK");
      return { outcome: "duplicate", accountId: undefined };
    }
    if (reading.kind !== "event") {
      await client.query("COMMIT");
      return { outcome: reading.kind, accountId: undefined };
    }

    const event = reading.event;
    const accountId = await accountFor(client, input.provider, event);
    if (accountId === undefined) {
      await client.query("COMMIT");
      return { outcome: "unmatched", accountId: undefined };
    }

    const plan = input.plans.get(event.planKey);
    if (plan === undefined) {
      await settle(client, input.provider, event.eventId, "unmapped", accountId);
      await client.query("COMMIT");
      return { outcome: "unmapped", accountId };
    }

    const write = writeFor(event, plan, input.graceMilliseconds);
    const moved = await client.query<{ account_id: string }>(
      `INSERT INTO sonny.entitlement (
              account_id, plan, capabilities, revoked_at, past_due_since, grace_until,
              billing_provider, billing_subscription_id, billing_event_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
       ON CONFLICT (account_id) DO UPDATE
              SET plan = EXCLUDED.plan,
                  capabilities = EXCLUDED.capabilities,
                  revoked_at = EXCLUDED.revoked_at,
                  -- Two rules in one expression, and the plain COALESCE that expresses only the
                  -- first of them is a defect this branch shipped for one commit and its own test
                  -- caught. (1) While a failure is outstanding, grace runs from the FIRST one: a
                  -- provider retries and sends past_due again each time, and taking the newest
                  -- instant would push the deadline out on every retry so the window never closes.
                  -- (2) A delivery that is NOT a failure clears it: the renewal succeeded, or the
                  -- subscription ended, and either way the old deadline is no longer about anything.
                  -- COALESCE alone gets (1) right and (2) exactly backwards -- it kept a stale grace
                  -- window alive across a successful payment, so an account that had recovered was
                  -- still counting down to a revocation nothing was owed for.
                  past_due_since = CASE WHEN EXCLUDED.past_due_since IS NULL THEN NULL
                                        ELSE COALESCE(sonny.entitlement.past_due_since,
                                                      EXCLUDED.past_due_since) END,
                  grace_until = CASE WHEN EXCLUDED.grace_until IS NULL THEN NULL
                                     ELSE COALESCE(sonny.entitlement.grace_until,
                                                   EXCLUDED.grace_until) END,
                  billing_provider = EXCLUDED.billing_provider,
                  billing_subscription_id = EXCLUDED.billing_subscription_id,
                  billing_event_at = EXCLUDED.billing_event_at,
                  updated_at = now()
            WHERE sonny.entitlement.billing_event_at IS NULL
               OR sonny.entitlement.billing_event_at < EXCLUDED.billing_event_at
         RETURNING account_id`,
      [
        accountId,
        write.plan,
        write.capabilities,
        write.revokedAt,
        write.pastDueSince,
        write.graceUntil,
        input.provider,
        event.subscriptionId,
        event.occurredAt,
      ],
    );
    // No row means the `WHERE` refused: this delivery is not newer than the state it met.
    const outcome: BillingOutcome = moved.rows.length === 0 ? "stale" : "applied";
    await settle(client, input.provider, event.eventId, outcome, accountId);
    await client.query("COMMIT");
    return { outcome, accountId };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/** Correct the provisional outcome the claim was written with, and record which account it reached. */
async function settle(
  client: pg.Client,
  provider: string,
  eventId: string,
  outcome: BillingOutcome,
  accountId: string,
): Promise<void> {
  await client.query(
    `UPDATE sonny.billing_event SET outcome = $3, account_id = $4
      WHERE provider = $1 AND event_id = $2`,
    [provider, eventId, outcome, accountId],
  );
}

/**
 * The store as the webhook route uses it.
 *
 * A seam of the same shape and for the same reason as `EntitlementStore`, `MeteringStore` and
 * `KeyStore`: the flagged `npm test` runs with no database, so without it every behaviour this
 * ticket is about — a replay changing nothing, a cancellation revoking, a payment failure opening a
 * grace window, an unattributable customer granting nothing — would be verified only under
 * `npm run test:db`, and the run this repository gates on would be silent about the route that
 * grants paid entitlements. `billing.db.test.ts` proves the SQL underneath against a real Postgres.
 */
export interface BillingStore {
  readonly apply: (input: BillingApplyInput) => Promise<BillingApplyResult>;
}

export function postgresBillingStore(withConnection: WithConnection): BillingStore {
  return {
    apply: (input) => withConnection((client) => applyBillingDelivery(client, input)),
  };
}
