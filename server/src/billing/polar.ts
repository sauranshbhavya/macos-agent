import type {
  BillingProvider,
  PortalLink,
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
  // **`Object.hasOwn` rather than a bare lookup, because the bare one reaches `Object.prototype`**
  // (PR #178 review, F4). `STATUS["constructor"]` is a function, not `undefined`, so a payload whose
  // status is any inherited key — `constructor`, `toString`, `valueOf`, `__proto__`,
  // `hasOwnProperty`, `isPrototypeOf` — walked straight past the refusal below carrying a `state`
  // that is not a `SubscriptionState`. `writeFor`'s exhaustive switch then matched nothing, returned
  // `undefined`, and the delivery became a `TypeError` and a 500 instead of the recorded `unreadable`
  // row this table's own doc comment promises. Same reachability as F3 — it needs the signing secret,
  // so this is robustness rather than an exploit — and the table's "no default arm" claim is only
  // true with this guard in front of it.
  const state = Object.hasOwn(STATUS, status) ? STATUS[status] : undefined;
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
  /**
   * An Organization Access Token with `customer_sessions:write` (SONNY-216). Never logged.
   *
   * **This is the first provider API credential this gateway has ever held**, and its arrival is a
   * deliberate reversal argued in this file's portal section below.
   */
  readonly accessToken: string;
  /**
   * Polar's API origin. Defaults to production; a sandbox deployment overrides it.
   *
   * Configuration rather than a constant for the same reason `checkoutUrl` is: the sandbox and the
   * production API are different hosts, and moving between them must be a redeploy rather than a
   * code change. The default lives *here* rather than in `config.ts` because this is the file that
   * is allowed to know a Polar hostname.
   */
  readonly apiBaseUrl?: string | undefined;
  /**
   * The `fetch` this adapter calls. **Tests only** — nothing a deployment sets.
   *
   * Injected rather than reached for globally so a test can assert what was sent without a network,
   * the same shape `BillingRouteDeps.now` uses for the clock.
   */
  readonly fetchImplementation?: typeof fetch | undefined;
}

/** Polar's production API origin. Overridden by `apiBaseUrl` for sandbox deployments. */
const POLAR_API_BASE_URL = "https://api.polar.sh";

/** The path that mints a customer portal session. */
const CUSTOMER_SESSIONS_PATH = "/v1/customer-sessions/";

/**
 * How long this gateway waits for Polar before giving up: **eight seconds**.
 *
 * **Chosen against the Mac's own budget rather than against a guess at Polar's latency**, because
 * what the number decides is *which* timeout the user meets. The Mac spends
 * `SonnyBackendTimeouts.auth` — 20 seconds — on an account call
 * (`Sources/MacAgentCore/SonnyBackendClient.swift:28`). If this budget were the larger of the two,
 * the Mac's own transport timeout would fire first, and that one is **not retried**; a typed `504
 * provider.timeout` from this gateway **is** retried once, which that file's own comment at `:33-39`
 * spells out. So the requirement is that this number be comfortably the smaller, and eight seconds
 * leaves twelve for the round trip in both directions.
 *
 * The other end of the range is an ordinary successful call, which is one TLS handshake and one
 * small JSON round trip to a commercial API — hundreds of milliseconds, not seconds. Eight is far
 * enough above that to never fire on a healthy call and far enough below twenty to always beat the
 * client.
 *
 * **What it is not is a guess that this gateway can afford to wait eight seconds.** An unbounded
 * call inside a request handler is how a route stops answering at all, and every value here is
 * better than none.
 */
const PORTAL_SESSION_TIMEOUT_MS = 8_000;

