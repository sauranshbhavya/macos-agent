import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import { meteredRouteFor } from "../metering/event.js";
import { upstreamWasAttempted } from "../metering/hook.js";
import type { EntitlementStore } from "./store.js";

/**
 * "Is this user allowed to do this right now, and have they used more than they are allowed" — as
 * one hook on the root instance, covering every route (SONNY-135).
 *
 * **One app-level set of hooks, never per-route wiring**, which is the fourth time this repository
 * has made that choice and for the same reason each time: `auth/gate.ts` for authentication,
 * `idempotency/hook.ts` for §9.2, `metering/hook.ts` for §11, and now the cap. A route that has to
 * remember to check its own cap is a route where the author who did not think about it ships
 * something that serves correctly, passes its own tests, and is free. Coverage is *encapsulation*
 * rather than registration order — this is installed on the root instance, so every route on it and
 * on its descendants is covered.
 *
 * **What is checked, and where each part lives.** `store.ts`'s `admitRequest` runs the three checks
 * in order — the per-account rate limit, the capability gate, the spend cap — on one connection, and
 * that ordering is policy and is argued there. This file is what turns each outcome into the §7.2
 * answer a client acts on, and what closes the hold on the way out. The split is the same one
 * `auth/gate.ts` and `auth/token.ts` make: the decision in one place, the wire in the other.
 *
 * ## Where it sits, which is load-bearing
 *
 * `preHandler`, registered **after** `registerIdempotency`, so the key's own bookkeeping decides
 * first. That is what keeps a repeat from spending the cap twice: a replayed request and both
 * `409`s are answered inside that hook with `reply.send`, which ends the `preHandler` chain, so this
 * hook never runs for them.
 *
 * The settle is on `onSend`, registered **after** `registerMetering`, so §11's event lands before
 * the charge that cites it. `app.ts` carries the full argument for both positions and what the
 * window between them costs.
 */

/**
 * Which routes require which capability key. **Empty, deliberately, and this is the whole of row
 * 12's answer to "what is gated".**
 *
 * §5.3: "Which capabilities are gated is row 18's (SONNY-23), not this contract's — this contract
 * fixes only that they are named strings in a list the client reads." This ticket's never-touch list
 * says the same thing in stronger terms: it "must not decide that screen control is gated — it must
 * make it possible to gate it". Under the 2026-08-16 pricing shape screen control is the paid line,
 * and wiring that gate is still row 18's.
 *
 * So the map is empty, `theGatedRouteSetIsEmptyAndBelongsToRowEighteen` asserts that it is, and the
 * 403 path below is driven in tests through the injectable override rather than by gating a real
 * route here. An entry added here is a product decision and belongs to SONNY-23.
 */
export const CAPABILITY_REQUIRED: ReadonlyMap<string, string> = new Map();

export interface EntitlementDeps {
  readonly store: EntitlementStore;
  /** `SPEND_CAP_UNITS`, for an account whose entitlement row names no cap of its own. */
  readonly defaultCapUnits: number;
  readonly rateLimitSalt: string;
  /** Tests only. Nothing a deployment sets, the same seam and reason as the gate's. */
  readonly now?: (() => Date) | undefined;
  /** Tests only: drives the 403 path without gating a real route. See `CAPABILITY_REQUIRED`. */
  readonly requiredCapabilities?: ReadonlyMap<string, string> | undefined;
}

/** The hold this request is carrying, so the response path can close it. */
interface SpendHold {
  readonly reservationId: string;
  settled: boolean;
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set when this request took a hold against the spend cap; `null` otherwise. */
    spendHold: SpendHold | null;
  }
}

