import type { FastifyInstance } from "fastify";
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
    return reply.send({ checkout_url: deps.provider.checkoutUrlFor(caller.accountId) });
  });
}
