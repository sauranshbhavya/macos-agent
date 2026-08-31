import type {
  BillingProvider,
  SubscriptionEvent,
  SubscriptionState,
  VerifiedDelivery,
  WebhookReading,
} from "./provider.js";

/**
 * The Polar adapter (SONNY-211) — **the only file in this repository that has heard of Polar.**
 *
 * Polar is the merchant of record, finalised by the founders on 2026-08-30. That decision named a
 * provider; it did not remove the seam, deliberately, so everything here is reachable only through
 * `BillingProvider` and a second provider is a second file beside this one.
 *
 * ## The one detail with real teeth: how the endpoint secret becomes an HMAC key
 *
 * Polar signs deliveries with [Standard Webhooks](https://www.standardwebhooks.com/), and the
 * specification's own encoding is `whsec_` followed by **base64** of the key bytes. Polar's secrets
 * are not that shape: its dashboard issues a plain string, and its own SDK base64-**encodes** that
 * string before handing it to a standard-webhooks verifier — which then base64-*decodes* it. The two
 * operations cancel, so **Polar's effective HMAC key is the raw UTF-8 bytes of the secret**.
 *
 * That is written down rather than inferred at run time on purpose. A verifier that tried both
 * derivations would accept a delivery under either, which turns a misconfiguration — the founder
 * pasting the wrong secret — into something that silently half-works, and doubles the key space an
 * attacker's forgery has to miss. One derivation, stated, and a wrong secret produces a clean
 * `signature_mismatch` that names itself.
 *
 * ## Why the mapping is on `status` and not on the event type
 *
 * Polar sends ten subscription event types (`created`, `active`, `updated`, `canceled`,
 * `uncanceled`, `cycled`, `past_due`, `revoked`, `paused`, `resumed`) and the same account state is
 * reachable through several of them. Worse, one of those verbs means the opposite of what it looks
 * like: **`subscription.canceled` fires when the user asks to cancel, and access continues to the
 * end of the paid period** — the payload still says `status: "active"` with
 * `cancel_at_period_end: true`, and it is `subscription.revoked` that fires when access actually
 * ends. An adapter switching on the verb would cut a paying user off the moment they clicked cancel,
 * for the remainder of a period they had already paid for. Switching on the state the payload
 * reports gets that case right without knowing it is a case.
 *
 * The verb is still recorded — `sonny.billing_event.event_type` keeps it verbatim — because an
 * operator asking "why did this stop" needs the provider's own word, not this file's reading of it.
 */

/** The provider name, as `sonny.billing_event.provider` and `sonny.entitlement.billing_provider`. */
export const POLAR = "polar";

/**
 * Polar's own subscription statuses, mapped onto the neutral state.
 *
 * **A table with no default arm**, so a status Polar adds later reads as `unreadable` and lands in
 * `sonny.billing_event` where somebody can see it — rather than being guessed at in either
 * direction. Guessing "active" grants a subscription nobody paid for; guessing "ended" revokes one
 * somebody did.
 */
const STATUS: Readonly<Record<string, SubscriptionState>> = {
  active: "active",
  trialing: "active",
  past_due: "past_due",
  paused: "paused",
  canceled: "ended",
  revoked: "ended",
  unpaid: "ended",
  incomplete: "ended",
  incomplete_expired: "ended",
};

/** Every delivery whose type begins with this is a subscription transition; everything else is not. */
const SUBSCRIPTION_PREFIX = "subscription.";

/**
 * The query parameter a Polar checkout link reads the account out of, and the one thing that makes a
 * later webhook resolvable to an account at all.
 *
 * The account id travels to Polar here, comes back on the customer as `external_id`, and
 * `billing/store.ts` matches on it. A checkout opened without it produces a paying customer this
 * gateway cannot attribute — which `sonny.billing_event`'s `unmatched` outcome records rather than
 * swallowing.
 */
const EXTERNAL_CUSTOMER_PARAMETER = "customer_external_id";

