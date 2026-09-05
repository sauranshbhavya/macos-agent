import pg from "pg";
import { describe, expect } from "vitest";
import {
  applyBillingDelivery,
  hasLiveSubscription,
  hasSubscriptionRecord,
  paymentStateFor,
  type BillingPlans,
} from "../src/billing/store.js";
import { POLAR } from "../src/billing/polar.js";
import type { SubscriptionEvent, SubscriptionState, WebhookReading } from "../src/billing/provider.js";
import { claimFactsFor, readEntitlement } from "../src/entitlement/store.js";
import { grant, setRevoked } from "../src/entitlements.js";
import { testDatabaseUrl } from "./support/database.js";
import { rebuildSchema } from "./support/schema.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";

/**
 * A subscription reaching the entitlement, against a real Postgres (SONNY-211).
 *
 * **This is where the ticket's acceptance criteria are actually met**, because every one of them is
 * a property of a statement rather than of a shape. `billing.test.ts` proves the signature and the
 * mapping against a fake store; a fake cannot prove that a replay is bounded — its dedupe would be
 * the thing being tested — and it cannot prove that a delivery arriving out of order refuses to
 * overwrite, because that refusal is an `ON CONFLICT … WHERE` returning no row.
 *
 * Opt-in like the other `*.db.test.ts` files: `npm test` skips it, `npm run test:db` runs it.
 */
const url = process.env["DATABASE_URL"] ?? undefined;
const describeDb = url ? describe : describe.skip;

const PRODUCT = "prod_screen_control";
const SUBSCRIPTION = "sub_123";
/**
 * A second product, so a **plan change** can be expressed at all — no test could before (PR #178's
 * cycle-3 re-check). Two products and two capability lists is the smallest fixture that tells an
 * upgrade from a resubscription: without the second, every delivery carries the same `planKey` and
 * the three shapes below are indistinguishable from one another.
 */
const PRODUCT_PRO = "prod_pro";
const PLANS: BillingPlans = new Map([
  [PRODUCT, { plan: "paid", capabilities: ["screen_control"] }],
  [PRODUCT_PRO, { plan: "pro", capabilities: ["screen_control", "power"] }],
]);
const GRACE_MS = 14 * 24 * 60 * 60 * 1000;
const NOW = new Date("2026-08-30T12:00:00Z");

