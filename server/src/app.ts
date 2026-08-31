import { randomUUID } from "node:crypto";
import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import {
  requireEntitlementSigningKey,
  requireRateLimitSalt,
  requireSpendCapUnits,
  requireSupabaseJwtPolicy,
  type Config,
} from "./config.js";
import { registerEntitlement } from "./entitlement/hook.js";
import { postgresEntitlementStore, type EntitlementStore } from "./entitlement/store.js";
import { registerEntitlementRoutes } from "./routes/entitlements.js";
import { registerAuthGate } from "./auth/gate.js";
import { classify, errorBody, registerErrorHandlers } from "./errors.js";
import { registerHealth } from "./routes/health.js";
import { registerIdempotency } from "./idempotency/hook.js";
import { postgresKeyStore, type KeyStore } from "./idempotency/store.js";
import { registerMetering } from "./metering/hook.js";
import { postgresMeteringStore, type MeteringStore } from "./metering/store.js";
import { registerAuth, type AuthDeps } from "./routes/auth.js";
import { registerContent } from "./content/hook.js";
import { postgresContentStore, type ContentStore } from "./content/store.js";
import { registerTaskRoutes } from "./routes/tasks.js";
import fastifyMultipart from "@fastify/multipart";
import { BODY_LIMIT_BYTES } from "./model/limits.js";
import { describeRouting, modelProvidersFrom } from "./model/providers.js";
import { registerModelRoutes } from "./routes/model.js";
import { visionProviderFrom } from "./model/vision.js";
import { registerScreenRoutes } from "./routes/screen.js";
import { billingDepsFrom } from "./billing/deps.js";
import { postgresBillingStore, type BillingStore } from "./billing/store.js";
import { registerBillingRoutes } from "./routes/billing.js";

/** The API minor version this build serves. `Sonny-Api-Version`, contract §2.3. */
export const API_VERSION = "1.0";

/**
 * Server-wide request body limit, 1 MiB, matching contract §6.1's "every other route".
 *
 * **This is the floor, not the ceiling.** §6.1 gives three routes a larger limit of their own —
 * `/v1/screen/analyze` 4,200,000, `/v1/transcriptions` 10 MiB, `/v1/research/synthesize` 4 MiB —
 * and each sets its own `bodyLimit` on its route definition. A route that forgets to therefore
 * inherits the *smallest* limit and fails loudly at 1 MiB, which is the safe direction: the
 * alternative default would let a route accept far more than its contract allows and discover it in
 * production.
 *
 * All three exist now: SONNY-130 added the second and third, SONNY-131 the first. **This said "four
 * routes" and then listed three**, because §6.1's table has four rows and the fourth is "every other
 * route" at 1 MiB — which is this constant, not a route with a larger limit of its own.
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
/**
/**
 * Seams a test may replace, and nothing a deployment sets.
 *
 * **Two fields, added by two branches for the same reason, kept as one type.** SONNY-300 added the
 * first and SONNY-132 arrived with a second of its own, `BuildAppOptions`; two parallel
 * test-seam parameters on one function is the shape where the next ticket adds a third, so they are
 * one type here rather than one each.
 *
 * **`idempotencyStore` exists so the flagged `npm test` can cover contract §9.2 at all** (SONNY-300).
 * The idempotency store is Postgres, and a database-backed test runs only when `DATABASE_URL` is
 * set — which `npm test` deliberately does not do. Without this seam every behaviour §9.2 names
 * would be verified only in `npm run test:db`, so the run this repository gates on would be silent
 * about the guarantee that stops a retry double-billing a user. With it, those tests drive the whole
 * real app — the gate, the account scope, the error envelope, the routes — against a store the test
 * controls, and `idempotency.db.test.ts` proves the SQL underneath separately.
 *
 * **`meteringStore` exists for exactly the reason `idempotencyStore` does** (SONNY-133). Contract
 * §11's event is a Postgres row, so without a seam every behaviour §11 names — the per-route field
 * values, the incognito case, the retry that must not double-count — would be verified only in
 * `npm run test:db`, and the run this repository gates on would be silent about what every call
 * costs. With it those tests drive the whole real app and assert the event a client's request
 * actually produced; `metering.db.test.ts` proves the SQL and the at-most-once claim underneath.
 *
 * **`logStream` exists because two behaviours were unpinned** (SONNY-132, PR #143's F3). A mutation
 * battery on the provider router killed nineteen of twenty mutants; the three that survived were all
 * on the *recording* half — `recordServingProvider` gutted, the provider it records hard-coded, and
 * the `model routing` line deleted from this function. SONNY-132's third acceptance criterion is
 * that "the recorded metering says which provider actually served it", and the startup line is what
 * all four `deploy.sh` demonstrations and the founder's manual row 7 read. Neither could be asserted
 * because pino writes to fd 1 through `sonic-boom`, which `process.stdout.write` never sees.
 *
 * The same seam and the same reason as `PoolOptions.createPool` and `SupabaseAuthConfig.fetch`.
 * Both are absent in every shipping path, so nothing a deployment does changes.
 */
