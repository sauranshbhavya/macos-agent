import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import type { WithConnection } from "../db/connection.js";
import { accountForSupabaseUser } from "./attribution.js";
import { verifyAccessToken, type SupabaseJwtPolicy, type TokenRefusal } from "./token.js";

/**
 * The gate that decides whether a request is authenticated at all (SONNY-203).
 *
 * **Deny by default.** One `onRequest` hook covers every route this server has or will have, and a
 * route is public only by appearing in `PUBLIC_ROUTES` below. The alternative — each route opting
 * *in* to authentication — has one failure mode, and it is silent: a route added by a later ticket
 * whose author does not think about auth is wide open, serves correctly, passes its own tests, and
 * looks exactly like a route that was considered. Deny-by-default inverts that. A route added
 * without thought answers `401` to everyone including its author, which is a failure nobody can
 * ship past. It is the same reasoning `app.ts` gives for `DEFAULT_BODY_LIMIT_BYTES` being the
 * smallest limit rather than the largest: the direction a forgotten decision fails in is the whole
 * design.
 *
 * **What is checked, in order, and where each part lives.** `token.ts` verifies the token itself —
 * HS256 pinned, signature, `iss`, `aud`, `nbf`, `exp` against `clock.ts`'s one-directional
 * tolerance. This file then answers the question the token cannot: which Sonny account, if any, that
 * provider-side user is. Both have to pass. A cryptographically perfect token naming a closed
 * account is refused here.
 *
 * **Two properties a reviewer will ask about, answered here rather than left to be inferred.** The
 * hook runs before the body is parsed, so an unauthenticated request is refused without this server
 * reading the payload it was carrying. And the connection attribution takes is released before the
 * handler runs — `withConnection` returns it on the way out — so a protected request checks a
 * connection out twice in sequence and never holds two at once, which is what keeps a small pool
 * from deadlocking against itself.
 *
 * **What an unauthenticated caller can still learn is the route table**, because a path that exists
 * answers 401 while one that does not answers 404. That is deliberate: §4.1 of the API contract
 * publishes the route table, so the distinction discloses nothing that is not already written down,
 * and collapsing 404 into 401 would make every client's "no such route" indistinguishable from
 * "sign in again".
 *
 * **The residual, stated rather than papered over.** A Supabase access token is self-contained, so
 * this gateway can verify it without asking the provider — which is the point — and equally cannot
 * un-issue one. Signing out revokes the *refresh* family at the provider; an access token already in
 * the user's hands stays valid until its own `exp` **plus `EXPIRY_SKEW_TOLERANCE_SECONDS`** — one
 * hour on Supabase's default, and thirty seconds more than that here. The tolerance is deliberate
 * and `clock.ts` argues for it; naming `exp` alone would understate the window this gate leaves
 * open by exactly the amount this gate itself adds (PR #104's adversarial review, F9). What
 * this gate does cover is the account: `DELETE /v1/account` closes it, and every subsequent request
 * with any token naming it is refused on the attribution step below, immediately. Closing the
 * remaining window means a denylist of revoked sessions consulted per request, which is a table, a
 * migration and a dependency on Supabase's `session_id` claim — filed rather than built here, and
 * recorded in `server/README.md`.
 */

/**
 * The routes that carry no `Authorization` header, taken from the contract's §4.1 `Auth` column,
 * which §2.2 names as the single source of truth for that question.
 *
 * Three of these have no handler yet — `GET /v1/meta` (SONNY-155), and the two OAuth routes
 * (SONNY-129). They are listed because this list answers "is this route public", not "does this
 * route exist": an entry for a route nobody has written matches nothing, while an entry *missing*
 * when its ticket lands means a public sign-in route that answers 401 to the person who cannot yet
 * have a token. `POST /v1/auth/refresh` is the subtle one and the contract explains it: it
 * authenticates with the refresh token in its body and deliberately sends no header, so that an
 * expired or missing access token can never be the reason a refresh fails.
 *
 * Method and path together, because `DELETE /v1/account` and a future `GET /v1/account` are not the
 * same question.
 */
export const PUBLIC_ROUTES: ReadonlySet<string> = new Set([
  "GET /v1/meta",
  "GET /v1/health",
  "POST /v1/auth/email/start",
  "POST /v1/auth/email/verify",
  "POST /v1/auth/oauth/google",
  "POST /v1/auth/oauth/apple",
  "POST /v1/auth/refresh",
  // **Not public in the sense the six above are: authenticated, by a different mechanism.** The
  // payment provider signs each delivery with an HMAC over the exact request bytes and holds no
  // Supabase token to send, so this gateway cannot challenge it here — `routes/billing.ts` verifies
  // the signature before it reads a byte of the payload, and refuses with 401 when it fails. It is
  // named in this list because the list is derived from the contract's §4.1 `Auth` column and that
  // column now carries the route, with the mechanism in the cell rather than `none` (SONNY-211).
  "POST /v1/billing/webhook",
]);

