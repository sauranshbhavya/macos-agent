/**
 * The payment-provider seam (SONNY-211).
 *
 * **Polar is the provider and this file does not know that.** The founders finalised Polar on
 * 2026-08-30 and the account exists; the same decision says the seam stays, because a
 * merchant-of-record swap is a business decision that can recur and the seam is what makes one a
 * configuration change rather than a rewrite. So everything a provider knows how to do is behind
 * `BillingProvider`, everything downstream of it speaks `SubscriptionEvent`, and
 * `billing/polar.ts` is the only file in this repository that has heard of Polar's event names or
 * its payload shape.
 *
 * ## Why the neutral event carries a state and not a verb
 *
 * The obvious neutral vocabulary is the four words the ticket names — created, updated, cancelled,
 * payment-failed — and it is the wrong one, because two providers disagree about which verb a given
 * transition is while agreeing exactly about the *state* the subscription ended up in. Polar alone
 * sends ten subscription event types and the same account state is reachable through several of
 * them. So an adapter's job is to answer "what is this subscription now", and the four verbs survive
 * only as `SubscriptionState`'s four values — which is what the entitlement is derived from.
 */

/**
 * What the provider says this subscription is, right now.
 *
 * - `active` — paid and in good standing. The entitlement carries the plan's capabilities.
 * - `past_due` — a payment failed and the provider has not given up. **Capabilities are kept** and a
 *   grace window opens; spec §16.4's whole point is that billing never cuts a user off mid-task.
 * - `ended` — cancelled, revoked, or lapsed past the provider's own retries. The entitlement is
 *   revoked: it keeps its plan key and mints claims with no capabilities, which is 0013's shape and
 *   `entitlement/store.ts`'s reasoning for it.
 * - `paused` — billing is suspended and the provider has withdrawn the benefits. Treated exactly as
 *   `ended` at the entitlement, and kept as a distinct value because `sonny.billing_event` records
 *   what the provider actually said and an operator asking "why did this stop" deserves the
 *   difference.
 */
export type SubscriptionState = "active" | "past_due" | "ended" | "paused";

/** One subscription transition, as everything downstream of the adapter sees it. */
export interface SubscriptionEvent {
  /** The provider's own id for this delivery. The replay bound; see `billing/store.ts`. */
  readonly eventId: string;
  /** The provider's own type string, verbatim. Recorded, never switched on outside the adapter. */
  readonly eventType: string;
  /** When the provider says it happened. Decides whether this delivery is newer than the state. */
  readonly occurredAt: Date;
  readonly state: SubscriptionState;
  /** The provider's id for the subscription. How later deliveries find the account. */
  readonly subscriptionId: string;
  /**
   * The account this subscription belongs to, as the provider was told it at checkout, or
   * `undefined` when the payload names none. `undefined` is not a failure: the subscription id
   * resolves it whenever this gateway has seen the subscription before.
   */
  readonly accountId: string | undefined;
  /**
   * The provider's **own** id for the customer this subscription belongs to, or `undefined` when the
   * payload names none (SONNY-215).
   *
   * Kept because an off-session top-up charge is addressed to it and to nothing else — the external
   * id checkout travels on is not accepted there. `undefined` is not a failure, for `accountId`'s
   * reason: a delivery that names no customer still moves the subscription's state, and what it
   * costs is that this account cannot be topped up until a delivery that does name one arrives.
   */
  readonly customerId: string | undefined;
  /**
   * The provider's plan key — its product or price identifier. Opaque here, exactly as
   * `sonny.entitlement.plan` is opaque: which capabilities it grants is deployment configuration,
   * and what it costs is SONNY-212's.
   */
  readonly planKey: string;
}

