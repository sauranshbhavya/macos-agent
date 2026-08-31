import pg from "pg";
import { describe, expect } from "vitest";
import {
  applyBillingDelivery,
  hasLiveSubscription,
  type BillingPlans,
} from "../src/billing/store.js";
import { POLAR } from "../src/billing/polar.js";
import type { SubscriptionEvent, SubscriptionState, WebhookReading } from "../src/billing/provider.js";
import { claimFactsFor, readEntitlement } from "../src/entitlement/store.js";
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
const PLANS: BillingPlans = new Map([[PRODUCT, { plan: "paid", capabilities: ["screen_control"] }]]);
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
});