/**
 * **`HEAD` is judged as the `GET` it mirrors.** Fastify generates a `HEAD` route for every `GET` one
 * (`exposeHeadRoutes`, on by default), so `HEAD /v1/health` is a real route whose method is not
 * `GET` — and a liveness probe using `HEAD`, which is what several of them do, would otherwise meet
 * a 401 from a route the contract calls unauthenticated.
 */
export function isPublicRoute(method: string, routeUrl: string): boolean {
  const effective = method === "HEAD" ? "GET" : method;
  return PUBLIC_ROUTES.has(`${effective} ${routeUrl}`);
}

/** Who the caller is, derived server-side from the verified token. Never from a request field. */
export interface AuthenticatedCaller {
  readonly accountId: string;
  /** The verified `sub`. Kept for the routes that talk to the provider about this user. */
  readonly supabaseUserId: string;
  /**
   * The raw access token, for the one thing a route legitimately does with it: hand it back to the
   * provider. `POST /v1/auth/signout` is that route.
   */
  readonly accessToken: string;
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set by the gate on every authenticated route; `null` on a public one. */
    auth: AuthenticatedCaller | null;
  }
}

/**
 * The caller on a protected route, or a thrown error.
 *
 * A route reached with `request.auth` unset is a route the gate did not run for, which can only mean
 * it was added to `PUBLIC_ROUTES` by mistake. That is a programming error rather than a request
 * error, so it throws and becomes a 500 — the loud answer — instead of quietly acting for nobody.
 */
export function callerOf(request: FastifyRequest): AuthenticatedCaller {
  if (!request.auth) {
    throw new Error(
      `${request.method} ${request.routeOptions.url ?? request.url} ran without an authenticated ` +
        "caller: it is listed as public in PUBLIC_ROUTES but reads the caller's account",
    );
  }
  return request.auth;
}

/**
 * Contract §7.2's codes, one per refusal.
 *
 * Only `expired` becomes `auth.token_expired`, and that split is the client's whole behaviour: §3.3
 * makes `auth.token_expired` the one 401 a client answers by refreshing once and retrying once,
 * while `auth.unauthenticated` sends the user to sign-in. Mapping a forged or misaddressed token to
 * `token_expired` would put every such client into a refresh loop; mapping a genuinely expired one
 * to `unauthenticated` would sign a user out mid-session for a token that was working a second ago.
 */
const REFUSAL_CODE: Record<TokenRefusal, string> = {
  malformed: "auth.unauthenticated",
  algorithm: "auth.unauthenticated",
  signature: "auth.unauthenticated",
  issuer: "auth.unauthenticated",
  audience: "auth.unauthenticated",
  subject: "auth.unauthenticated",
  not_yet_valid: "auth.unauthenticated",
  expired: "auth.token_expired",
};

export interface GateDeps {
  readonly policy: SupabaseJwtPolicy;
  readonly withConnection: WithConnection;
  readonly now?: (() => Date) | undefined;
}

/**
 * Install the gate **on the root instance**, which is what decides its coverage.
 *
 * **The rule is encapsulation, not registration order, and this docstring said the opposite** (PR
 * #104's adversarial review, F3). It claimed Fastify resolves a route's hook chain when the route is
 * added, so a hook added afterwards misses it. Measured against Fastify 5.12.1, that is not what
 * happens — a route registered *before* `registerAuthGate` in the same context is still challenged.
 * What actually decides coverage is where the hook lives: an `onRequest` hook added to a context
 * covers every route in that context and its descendants, whenever they were added, and covers
 * nothing outside it.
 *
 * Seven wirings, each answered by a `POST /v1/plan` with no token (`401` = the gate ran):
 *
 * | wiring                                            | result |
 * |---------------------------------------------------|--------|
 * | route at root, registered BEFORE the gate          | 401    |
 * | route at root, registered AFTER the gate           | 401    |
 * | plugin registered before the gate, awaited         | 401    |
 * | plugin registered before the gate, not awaited     | 401    |
 * | gate at root, route inside a plugin afterwards     | 401    |
 * | **gate inside a plugin, route at root afterwards** | **200**|
 * | **gate in plugin 1, route in a SIBLING plugin 2**  | **200**|
 *
 * **So the thing to get right is the context, and the wrong rule was the dangerous one to believe**:
 * a later ticket that carefully registers its routes after the gate — and wraps either of them in a
 * plugin for encapsulation — obeys the sentence that used to be here and ships an unauthenticated
 * route anyway. `app.ts` calls this on the root instance, before the routes, and only the first half
 * of that is load-bearing. `theGateCoversARouteRegisteredBeforeIt` and its sibling in
 * `gate.test.ts` pin both halves so the table above is executable rather than remembered.
 *
 * `deps` is optional so a deployment that mounts no authenticated route needs no JWT secret and no
 * database. When it is absent the gate is still installed and still refuses: a protected route
 * reached by a process with no way to authenticate anyone answers 401 and logs an error, rather than
 * serving. There is no configuration of this server in which a protected route is open.
 */