/**
 * Mint a customer portal session for one account, and turn every way that can go wrong into a
 * `PortalLink` case (SONNY-216).
 *
 * ## Why this makes an outbound call when `checkoutUrlFor` beside it makes none
 *
 * **SONNY-211 established the opposite property deliberately, and this reverses it for one route.**
 * Its closing comment states that the hosted checkout "needs no provider API credential and makes no
 * outbound request" — that was a design property, not an accident, and it is why every billing path
 * before this one is inbound.
 *
 * Polar offers both shapes, and the static one is unusable *here* for a reason that has nothing to
 * do with security. `polar.sh/<org>/portal` authenticates the human by emailing a one-time code to
 * the address on their Polar customer record — so reaching it requires the user to type an address
 * Polar recognises. **Sonny does not key on the email address**:
 * `docs/sonny-identity-linking-rule.md:14` states that "the identity key is `(provider, subject)`.
 * It is never the email address", and §2 records Sign in with Apple returning
 * `abc123@privaterelay.appleid.com`. So a Hide My Email user whose Polar record carries a relay
 * address — or any user whose Sonny sign-in and Polar checkout used different addresses — cannot
 * reach their own billing portal at all, with **no error this gateway can surface and no recovery
 * the app can offer**. That is a paying customer silently locked out of cancelling their own
 * subscription.
 *
 * A credential is a cost the founders can manage by rotating it. That one is a cost the user pays
 * and nobody can fix, which is what decides it.
 *
 * **The account id is the whole of the lookup, and it already travels.** `checkoutUrlFor` sends
 * `customer_external_id` (see `EXTERNAL_CUSTOMER_PARAMETER` above), so the Polar customer carries
 * this gateway's account id as its `external_id` — and `external_customer_id` on this request
 * resolves it. Nothing here reads `sonny.entitlement`, so the portal path touches no store, no
 * column and no migration.
 *
 * **The link is not cached, and the expiry is why.** Polar scopes the session token to one customer
 * and expires it after roughly an hour; a cached link handed to a second user would be the first
 * user's invoices, and a cached link handed back to the same user after expiry is a dead page. One
 * mint per press is the only shape with neither failure.
 */
async function polarPortalSession(
  config: PolarProviderConfig,
  accountId: string,
): Promise<PortalLink> {
  const call = config.fetchImplementation ?? fetch;
  const endpoint = new URL(CUSTOMER_SESSIONS_PATH, config.apiBaseUrl ?? POLAR_API_BASE_URL);

  let response: Response;
  try {
    response = await call(endpoint, {
      method: "POST",
      headers: {
        // The credential. Never logged: every `reason` below is built from the status and the
        // adapter's own words, and none of them interpolates a header.
        authorization: `Bearer ${config.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ external_customer_id: accountId }),
      signal: AbortSignal.timeout(PORTAL_SESSION_TIMEOUT_MS),
    });
  } catch (error) {
    // **`AbortSignal.timeout` rejects with a `TimeoutError`, and a dropped connection rejects here
    // too** — they are told apart by name, because one is worth reporting as this gateway's own
    // budget being spent and the other as the provider being unreachable, and 7.2 gives them
    // different codes.
    const name = error instanceof Error ? error.name : "";
    if (name === "TimeoutError") {
      return { kind: "timedOut", reason: `no answer within ${PORTAL_SESSION_TIMEOUT_MS}ms` };
    }
    return { kind: "unavailable", reason: name === "" ? "request failed" : name };
  }

  // **404 is the account with no Polar customer**, which is the ordinary case rather than a fault.
  // Polar answers a `external_customer_id` it does not know with a not-found rather than an empty
  // success, so this is where a user who has never subscribed lands.
  //
  // **Confirmed against the live account by a manual row rather than asserted here.** A 422 is the
  // other plausible answer for an unknown external id, and nobody on this project has run this
  // request against real Polar yet; if it turns out to be 422, this branch is where that is fixed
  // and the manual row is what would find it. Until then a 422 falls to `rejected` below, which is
  // the safe direction: it reports a fault loudly instead of telling a paying subscriber they have
  // no subscription.
  if (response.status === 404) return { kind: "noCustomer" };
  if (response.status >= 500) {
    return { kind: "unavailable", reason: `provider answered ${response.status}` };
  }
  if (!response.ok) {
    return { kind: "rejected", reason: `provider answered ${response.status}` };
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return { kind: "rejected", reason: "provider answered 200 with a body that is not JSON" };
  }
  // Reuses this file's own `readString`, which is the one the delivery reader already uses — so a
  // response object and a webhook payload are read by one rule rather than two that can drift.
  const session =
    typeof payload === "object" && payload !== null && !Array.isArray(payload)
      ? (payload as Record<string, unknown>)
      : undefined;
  const url = session === undefined ? undefined : readString(session, "customer_portal_url");
  if (url === undefined) {
    return { kind: "rejected", reason: "provider answered 200 naming no customer_portal_url" };
  }
  // **A missing or unparseable `expires_at` does not lose the link.** The instant is carried for the
  // client's benefit, not for a decision this gateway makes, so discarding a working URL over a
  // field nothing depends on would be the worse failure. The fallback is deliberately the *shortest*
  // honest answer — treat it as already expiring — rather than an invented hour, so a client that
  // caches on this value re-mints instead of holding a link nothing vouched for.
  const declared = readString(session!, "expires_at");
  const parsed = declared === undefined ? undefined : new Date(declared);
  const expiresAt =
    parsed !== undefined && !Number.isNaN(parsed.getTime()) ? parsed : new Date(Date.now());
  return { kind: "link", url, expiresAt };
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
    portalUrlFor: (accountId) => polarPortalSession(config, accountId),
  };
}