function readString(source: Record<string, unknown>, key: string): string | undefined {
  const value = source[key];
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function readObject(source: Record<string, unknown>, key: string): Record<string, unknown> | undefined {
  const value = source[key];
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

/**
 * When Polar says this happened.
 *
 * `modified_at` is the subscription's own last-changed instant and is the right ordering key: it is
 * the provider's statement about the *resource*, so two deliveries about one subscription order
 * correctly even when they were sent out of order or retried days apart. Falling back to the signed
 * `webhook-timestamp` rather than to this gateway's clock keeps the value one an attacker cannot
 * choose, which matters because it is what decides whether a delivery may overwrite existing state.
 */
function occurredAt(data: Record<string, unknown>, sentAt: Date): Date {
  const raw = readString(data, "modified_at") ?? readString(data, "created_at");
  if (raw === undefined) return sentAt;
  const parsed = new Date(raw);
  return Number.isNaN(parsed.getTime()) ? sentAt : parsed;
}

/**
 * The account this subscription belongs to, as Polar echoes it back.
 *
 * Two places, because Polar's payload has carried it in both across API versions: on the embedded
 * customer as `external_id`, and flattened onto the subscription as `customer_external_id`. Reading
 * both costs one line and removes a class of failure — an unattributable paying customer — whose
 * only symptom is a support ticket.
 */
function accountIdFrom(data: Record<string, unknown>): string | undefined {
  const customer = readObject(data, "customer");
  return (
    (customer === undefined ? undefined : readString(customer, "external_id")) ??
    readString(data, "customer_external_id")
  );
}

/**
 * The provider's plan key: the product this subscription is for.
 *
 * The **product** and not the price, because a price change on one product is not a plan change and
 * would otherwise silently unmap the plan and drop every subscriber's capabilities.
 */
function planKeyFrom(data: Record<string, unknown>): string | undefined {
  const product = readObject(data, "product");
  return (
    readString(data, "product_id") ?? (product === undefined ? undefined : readString(product, "id"))
  );
}

export function readPolarDelivery(delivery: VerifiedDelivery): WebhookReading {
  let envelope: unknown;
  try {
    envelope = JSON.parse(delivery.body.toString("utf8"));
  } catch {
    return { kind: "unreadable", eventId: delivery.eventId, reason: "body is not JSON" };
  }
  if (typeof envelope !== "object" || envelope === null || Array.isArray(envelope)) {
    return { kind: "unreadable", eventId: delivery.eventId, reason: "body is not a JSON object" };
  }
  const outer = envelope as Record<string, unknown>;
  const eventType = readString(outer, "type");
  if (eventType === undefined) return { kind: "unreadable", eventId: delivery.eventId, reason: "no type" };
  if (!eventType.startsWith(SUBSCRIPTION_PREFIX)) {
    return { kind: "ignored", eventId: delivery.eventId, eventType };
  }

  const data = readObject(outer, "data");
  if (data === undefined) return { kind: "unreadable", eventId: delivery.eventId, reason: `${eventType} carried no data` };
  const subscriptionId = readString(data, "id");
  if (subscriptionId === undefined) {
    return { kind: "unreadable", eventId: delivery.eventId, reason: `${eventType} named no subscription` };
  }
  const status = readString(data, "status");
  if (status === undefined) {
    return { kind: "unreadable", eventId: delivery.eventId, reason: `${eventType} carried no status` };
  }
  const state = STATUS[status];
  if (state === undefined) {
    // Named in the reason, because the fix is one entry in the table above and the reason is the
    // only place the missing word appears.
    return { kind: "unreadable", eventId: delivery.eventId, reason: `unknown subscription status ${JSON.stringify(status)}` };
  }
  const planKey = planKeyFrom(data);
  if (planKey === undefined) {
    return { kind: "unreadable", eventId: delivery.eventId, reason: `${eventType} named no product` };
  }

  const event: SubscriptionEvent = {
    eventId: delivery.eventId,
    eventType,
    occurredAt: occurredAt(data, delivery.sentAt),
    state,
    subscriptionId,
    accountId: accountIdFrom(data),
    planKey,
  };
  return { kind: "event", event };
}

export interface PolarProviderConfig {
  /** The endpoint secret from Polar's dashboard, verbatim. Never logged, never in this repository. */
  readonly webhookSecret: string;
  /** The hosted checkout link, from Polar's dashboard. Where a user is sent to subscribe. */
  readonly checkoutUrl: string;
}

export function polarProvider(config: PolarProviderConfig): BillingProvider {
  return {
    name: POLAR,
    // The one Polar-specific derivation, argued in this file's header: the raw UTF-8 bytes of the
    // secret, because Polar's SDK base64-encodes the secret into a verifier that base64-decodes it.
    webhookKey: Buffer.from(config.webhookSecret, "utf8"),
    read: readPolarDelivery,
    checkoutUrlFor: (accountId) => {
      // `URL` rather than string concatenation: the configured link may already carry query
      // parameters of its own, and it encodes the account id rather than trusting it to be safe in a
      // URL. The id is a uuid this gateway minted, so nothing hostile reaches here — the encoding is
      // for the day something else does.
      const url = new URL(config.checkoutUrl);
      url.searchParams.set(EXTERNAL_CUSTOMER_PARAMETER, accountId);
      return url.toString();
    },
  };
}
