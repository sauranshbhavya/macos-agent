import { randomUUID } from "node:crypto";
import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import { requireRateLimitSalt, requireSupabaseJwtPolicy, type Config } from "./config.js";
import { registerAuthGate } from "./auth/gate.js";
import { classify, errorBody, registerErrorHandlers } from "./errors.js";
import { registerHealth } from "./routes/health.js";
import { registerAuth, type AuthDeps } from "./routes/auth.js";

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

/**
 * `auth` is optional so a deployment that mounts no auth route needs no provider, no rate-limit salt
 * and no JWT secret. When it is supplied all three are required, and `requireRateLimitSalt` /
 * `requireSupabaseJwtPolicy` refuse at startup rather than letting `bucketKey` hash addresses
 * unsalted, or every protected route refuse every caller, at request time.
 */
export function buildApp(config: Config, auth?: AuthDeps): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      /**
       * Redaction, added before the adapter that would need it exists (PR #87 F11).
       *
       * The real Supabase and Resend adapters raise errors carrying request URLs — which contain
       * the project ref — headers, and response bodies. Fastify logs a request's headers on error
       * by default, and `Authorization` is one of them. Adding this list after those adapters land
       * means the first weeks of logs are the ones that leak, so it goes in now while the list is
       * short enough to reason about.
       */
      redact: {
        paths: [
          "req.headers.authorization",
          "req.headers.cookie",
          'req.headers["sonny-account-id"]',
          "req.body.code",
          "req.body.refresh_token",
          "req.body.email",
          "err.config.headers.Authorization",
          "err.config.url",
          "err.request.url",
          "err.response.data",
        ],
        censor: "[redacted]",
      },
    },

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
     * `X-Forwarded-For` is a header any caller can set, so believing it unconditionally lets a
     * caller choose its own apparent address. Not believing it *at all* behind a load balancer is
     * equally wrong in the other direction: every request then reports the balancer, and the
     * per-source rate limit becomes one global bucket. **A boolean has no safe setting**, so this
     * is a list of trusted proxies from `TRUSTED_PROXIES`, empty by default — Fastify walks the
     * forwarded chain and stops at the first hop not on the list. **Not a hop count**: the parser
     * has never produced one, and this comment's parenthesis said otherwise until the second review
     * round swept the claim out of all three places it lived (PR #87 F3).
     */
    trustProxy: config.trustProxy,

    /**
     * The last door out of the framework's own envelope.
     *
     * `setErrorHandler` and `setNotFoundHandler` cover errors raised *during* routing and
     * handling. A malformed URL is rejected **before** either runs — `GET /v1/%zz` produced
     * `{"error":"Bad Request","code":"FST_ERR_BAD_URL","message":"'/v1/%zz' is not a valid url
     * component","statusCode":400}`, which is Fastify's shape, names a framework error code, and
     * **echoes the offending path back to the caller**. `frameworkErrors` is the hook for that
     * class, and with it every response this server can produce carries contract §7.1's envelope.
     */
    frameworkErrors: (error, request, reply) => {
      const mapped = classify(error);
      request.log.info({ err: error, code: mapped.code }, "request rejected before routing");
      // The reply handed to `frameworkErrors` is generically narrower than a route's, because no
      // route schema has been resolved -- there is no route yet. The cast is to the ordinary
      // reply interface and nothing more; the values sent are the same `ErrorBody` every other
      // handler sends.
      void (reply as unknown as FastifyReply)
        .status(mapped.status)
        .header("Sonny-Api-Version", API_VERSION)
        .header("Sonny-Request-Id", request.id)
        .send(errorBody(mapped.code, mapped.message, request.id, { retryable: mapped.retryable }));
    },

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

  // **And so does the auth gate** (SONNY-203) — installed on THIS instance, the root one, which is
  // what decides which routes it covers.
  //
  // **Not because of registration order**, which this comment used to claim and which PR #104's
  // adversarial review measured as false (F3): against Fastify 5.12.1 a route registered before the
  // gate in the same context is challenged exactly like one registered after it. Coverage is
  // encapsulation — a root-context `onRequest` hook covers every route in this instance and its
  // descendants, and a gate installed inside a plugin would cover only that plugin's subtree while
  // a sibling plugin's routes served unauthenticated. `auth/gate.ts` carries the seven wirings that
  // were measured. The line below is correct for the reason that matters: it is `app`, not a scope.
  //
  // Installed unconditionally, including when no auth is configured: in that shape it refuses every
  // non-public route rather than leaving one open.
  registerAuthGate(
    app,
    auth
      ? {
          policy: requireSupabaseJwtPolicy(config),
          withConnection: auth.withConnection,
          now: auth.now,
        }
      : undefined,
  );

  registerHealth(app, config);
  if (auth) {
    requireRateLimitSalt(config);
    registerAuth(app, config, auth);
  }
  return app;
}