export function registerEntitlement(app: FastifyInstance, deps?: EntitlementDeps): void {
  const now = deps?.now ?? (() => new Date());
  const gated = deps?.requiredCapabilities ?? CAPABILITY_REQUIRED;
  app.decorateRequest("spendHold", null);

  /**
   * Close this request's hold, at most once.
   *
   * **Charged when a provider call was opened, released when none was.** That is the honest split: a
   * request refused at validation, or one that met a route with no configured adapter, cost this
   * gateway nothing and must not spend the user's period; a request that reached a vendor may have
   * been billed by that vendor whatever this gateway answered afterwards.
   *
   * **A caller who disconnects mid-handler is charged, and that is §12's own rule** — "silently free
   * cancellations would be a hole in the spend cap". `onSend` never runs for such a request, so the
   * response's `close` event is a second writer with the `settled` flag between them, which is the
   * same pair and the same flag `metering/hook.ts` uses for the same shape.
   */
  async function closeHold(request: FastifyRequest): Promise<void> {
    const hold = request.spendHold;
    if (hold === null || hold.settled || !deps) return;
    hold.settled = true;
    try {
      await deps.store.settle(hold.reservationId, upstreamWasAttempted(request));
    } catch (error) {
      // **A settle that fails never fails the response**, the same call `metering/hook.ts` and
      // `idempotency/hook.ts` make and for the same reason: the handler has already done its work,
      // possibly an upstream call that cost money, and turning that into a 500 would be the worst of
      // both. What is lost is bounded rather than permanent — the hold sits unsettled and the sweep
      // reclaims it once it expires, so the account is briefly held against its own cap and is never
      // over-charged.
      request.log.error(
        { err: error, reservationId: hold.reservationId, requestId: request.id },
        "spend-cap reservation could not be settled; the sweep will reclaim it",
      );
    }
  }

  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    // The second writer, attached before anything can take a hold. See `closeHold`.
    reply.raw.on("close", () => {
      void closeHold(request);
    });
  });

  app.addHook("preHandler", async (request: FastifyRequest, reply: FastifyReply) => {
    const routeUrl = request.routeOptions.url;
    // No route matched. The not-found handler owns the answer — the same guard, and the same
    // reason, as the gate's, the idempotency hook's and the metering hook's.
    if (routeUrl === undefined) return;
    // A public route has no account to check anything against. `auth/gate.ts` has already refused
    // every non-public route that reached here without one, so `null` here means public.
    const caller = request.auth;
    if (caller === null) return;

    if (!deps) {
      // **Unreachable on every deployment this repository builds**, and said plainly rather than
      // dressed up as a prevented failure: this branch needs an authenticated caller, and a
      // deployment with no `auth` has no database, mounts no auth route, and `registerAuthGate`
      // answers 401 to every other route before this hook runs. It refuses rather than serving
      // anyway, because what it is guarding is money.
      request.log.error(
        { route: `${request.method} ${routeUrl}` },
        "authenticated route reached with no entitlement store configured; refusing",
      );
      return reply.status(503).send(
        errorBody("server.unavailable", "Entitlement checks are not available.", request.id, {
          retryable: true,
        }),
      );
    }

    const outcome = await deps.store.admit({
      accountId: caller.accountId,
      requiredCapability: gated.get(`${request.method} ${routeUrl}`),
      metered: meteredRouteFor(request.method, routeUrl) !== undefined,
      defaultCapUnits: deps.defaultCapUnits,
      rateLimitSalt: deps.rateLimitSalt,
      now: now(),
    });
    const route = `${request.method} ${routeUrl}`;

    switch (outcome.kind) {
      case "rate_limited":
        request.log.info({ route }, "account rate limit reached");
        // §7.2 case 3: retryable, **with** a `Retry-After`, because waiting really does fix it.
        return reply
          .status(429)
          .header("Retry-After", String(outcome.retryAfterSeconds))
          .send(
            errorBody("limit.rate", "Too many requests for this account.", request.id, {
              retryable: true,
              retryAfterSeconds: outcome.retryAfterSeconds,
            }),
          );
      case "not_entitled":
        request.log.info({ route, capability: outcome.capability }, "account is not entitled");
        // §7.2 case 2. Not retryable: a second attempt produces the identical answer, and the
        // client's stated behaviour is to refuse locally rather than retry.
        return reply.status(403).send(
          errorBody("entitlement.required", "This account is not entitled to this.", request.id),
        );
      case "over_cap":
        request.log.info({ route, capUnits: outcome.capUnits }, "account is over its spend cap");
        // §7.2 case 3a. **No `Retry-After`**, and the contract is explicit about why: "waiting
        // seconds does not fix it". `retryable: false` for the same reason — the client refuses
        // locally rather than backing off.
        return reply.status(429).send(
          errorBody(
            "limit.spend",
            "This account is over its spend cap for this period.",
            request.id,
          ),
        );
      case "admitted":
        if (outcome.reservationId !== undefined) {
          request.spendHold = { reservationId: outcome.reservationId, settled: false };
        }
        return undefined;
    }
  });

  app.addHook("onSend", async (request: FastifyRequest, _reply: FastifyReply, payload: unknown) => {
    await closeHold(request);
    return payload;
  });
}
