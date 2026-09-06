import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { callerOf } from "../auth/gate.js";
import { errorBody } from "../errors.js";
import type { BillingPlans, BillingStore } from "../billing/store.js";
import type { BillingProvider } from "../billing/provider.js";
import { verifyWebhookSignature } from "../billing/webhook-signature.js";

/**
 * The two billing routes (SONNY-211): where a user goes to subscribe, and where the provider tells
 * this gateway what happened.
 *
 * ## `POST /v1/billing/webhook` is the highest-stakes route in this repository
 *
 * It is reachable by anyone on the internet, it carries no user credential, and what it does is
 * grant paid entitlements. Everything below is arranged around that one sentence.
 *
 * **The signature is the authentication; the `PUBLIC_ROUTES` entry is bookkeeping.** `auth/gate.ts`
 * is deny-by-default, so this route has to be named there to be reachable at all — but being named
 * there is what makes it *unchallenged*, not what makes it safe. The HMAC over the exact request
 * bytes is the check, and nothing in this handler reads the payload before it passes.
 *
 * **`request.auth` is never consulted here and must not be.** `callerOf` throws on a public route,
 * which is correct and loud; a handler that reached for a caller on a route the gate never
 * challenged would be reading `null` and deciding something from it.
 *
 * **The raw bytes.** Fastify parses `application/json` into an object by default, and an HMAC over a
 * re-serialised object is not the HMAC that was sent — and, worse, would verify bytes that are not
 * the bytes then interpreted. This route is registered inside its own encapsulated scope with a
 * content-type parser that hands the handler a `Buffer` and parses nothing. **Encapsulated, so it
 * reaches this route and no other**: a root-level parser would change what every existing route's
 * handler receives, which is the same encapsulation property `auth/gate.ts` and `app.ts` each depend
 * on, used here in the opposite direction.
 *
 * ## Why a delivery that passes the signature is answered `200` whatever it then turns out to be
 *
 * A provider that collects errors from an endpoint disables it. So the failures *after* the
 * signature — a type this gateway ignores, a payload it cannot read, an account it cannot place, a
 * product `BILLING_PLANS` does not name — are recorded in `sonny.billing_event` with an outcome that
 * says which, and answered `200`. None of them is fixed by the provider sending the same bytes
 * again, and treating them as retryable would trade a queryable row for a disabled endpoint and a
 * subscription that never arrives. **A delivery that fails the signature is `401` and is recorded
 * nowhere**, which is the other half of the same decision: an unauthenticated caller must not be
 * able to write rows into this gateway's tables by POSTing at it.
 *
 * ## `POST /v1/billing/portal` is where a subscriber goes to manage what they pay for
 *
 * Authenticated, and — unlike every billing path before it — it **calls the provider**. The whole of
 * why is in `billing/polar.ts`: the provider's static portal authenticates the human by emailing a
 * one-time code to the address on their provider record, and Sonny does not key on the email
 * address, so a Hide My Email user could not reach their own billing portal at all. The link is
 * minted per press because the provider's session token is short-lived and scoped to one customer.
 *
 * **The account with no provider customer is the ordinary case and gets its own code.** A user who
 * signed in and never subscribed has nothing to manage; that is not a fault, and it is not an empty
 * success either. `entitlement.no_subscription` says so, and the app is expected to know its own
 * entitlement and not offer the control at all — the same relationship `entitlement.already_subscribed`
 * has with Subscribe.
 *
 * **And that account is answered without the call** (SONNY-387). The sentence above says "unlike
 * every billing path before it, it calls the provider", and that is true of a subscriber; it is not
 * true of the majority of accounts, which hold no subscription this gateway ever recorded. Only the
 * *absence* of a record short-circuits, and only into the refusal — a record present still calls,
 * so the provider remains the thing that decides whether a link exists. `billing/store.ts`'s
 * `hasSubscriptionRecord` carries which question this asks and why it is not the checkout guard's.
 *
 * ## `GET /v1/billing/payment-state` is the one thing the signed claim cannot say
 *
 * A customer whose card was declined keeps every capability until the grace window closes — §16.4,
 * deliberately, so that billing never interrupts someone mid-task — and the claim carries `plan` and
 * `capabilities` and nothing else. So a past-due account and a healthy one mint byte-identical
 * claims, and the app read `Active` for a customer whose payment had failed, for the whole window,
 * with the provider's own dunning email as their only notice (SONNY-380). §16.4 exists to stop a
 * surprise wall and that was a quiet route to one.
 *
 * **A separate read rather than a field on the claim**, decided by the founders on 2026-09-05: the
 * claim's shape is §4.1 and §5.3, and §8.2 makes changing it a `/v2` question, which is not a trade
 * worth making for a status word. So the word travels here instead, unsigned.
 *
 * **Unsigned is not a weakness here, because this answer decides nothing.** It picks the word on one
 * line and the label on one control. Every gate in this system — `admitRequest`, the per-capability
 * check, the entitlement claim itself — is untouched by it, and a caller who forged this response
 * would change a sentence on their own screen. That is the whole reason it can live outside the
 * claim; it would not be if anything were allowed to depend on it.
 *
 * **Authenticated like everything else on this surface**, and answering only about the caller's own
 * account: it takes no parameters, so there is nothing to name somebody else with.
 *
 * ## `POST /v1/billing/checkout` is authenticated and returns a URL
 *
 * The account id travels to the provider on that URL and comes back on the customer, which is what
 * lets a later webhook be attributed. Non-goal, from the ticket: the client-side subscribe flow
 * beyond opening this URL.
 */