export interface AppOverrides {
  readonly idempotencyStore?: KeyStore;
  readonly meteringStore?: MeteringStore;
  readonly logStream?: NodeJS.WritableStream;
  /**
   * **`contentStore` exists for the third time and the same reason** (SONNY-134). Contract §10's
   * store is Postgres, so without a seam every behaviour §10.1 names — an incognito run leaving
   * nothing anywhere, a request that declared no `retention` storing nothing, voice audio and a
   * provider's error body landing on the content clock — would be verified only in
   * `npm run test:db`, and the run this repository gates on would be silent about the guarantee
   * that a run marked "Don't save this task" is never stored. With it those tests drive the whole
   * real app and assert what a client's request actually retained; `content.db.test.ts` proves the
   * SQL, the clock and the structural exclusions underneath.
   */
  readonly contentStore?: ContentStore;
  /**
   * **`entitlementStore` exists for the fourth time and the fourth identical reason** (SONNY-135).
   * The cap's counter is Postgres, so without a seam every behaviour this ticket is about *except*
   * the race itself — which refusal each state produces, whether a hold is charged or released,
   * that a replay takes no hold, that a free capability never asks — would be verified only in
   * `npm run test:db`, and the run this repository gates on would be silent about the check that
   * decides whether a user can do anything at all. `entitlement.db.test.ts` proves the SQL and the
   * race underneath, against a real Postgres, because a race against a fake proves nothing.
   */
  readonly entitlementStore?: EntitlementStore;
  /**
   * **`billingStore` exists for the fifth time and the fifth identical reason** (SONNY-211). The
   * subscription state is Postgres, so without a seam every behaviour this ticket is about — a
   * signed delivery moving the entitlement to paid, a cancellation revoking it, a payment failure
   * opening a grace window, a replay changing nothing, a customer this gateway cannot place granting
   * nothing — would be verified only under `npm run test:db`, and the run this repository gates on
   * would be silent about the route that grants paid entitlements. `billing.db.test.ts` proves the
   * SQL, the replay bound and the out-of-order refusal underneath, against a real Postgres.
   */
  readonly billingStore?: BillingStore;
}