describeDb("a subscription reaches the entitlement", () => {
  let client: pg.Client;
  let account: string;
  const opened: pg.Client[] = [];

  /** A second real connection, for the one property a shared client cannot express. */
  const connect = async (): Promise<pg.Client> => {
    const extra = new pg.Client({ connectionString: testDatabaseUrl() });
    await extra.connect();
    opened.push(extra);
    return extra;
  };

  const event = (
    overrides: Partial<SubscriptionEvent> & { state: SubscriptionState },
  ): WebhookReading => ({
    kind: "event",
    event: {
      eventId: "msg_1",
      eventType: "subscription.active",
      occurredAt: NOW,
      subscriptionId: SUBSCRIPTION,
      accountId: account,
      // SONNY-215: the provider's own customer id, which an off-session top-up charge is addressed
      // to. `undefined` here so every existing case still describes a delivery that names none.
      customerId: undefined,
      planKey: PRODUCT,
      ...overrides,
    },
  });

  const apply = (reading: WebhookReading) =>
    applyBillingDelivery(client, {
      provider: POLAR,
      reading,
      plans: PLANS,
      graceMilliseconds: GRACE_MS,
    });

  const recorded = async (eventId: string) => {
    const rows = await client.query<{ outcome: string; account_id: string | null }>(
      "SELECT outcome, account_id FROM sonny.billing_event WHERE provider = $1 AND event_id = $2",
      [POLAR, eventId],
    );
    return rows.rows[0];
  };

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: testDatabaseUrl() });
    await client.connect();
    await rebuildSchema(client);
  });

  afterAllUnderHangBackstop(async () => {
    for (const extra of opened) await extra.end();
    await client.end();
  });

  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.billing_event, sonny.entitlement");
    await client.query("DELETE FROM sonny.account");
    const created = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );
    account = created.rows[0]!.id;
  });

  itUnderHangBackstop("anActiveSubscriptionGrantsThePlansCapabilities", async () => {
    const result = await apply(event({ state: "active" }));

    expect(result).toEqual({ outcome: "applied", accountId: account });
    const record = await readEntitlement(client, account);
    expect(record.plan).toBe("paid");
    expect(record.capabilities).toEqual(["screen_control"]);
    expect(record.revokedAt).toBeNull();
    expect(record.graceUntil).toBeNull();
    // The claim the client is handed, derived from the row rather than asserted about it.
    expect(claimFactsFor(record, NOW)).toEqual({ plan: "paid", capabilities: ["screen_control"] });
    expect(await recorded("msg_1")).toEqual({ outcome: "applied", account_id: account });
  });

  itUnderHangBackstop("aCancellationRevokesAndTheClaimGoesEmpty", async () => {
    await apply(event({ state: "active" }));
    const result = await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );

    expect(result.outcome).toBe("applied");
    const record = await readEntitlement(client, account);
    expect(record.revokedAt).not.toBeNull();
    // The plan key survives the revocation, which 0013 chose deliberately: an errored client that
    // keeps its old claim is slower to stop than one handed a fresh, signed, capability-less one.
    expect(record.plan).toBe("paid");
    expect(claimFactsFor(record, new Date(NOW.getTime() + 60_000))).toEqual({
      plan: "paid",
      capabilities: [],
    });
  });

  itUnderHangBackstop("aPaymentFailureOpensGraceAndKeepsEveryCapabilityInsideIt", async () => {
    // Spec §16.4: a billing event never cuts a user off mid-task. The failure sets a deadline.
    await apply(event({ state: "active" }));
    const failedAt = new Date(NOW.getTime() + 60_000);
    const result = await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.past_due",
        state: "past_due",
        occurredAt: failedAt,
      }),
    );

    expect(result.outcome).toBe("applied");
    const record = await readEntitlement(client, account);
    expect(record.revokedAt).toBeNull();
    expect(record.pastDueSince?.toISOString()).toBe(failedAt.toISOString());
    expect(record.graceUntil?.toISOString()).toBe(new Date(failedAt.getTime() + GRACE_MS).toISOString());
    expect(claimFactsFor(record, failedAt)).toEqual({ plan: "paid", capabilities: ["screen_control"] });
    expect(claimFactsFor(record, new Date(failedAt.getTime() + GRACE_MS))).toEqual({
      plan: "paid",
      capabilities: [],
    });
  });

  itUnderHangBackstop("aRetriedPaymentFailureDoesNotPushTheDeadlineOut", async () => {
    // The provider retries a failed payment and sends `past_due` each time. Taking the newest
    // instant would extend the window on every retry, and it would never close.
    const first = new Date(NOW.getTime() + 60_000);
    await apply(event({ state: "past_due", occurredAt: first }));
    await apply(
      event({ eventId: "msg_2", state: "past_due", occurredAt: new Date(first.getTime() + 86_400_000) }),
    );

    const record = await readEntitlement(client, account);
    expect(record.pastDueSince?.toISOString()).toBe(first.toISOString());
    expect(record.graceUntil?.toISOString()).toBe(new Date(first.getTime() + GRACE_MS).toISOString());
  });

  itUnderHangBackstop("aSuccessfulRenewalClearsTheGraceWindow", async () => {
    await apply(event({ state: "past_due", occurredAt: new Date(NOW.getTime() + 60_000) }));
    await apply(
      event({ eventId: "msg_2", state: "active", occurredAt: new Date(NOW.getTime() + 120_000) }),
    );

    const record = await readEntitlement(client, account);
    expect(record.graceUntil).toBeNull();
    expect(record.pastDueSince).toBeNull();
    expect(record.revokedAt).toBeNull();
  });

  itUnderHangBackstop("aReplayedDeliveryChangesNothing", async () => {
    // A valid signature stays valid, so the signature cannot be what stops a captured `active`
    // delivery from resurrecting a cancelled subscription. The event id being a primary key is.
    await apply(event({ state: "ended", occurredAt: new Date(NOW.getTime() + 120_000) }));
    const before = await readEntitlement(client, account);

    const replay = await apply(event({ state: "active" }));
    expect(replay).toEqual({ outcome: "duplicate", accountId: undefined });

    const after = await readEntitlement(client, account);
    expect(after.revokedAt?.toISOString()).toBe(before.revokedAt?.toISOString());
    expect(claimFactsFor(after, NOW).capabilities).toEqual([]);
    // One row, not two: the replay wrote nothing at all.
    const rows = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.billing_event",
    );
    expect(rows.rows[0]!.n).toBe(1);
  });

  itUnderHangBackstop("anOlderDeliveryArrivingLaterDoesNotUndoANewerOne", async () => {
    // Webhooks are retried, so a retry of an older event can land after a newer one. A `cancelled`
    // retried after a reactivation must not revoke a live subscription.
    const cancelledAt = new Date(NOW.getTime() - 3_600_000);
    await apply(event({ state: "active", occurredAt: NOW }));

    const stale = await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: cancelledAt,
      }),
    );

    expect(stale.outcome).toBe("stale");
    const record = await readEntitlement(client, account);
    expect(record.revokedAt).toBeNull();
    expect(claimFactsFor(record, NOW).capabilities).toEqual(["screen_control"]);
    // Recorded rather than dropped: an operator asking why a cancellation did not take needs to see
    // that it arrived and why it did not apply.
    expect(await recorded("msg_2")).toEqual({ outcome: "stale", account_id: account });
  });

  itUnderHangBackstop("aDeliveryNamingNoAccountThisGatewayKnowsGrantsNothing", async () => {
    const result = await apply(
      event({ state: "active", accountId: "11111111-2222-3333-4444-555555555555" }),
    );

    expect(result).toEqual({ outcome: "unmatched", accountId: undefined });
    const rows = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.entitlement",
    );
    expect(rows.rows[0]!.n).toBe(0);
    expect(await recorded("msg_1")).toEqual({ outcome: "unmatched", account_id: null });
  });

  itUnderHangBackstop("aLaterDeliveryWithNoExternalIdIsResolvedByItsSubscription", async () => {
    // The first delivery records the subscription against the account; every later one can then be
    // placed without the payload carrying an account at all.
    await apply(event({ state: "active" }));

    const result = await apply(
      event({
        eventId: "msg_2",
        state: "ended",
        accountId: undefined,
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );

    expect(result).toEqual({ outcome: "applied", accountId: account });
    expect((await readEntitlement(client, account)).revokedAt).not.toBeNull();
  });

  itUnderHangBackstop("aClosedAccountIsNotGrantedAnything", async () => {
    await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [account]);

    const result = await apply(event({ state: "active" }));

    expect(result.outcome).toBe("unmatched");
    const rows = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.entitlement",
    );
    expect(rows.rows[0]!.n).toBe(0);
  });

  itUnderHangBackstop("aProductNoDeploymentConfiguredGrantsNothingAndSaysSo", async () => {
    const result = await apply(event({ state: "active", planKey: "prod_nobody_configured" }));

    expect(result).toEqual({ outcome: "unmapped", accountId: account });
    const rows = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.entitlement",
    );
    expect(rows.rows[0]!.n).toBe(0);
    expect(await recorded("msg_1")).toEqual({ outcome: "unmapped", account_id: account });
  });

  itUnderHangBackstop("aDeliveryThisGatewayDoesNotActOnIsRecordedAndNothingElse", async () => {
    const ignored = await apply({ kind: "ignored", eventId: "msg_1", eventType: "order.paid" });
    const unreadable = await apply({ kind: "unreadable", eventId: "msg_2", reason: "no status" });

    expect(ignored.outcome).toBe("ignored");
    expect(unreadable.outcome).toBe("unreadable");
    const rows = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.entitlement",
    );
    expect(rows.rows[0]!.n).toBe(0);
    // Both are replay-bounded too: a delivery this gateway ignores can be replayed as easily as one
    // it applies, and the row is what makes the second copy a no-op.
    expect((await apply({ kind: "ignored", eventId: "msg_1", eventType: "order.paid" })).outcome)
      .toBe("duplicate");
  });

  itUnderHangBackstop("twoConcurrentCopiesOfOneDeliveryProduceOneRowAndOneGrant", async () => {
    // **The claim `store.ts`'s header, the PR body and the ticket all make, and which nothing held**
    // (PR #178 review, F5): a concurrent duplicate blocks on the speculative-insertion lock and then
    // takes its `DO NOTHING` branch. `aReplayedDeliveryChangesNothing` is sequential and this
    // fixture's shared `client` serialises everything through one connection, so neither could
    // express the race at all. Two real connections can. Eight of this suite's own database files
    // already drive concurrency this way; `entitlement.db.test.ts` and `idempotency.db.test.ts` are
    // the closest shapes, the second being the same "the first statement is the claim" design.
    const a = await connect();
    const b = await connect();
    const delivery = event({ state: "active" });
    const run = (on: pg.Client) =>
      applyBillingDelivery(on, {
        provider: POLAR,
        reading: delivery,
        plans: PLANS,
        graceMilliseconds: GRACE_MS,
      });

    const [first, second] = await Promise.all([run(a), run(b)]);

    // **Which one wins is not asserted, because it is a real race** — the reviewer observed the
    // winner varying across runs. What is asserted is the invariant that holds whichever way it
    // lands: exactly one applied, exactly one duplicate.
    expect([first.outcome, second.outcome].sort()).toEqual(["applied", "duplicate"]);

    const events = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.billing_event",
    );
    expect(events.rows[0]!.n).toBe(1);
    const entitlements = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.entitlement",
    );
    expect(entitlements.rows[0]!.n).toBe(1);
    // And the grant is the one the delivery describes, not a half-applied version of it.
    expect((await readEntitlement(client, account)).capabilities).toEqual(["screen_control"]);
  });

  itUnderHangBackstop("aSecondSubscriptionOnOneAccountCannotRevokeTheLiveOne", async () => {
    // **The gap the unique index does not cover, and the direction that costs the customer access**
    // (PR #178 review, F1). `sonny.entitlement` is keyed on the account and holds one subscription
    // id; before the fix, a second subscription's events simply overwrote the first's, so cancelling
    // the *duplicate* set `revoked_at` and emptied the capabilities while the other subscription was
    // still active and still billing — recorded as `applied`, so the audit table said nothing was
    // wrong either.
    await apply(event({ state: "active" }));

    // The second subscription is refused and recorded rather than silently overwriting.
    const second = await apply(
      event({
        eventId: "msg_2",
        state: "active",
        subscriptionId: "sub_456",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );
    expect(second).toEqual({ outcome: "conflict", accountId: account });
    expect(await recorded("msg_2")).toEqual({ outcome: "conflict", account_id: account });

    // **The property that was broken**: cancelling the subscription that never granted anything must
    // not revoke the access the live one grants.
    const cancelled = await apply(
      event({
        eventId: "msg_3",
        eventType: "subscription.revoked",
        state: "ended",
        subscriptionId: "sub_456",
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );
    expect(cancelled.outcome).toBe("conflict");

    const record = await readEntitlement(client, account);
    expect(record.revokedAt).toBeNull();
    expect(claimFactsFor(record, new Date(NOW.getTime() + 120_000)).capabilities)
      .toEqual(["screen_control"]);
  });

  itUnderHangBackstop("aResubscriptionAfterACancellationIsNotAConflict", async () => {
    // The other side of the liveness test, and the reason `refuseForeignSubscription` asks whether
    // the row is live rather than whether it names a different subscription: cancel-then-resubscribe
    // is the ordinary path and a new subscription must take the revoked row over.
    await apply(event({ state: "active" }));
    await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );

    const fresh = await apply(
      event({
        eventId: "msg_3",
        state: "active",
        subscriptionId: "sub_789",
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );

    expect(fresh).toEqual({ outcome: "applied", accountId: account });
    const record = await readEntitlement(client, account);
    expect(record.revokedAt).toBeNull();
    expect(claimFactsFor(record, new Date(NOW.getTime() + 120_000)).capabilities)
      .toEqual(["screen_control"]);
  });

  itUnderHangBackstop("aSecondSubscriptionIsRefusedWhileTheFirstIsMerelyPastDue", async () => {
    // A row in grace is live — `revoked_at` is still NULL — so a second subscription beside a
    // past-due one is the same anomaly and gets the same answer. Asserted because "live" is the whole
    // of the test and a reader could reasonably expect past_due to count as not-live.
    await apply(event({ state: "past_due", occurredAt: new Date(NOW.getTime() + 60_000) }));

    const second = await apply(
      event({
        eventId: "msg_2",
        state: "active",
        subscriptionId: "sub_456",
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );

    expect(second.outcome).toBe("conflict");
    const record = await readEntitlement(client, account);
    expect(record.pastDueSince).not.toBeNull();
  });

  /**
   * **The three shapes a plan change can take, none of which any test covered** (PR #178's cycle-3
   * re-check). Which one the payment provider actually produces is the founders' fourth manual row —
   * change the plan on the live test subscription and record whether the subscription id moves — and
   * until that is run, all three are pinned so the answer lands on tests rather than on a belief.
   *
   * They differ only in what the provider does and in what order the deliveries arrive:
   *
   * - **A** — modified in place, one subscription id throughout. The founders' expectation.
   * - **B** — cancelled and created, the old subscription's revoke arriving first.
   * - **C** — cancelled and created, the new subscription arriving first. The regression.
   */
  itUnderHangBackstop("aPlanChangeOnOneSubscriptionIdUpgradesTheEntitlement", async () => {
    // **Shape A.** The provider modifies the subscription in place, so the id never moves and the
    // foreign-subscription refusal never sees it — `<> $3` excludes the row's own subscription, which
    // is exactly why the refusal is written that way. Unpinned until now, which means the founders'
    // own expectation was the shape with no test behind it.
    await apply(event({ state: "active" }));

    const upgraded = await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.updated",
        state: "active",
        planKey: PRODUCT_PRO,
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );

    expect(upgraded).toEqual({ outcome: "applied", accountId: account });
    const record = await readEntitlement(client, account);
    expect(record.plan).toBe("pro");
    expect(claimFactsFor(record, new Date(NOW.getTime() + 60_000)).capabilities)
      .toEqual(["screen_control", "power"]);
    expect(record.revokedAt).toBeNull();
  });

  itUnderHangBackstop("aPlanChangeWhoseRevokeArrivesFirstUpgradesTheEntitlement", async () => {
    // **Shape B.** Cancel-and-create with the deliveries in the order the provider sent them. The
    // revoke lands, the row stops being live, and the replacement takes it over through the same
    // door `aResubscriptionAfterACancellationIsNotAConflict` uses. Correct before this round and
    // correct after it — recorded so a later change to the refusal cannot break it silently.
    await apply(event({ state: "active" }));
    await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );

    const replacement = await apply(
      event({
        eventId: "msg_3",
        state: "active",
        subscriptionId: "sub_456",
        planKey: PRODUCT_PRO,
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );

    expect(replacement).toEqual({ outcome: "applied", accountId: account });
    const record = await readEntitlement(client, account);
    expect(record.plan).toBe("pro");
    expect(record.revokedAt).toBeNull();
    expect(claimFactsFor(record, new Date(NOW.getTime() + 120_000)).capabilities)
      .toEqual(["screen_control", "power"]);
  });

  itUnderHangBackstop("aPlanChangeWhoseNewSubscriptionArrivesFirstLosesAccessToday", async () => {
    // **Shape C, and this test RECORDS A REGRESSION rather than asserting a guarantee.** Read the
    // name that way: what it pins is what the code does today, so that a remedy changes it
    // deliberately and visibly instead of quietly.
    //
    // **The mechanism is two guards interacting.** Refusing the upgrade does not merely drop it — it
    // leaves `billing_event_at` at the OLD subscription's instant, which disarms the staleness guard
    // that had been refusing the out-of-order revoke. So the revoke, which arrives carrying an
    // earlier instant than the upgrade it followed, is no longer stale and applies.
    //
    // **Before this branch's F1 refusal existed, these same three deliveries left the customer on the
    // old plan** — the upgrade applied, and the late revoke was refused as stale. After it, they end
    // with nothing. That is why the justification this refusal rests on is now qualified in
    // `store.ts` as "does not lose access TO A CANCELLATION": unqualified, it is false here.
    //
    // Whether this shape is reachable at all depends on what the provider does with a plan change,
    // which nobody has checked in either direction; the founders' fourth manual row settles it.
    await apply(event({ state: "active" }));

    const upgrade = await apply(
      event({
        eventId: "msg_2",
        state: "active",
        subscriptionId: "sub_456",
        planKey: PRODUCT_PRO,
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );
    expect(upgrade.outcome).toBe("conflict");

    const lateRevoke = await apply(
      event({
        eventId: "msg_3",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );
    // Not `stale`, which is the whole mechanism: the marker never moved, so the earlier instant is
    // still newer than what the row carries.
    expect(lateRevoke.outcome).toBe("applied");

    const lost = await readEntitlement(client, account);
    expect(lost.revokedAt).not.toBeNull();
    expect(claimFactsFor(lost, new Date(NOW.getTime() + 180_000)).capabilities).toEqual([]);

    // **And the bound on it, which is why this is up to one billing period rather than permanent.**
    // The next delivery about the new subscription restores the correct state, because the row is no
    // longer live and the replacement takes it over.
    const renewal = await apply(
      event({
        eventId: "msg_4",
        eventType: "subscription.cycled",
        state: "active",
        subscriptionId: "sub_456",
        planKey: PRODUCT_PRO,
        occurredAt: new Date(NOW.getTime() + 180_000),
      }),
    );
    expect(renewal).toEqual({ outcome: "applied", accountId: account });
    const healed = await readEntitlement(client, account);
    expect(healed.plan).toBe("pro");
    expect(healed.revokedAt).toBeNull();
    expect(claimFactsFor(healed, new Date(NOW.getTime() + 180_000)).capabilities)
      .toEqual(["screen_control", "power"]);
  });

  itUnderHangBackstop("theCheckoutGuardSeesALiveSubscriptionAndNotARevokedOne", async () => {
    // The predicate the checkout route's 409 rests on, in both directions, against the real column
    // rather than the fake the route test uses. Same liveness rule as the foreign-subscription
    // refusal, and deliberately the same SQL — two spellings of "live" would let the webhook refuse a
    // delivery the checkout route had just handed someone a link for.
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);

    await apply(event({ state: "active" }));
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(true);

    // In grace is still live, which is what stops a past-due account opening a second subscription.
    await apply(
      event({ eventId: "msg_2", state: "past_due", occurredAt: new Date(NOW.getTime() + 60_000) }),
    );
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(true);

    // Revoked is not, so a cancelled account can subscribe again — the same door
    // `aResubscriptionAfterACancellationIsNotAConflict` walks through from the webhook side.
    await apply(
      event({
        eventId: "msg_3",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 120_000),
      }),
    );
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);
  });

  itUnderHangBackstop("thePortalGuardStillSeesASubscriptionTheCheckoutGuardCallsDead", async () => {
    // **SONNY-387, and the two predicates are asserted side by side because the divergence is the
    // property.** The portal route asks whether this gateway ever recorded a subscription here; the
    // checkout route asks whether one is live. They agree everywhere except on a cancelled account —
    // and that account is precisely who the hosted portal is for, so a portal route reusing the
    // checkout guard would refuse the user whose Account row still shows a live Manage button.
    expect(await hasSubscriptionRecord(client, POLAR, account)).toBe(false);
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);

    await apply(event({ state: "active" }));
    expect(await hasSubscriptionRecord(client, POLAR, account)).toBe(true);
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(true);

    await apply(
      event({
        eventId: "msg_2",
        eventType: "subscription.revoked",
        state: "ended",
        occurredAt: new Date(NOW.getTime() + 60_000),
      }),
    );
    // The row is revoked. This is the one place the two answers differ, and it is the whole ticket.
    expect(await readEntitlement(client, account).then((row) => row.revokedAt)).not.toBeNull();
    expect(await hasSubscriptionRecord(client, POLAR, account)).toBe(true);
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);

    // Both are scoped to the provider that issued the subscription, so a deployment that changed
    // provider does not read the old one's record as this one's — the `$2` is not decoration.
    expect(await hasSubscriptionRecord(client, "stripe", account)).toBe(false);
  });

  itUnderHangBackstop("aPlanTheOperatorGrantedIsNotASubscriptionToManage", async () => {
    // **The other half of what the portal guard asks** (SONNY-387). `entitlements.ts`'s `grant`
    // writes a plan and capabilities and names no subscription, so such an account renders
    // `<Plan> · Active` and a Manage button while the provider has no customer for it at all. The
    // guard answers `false` — which is the same 409 the provider's own `noCustomer` produced before
    // it, reached without the call.
    await client.query(
      `INSERT INTO sonny.entitlement (account_id, plan, capabilities, cap_units, updated_at)
            VALUES ($1, 'pro', $2, NULL, now())`,
      [account, ["screen_control"]],
    );
    const granted = await readEntitlement(client, account);
    expect(granted.plan).toBe("pro");
    expect(granted.capabilities).toEqual(["screen_control"]);

    expect(await hasSubscriptionRecord(client, POLAR, account)).toBe(false);
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);

    // **And the shape `billing_subscription_id IS NOT NULL` is actually about**, written directly
    // because no writer in this repository produces it: `entitlement_billing_identity_is_whole`
    // forbids a subscription id with no provider and permits the reverse, so a row naming the
    // provider and no subscription is a legal state. Without the clause it answers both questions
    // `true` — the portal would spend the call this guard exists to save, and the checkout route
    // would refuse a subscribe with `already_subscribed` for an account that has no subscription at
    // all. Found by a survivor: the operator-grant row above leaves `billing_provider` NULL, so it
    // never reaches the clause. (SONNY-387, mutant P5.)
    await client.query("UPDATE sonny.entitlement SET billing_provider = $2 WHERE account_id = $1", [
      account,
      POLAR,
    ]);
    expect(await hasSubscriptionRecord(client, POLAR, account)).toBe(false);
    expect(await hasLiveSubscription(client, POLAR, account)).toBe(false);
  });

  itUnderHangBackstop("aSubscriptionCannotBeMovedOntoASecondAccount", async () => {
    // The account id on a payload came from a URL, so it is caller-influenced. Without the unique
    // index a second account could claim a live subscription by starting a checkout that named it.
    await apply(event({ state: "active" }));
    const second = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );
    const other = second.rows[0]!.id;

    await expect(
      apply(
        event({
          eventId: "msg_2",
          state: "active",
          accountId: other,
          occurredAt: new Date(NOW.getTime() + 60_000),
        }),
      ),
    ).rejects.toThrow();

    // **The refusal is a thrown error and therefore a 500, and that is a deliberate residual rather
    // than an oversight.** Two accounts claiming one subscription is not a state the provider can
    // produce on its own — it mints the subscription id — so it means something is wrong that a
    // person has to look at, and the loud answer is the right one. What it costs is that the
    // provider will retry that delivery until it gives up. The alternative, classifying the
    // constraint violation and recording it as an outcome, is a real improvement and is not this
    // ticket's: it would need its own outcome value and its own reasoning about who wins.
    const owner = await client.query<{ account_id: string }>(
      `SELECT account_id FROM sonny.entitlement
        WHERE billing_provider = $1 AND billing_subscription_id = $2`,
      [POLAR, SUBSCRIPTION],
    );
    expect(owner.rows.map((row) => row.account_id)).toEqual([account]);
  });

  // SONNY-380 — the read that separates a past-due customer from a healthy one, against the real
  // column. `billing.test.ts` proves the route over a fake store; only these prove that the SQL
  // reads the column the webhook path actually writes.

  itUnderHangBackstop("aDeclinedCardIsReportedPastDue", async () => {
    await apply(event({ state: "active" }));
    expect(await paymentStateFor(client, account)).toBe("current");

    await apply(
      event({ eventId: "msg_2", state: "past_due", occurredAt: new Date(NOW.getTime() + 60_000) }),
    );

    expect(await paymentStateFor(client, account)).toBe("past_due");
    // **And the claim still says nothing**, which is the whole reason this read exists: §16.4 keeps
    // the capabilities through the window, so the signed claim a past-due account mints is
    // byte-identical to a healthy one's and the app read `Active` off it.
    const record = await readEntitlement(client, account);
    expect(claimFactsFor(record, NOW)).toEqual({ plan: "paid", capabilities: ["screen_control"] });
  });

  itUnderHangBackstop("aPastDueAccountIsStillPastDueOnceItsWindowHasClosed", async () => {
    // The half a `grace_until` reading would get wrong. Past the deadline the capabilities go, so
    // the claim flips to the shape a cancellation mints and the app would say `Ended` — but the
    // card is still declined and the control that fixes it is still the right one to offer, so
    // this must not revert to `current`.
    await apply(event({ state: "past_due" }));
    const closed = new Date(NOW.getTime() + GRACE_MS + 60_000);

    const record = await readEntitlement(client, account);
    expect(claimFactsFor(record, closed)).toEqual({ plan: "paid", capabilities: [] });
    expect(await paymentStateFor(client, account)).toBe("past_due");
  });

  itUnderHangBackstop("aRecoveredPaymentStopsBeingReportedPastDue", async () => {
    await apply(event({ state: "past_due" }));
    expect(await paymentStateFor(client, account)).toBe("past_due");

    await apply(
      event({ eventId: "msg_2", state: "active", occurredAt: new Date(NOW.getTime() + 60_000) }),
    );

    expect(await paymentStateFor(client, account)).toBe("current");
  });

  itUnderHangBackstop("aCancelledSubscriptionIsNotAPaymentFailure", async () => {
    // `writeFor`'s `ended` arm clears `past_due_since`, so a cancelled subscriber answers `current`
    // and the line they meet is the claim's own `Ended`. Asserted rather than assumed, because the
    // opposite would tell someone who cancelled on purpose that their payment failed.
    await apply(event({ state: "past_due" }));
    await apply(
      event({ eventId: "msg_2", state: "ended", occurredAt: new Date(NOW.getTime() + 60_000) }),
    );

    expect(await paymentStateFor(client, account)).toBe("current");
  });

  itUnderHangBackstop("anAccountWithNoEntitlementRowIsNotPastDue", async () => {
    // Every account that has never subscribed, which is most of them. `current` is the absence of a
    // recorded failure and not a claim that anything was paid.
    const fresh = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );

    expect(await paymentStateFor(client, fresh.rows[0]!.id)).toBe("current");
  });

  itUnderHangBackstop("anOperatorGrantEndsAnOutstandingPaymentFailure", async () => {
    // **PR #206's F2, and the doc sentence that claimed this was already true is what found it.**
    // `grant`'s upsert cleared `revoked_at` and touched neither payment column, so a comped
    // customer read `<Plan> · Past due` with an `Update payment` button **indefinitely** — the only
    // thing that clears `past_due_since` is a newer billing delivery, and for an account somebody
    // is comping one may never arrive.
    await apply(event({ state: "past_due" }));
    expect(await paymentStateFor(client, account)).toBe("past_due");

    await grant(client, {
      accountId: account,
      plan: "comped",
      capabilities: ["screen_control"],
      capUnits: null,
    });

    expect(await paymentStateFor(client, account)).toBe("current");
    // **The half that is worse than the line, and it is why this is a behaviour fix rather than a
    // wording one.** `claimFactsFor` compares `grace_until` against the instant it is given, so a
    // deadline left behind by the failure empties the capabilities on every read past it — the
    // grant would not have restored access at all. Asserted well past the window to prove the
    // deadline is gone rather than merely far away.
    const record = await readEntitlement(client, account);
    expect(record.pastDueSince).toBeNull();
    expect(record.graceUntil).toBeNull();
    expect(claimFactsFor(record, new Date(NOW.getTime() + GRACE_MS + 86_400_000))).toEqual({
      plan: "comped",
      capabilities: ["screen_control"],
    });
  });

  itUnderHangBackstop("anOperatorRevokeEndsAnOutstandingPaymentFailure", async () => {
    // The mirror (PR #206's F2). A revoked account is not past due, it is over — and leaving the
    // column set made the line read `Past due` with an `Update payment` control for an account the
    // operator had just ended, which is the opposite of what they did.
    await apply(event({ state: "past_due" }));
    expect(await paymentStateFor(client, account)).toBe("past_due");

    expect(await setRevoked(client, account, true)).toBe(true);

    expect(await paymentStateFor(client, account)).toBe("current");
    const record = await readEntitlement(client, account);
    expect(record.revokedAt).toBeInstanceOf(Date);
    expect(record.pastDueSince).toBeNull();
    expect(record.graceUntil).toBeNull();
    // So the line the operator's own action produces is the claim's `Ended`, not `Past due`.
    expect(claimFactsFor(record, NOW)).toEqual({ plan: "paid", capabilities: [] });
  });

  itUnderHangBackstop("onePastDueAccountDoesNotMakeAnotherOnePastDue", async () => {
    // The predicate takes no provider, deliberately (`paymentStateFor` says why), so the account id
    // is the only thing narrowing it — and a read that dropped that clause would answer `past_due`
    // for the whole deployment while every test above still passed.
    await apply(event({ state: "past_due" }));
    const second = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );

    expect(await paymentStateFor(client, second.rows[0]!.id)).toBe("current");
    expect(await paymentStateFor(client, account)).toBe("past_due");
  });
});