export interface BillingRouteDeps {
  readonly provider: BillingProvider;
  readonly store: BillingStore;
  readonly plans: BillingPlans;
  readonly graceMilliseconds: number;
  /** Tests only. Nothing a deployment sets. */
  readonly now?: (() => Date) | undefined;
}

export const BILLING_WEBHOOK_PATH = "/v1/billing/webhook";
export const BILLING_CHECKOUT_PATH = "/v1/billing/checkout";
export const BILLING_PORTAL_PATH = "/v1/billing/portal";
export const BILLING_PAYMENT_STATE_PATH = "/v1/billing/payment-state";

/**
 * "This account holds no subscription to manage", as **one** answer with two arms behind it — the
 * local one and the provider's (SONNY-387).
 *
 * Two spellings would let a client tell which side answered, and which side answered is this
 * gateway's business rather than the caller's: both arms are saying the same thing about the same
 * account, and the client's copy for it is written once (`BillingPortalCopy`).
 */
function noSubscriptionToManage(request: FastifyRequest, reply: FastifyReply): FastifyReply {
  return reply
    .status(409)
    .send(
      errorBody(
        "entitlement.no_subscription",
        "This account holds no subscription to manage.",
        request.id,
        { retryable: false },
      ),
    );
}

export function registerBillingRoutes(app: FastifyInstance, deps: BillingRouteDeps): void {
  const now = deps.now ?? (() => new Date());

  void app.register(async (scope) => {
    // Hands the handler the bytes. `parseAs: "buffer"` is what stops Fastify's JSON parser running,
    // and returning the buffer unchanged is what stops anything else from running either.
    scope.addContentTypeParser(
      "application/json",
      { parseAs: "buffer" },
      (_request, body, done) => {
        done(null, body);
      },
    );
    // A provider that sends `application/json; charset=utf-8` matches the parser above; one that
    // sends something else entirely would otherwise be refused by Fastify before this handler runs,
    // with a framework error rather than a signature refusal. The catch-all keeps the refusal this
    // route's own.
    scope.addContentTypeParser("*", { parseAs: "buffer" }, (_request, body, done) => {
      done(null, body);
    });

    scope.post(BILLING_WEBHOOK_PATH, async (request, reply) => {
      const body = Buffer.isBuffer(request.body) ? request.body : Buffer.alloc(0);
      const verdict = verifyWebhookSignature({
        key: deps.provider.webhookKey,
        headers: request.headers,
        body,
        now: now(),
      });
      if (!verdict.ok) {
        // The refusal reason is logged and never sent. A caller probing this endpoint learns only
        // that it was refused; telling it whether the signature was wrong or the timestamp was stale
        // is telling it which half to fix.
        request.log.warn({ refusal: verdict.refusal }, "billing webhook refused");
        return reply
          .status(401)
          .send(
            errorBody("auth.required", "This request is not signed by the payment provider.", request.id, {
              retryable: false,
            }),
          );
      }

      const reading = deps.provider.read({
        eventId: verdict.eventId,
        sentAt: verdict.sentAt,
        body,
      });
      const result = await deps.store.apply({
        provider: deps.provider.name,
        reading,
        plans: deps.plans,
        graceMilliseconds: deps.graceMilliseconds,
      });
      // The account id is in the log line and never in the response: the provider does not need it,
      // and a body that echoed it would tell a caller who guessed a delivery id whose account it hit.
      request.log.info(
        { outcome: result.outcome, accountId: result.accountId, eventId: verdict.eventId },
        "billing webhook",
      );
      return reply.status(200).send({ received: true });
    });
  });

  app.post(BILLING_CHECKOUT_PATH, async (request, reply) => {
    const caller = callerOf(request);
    /**
     * **The second defence beside F1's, never instead of it** (founder direction, 2026-08-30). This
     * route had no guard at all: three lines that read the caller and returned a link, so a second
     * checkout on one account was an ordinary user action. The entitlement-side refusal is what
     * actually holds the property — the gateway must not rest on a belief about what the provider
     * does with a plan change — and this narrows the door in front of it.
     *
     * **It closes the sequential case and not the concurrent one**, and the reason is the static
     * link rather than this check: both tabs obtained their URL before any subscription existed, so
     * neither asks this route again. `billing/store.ts`'s `hasLiveSubscription` carries the whole of
     * that reasoning, and the complete answer is the per-user checkout session already recorded as a
     * residual.
     */
    if (await deps.store.hasLiveSubscription(deps.provider.name, caller.accountId)) {
      return reply
        .status(409)
        .send(
          errorBody(
            "entitlement.already_subscribed",
            "This account already holds a live subscription.",
            request.id,
            { retryable: false },
          ),
        );
    }
    return reply.send({ checkout_url: deps.provider.checkoutUrlFor(caller.accountId) });
  });

  app.post(BILLING_PORTAL_PATH, async (request, reply) => {
    const caller = callerOf(request);
    /**
     * **The never-subscribed account is answered here, without asking the provider** (SONNY-387).
     * It is most accounts, and the outbound call it used to cost only ever discovered the absence
     * this gateway had already recorded. The answer is byte-identical to the `noCustomer` arm below
     * on purpose: the client must not be able to tell which side answered, because the two are
     * saying the same thing about the same account.
     *
     * **The store's answer is decisive in one direction only.** A recorded subscription decides
     * nothing — the provider is still called, and its `noCustomer` still wins, which is what keeps
     * a stale row from minting a link that does not exist. Only the absence short-circuits, and
     * `hasSubscriptionRecord` carries the enumeration of when an absence can be wrong and why none
     * of those shapes is reachable from the app.
     *
     * **It is `hasSubscriptionRecord`, not the checkout route's `hasLiveSubscription`.** A cancelled
     * subscriber is exactly who this route is for, and their row is revoked.
     */
    if (!(await deps.store.hasSubscriptionRecord(deps.provider.name, caller.accountId))) {
      return noSubscriptionToManage(request, reply);
    }
    const link = await deps.provider.portalUrlFor(caller.accountId);
    // One arm per case, and every failure arm's status and `retryable` come straight from 7.2's
    // taxonomy rather than being decided here — which is why `PortalLink`'s cases are named for
    // what the caller must do rather than for what went wrong upstream.
    switch (link.kind) {
      case "link":
        // `expires_at` is carried so the client can tell a stale link from a broken one rather than
        // reporting "the portal is down" for a window it sat on for an hour.
        return reply.send({ portal_url: link.url, expires_at: link.expiresAt.toISOString() });
      case "noCustomer":
        return noSubscriptionToManage(request, reply);
      case "timedOut":
        // The reason is logged and never sent, exactly as the webhook's refusal reason is: it
        // describes this gateway's own budget and its upstream, neither of which is the caller's.
        request.log.warn({ reason: link.reason }, "billing portal timed out");
        return reply
          .status(504)
          .send(
            errorBody("provider.timeout", "The payment provider took too long.", request.id, {
              retryable: true,
            }),
          );
      case "unavailable":
        request.log.warn({ reason: link.reason }, "billing portal provider unavailable");
        return reply
          .status(502)
          .send(
            errorBody("provider.unavailable", "The payment provider could not be reached.", request.id, {
              retryable: true,
            }),
          );
      case "rejected":
        // **`error`, not `warn`.** This one is an operator's to fix — a revoked or wrong access
        // token, or a request shape the provider stopped accepting — and a retry cannot help.
        request.log.error({ reason: link.reason }, "billing portal refused by provider");
        return reply
          .status(502)
          .send(
            errorBody("provider.rejected", "The payment provider refused this request.", request.id, {
              retryable: false,
            }),
          );
    }
  });

  app.get(BILLING_PAYMENT_STATE_PATH, async (request, reply) => {
    const caller = callerOf(request);
    /**
     * **No provider call, and no refusal for an account with nothing to say.** Unlike the portal
     * route above, this is a single read of `sonny.entitlement` — so it costs one indexed `SELECT`
     * and answers the same way for every account, including the majority that hold no subscription
     * at all. There is deliberately no `entitlement.no_subscription` arm: the portal route refuses
     * because there is no link to mint, and here there is always an answer — an account with no
     * failure recorded is `"current"`, which is what a never-subscribed account is.
     *
     * **One field, and the client is expected to ignore any other** (§2.1). What a later version
     * may not do is add a third value to `payment` without §8.4's ladder, which
     * `BillingPaymentState` in `billing/store.ts` carries the reasoning for.
     */
    return reply.send({ payment: await deps.store.paymentState(caller.accountId) });
  });
}