/** A delivery the adapter understood, or the reason it did not. */
export type WebhookReading =
  | { readonly kind: "event"; readonly event: SubscriptionEvent }
  /**
   * A delivery whose signature was good and whose type this gateway does not act on — an order
   * receipt, a benefit grant, a type the provider added after this code was written.
   *
   * **Answered `200` and recorded, never refused.** A provider that receives an error disables the
   * endpoint after enough of them, so refusing the types we ignore is how a deployment loses the
   * types it does not.
   */
  | { readonly kind: "ignored"; readonly eventId: string; readonly eventType: string }
  /**
   * A delivery that passed the signature and then did not parse — the body is not JSON, or it is
   * JSON without the fields its own declared type requires.
   *
   * Distinct from `ignored` because it means one of two things, both worth seeing: the provider
   * changed a payload shape, or something holding the endpoint secret is sending nonsense.
   */
  | { readonly kind: "unreadable"; readonly eventId: string; readonly reason: string };

/**
 * Where to send a subscriber to manage what they are paying for, or why there is nowhere to send
 * them (SONNY-216).
 *
 * **A result type rather than a thrown error, for the reason `WebhookReading` is one.** Three of the
 * four cases below are ordinary, expected answers rather than faults — most of all `noCustomer`,
 * which is every signed-in user who has never subscribed. A `throw` would flatten those into one
 * shape at the route, and the route has a different status and a different client behaviour for
 * each.
 *
 * **The failure cases are named for what the caller must do, not for what went wrong upstream.**
 * `unavailable` and `timedOut` are worth retrying and `rejected` is not, which is exactly the
 * distinction contract 7.2 draws between `provider.unavailable`, `provider.timeout` and
 * `provider.rejected` — so the mapping at the route is one line per case with nothing to decide.
 */
export type PortalLink =
  /** A link for this customer. Short-lived: see `expiresAt`, and see `polar.ts` on why it is not cached. */
  | { readonly kind: "link"; readonly url: string; readonly expiresAt: Date }
  /**
   * The provider has no customer for this account.
   *
   * **The ordinary case, not an error.** An account reaches it by signing in and never subscribing,
   * which is the majority of accounts. It is distinct from every failure below because the answer to
   * the user is different in kind: there is nothing wrong, and there is nothing to manage.
   */
  | { readonly kind: "noCustomer" }
  /** The provider could not be reached, or answered `5xx`. Worth retrying. */
  | { readonly kind: "unavailable"; readonly reason: string }
  /** The provider did not answer inside this gateway's own budget. Worth retrying. */
  | { readonly kind: "timedOut"; readonly reason: string }
  /**
   * The provider answered, and refused. A credential this gateway holds is wrong or has been
   * revoked, or the request shape is not one this provider accepts.
   *
   * **Not retryable, and that is the useful half**: an identical retry fails identically, so the
   * only thing a retry buys is a second failed request. What this case actually calls for is an
   * operator reading the log line, which is why the reason is carried.
   */
  | { readonly kind: "rejected"; readonly reason: string };

/**
 * What one automatic top-up charge is asking for (SONNY-215).
 *
 * **The provider's own customer id, not the account id.** Checkout sends the account id as an
 * *external* id and the customer comes back carrying it, which is how a webhook is attributed; an
 * off-session charge is addressed to the customer the provider minted, and
 * `sonny.entitlement.billing_customer_id` is where this gateway keeps it.
 */
export interface TopUpChargeRequest {
  readonly customerId: string;
  /** The provider's one-time product a top-up buys. `CREDIT_PLANS.topUp.productId`. */
  readonly productId: string;
}

/**
 * What happened when this gateway tried to charge a saved payment method (SONNY-215).
 *
 * **`PortalLink`'s shape and its reasoning, applied to the one call in this repository that moves
 * money.** A result type rather than a thrown error, because several of these are ordinary expected
 * answers rather than faults, and each has a different status and a different client behaviour.
 *
 * **Only `charged` grants credit, and every other case grants none.** That is the fail-closed
 * direction for a *grant*, and it is deliberately not the fail-closed direction for the *user*:
 * `unconfirmed` is the case where money may have moved and nothing is credited for it. The
 * alternative — crediting on an answer this gateway could not read — hands out product on a charge
 * that may never have happened, and a charge that did happen leaves an order at the provider that
 * an operator can see, which is a recoverable state. That asymmetry is the whole of the choice and
 * it is argued at `chargeTopUp` in `billing/polar.ts`.
 */
