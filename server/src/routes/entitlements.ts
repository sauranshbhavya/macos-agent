import type { FastifyInstance } from "fastify";
import { callerOf } from "../auth/gate.js";
import {
  mintEntitlementClaim,
  type EntitlementSigningKey,
} from "../entitlement/claim.js";
import { claimFactsFor, type EntitlementStore } from "../entitlement/store.js";
import { ACCOUNT_DEADLINE_MS } from "../model/limits.js";
import { sendUpstreamFailure, underTotalDeadline } from "../model/routing.js";

/**
 * `GET /v1/account/entitlements` — contract §5.3 (SONNY-135).
 *
 * **The response is a signed claim and never a decision.** The gateway says what this account's plan
 * and capabilities are and signs that statement; whether a given capability gates a given feature is
 * row 18's (SONNY-23), and it is decided on the Mac against the claim rather than here. That split
 * is what makes §16.3's guarantee possible at all: a client that has to ask the server "may I" is a
 * client that cannot answer offline.
 *
 * **Authenticated, and therefore absent from `PUBLIC_ROUTES`** — `auth/gate.ts`'s deny-by-default.
 * §5.3's claim is about the caller, and `sub` is the verified account rather than anything the
 * request named.
 *
 * **Not metered and not charged against the spend cap.** §11's `route` enum has no value for it, and
 * it opens no provider call: charging a user for asking what they are allowed would make the check
 * that keeps them working the thing that runs them out. It *is* rate limited, along with every other
 * authenticated route, because a leaked token hammering it still costs the founder a database.
 *
 * **Bounded by §12's last row's total, as a request-scoped budget** (SONNY-434). The store leases
 * its own connection, so the handler has nothing to wrap; `underTotalDeadline` carries the budget to
 * that lease, and a read cancelled inside it answers §7.2's `504 provider.timeout`, retryable — it
 * is a read, and repeating it costs nothing. `model/routing.ts` carries the reasoning.
 */
export interface EntitlementRouteDeps {
  readonly store: EntitlementStore;
  readonly signingKey: EntitlementSigningKey;
  /** Tests only. Nothing a deployment sets. */
  readonly now?: (() => Date) | undefined;
}

export function registerEntitlementRoutes(app: FastifyInstance, deps: EntitlementRouteDeps): void {
  const now = deps.now ?? (() => new Date());

  app.get("/v1/account/entitlements", async (request, reply) => {
    const caller = callerOf(request);
    let record;
    try {
      record = await underTotalDeadline(ACCOUNT_DEADLINE_MS, () =>
        deps.store.entitlementFor(caller.accountId),
      );
    } catch (error) {
      // §7.2 case 5a through the shared mapper; anything it does not recognise is rethrown to the
      // root error handler, so a bug here is a logged 500 and never a dressed-up timeout.
      return sendUpstreamFailure(request, reply, error);
    }
    // One clock read for the whole response: the instant that decides whether a grace window has
    // closed is the same instant the claim is issued at, so a claim cannot be minted as entitled and
    // stamped a millisecond later as if it were not.
    const issuedAt = now();
    const facts = claimFactsFor(record, issuedAt);
    const claim = mintEntitlementClaim(
      {
        /**
         * **`sub` is the identity that asked; the claim's CONTENT is the account's.** The two are
         * different things and §5.3's own example writes this field as `<user id>`, which is the
         * choice made here for a reason the client cannot work around: the Mac must be able to check
         * that a cached claim belongs to the session it is holding — otherwise a claim cached before
         * a sign-out keeps granting capabilities to whoever signs in next, for up to its own grace
         * window — and **the only identifier the Mac has is `user.id` from §3.2's token response**.
         * It never learns an account id; §5 keeps the account server-side as the billable identity.
         *
         * What that costs, stated rather than left to be discovered: an account holding two linked
         * provider identities (`docs/sonny-identity-linking-rule.md`) receives a *different* claim
         * under each, carrying identical plan and capabilities because both are read from the one
         * account row. So the claims are equivalent in content and distinct in binding, and a client
         * that signs out of one identity and into the other refreshes rather than reusing the cached
         * one. That is the correct behaviour for a session change and costs one request.
         */
        subject: caller.supabaseUserId,
        plan: facts.plan,
        capabilities: facts.capabilities,
      },
      deps.signingKey,
      issuedAt,
    );
    // §2.1 makes the client tolerant of unknown response fields, so this body can grow additively.
    return reply.send(claim);
  });
}