export function registerAuthGate(app: FastifyInstance, deps?: GateDeps): void {
  const now = deps?.now ?? (() => new Date());
  app.decorateRequest("auth", null);

  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    // No route matched. The not-found handler owns the answer, and a 404 that became a 401 would
    // change what an unauthenticated caller learns about paths that do not exist — for the worse in
    // both directions, since it is neither true nor useful.
    const routeUrl = request.routeOptions.url;
    if (routeUrl === undefined) return;
    if (isPublicRoute(request.method, routeUrl)) return;

    if (!deps) {
      request.log.error(
        { route: `${request.method} ${routeUrl}` },
        "protected route reached with no authentication configured; refusing",
      );
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "Authentication is not available.", request.id),
      );
    }

    const presented = bearerToken(request.headers.authorization);
    if (presented === undefined) {
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "A bearer token is required.", request.id),
      );
    }

    const verdict = verifyAccessToken(presented, deps.policy, now());
    if (!verdict.ok) {
      // **The reason is logged and never returned.** A caller learns that the token was refused and
      // whether refreshing would help; it does not learn *which* check refused it. Answering
      // "wrong audience" to one forgery and "bad signature" to another turns this endpoint into a
      // tool for tuning the next attempt — the same reasoning §3.6 applies to the sign-in routes'
      // uniform answers, one layer up.
      request.log.info(
        { refusal: verdict.refusal, route: `${request.method} ${routeUrl}` },
        "access token refused",
      );
      const code = REFUSAL_CODE[verdict.refusal];
      return reply.status(401).send(
        errorBody(
          code,
          verdict.refusal === "expired" ? "Access token has expired." : "Access token is not valid.",
          request.id,
          // §9.3: `auth.token_expired` is the one 401 that is retryable, after exactly one refresh.
          { retryable: verdict.refusal === "expired" },
        ),
      );
    }

    const owner = await deps.withConnection((client) =>
      accountForSupabaseUser(client, verdict.token.supabaseUserId),
    );
    if (!("accountId" in owner)) {
      // **`auth.token_revoked`, matching what `POST /v1/auth/refresh` already answers for the same
      // two states**, so the two surfaces cannot disagree about what a closed or ambiguous account
      // means. §7.2 makes that code "clears the Keychain entry, opens sign-in", which is the correct
      // recovery: refreshing would fail identically, because the refresh route refuses these too.
      request.log.info(
        { ambiguous: owner.ambiguous, route: `${request.method} ${routeUrl}` },
        "verified token could not be attributed to a live account",
      );
      return reply.status(401).send(
        errorBody(
          "auth.token_revoked",
          owner.ambiguous
            ? "This session cannot be attributed to a single account."
            : "This session no longer belongs to an active account.",
          request.id,
        ),
      );
    }

    request.auth = {
      accountId: owner.accountId,
      supabaseUserId: verdict.token.supabaseUserId,
      accessToken: presented,
    };
    return undefined;
  });
}

/**
 * `Authorization: Bearer <token>` → the token, or `undefined`.
 *
 * The scheme is compared case-insensitively because RFC 7235 says it is case-insensitive; the token
 * itself is not touched beyond trimming the separator, since every character of it is signed input
 * and `verifyAccessToken` is what judges its shape.
 */
function bearerToken(header: string | undefined): string | undefined {
  if (!header) return undefined;
  const space = header.indexOf(" ");
  if (space === -1) return undefined;
  if (header.slice(0, space).toLowerCase() !== "bearer") return undefined;
  const token = header.slice(space + 1).trim();
  return token.length > 0 ? token : undefined;
}
