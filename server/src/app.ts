import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.js";
import { registerHealth } from "./routes/health.js";

/** The API minor version this build serves. `Sonny-Api-Version`, contract §2.3. */
export const API_VERSION = "1.0";

/**
 * Builds the server without listening, so tests can exercise routes through `app.inject` rather
 * than over a real socket — no port, no teardown race, and the same code path either way.
 */
export function buildApp(config: Config): FastifyInstance {
  const app = Fastify({
    logger: { level: config.logLevel },
    // The gateway sets its own limits rather than inheriting a platform's -- that is the whole
    // point of the 2026-08-21 move to a VM (decision doc §12.2). The value itself is deliberately
    // NOT set here: contract §6.1 gives each route its own limit, and a server-wide number would
    // either be too small for /v1/screen/analyze's 4,200,000 bytes or far too large for every
    // other route. The routes that carry bodies arrive with their own ticket, and each sets its
    // own. Until then nothing accepts a body at all.
    bodyLimit: 1024 * 1024,
    // Request-log volume is controlled by LOG_LEVEL per environment rather than by Fastify's
    // `disableRequestLogging`, which is deprecated in Fastify 5 and whose replacement --
    // `logController` -- takes a controller class to subclass. Subclassing one to express a
    // preference this server does not yet need would be a workaround; setting the level is the
    // plain equivalent. Request lines are emitted at `info`, so a `warn` level silences them.
    // The ticket that adds a route needing finer control is the one that should reach for
    // `logController`.
    trustProxy: true,
  });

  app.addHook("onSend", async (request, reply, payload) => {
    reply.header("Sonny-Api-Version", API_VERSION);
    reply.header("Sonny-Request-Id", request.id);
    return payload;
  });

  registerHealth(app, config);
  return app;
}