export type TopUpCharge =
  /** The provider charged the customer. `orderId` is its own id for the paid order. */
  | { readonly kind: "charged"; readonly orderId: string }
  /**
   * The provider answered and did **not** charge: the card was declined, there is no payment method
   * on file, or the charge needs an authentication challenge that an off-session attempt cannot
   * answer.
   *
   * **Not retryable and not a fault.** Sending the same request again produces the same decline, and
   * the thing that fixes it is the user changing their payment method — which is what the hosted
   * portal is for.
   */
  | { readonly kind: "declined"; readonly reason: string }
  /** The provider has no such customer. The account cannot be charged and never could be. */
  | { readonly kind: "noCustomer" }
  /** The provider could not be reached, answered `5xx`, or throttled this gateway. Worth retrying. */
  | { readonly kind: "unavailable"; readonly reason: string }
  /** The provider did not answer inside this gateway's own budget. Worth retrying. */
  | { readonly kind: "timedOut"; readonly reason: string }
  /**
   * The provider answered and refused this *gateway* — a wrong or revoked credential, a product it
   * does not recognise, a request shape it does not accept. An operator's to fix; a retry fails
   * identically.
   */
  | { readonly kind: "rejected"; readonly reason: string }
  /**
   * The charge was attempted and its answer could not be read. **Money may have moved.**
   *
   * Distinct from every case above because it is the only one where doing nothing is not obviously
   * safe. `orderId` is carried whenever the draft got as far as existing, so the row this produces
   * names the object an operator has to look at.
   */
  | { readonly kind: "unconfirmed"; readonly reason: string; readonly orderId: string | undefined };

/** A delivery whose signature has already been checked, as the adapter receives it. */
export interface VerifiedDelivery {
  /** `webhook-id`, which the signature covers. The provider's own id for this delivery. */
  readonly eventId: string;
  /**
   * `webhook-timestamp`, which the signature also covers.
   *
   * **The fallback for `occurredAt`, and a signed one**, which is why it is passed rather than the
   * adapter reaching for its own clock: a payload that carries no instant of its own still has to be
   * orderable against the state it meets, and the only instant available that an attacker cannot
   * choose is the one inside the signed content.
   */
  readonly sentAt: Date;
  /** The exact bytes. Unparsed, because the signature was checked over these. */
  readonly body: Buffer;
}

/** What a provider adapter has to be able to do. The whole of the seam. */
export interface BillingProvider {
  /** The provider's name, as `sonny.billing_event.provider` and the entitlement row record it. */
  readonly name: string;
  /**
   * The HMAC key this provider's deliveries are signed with, derived from the configured endpoint
   * secret. Bytes rather than a string because the derivation is the provider's own — see
   * `billing/polar.ts`, where it is the one Polar-specific detail with real teeth.
   */
  readonly webhookKey: Buffer;
  /** Turn a verified delivery into a neutral event, or say why not. */
  readonly read: (delivery: VerifiedDelivery) => WebhookReading;
  /** Where to send this account to subscribe. */
  readonly checkoutUrlFor: (accountId: string) => string;
  /**
   * Where to send this account to manage an existing subscription (SONNY-216).
   *
   * **Asynchronous, and `checkoutUrlFor` beside it is not — the asymmetry is the whole design
   * decision and is argued in `polar.ts`.** A checkout link is configuration: the same URL for every
   * user, with an account id appended. A portal link cannot be, because a portal shows one
   * customer's invoices and payment methods and therefore has to be minted for that customer.
   */
  readonly portalUrlFor: (accountId: string) => Promise<PortalLink>;
  /**
   * Charge this customer's saved payment method for one top-up pack (SONNY-215).
   *
   * **The only method on this seam that moves money**, and the only one whose failure cases a caller
   * must not collapse: `TopUpCharge` distinguishes a decline from an outage from an answer that
   * could not be read, because what the gateway records and what the user is told differ for each.
   */
  readonly chargeTopUp: (request: TopUpChargeRequest) => Promise<TopUpCharge>;
}
