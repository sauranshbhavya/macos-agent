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
}
