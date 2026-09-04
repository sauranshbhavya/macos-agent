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
  /**
   * A delivery about a different subscription than the one this account's entitlement is already
   * live on. Nothing moves. See `refuseForeignSubscription` below.
   */
  | "conflict"
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
 * Is this delivery about a subscription other than the one this account is already live on?
 *
 * **The gap this closes is the mirror of the one the unique index already covers, and it is the half
 * that costs the customer their access** (PR #178 review, F1). `entitlement_billing_subscription_idx`
 * refuses two accounts on one subscription. Nothing refused **two subscriptions on one account** —
 * `sonny.entitlement` is keyed on the account and holds exactly one `billing_subscription_id`, and
 * every delivery resolved by the payload's account id, so the second subscription's events simply
 * overwrote the first's. Proved against a real Postgres before the fix: subscribe twice, then cancel
 * the *first*, and `revoked_at` is set with the capabilities emptied **while the second subscription
 * is still active and still billing** — and `sonny.billing_event` records that revocation as
 * `applied`, so the audit table says nothing is wrong either.
 *
 * **This is not hypothetical user behaviour.** The hosted checkout is a static link with the account
 * id appended, so opening it twice is an ordinary thing a person does. Whether the *provider* permits
 * a second concurrent subscription for one customer and product is a dashboard question the founders
 * are answering separately; the gateway-side gap is real whatever that answer turns out to be, which
 * is why the fix is not scoped to it.
 *
 * **Refusing the foreign delivery is the direction that does not lose access TO A CANCELLATION, and
 * both directions cost something.** That qualifier is the whole of what was established, and the
 * unqualified sentence this used to carry was **false in one shape** (PR #178's cycle-3 re-check).
 * Refused: a customer who somehow holds two subscriptions keeps the access the first one grants and
 * pays twice. Accepted, which is what shipped first: the two overwrite each other and a cancellation
 * of *either* revokes access the other is still paying for.
 *
 * **Where the unqualified version is false, and it is worth reading before trusting this refusal.**
 * If the payment provider handles a plan change by cancelling and creating rather than by modifying
 * in place, and the two deliveries arrive out of order — the new subscription first, then the old
 * one's revoke — this refusal drops the upgrade, and dropping it leaves `billing_event_at` at the
 * *old* subscription's instant. That disarms the staleness guard which had been refusing the
 * out-of-order revoke, so the revoke now applies and the customer ends with no capabilities. Before
 * this refusal existed the same three deliveries left them on the old plan. Measured against a real
 * Postgres, and pinned below by `aPlanChangeWhoseNewSubscriptionArrivesFirstLosesAccessToday`.
 *
 * **Three things bound it.** It needs the provider to cancel-and-create, which is unverified in
 * either direction and is what the founders' fourth manual row settles. It needs the two deliveries
 * out of order, which this branch's own design assumes is possible — `billing_event_at` exists for
 * exactly that — but does not guarantee. And it **self-heals**: the next delivery about the new
 * subscription, a renewal or any update, restores the correct state, so the exposure is up to one
 * billing period rather than a permanent loss. That is bounded, not benign.
 *
 * **What a `conflict` row actually buys, said accurately because the sentence here used to overstate
 * it.** This said the second subscription is "visible in `sonny.billing_event` as `conflict` for a
 * human to unpick". **No such human exists yet.** The re-check enumerated rather than assumed: none
 * of the five operator CLIs reads this table, there is no alerting, metric or dashboard anywhere in
 * `server/src`, and the only reads of `sonny.billing_event` in the whole repository are three
 * one-off `SELECT`s inside this branch's own manual-test rows, none of which looks at `conflict`.
 * What the row is today is *evidence that survives*, queryable by anyone who already holds
 * `DATABASE_URL` and knows to look — which is strictly better than the log line this table's own
 * migration comment rejects, and is not a person being told. An operator surface with the shape
 * `revocations.ts` already has — a command that exits non-zero while there is unresolved debt — is
 * what would make the sentence true, and whether it is built now or filed is the founders'.
 *
 * **Liveness is the whole of the test, and it is what keeps resubscription working.** A row whose
 * subscription is revoked is not live, so a new subscription takes it over exactly as before — which
 * is the ordinary cancel-then-resubscribe path and must not become a conflict. A row in grace is
 * live (`revoked_at` is still `NULL`), so a second subscription arriving beside a past-due one is
 * refused, which is correct: two live subscriptions is the anomaly whatever state either is in.
 *
 * **What this does NOT do**, said plainly rather than left to be discovered: it does not merge the
 * two, does not decide which one *should* win, and does not refund or cancel anything at the
 * provider. It records the collision and refuses to let it corrupt the entitlement. Deciding who
 * wins is the same "who wins" reasoning the two-accounts-on-one-subscription residual already needs,
 * and both belong on one ticket rather than being improvised in a fix round.
 */
/**
 * What "this gateway has recorded a subscription for this account with this provider" means, as
 * **one** definition with three consumers — the foreign-delivery refusal below, the checkout route's
 * guard, and the portal route's (SONNY-387).
 *
 * Two spellings of this would be the defect one layer up: the webhook would refuse a delivery the
 * checkout route had just handed someone a link for, or the reverse, and which of the two was wrong
 * would depend on which one a reader happened to open. So the shared fragment is the whole of what a
 * recorded subscription is, and each caller that needs *less* than the whole appends its own clause.
 *
 * **`billing_subscription_id IS NOT NULL` is what makes this a statement about the provider rather
 * than about the plan.** `entitlements.ts`'s operator `grant` writes a plan and capabilities onto a
 * row and names no subscription, so an account can hold a plan this gateway granted itself and have
 * no customer at the provider at all. Every consumer here is asking about the provider's side.
 *
 * **It was written with a nullable third parameter — `($3::text IS NULL OR billing_subscription_id
 * <> $3)`, `null` meaning "exclude nothing" — and a mutation battery is what took that out.** H3 of
 * the guard round replaced that `null` with `""` and **survived**: an empty string is not null, so
 * the clause became `billing_subscription_id <> ''`, which is true of every subscription id there
 * can ever be, so the mutant meant exactly what the original meant. It was an equivalent mutant
 * rather than a coverage gap — the adapter's `readString` refuses an empty id, so the sentinel could
 * never collide with real data — and the honest options were to argue that in prose or to remove the
 * sentinel so the shape does not exist. This is the second. One caller passes two parameters and the
 * other passes three, which is what they actually differ by.
 */
const SUBSCRIPTION_RECORD = `SELECT billing_subscription_id FROM sonny.entitlement
      WHERE account_id = $1
        AND billing_provider = $2
        AND billing_subscription_id IS NOT NULL`;

/**
 * The same rows, narrowed to the ones that are still live. **The narrowing clause is the whole of
 * what separates this from the portal's question below**, and writing it as an extension rather
 * than as a second `SELECT` is what stops the two drifting into disagreeing about what a
 * subscription *is* while disagreeing only about `revoked_at`, which is what they mean to differ by.
 */
const LIVE_SUBSCRIPTION = `${SUBSCRIPTION_RECORD}
        AND revoked_at IS NULL`;

async function refuseForeignSubscription(
  client: pg.Client,
  provider: string,
  accountId: string,
  subscriptionId: string,
): Promise<boolean> {
  // The one thing the refusal needs that the guard does not: the row's OWN subscription is not
  // foreign to it, so a delivery about the subscription this account is live on is not a conflict.
  const existing = await client.query(`${LIVE_SUBSCRIPTION}
        AND billing_subscription_id <> $3`, [accountId, provider, subscriptionId]);
  return existing.rows.length > 0;
}

/**
 * Does this account already hold a live subscription with this provider?
 *
 * **The checkout route's guard, and it is the second defence rather than the first** (founder
 * direction, 2026-08-30, on PR #178's F1). The gateway must not depend on a belief about what the
 * provider does with a plan change, so the entitlement-side refusal stands whatever this answers.
 *
 * **What it closes, and what it cannot**, stated because the difference decides how much weight this
 * carries. It closes the *sequential* door: an account that is already subscribed asks for a checkout
 * link and is refused instead of handed one. It does **not** close the concurrent races — two tabs, a
 * double-click, a retry after a slow response — and the reason is the shape of the link rather than
 * the shape of the check. `checkoutUrlFor` returns a **static** checkout link with the account id
 * appended, so possession of it predates any check: both tabs obtained their link while the account
 * still had no subscription, and both can complete afterwards without asking this route again. The
 * complete checkout-side answer is a per-user checkout **session** minted per request, which is the
 * residual this branch already records against `BillingProvider.checkoutUrlFor`. Until then, F1's
 * refusal is what actually holds the property, and this narrows the door.
 */
export async function hasLiveSubscription(
  client: pg.Client,
  provider: string,
  accountId: string,
): Promise<boolean> {
  const existing = await client.query(LIVE_SUBSCRIPTION, [accountId, provider]);
  return existing.rows.length > 0;
}

/**
 * Has this gateway recorded *any* subscription for this account with this provider — live or ended?
 *
 * **The portal route's guard, and it is deliberately not `hasLiveSubscription`** (SONNY-387). A
 * cancelled subscriber is exactly who the hosted portal is for: they go there to read an invoice, to
 * take a card off the account, or to subscribe again. `revoked_at` is set for them
 * (`writeFor`'s `ended` and `paused` arms), so the checkout guard's question answers `false` — and a
 * portal route asking that question would refuse the user the app is offering the control to. The
 * app's own gate is the one this matches: `SubscriptionReading.read` renders `<Plan> · Ended` and a
 * live Manage button off a claim whose plan is set and whose capabilities are empty, which is what a
 * revoked row mints.
 *
 * **What this answers is what the gateway was told, not what is true at the provider now**, and the
 * route is arranged so that only one direction of that gap can matter. A `true` here decides
 * nothing: the provider is still called and its answer still wins, including its `noCustomer`. A
 * `false` is what saves the call, and it is a refusal — so the question is whether this can be
 * `false` while the provider does hold a customer.
 *
 * **It can, in three shapes that arrive through the provider, and none of those is reachable from
 * the app.** A checkout whose webhook has not landed yet; a delivery this gateway recorded
 * `unmatched`, `unmapped` or `unreadable`, so a customer exists at the provider and no row was ever
 * written; and a customer created in the provider's own dashboard against this account's external
 * id. In every one of them the same missing row is what `claimFactsFor` reads, so the claim this Mac
 * holds says `plan: 'none'`, `SubscriptionReading.read` answers `nil`, and the Account section
 * renders no Manage control at all — the user cannot reach this refusal, because the app already
 * refuses itself, from the same row and for the same reason. The first shape closes itself when the
 * delivery lands. **The second is the real residual**: a paying customer whose product
 * `BILLING_PLANS` does not name could, before this guard, have been handed a portal link by a client
 * that called the route directly, and now cannot. That is a support path narrowing, recorded rather
 * than discovered later; the state it needs is already a support incident (`unmapped` is a paying
 * customer with no entitlement), and the fix for it is the mapping, not the portal.
 *
 * **A fourth shape does reach the app, and the sentence above does not cover it** (PR #189's review,
 * F3). The reachability argument leans on a missing row minting `plan: 'none'`, and that step holds
 * only for an account whose entitlement came from the provider. The operator `grant` in
 * `entitlements.ts` writes `plan` and `capabilities` onto **this same row** and clears `revoked_at`,
 * **touching neither billing column** — it is an upsert, so on the insert path they are NULL because
 * nothing writes them and on the `ON CONFLICT DO UPDATE` path they are left exactly as they were,
 * which is NULL for the row this shape is about. So an operator-granted account
 * mints a claim with a real plan, `SubscriptionReading.read` returns a snapshot, and `SignInView`
 * renders a live Manage button while this predicate answers `false`. Combine that grant with any of
 * the three shapes above — say a customer made in the provider's dashboard — and the user really can
 * press Manage and be told there is no subscription. **It is pre-existing rather than a regression**:
 * an operator-granted account with no provider customer got the identical 409 from the provider's own
 * `noCustomer` before this guard existed, and this guard changes only the grant-*plus*-customer
 * combination, from "maybe a link" to a refusal. It is written down here because the enumeration is
 * what the whole argument rests on, and an enumeration that omits a case is the one kind of claim a
 * reader cannot check against the code it sits on. `aPlanTheOperatorGrantedIsNotASubscriptionToManage`
 * in `billing.db.test.ts` writes exactly this row and its own comment describes the rendering.
 */
export async function hasSubscriptionRecord(
  client: pg.Client,
  provider: string,
  accountId: string,
): Promise<boolean> {
  const existing = await client.query(SUBSCRIPTION_RECORD, [accountId, provider]);
  return existing.rows.length > 0;
}

/**
 * The provider's own customer id for this account (SONNY-215).
 *
 * **Not narrowed to a live subscription**, and the omission is the decision: a cancelled subscriber
 * still has a customer at the provider and a card on file, and a top-up is a one-time purchase
 * rather than a subscription benefit. Whether they are *allowed* one is the credit route's question
 * — it reads the plan's allowance, which a revoked entitlement has already lost — and answering it
 * twice, once here on a different rule, is how two paths come to disagree about who may buy.
 */
export async function billingCustomerFor(
  client: pg.Client,
  provider: string,
  accountId: string,
): Promise<string | undefined> {
  const { rows } = await client.query<{ billing_customer_id: string | null }>(
    `SELECT billing_customer_id FROM sonny.entitlement
      WHERE account_id = $1 AND billing_provider = $2`,
    [accountId, provider],
  );
  return rows[0]?.billing_customer_id ?? undefined;
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

    // **Before the plan is even looked up**, because the collision is about identity and does not
    // depend on this delivery's product being one the deployment configured — reporting `unmapped`
    // for a delivery that would have been refused anyway names the less actionable of the two facts.
    if (await refuseForeignSubscription(client, input.provider, accountId, event.subscriptionId)) {
      await settle(client, input.provider, event.eventId, "conflict", accountId);
      await client.query("COMMIT");
      return { outcome: "conflict", accountId };
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
              billing_provider, billing_subscription_id, billing_customer_id, billing_event_at,
              updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $10, $9, now())
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
                  -- **COALESCE, unlike every column above it** (SONNY-215). The others are this
                  -- delivery's statement about the subscription and replace what was there. A
                  -- customer id is a durable identifier that a payload may simply omit, and
                  -- overwriting a known one with NULL would leave an account that cannot be charged
                  -- until some later delivery happened to carry it again. New value wins; absence
                  -- keeps what is known.
                  billing_customer_id = COALESCE(EXCLUDED.billing_customer_id,
                                                 sonny.entitlement.billing_customer_id),
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
        event.customerId ?? null,
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
  /** The checkout route's guard. See `hasLiveSubscription` for what it closes and what it does not. */
  readonly hasLiveSubscription: (provider: string, accountId: string) => Promise<boolean>;
  /**
   * The portal route's guard. See `hasSubscriptionRecord` for why it is a different question from
   * the one above, and for the gap between what this answers and what is true at the provider.
   */
  readonly hasSubscriptionRecord: (provider: string, accountId: string) => Promise<boolean>;
  /**
   * The provider's own customer id for this account, or `undefined` (SONNY-215).
   *
   * **A third question about the same row, and it is deliberately not either of the two above.** A
   * top-up asks "is there something at the provider I can charge", which is neither "is a
   * subscription live" (`hasLiveSubscription`, which excludes a cancelled subscriber) nor "has one
   * ever existed" (`hasSubscriptionRecord`, which is true for a customer whose id nothing kept —
   * every account provisioned before 0019). Answering with the id itself rather than with a boolean
   * is what makes the difference impossible to lose: the caller cannot get as far as a charge
   * without holding the thing the charge is addressed to.
   */
  readonly billingCustomerFor: (
    provider: string,
    accountId: string,
  ) => Promise<string | undefined>;
}

export function postgresBillingStore(withConnection: WithConnection): BillingStore {
  return {
    apply: (input) => withConnection((client) => applyBillingDelivery(client, input)),
    hasLiveSubscription: (provider, accountId) =>
      withConnection((client) => hasLiveSubscription(client, provider, accountId)),
    hasSubscriptionRecord: (provider, accountId) =>
      withConnection((client) => hasSubscriptionRecord(client, provider, accountId)),
    billingCustomerFor: (provider, accountId) =>
      withConnection((client) => billingCustomerFor(client, provider, accountId)),
  };
}