export function buildApp(
  config: Config,
  auth?: AuthDeps,
  overrides: AppOverrides = {},
): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      ...(overrides.logStream === undefined ? {} : { stream: overrides.logStream }),
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

  /**
   * Contract §9's `Idempotency-Key`, on THIS instance for the same reason the gate is (SONNY-300).
   *
   * A `preHandler`/`onSend` pair covering every `POST` this instance and its descendants serve, so
   * the routes SONNY-131 and SONNY-132 are adding inherit §9.2's guarantees by existing rather than
   * by each remembering to wire them. Coverage is encapsulation, not registration order —
   * `auth/gate.ts` carries the seven wirings that were measured, and the conclusion is the same one
   * here: what matters is that this is `app` and not a scope.
   *
   * Takes the same `withConnection` the gate takes, and answers `undefined` for a health-only
   * deployment, which has no database and — because `registerAuthGate` refuses every non-public
   * route — no reachable `POST` for the store to protect.
   */
  const idempotencyStore =
    overrides.idempotencyStore ??
    (auth ? postgresKeyStore(auth.withConnection) : undefined);
  registerIdempotency(app, idempotencyStore ? { store: idempotencyStore } : undefined);

  /**
   * Contract §11's metering event, on THIS instance for the third time and the same reason
   * (SONNY-133).
   *
   * **Registered after the idempotency hook, and this time the order really is load-bearing.**
   * Fastify runs `onSend` hooks in registration order, and both modules have one: the idempotency
   * hook's stores or releases the key's response, and this one writes the metering event and reads
   * `request.idempotency` to decide whether this request may spend the key's one metering claim — a
   * replay and a `409` wrote nothing and must not take a claim from the request that did the work.
   * That state is set in `preHandler`, so it is there either way; what this line's position decides
   * is that the key's own bookkeeping settles before the event that cites it is written.
   *
   * **A window between the two survives, it loses money rather than duplicating it, and this branch
   * chose the order on readability after reversing `onResponse` on exactly that criterion** — so it
   * is written down here rather than left for the next session to re-derive (PR #147's review, F6).
   * Both directions traced:
   *
   * - **As built** — the key completes, then the event is written. A process killed between the two
   *   leaves a `completed` key row with a stored response and `metering_claimed_at` still NULL. The
   *   client's retry replays that stored response, so `ClaimState` is `replayed` and the metering
   *   hook returns without asking the store. The provider call was paid for and is **never metered,
   *   ever**.
   * - **Reversed** — the event is written, then the key completes. A kill between them leaves an
   *   event and a key still `in_flight`; the lease expires, the retry genuinely re-runs and calls
   *   the provider a second time, and its claim is already taken so the second call goes unbilled.
   *   The first call *is* recorded.
   *
   * So neither order is free, and the reversed one loses less. **It is not changed here**, because
   * the window is one database round trip wide and strictly narrower than the `onResponse` window
   * this branch already removed — the change would be trading a known small residual for a reordering
   * whose own failure mode (a re-run the gateway pays for and does not record) is not obviously
   * better, and the ticket that has to weigh that is the one that owns the spend cap.
   *
   * **What the single transaction in `writeMeteringEvent` does and does not close**, since it is easy
   * to read as covering this. It closes claim-versus-insert: the claim cannot be taken without the
   * event landing, which is the direction that would lose an event permanently. It cannot close the
   * gap above, because the key's completion and the metering write are two transactions on two
   * connections by construction — `KeyStore` and `MeteringStore` each lease their own — and merging
   * them would put the metering write inside the key store's transaction, which is the coupling
   * SONNY-300's seam exists to avoid.
   *
   * **The gate's `onRequest` runs before both**, because it is registered before both, which is
   * what makes `request.auth` available by the time the event is built.
   *
   * Takes the same `withConnection` the gate and the key store take, and answers `undefined` for a
   * health-only deployment — which has no database, and no metered route it could reach either,
   * since every one of the five is authenticated.
   */
  const meteringStore =
    overrides.meteringStore ?? (auth ? postgresMeteringStore(auth.withConnection) : undefined);
  registerMetering(app, config, meteringStore ? { store: meteringStore } : undefined);

  /**
   * Contract §10's content store, on THIS instance for the fourth time and the same reason
   * (SONNY-134).
   *
   * **Registered after the metering hook, and the order carries one real consequence.** Fastify runs
   * `onSend` hooks in registration order and both modules have one, so this captures the payload the
   * client is actually being sent — after the idempotency hook has stored or released it and after
   * metering has measured it. The *write* is not in `onSend` at all: it is in `onResponse`, after the
   * response has left, which is the deliberate opposite of the call metering makes about its own
   * write. `content/hook.ts` carries both halves of that reasoning — what is lost differs in kind
   * (money against a debugging copy), and what it costs differs by three orders of magnitude (a row
   * of integers against a megabyte screenshot, twelve times a screen-control session).
   *
   * **Nothing here consults `retention` and nothing here needs to.** §10.1 puts the guarantee at the
   * storage layer, so the hook refuses before it reads a body and the table refuses under it. This
   * line's only job is that the hook is installed on `app` and not on a scope, which is the same
   * property the gate, the key store and the metering hook each depend on.
   *
   * Takes the same `withConnection` the other three take, and answers `undefined` for a health-only
   * deployment — which has no database, and no content-bearing route it could reach either, since
   * every one of the five is authenticated.
   */
  const contentStore =
    overrides.contentStore ?? (auth ? postgresContentStore(auth.withConnection) : undefined);
  registerContent(app, config, contentStore ? { store: contentStore } : undefined);

  /**
   * `DELETE /v1/tasks/{task_id}` (SONNY-134), contract §4.6 — the user's own delete reaching the
   * server's copy.
   *
   * Mounted here rather than beside the auth routes below because it is not an auth route and does
   * not want that block's `if (auth)` gate: `app.ts`'s standing argument is that the route table
   * must not change shape with the environment. It is a `DELETE`, so it passes through neither the
   * idempotency hook nor the metering hook — both are `POST`-only — which is why nothing about
   * metering's shape changes on this branch.
   */
  registerTaskRoutes(app, auth ? { withConnection: auth.withConnection } : undefined);

  /**
   * `POST /v1/transcriptions` is the one route with a `multipart/form-data` body (contract §4.4),
   * so the parser is registered here, on the root instance, beside the routes that need it.
   *
   * **`limits` is not decoration beside the route's `bodyLimit`.** `bodyLimit` bounds the request;
   * `fileSize` bounds one part, and it is the one that fires while the part is still streaming
   * rather than after a body has been assembled. `files: 1` and `fields: 1` say what §4.4's body is
   * — one file part and one JSON field — so a body carrying more is refused rather than partly
   * ignored, which is the direction a forgotten decision should fail in.
   */
  void app.register(fastifyMultipart, {
    limits: {
      fileSize: BODY_LIMIT_BYTES.transcriptions,
      files: 1,
      fields: 1,
      parts: 2,
    },
  });

  /**
   * Mounted unconditionally, including where no provider credential is configured (SONNY-130).
   *
   * The route table then does not change shape with the environment, which matters because the
   * alternative is a `404 resource.not_found` — a code the client reads as "no such route", not
   * retryable — standing in for a deployment that is simply missing a key. A configured route with
   * no adapter answers `502 provider.unavailable` instead, which is true from the caller's side.
   * The gate covers all four by not listing them in `PUBLIC_ROUTES`, so on a deployment with no
   * `auth` — a health-only one, which is what `./scripts/deploy.sh local` starts today — every one
   * of them refuses with a 401 rather than serving.
   */
  registerModelRoutes(app, modelProvidersFrom(config));

  /**
   * `POST /v1/screen/analyze` (SONNY-131), mounted on the same terms and for the same reasons.
   *
   * Its provider comes from `model/vision.ts` rather than from `modelProvidersFrom` above.
   *
   * **That was written as a lane boundary that would end when SONNY-132 landed — "the two collapse
   * when that one lands" — and SONNY-132 has now landed without collapsing them.** Nothing forced
   * the collapse: this route reads no `ModelProviders` field, exactly as that comment predicted, so
   * the provider router grew `plan`, `synthesize`, `transcriptions` and `search` chains and left
   * this route untouched. Collapsing it is a real and probably worthwhile change — a
   * `MODEL_ROUTE_SCREEN_ANALYZE` chain would give the vision route the same failover and the same
   * per-provider retention policy the other four now have, which is precisely what SONNY-110 needs
   * of it — but the vision route and `VisionModelClient` are on SONNY-132's never-touch list, so it
   * is not that branch's to take. Whoever owns it next starts here.
   */
  registerScreenRoutes(app, visionProviderFrom(config));

  // **What this deployment's routing actually resolved to, printed once** (SONNY-132). Which
  // provider serves which route is configuration now, and per-provider retention/training terms are
  // configuration that nothing routes on until SONNY-110 answers — so both are said out loud at
  // startup, where an operator can see what the container was told rather than inferring it from
  // which requests succeed. `describeRouting` carries provider names, policy words and a boolean
  // per credential, and never a key. It describes the four routes the router owns; the vision route
  // above is not among them, for the reason its own comment gives.
  app.log.info(describeRouting(config), "model routing");

  /**
   * Contract §5.3's entitlement check and §7.2's `limit.*` and `entitlement.*` refusals, on THIS
   * instance for the fourth time and the same reason (SONNY-135).
   *
   * **Registered after the metering hook, and both of its positions are load-bearing.** Fastify runs
   * hooks of one kind in registration order, and this module has a `preHandler` and an `onSend`:
   *
   * - Its **`preHandler` runs after the idempotency hook's**, which is what stops a repeat spending
   *   the cap twice. A replay and both `409`s are answered from inside that hook with `reply.send`,
   *   which ends the `preHandler` chain — so this hook does not run for them at all, and the request
   *   that really does the work is the only one that takes a hold.
   * - Its **`onSend` runs after the metering hook's**, so §11's event is written before the charge
   *   that cites it. That is the property the host decision's "same transaction as the metering
   *   event" was after — *a charge cannot exist without its audit row* — reached by ordering rather
   *   than by coupling, because `MeteringStore` and `EntitlementStore` lease their own connections
   *   by construction and merging their transactions is the coupling SONNY-300's seam exists to
   *   avoid.
   *
   * **What the window between them costs, traced rather than asserted**, since PR #147's F6 left
   * exactly this weighing to "the ticket that owns the spend cap". A process killed between the
   * metering write and the settle leaves an event and an **unsettled hold**. The hold is not lost:
   * `expires_at` is 300 seconds out and `sweepExpiredReservations` reclaims it, so the
   * account is briefly held against its own cap and is never over-charged, and the audit row that
   * says the call happened is already on disk. The reverse order would leave a *charge* with no
   * event — money moved with nothing recording what moved it, which is the direction this whole row
   * exists to close.
   */
  const entitlementStore =
    overrides.entitlementStore ?? (auth ? postgresEntitlementStore(auth.withConnection) : undefined);
  registerEntitlement(
    app,
    auth && entitlementStore
      ? {
          store: entitlementStore,
          defaultCapUnits: requireSpendCapUnits(config),
          rateLimitSalt: requireRateLimitSalt(config),
          now: auth.now,
        }
      : undefined,
  );

  /**
   * The subscription webhook and the checkout link (SONNY-211).
   *
   * **Mounted on `BILLING_PROVIDER` rather than on `auth`**, so a deployment that does no billing
   * carries no webhook endpoint at all — unlike the model routes above, which mount unconditionally
   * because a missing credential there should read as `502` rather than `404`. The argument
   * inverts here: an unmounted billing endpoint is not a degraded service, it is a gateway that was
   * never told to take payments, and mounting a signature-checked endpoint whose secret is a
   * placeholder would be a route that refuses everything while looking configured.
   *
   * `billingDepsFrom` refuses at startup when a provider is named and its secret, its checkout link
   * or its plan map is not, which is `config.ts`'s standing property: a missing credential is a
   * startup failure with a named variable.
   */
  const billing = billingDepsFrom(config);
  const billingStore =
    overrides.billingStore ?? (auth ? postgresBillingStore(auth.withConnection) : undefined);
  if (billing && billingStore) {
    registerBillingRoutes(app, {
      provider: billing.provider,
      store: billingStore,
      plans: billing.plans,
      graceMilliseconds: billing.graceMilliseconds,
      now: auth?.now,
    });
  }

  if (auth) {
    requireRateLimitSalt(config);
    registerAuth(app, config, auth);
    /**
     * `GET /v1/account/entitlements`, mounted with the auth routes because it is the one route that
     * needs a signing key, and `requireEntitlementSigningKey` refuses at startup rather than letting
     * it answer an error on the first real request.
     *
     * **`entitlementStore` is non-null in this branch by construction** — it is built from `auth`
     * three lines above — and the `if` is what tells the compiler so rather than a non-null
     * assertion, which would be a claim instead of a check.
     */
    if (entitlementStore) {
      registerEntitlementRoutes(app, {
        store: entitlementStore,
        signingKey: requireEntitlementSigningKey(config),
        now: auth.now,
      });
    }
  }
  return app;
}
