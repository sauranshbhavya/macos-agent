import { DEADLINE_MS } from "../model/limits.js";
import type {
  BillingProvider,
  PortalLink,
  SubscriptionEvent,
  SubscriptionState,
  TopUpCharge,
  TopUpChargeRequest,
  TopUpOrder,
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
 * Polar's own id for the customer, as the embedded customer object carries it (SONNY-215).
 *
 * **`customer.id` and never `customer_external_id`.** They are two different identifiers for one
 * person: the external one is the account id this gateway sent to checkout and the one
 * `accountIdFrom` above reads, and the `id` is Polar's own — which is what an off-session order is
 * addressed to. Reading the wrong one produces a 404 at charge time on an account that is perfectly
 * well provisioned.
 *
 * `customer_id` flattened onto the subscription is read as well, for `accountIdFrom`'s reason: the
 * payload has carried it in both places across API versions, and reading both costs one line.
 */
function customerIdFrom(data: Record<string, unknown>): string | undefined {
  const customer = readObject(data, "customer");
  return (
    (customer === undefined ? undefined : readString(customer, "id")) ??
    readString(data, "customer_id")
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
    customerId: customerIdFrom(data),
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
   * An Organization Access Token with `customer_sessions:write` **and `orders:write`**
   * (SONNY-216, widened by SONNY-215). Never logged.
   *
   * **This is the first provider API credential this gateway has ever held**, and its arrival is a
   * deliberate reversal argued in this file's portal section below. One token for both calls
   * because they are one credential at the provider; the second scope is what places an automatic
   * top-up's off-session order.
   *
   * **Nothing here validates a scope at startup**, which is the same gap `server/README.md` records
   * for the token itself: a token carrying only the first scope deploys cleanly, mints portal
   * sessions, and fails on the first purchase. The only check is a real order, which is what
   * SONNY-215's manual rows are for.
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
  /**
   * How this adapter mints the deadline for a top-up call. **Tests only** — nothing a deployment
   * sets (SONNY-430, PR #220's F1).
   *
   * Injected for exactly `fetchImplementation`'s reason one field up, in the other direction: that
   * seam lets a test assert what was *sent* without a network, and this one lets a test assert what
   * was *spent* without waiting twelve seconds for it. What the tests read is the millisecond figure
   * each call hands over, which is the budget the adapter really spends rather than the constant it
   * is supposed to spend — the distinction PR #220's F1 was about, where a mutant tripling the number
   * at its use site passed all 1295 tests because every assertion was about the constant.
   */
  readonly deadlineFactory?: ((milliseconds: number) => AbortSignal) | undefined;
}

/** Polar's production API origin. Overridden by `apiBaseUrl` for sandbox deployments. */
const POLAR_API_BASE_URL = "https://api.polar.sh";

/** The path that mints a customer portal session. */
const CUSTOMER_SESSIONS_PATH = "/v1/customer-sessions/";

/**
 * How long this gateway waits for Polar before giving up: **eight seconds**.
 *
 * **The reason this number had was false, and is corrected here rather than quietly replaced**
 * (PR #183, F6). It was argued entirely on retry behaviour: that a typed `504 provider.timeout` from
 * this gateway is retried once by the Mac while the Mac's own transport timeout is not, so this
 * budget had to be the smaller of the two. **The Mac does not retry this route at all.**
 * `SonnyAccountService.hostedBillingPortalURL()` passes `isRetrySafe: false` — deliberately, because
 * each press should mint its own session — and `SonnyBackendClient.send` gates every retry on that
 * flag *before* it reaches the error's ceiling. So both outcomes are retried **zero** times here,
 * and the mechanism the number was derived from is switched off for this call. The citation it
 * carried, `SonnyBackendClient.swift:33-39`, is the doc comment on `screenAnalyze`, a route that
 * *is* retry-safe.
 *
 * **The reasons that survive, and they are enough.**
 *
 * - **It must be comfortably smaller than the Mac's own 20-second `SonnyBackendTimeouts.auth`
 *   budget** (`Sources/MacAgentCore/SonnyBackendClient.swift:28`), not so a retry can happen but so
 *   that the *user* is told something true. Under this budget the gateway answers a typed
 *   `504 provider.timeout` that it logs and the app can word for itself; over it, the Mac's
 *   transport gives up first and the app reports a generic unreachable-backend failure about a
 *   gateway that was working fine. One of those is diagnosable from the logs and the other is not.
 * - **An unbounded call inside a request handler is how a route stops answering at all**, which is
 *   an argument for a bound rather than for this bound.
 * - **The floor is an ordinary successful call**: one TLS handshake and one small JSON round trip to
 *   a commercial API, hundreds of milliseconds. Eight seconds is far enough above that never to
 *   fire on a healthy call, and far enough below twenty to always beat the client.
 *
 * **The relation to the Mac's 20 seconds is now pinned by a test rather than by this comment**
 * (`the outbound budget stays under the Mac's own`), following `ModelRouteNumbersTests`' precedent:
 * a cross-half number that lives in prose on one side is a number the next session moves without
 * noticing the other side. A mutant raising this to 30 000 survived the whole suite before that
 * test existed.
 */
export const PORTAL_SESSION_TIMEOUT_MS = 8_000;

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
/**
 * The body of a response, read once and never re-read.
 *
 * Only the 404 branch calls this, and nothing else consumes the same stream. **The reason is not
 * that the branch returns immediately** -- it does not, when `looksLikeAMissingCustomer` is false
 * control falls through to `!response.ok` (cycle 3's residual). It is that the only other read of
 * this body, `response.json()`, sits behind `response.ok`, and a 404 never reaches it. A body this
 * fails to read is `""`, which `looksLikeAMissingCustomer` refuses -- the fail-loud direction.
 */
async function peek(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "";
  }
}

/**
 * Does this 404 look like **the provider** saying it has no such customer, rather than something
 * else saying it has no such endpoint (PR #183, F5)?
 *
 * **What this can tell apart, and what it cannot, stated rather than implied.** A wrong origin or a
 * dropped path prefix is answered by a proxy, a load balancer or a framework's own handler, and
 * those answer HTML, an empty body, or plain text. The provider answers its own JSON error
 * envelope. So "the body parses as a JSON object" separates the two cases that matter here. It does
 * **not** verify that the object is Polar's not-found shape specifically, because nobody on this
 * project has yet seen one -- the manual row now records the body verbatim, and when it does, this
 * is where the check is tightened.
 *
 * **It fails in the safe direction on purpose.** A genuine missing-customer 404 whose body this
 * cannot parse falls through to `rejected`, which reports a loud fault to a user who has nothing to
 * manage. The opposite mistake tells a paying subscriber they have no subscription.
 */
function looksLikeAMissingCustomer(body: string): boolean {
  if (body.trim() === "") return false;
  try {
    const parsed: unknown = JSON.parse(body);
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed);
  } catch {
    return false;
  }
}

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
  // **The status alone is not enough, and that was the unexamined half of the same judgement**
  // (PR #183, F5). A 404 is also what a wrong path or a wrong origin answers -- `BILLING_API_BASE_URL`
  // is operator-set, and `CUSTOMER_SESSIONS_PATH` is root-anchored so a configured path prefix is
  // silently dropped. Mapping every 404 to `noCustomer` means that under a misconfiguration **every
  // paying subscriber** is told "This account holds no subscription to manage", which is verbatim
  // the outcome the 422 reasoning below calls a support incident that reads like data loss -- and
  // the client's second defence does not help, because those users hold claims, so their row is
  // rendered and they do press. So the body has to look like the provider answering.
  //
  // **Confirmed against the live account by a manual row rather than asserted here.** A 422 is the
  // other plausible answer for an unknown external id, and nobody on this project has run this
  // request against real Polar yet; if it turns out to be 422, this branch is where that is fixed
  // and the manual row is what would find it. Until then a 422 falls to `rejected` below, which is
  // the safe direction: it reports a fault loudly instead of telling a paying subscriber they have
  // no subscription.
  if (response.status === 404 && looksLikeAMissingCustomer(await peek(response))) {
    return { kind: "noCustomer" };
  }
  // **429 is on the provider's side of the line, not the caller's** (PR #183, F10). It is the one
  // 4xx that is retryable by definition, and this gateway decided that twice before this adapter
  // existed: `src/auth/supabase.ts:521-525` states the rule — "a rate limit and a server error are
  // statements about the provider's ability to answer, never about whether the user's input was
  // correct" — and `src/auth/revocation.ts` reads "any 4xx but 429 is ProviderRejected". This was
  // the third provider adapter in the tree and the only one that put 429 on the input-was-wrong
  // side, which sent a throttled call to the Mac as not-retryable and made it give up on the one
  // thing waiting would fix.
  if (response.status === 429 || response.status >= 500) {
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

/** The path that creates a draft order, and the one that charges it. */
const ORDERS_PATH = "/v1/orders/";
const FINALIZE_PATH = (orderId: string) => `/v1/orders/${encodeURIComponent(orderId)}/finalize`;

/**
 * How long this gateway waits for **each** of the two calls a top-up makes: **twelve seconds**
 * (SONNY-215).
 *
 * **Two budgets across three HTTP calls, which is SONNY-430's correction and not a contradiction.**
 * The draft creation spends one and the finalize spends the other; the read-back the finalize may
 * make on a `412` shares the finalize's rather than taking a third, because it is the second half of
 * that operation. Before SONNY-430 it took its own, so the sentence above was true of the design and
 * false of the code — one top-up could spend thirty-six seconds, which no §12 row has ever allowed
 * and which the Mac's own forty-second client timeout is not sized for.
 *
 * **This is §12's row halved, not a literal that agrees with it** (PR #220's F1). It was written the
 * other way round — a `12_000` here with the table's 24 described as "this number doubled" — and the
 * consequence was that `DEADLINE_MS.topUp.upstream` had **no production reader at all**: a mutant
 * tripling the budget at its use site passed the whole suite, and at 36 s upstream under a 30 s total
 * the two invert, so every slow charge is cut off mid-flight and recorded `unconfirmed`. The arrow now
 * points from the contract to the code, which is what `limits.ts` claims and what `auth/deps.ts` does
 * with `DEADLINE_MS.auth.upstream`. Two calls is the divisor because two calls is what a top-up makes;
 * `topup.test.ts` measures what the adapter really spends rather than asserting this constant.
 *
 * `PORTAL_SESSION_TIMEOUT_MS`'s three surviving reasons apply unchanged, and the number differs from
 * its eight for one reason that is specific to this call: **there are two of them, and the Mac's own
 * budget has to clear both.** A draft creation and a finalize run in sequence, so the ceiling this
 * gateway can spend is the client's budget minus its own overhead, divided by two.
 * `SonnyBackendTimeouts.topUp` on the Mac is 40 s against 24 s of provider budget here, and
 * `the top-up budget clears both of its calls inside the Mac's own` is what pins the relation rather
 * than this comment — following `PORTAL_SESSION_TIMEOUT_MS`'s own precedent, where a mutant raising
 * the number survived the whole suite until a test held it.
 *
 * **Why twelve rather than eight.** A card authorisation is a real payment network round trip and is
 * slower than minting a session token; eight seconds is comfortably above a healthy one of those and
 * is not obviously above a healthy charge. Twelve keeps the doubled budget inside the client's.
 */
export const TOPUP_CHARGE_TIMEOUT_MS = DEADLINE_MS.topUp.upstream / 2;

/**
 * §12's budget for one top-up call, minted the way this adapter's config says to.
 *
 * **The arrow is shape, not necessity, and the reason first given for it was false** (PR #220's delta
 * review, N1). It said the bare `config.deadlineFactory ?? AbortSignal.timeout` form fails because the
 * static is called with `AbortSignal` as its receiver and handing the reference around detaches it. It
 * does not: on node v22.23.1 `const bare = AbortSignal.timeout; bare(40)` returns a real signal that
 * aborts after its delay with a `TimeoutError`, and `bare.call(undefined, 40)` behaves the same, static
 * operations taking no receiver — measured here with `Map.prototype.get.call(undefined, "k")` as the
 * control that the probe can see a genuine detachment at all. What the arrow buys is that both arms of
 * the `??` read as the same thing, a `(ms: number) => AbortSignal`, so nobody has to stop and work out
 * whether the right-hand one needs binding. That is worth a line; it is not a correctness fix, and
 * saying it was is the class of claim F5 was about, one round after fixing F5.
 */
function topUpDeadline(config: PolarProviderConfig): AbortSignal {
  const mint = config.deadlineFactory ?? ((ms: number) => AbortSignal.timeout(ms));
  return mint(TOPUP_CHARGE_TIMEOUT_MS);
}

/** The order status Polar reports for an order it actually charged. */
const PAID = "paid";

/**
 * Create the order a top-up will be charged against — and charge nothing (SONNY-215).
 *
 * ## Two calls, and only the second one moves money
 *
 * Polar's off-session charge is a draft-then-finalize pair. `POST /v1/orders/` creates an order in
 * `draft` with no invoice number and **charges nothing**; `POST /v1/orders/{id}/finalize`
 * synchronously attempts the charge, and on success the order becomes `paid`. This is the first
 * half, and it is its own method on the seam so that the caller has a moment in which the order's id
 * exists and nothing has been charged — the moment PR #196's F1 found there was no way to reach.
 *
 * **So a process that dies here has cost the user nothing**: an unpaid draft at the provider is not
 * a charge, and nothing here needs recovering.
 *
 * ## Confirmed against the live account by a manual row rather than asserted here
 *
 * `looksLikeAMissingCustomer` above carries the same warning for the portal call and it applies
 * twice over here: **nobody on this project has run an order against real Polar**, no top-up product
 * exists at the provider yet because no price has been decided, and the statuses below are read from
 * Polar's published documentation rather than from a response anybody has seen. What that buys is
 * that every unexpected answer fails in the direction that grants nothing, and the manual rows this
 * branch adds are what will replace the documentation with an observation.
 */
async function polarCreateTopUpOrder(
  config: PolarProviderConfig,
  request: TopUpChargeRequest,
): Promise<TopUpOrder> {
  const call = config.fetchImplementation ?? fetch;
  let draft: Response;
  try {
    draft = await call(new URL(ORDERS_PATH, config.apiBaseUrl ?? POLAR_API_BASE_URL), {
      method: "POST",
      headers: polarHeaders(config),
      body: JSON.stringify({ customer_id: request.customerId, product_id: request.productId }),
      signal: topUpDeadline(config),
    });
  } catch (error) {
    // **However this ended, no money moved.** A draft charges nothing, so there is no unconfirmed
    // case on this half of the pair at all.
    const name = error instanceof Error ? error.name : "";
    if (name === "TimeoutError") {
      return { kind: "timedOut", reason: `no answer within ${TOPUP_CHARGE_TIMEOUT_MS}ms` };
    }
    return { kind: "unavailable", reason: name === "" ? "request failed" : name };
  }
  // The portal's own reading of a 404, for its reason: a wrong origin or a dropped path prefix is
  // answered by something that is not the provider, and only the provider's own JSON envelope means
  // "no such customer". Everything else falls to `rejected`, which reports a fault loudly.
  if (draft.status === 404 && looksLikeAMissingCustomer(await peek(draft))) {
    return { kind: "noCustomer" };
  }
  if (draft.status === 429 || draft.status >= 500) {
    return { kind: "unavailable", reason: `provider answered ${draft.status}` };
  }
  if (!draft.ok) {
    // **A 422 lands here, and it is the answer this gateway is least sure about.** Polar requires a
    // complete billing address and a saved payment method before an order can be created, and a
    // customer missing either is a state the *user* can fix rather than a fault — but it is
    // indistinguishable from an unrecognised product id without reading a body nobody has seen.
    // `rejected` is the safe direction: it reports loudly to an operator instead of telling a user
    // their card was declined when the deployment is misconfigured.
    return { kind: "rejected", reason: `provider answered ${draft.status}` };
  }
  const orderId = readOrderField(await readJson(draft), "id");
  if (orderId === undefined) {
    return { kind: "rejected", reason: "provider created an order naming no id" };
  }
  return { kind: "created", orderId };
}

/**
 * Charge an order this gateway already created (SONNY-215).
 *
 * ## The classification, and the one axis it is organised on
 *
 * Every answer is sorted by **whether money may have moved**, not by whether the request succeeded.
 * That is why every throw out of this call is `unconfirmed` while a throw out of the draft call is
 * not: an aborted request may still be executing at the provider, and a draft has nothing to
 * execute. **That over-reports, deliberately.** A DNS failure here moved no money and is still
 * recorded as `unconfirmed`, because `fetch` does not tell a caller whether its bytes reached the
 * far side. Over-reporting costs an operator — or, now, the account's own next attempt — one extra
 * look at an order that turns out not to be paid; under-reporting costs a charge nobody investigates.
 *
 * ## Calling this again on an order whose answer was lost is safe, and that is the recovery
 *
 * PR #196's F1: a grant lost between the charge and the record used to leave a paid order nothing
 * would ever find, and the account's next attempt bought a second pack. The caller now writes the
 * order id down before calling this, and resolves that order rather than creating another — which
 * only works if a second call on a paid order answers `charged` instead of charging again.
 *
 * **It does, and the mechanism is Polar's own `412`.** Finalizing an order that is no longer a draft
 * is refused with `412` and charges nothing; this reads the order back at that point and answers
 * `charged` when it says `paid`. So the second call is a *question* rather than a second charge, and
 * an order in any other non-draft state stays `unconfirmed` — which keeps it resolvable rather than
 * closing it wrongly.
 */
async function polarFinalizeTopUpOrder(
  config: PolarProviderConfig,
  orderId: string,
): Promise<TopUpCharge> {
  const call = config.fetchImplementation ?? fetch;
  const base = config.apiBaseUrl ?? POLAR_API_BASE_URL;

  /**
   * **One deadline for this call and the read-back it may make, not one each** (SONNY-430).
   *
   * The `412` path below asks the provider what an order became, and it is the second half of *this*
   * operation rather than an operation of its own — so it spends what is left of this budget instead
   * of starting a fresh one. Two independent twelve-second signals made a single top-up cost
   * thirty-six seconds of provider time across its three calls, against the twenty-four that
   * `TOPUP_CHARGE_TIMEOUT_MS` above and `SonnyBackendTimeouts.topUp` on the Mac both derive their own
   * numbers from; §12 has no row that ever allowed the thirty-six.
   *
   * **Sharing it cannot abandon a charge**, which is the property that decided the shape. An
   * exhausted budget reaches `polarReadPaidOrder` as a rejected `fetch`, and every exit from there is
   * `unconfirmed` — so the order id stays on the row and the account's next attempt resolves it,
   * which is the recovery PR #196's F1 built. A shared deadline can lose the *answer* to a charge
   * here; it can never close the row on one.
   */
  const deadline = topUpDeadline(config);

  let finalized: Response;
  try {
    finalized = await call(new URL(FINALIZE_PATH(orderId), base), {
      method: "POST",
      headers: polarHeaders(config),
      // The documented body is an empty object. `payment_method_id` is the one optional field and is
      // deliberately not sent: choosing which of a customer's cards to charge is not a decision this
      // gateway has any basis for, and the customer's own default is what they set at the provider.
      body: "{}",
      signal: deadline,
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "request failed";
    return { kind: "unconfirmed", reason: `finalize did not answer: ${name}` };
  }
  switch (true) {
    case finalized.ok:
      break;
    // Card declined, no payment method on file, or an authentication challenge this charge cannot
    // answer. The provider answered and did not charge.
    case finalized.status === 402:
      return { kind: "declined", reason: "provider answered 402" };
    // **The order stopped being a draft, which is what being paid looks like — so ask.** This is the
    // recovery path and the reason a second call is a question rather than a charge.
    case finalized.status === 412:
      return await polarReadPaidOrder(config, orderId, deadline);
    case finalized.status === 429:
      return { kind: "unavailable", reason: "provider answered 429" };
    case finalized.status >= 500:
      // Unlike the draft call's 5xx: a charge that failed inside the provider may have failed after
      // taking the money.
      return { kind: "unconfirmed", reason: `provider answered ${finalized.status}` };
    default:
      // 403 is the documented one here — the feature is disabled, or the organisation cannot accept
      // payments — and both are an operator's to fix.
      return { kind: "rejected", reason: `provider answered ${finalized.status}` };
  }
  return chargedFrom(await readJson(finalized), orderId, "finalize");
}

/**
 * Read an order back and say whether the provider considers it paid.
 *
 * Reached only from a `412`, which is the one status that positively means the order is no longer a
 * draft. Everything that is not a readable `paid` stays `unconfirmed`, which leaves the order
 * resolvable by the next attempt rather than closing it on a guess.
 */
async function polarReadPaidOrder(
  config: PolarProviderConfig,
  orderId: string,
  deadline: AbortSignal,
): Promise<TopUpCharge> {
  const call = config.fetchImplementation ?? fetch;
  let read: Response;
  try {
    read = await call(new URL(`${ORDERS_PATH}${encodeURIComponent(orderId)}`, config.apiBaseUrl ?? POLAR_API_BASE_URL), {
      method: "GET",
      headers: polarHeaders(config),
      // **The finalize's remaining budget, never a fresh one** (SONNY-430). An already-exhausted
      // signal rejects this `fetch` immediately, which the catch below reads as `unconfirmed` — the
      // answer that keeps the order resolvable, so running out of time here costs a question rather
      // than a charge.
      signal: deadline,
    });
  } catch (error) {
    const name = error instanceof Error ? error.name : "request failed";
    return { kind: "unconfirmed", reason: `order was no longer a draft and did not read back: ${name}` };
  }
  if (!read.ok) {
    return { kind: "unconfirmed", reason: `order was no longer a draft and read back ${read.status}` };
  }
  return chargedFrom(await readJson(read), orderId, "the order");
}

/**
 * An order body → `charged`, or `unconfirmed` naming what it said instead.
 *
 * **One reading for both callers**, so the finalize answer and the read-back answer cannot come to
 * disagree about what `paid` is. `where` names which call produced the body, because "finalize
 * answered 200 and the order is not paid" and "the order we read back is not paid" send an operator
 * to two different places.
 */
function chargedFrom(
  order: Record<string, unknown> | undefined,
  orderId: string,
  where: string,
): TopUpCharge {
  const status = readOrderField(order, "status");
  if (status !== PAID) {
    // **Anything that is not `paid` is not a success.** The documented transition on a successful
    // charge is to `paid`, so anything else is an answer this gateway cannot interpret, and
    // interpreting it generously is how credit gets granted for a charge that never happened.
    return { kind: "unconfirmed", reason: `${where} said status ${JSON.stringify(status ?? null)}` };
  }
  // **What the provider says it took, when it says so** (SONNY-215, PR #196's F6). The field name is
  // read two ways for `accountIdFrom`'s reason — the payload has carried it as both across API
  // versions — and both being absent is not a failure: the caller falls back to the price the
  // deployment configured, which is what the product had shown before the charge anyway.
  const amount = readOrderNumber(order, "total_amount") ?? readOrderNumber(order, "amount");
  const currency = readOrderField(order, "currency");
  return { kind: "charged", orderId, amount, currency };
}

/** The two headers every call above sends. The credential is here and in no `reason`. */
function polarHeaders(config: PolarProviderConfig): Record<string, string> {
  return {
    authorization: `Bearer ${config.accessToken}`,
    "content-type": "application/json",
  };
}

/** A JSON object body, or `undefined` — the same tolerance `polarPortalSession` applies. */
async function readJson(response: Response): Promise<Record<string, unknown> | undefined> {
  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return undefined;
  }
  return typeof payload === "object" && payload !== null && !Array.isArray(payload)
    ? (payload as Record<string, unknown>)
    : undefined;
}

/** One string field off an order body, through this file's own `readString` rule. */
function readOrderField(
  order: Record<string, unknown> | undefined,
  key: string,
): string | undefined {
  return order === undefined ? undefined : readString(order, key);
}

/**
 * One number field off an order body.
 *
 * **A finite number and nothing else.** A provider that sent a string, a `null` or a `NaN` is a
 * provider whose amount this gateway cannot record, and the caller's fallback — the configured price
 * — is a better answer than a figure nobody can add up.
 */
function readOrderNumber(
  order: Record<string, unknown> | undefined,
  key: string,
): number | undefined {
  const value = order === undefined ? undefined : order[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
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
    createTopUpOrder: (request) => polarCreateTopUpOrder(config, request),
    finalizeTopUpOrder: (orderId) => polarFinalizeTopUpOrder(config, orderId),
  };
}
