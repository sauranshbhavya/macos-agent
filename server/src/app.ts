import { randomUUID } from "node:crypto";
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.js";
import { registerErrorHandlers } from "./errors.js";
import { registerHealth } from "./routes/health.js";

/** The API minor version this build serves. `Sonny-Api-Version`, contract §2.3. */
export const API_VERSION = "1.0";

/**
 * Server-wide request body limit, 1 MiB, matching contract §6.1's "every other route".
 *
 * **This is the floor, not the ceiling.** §6.1 gives four routes a larger limit of their own —
 * `/v1/screen/analyze` 4,200,000, `/v1/transcriptions` 10 MiB, `/v1/research/synthesize` 4 MiB —
 * and each sets its own `bodyLimit` on its route definition when the ticket that owns it adds it.
 * A route that forgets to therefore inherits the *smallest* limit and fails loudly at 1 MiB, which
 * is the safe direction: the alternative default would let a route accept far more than its
 * contract allows and discover it in production.
 *
 * The gateway enforces this itself rather than inheriting a platform's, which is what the
 * 2026-08-21 move to a VM makes possible (`docs/sonny-row-12-host-decision.md` §12.2).
 */
export const DEFAULT_BODY_LIMIT_BYTES = 1024 * 1024;

export function buildApp(config: Config): FastifyInstance {
  const app = Fastify({
    logger: { level: config.logLevel },

    /**
     * A real UUID per request, not Fastify's default counter.
     *
     * **Contract §2.3 makes `Sonny-Request-Id` a join key**: "the one string a user could ever be
     * asked to quote for support", linking an error the user saw to the metering event and the
     * retained content. Fastify's default is a per-process counter that restarts at `req-1` on
     * every boot, so across two instances — or one instance before and after a restart — the same
     * id names different requests. A join key that collides is not a join key.
     */
    genReqId: () => randomUUID(),

    bodyLimit: DEFAULT_BODY_LIMIT_BYTES,

    /**
     * Off unless a proxy is actually in front, which is a per-environment fact.
     *
     * `trustProxy: true` makes `request.ip` and `request.protocol` read from `X-Forwarded-For` and
     * `X-Forwarded-Proto` — **headers any caller can set**. With nothing in front of the container
     * that turns the client's own IP into a value the client chooses, which matters the moment
     * anything rate-limits or logs by address. So it comes from configuration and defaults to
     * false; a deployment that really does sit behind a load balancer sets `TRUST_PROXY`.
     */
    trustProxy: config.trustProxy,

    // Request-log volume is controlled by LOG_LEVEL per environment rather than by Fastify's
    // `disableRequestLogging`, which is deprecated in Fastify 5 and whose replacement --
    // `logController` -- takes a controller class to subclass. Subclassing one to express a
    // preference this server does not yet need would be a workaround; setting the level is the
    // plain equivalent. Request lines are emitted at `info`, so a `warn` level silences them.
  });

  app.addHook("onSend", async (request, reply, payload) => {
    reply.header("Sonny-Api-Version", API_VERSION);
    reply.header("Sonny-Request-Id", request.id);
    return payload;
  });

  // Installed before any route, so every route added by a later ticket inherits the contract's
  // error envelope rather than the framework's.
  registerErrorHandlers(app);
  registerHealth(app, config);
  return app;
}
