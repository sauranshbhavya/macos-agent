import type { FastifyInstance } from "fastify";
import { callerOf } from "../auth/gate.js";
import { creditBalance } from "../credit/balance.js";
import type { CreditCatalogue } from "../credit/catalogue.js";
import type { CreditStore } from "../credit/store.js";

/**
 * `GET /v1/account/credits` — **the one number a user tracks**, served (SONNY-212).
 *
 * SONNY-17 fixed the user-facing unit: "screen-control runs left this month". This is where the Mac
 * reads it. `ScreenControlAllowanceService` on the client is the reader;
 * rendering it is SONNY-214's and refusing on it is SONNY-213's, and neither of those decisions is
 * taken here — this route reports and never refuses.
 *
 * ## Why this is not on the entitlement claim
 *
 * The obvious alternative was a field on §5.3's signed claim, and it is wrong for a reason the claim
 * itself states: that claim is cached for **24 hours** and honoured for **72 more** past expiry, so a
 * client can legitimately be acting on one that is four days old. An entitlement survives that
 * because it changes on the order of a subscription; a run count changes on the order of a run. A
 * runs-left figure with a four-day grace window would be wrong most of the time it was read, and it
 * would be wrong in the direction that matters — showing runs to somebody who has none.
 *
 * So it is a separate, unsigned, uncached read. **Unsigned is right here and would not be right
 * there**: the claim is signed because the *client* enforces it offline, and nothing offline can be
 * enforced about a number that is stale the moment it is stored.
 *
 * ## Not metered, not charged, and rate limited like everything else
 *
 * §11's `route` enum has no value for it and it opens no provider call, so it costs nothing to
 * serve — the same call `routes/entitlements.ts` makes, and for the sharper version of the same
 * reason: charging a user for asking how much they have left would make the question spend the
 * answer. It is authenticated, so it is absent from `PUBLIC_ROUTES` and rate limited with every
 * other authenticated route.
 */
export interface CreditRouteDeps {
  readonly store: CreditStore;
  readonly catalogue: CreditCatalogue;
  /** Tests only. Nothing a deployment sets, the same seam and reason as the entitlement route's. */
  readonly now?: (() => Date) | undefined;
}

export function registerCreditRoutes(app: FastifyInstance, deps: CreditRouteDeps): void {
  const now = deps.now ?? (() => new Date());

  app.get("/v1/account/credits", async (request, reply) => {
    const caller = callerOf(request);
    // One clock read for the whole response, so the period whose draw is counted is the period
    // reported, and the grace window is judged at the same instant both.
    const at = now();
    const facts = await deps.store.factsFor(caller.accountId, at);
    const balance = creditBalance({
      catalogue: deps.catalogue,
      planKey: facts.planKey,
      draw: facts.draw,
      now: at,
    });
    // §2.1 makes the client tolerant of unknown response fields, so this body can grow additively.
    return reply.send({
      plan: balance.plan,
      period_start: balance.periodStart.toISOString(),
      period_end: balance.periodEnd.toISOString(),
      /** The user-facing unit. Everything below it is the derivation that produced it. */
      screen_control_runs_left: balance.runsLeft,
      screen_control_runs_included: balance.runsIncluded,
      /**
       * **Diagnostic, and deliberately not a second thing to show a user.** The ticket's own
       * verification asks the founders to "sanity-check the numbers once measured costs exist", and
       * a runs figure with no visible derivation cannot be sanity-checked at all — the question is
       * always whether the weights or the divisor is what moved it. The rounding in `balance.ts`
       * exists so these four numbers and the run count agree with each other exactly.
       */
      credits: {
        allowance: balance.credits.allowance,
        drawn: balance.credits.drawn,
        remaining: balance.credits.remaining,
        per_run: balance.credits.perRun,
      },
    });
  });
}
