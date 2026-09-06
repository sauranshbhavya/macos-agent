import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import type { WithConnection } from "../db/connection.js";
import { accountForSupabaseUser } from "./attribution.js";
import { isProviderSessionRevoked } from "./denylist.js";
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
 * **Three things are asked of the database, and the order is deliberate.** A Supabase access token
 * is self-contained, so this gateway verifies it without asking the provider — which is the point —
 * and equally cannot un-issue one. What it *can* know locally is what it has been told, and it is
 * told two things. `DELETE /v1/account` closes the account, and every later request with any token
 * naming it is refused at the attribution step below. `POST /v1/auth/signout` revokes a session, and
 * `auth/denylist.ts` records it so that the token already in the user's hand stops verifying here —
 * that is SONNY-237, and it is consulted *before* attribution, because a signed-out session is
 * refused whether or not the account behind it still resolves, and because the answers differ:
 * `auth.token_revoked` with "this session was signed out" is not "this session no longer belongs to
 * an active account". Both run inside the one connection this hook leases, and
 * `DENYLIST_EXEMPT_ROUTES` below is the one route the first of them is skipped for.
 *
 * **The residual, stated rather than papered over, and it is now narrow.** Supabase's `session_id`
 * claim is `omitempty`, and a token carrying none cannot be denylisted: it stays valid until its own
 * `exp` **plus `EXPIRY_SKEW_TOLERANCE_SECONDS`** — one hour on Supabase's default, and thirty
 * seconds more than that here. The tolerance is deliberate and `clock.ts` argues for it; naming
 * `exp` alone would understate the window by exactly the amount this gate itself adds (PR #104's
 * adversarial review, F9). `routes/auth.ts` logs a sign-out that had no session to record rather
 * than letting it look complete, and `server/README.md` states the window that is left.
 */

/**
 * The routes that carry no `Authorization` header, taken from the contract's §4.1 `Auth` column,
 * which §2.2 names as the single source of truth for that question.
 *
 * Two of these have no handler yet — the two OAuth routes (SONNY-129). They are listed because this
 * list answers "is this route public", not "does this route exist": an entry for a route nobody has
 * written matches nothing, while an entry *missing* when its ticket lands means a public sign-in
 * route that answers 401 to the person who cannot yet have a token. **`GET /v1/meta` was the third
 * until SONNY-204 built it** (`routes/meta.ts`), and its entry needed no change when it landed,
 * which is the property this paragraph is claiming.
 *
 * `POST /v1/auth/refresh` is the subtle one and the contract explains it: it authenticates with the
 * refresh token in its body and deliberately sends no header, so that an expired or missing access
 * token can never be the reason a refresh fails.
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
 * The routes a denylisted session may still reach, because refusing them would refuse the very act
 * that denylisted it (SONNY-237).
 *
 * **One route, and it is not a convenience.** `POST /v1/auth/signout` records the row and *then*
 * calls the provider. When that call answers `502 provider.unavailable` or `504 provider.timeout` —
 * both retryable under §9.3, and both meaning the refresh-token family is still live — the caller is
 * told to try again. Without this exemption the retry meets the row the first attempt wrote, is
 * refused `401` at the gate, and the provider-side revocation can never be reached by anyone: the
 * one path to it is closed by the local half having succeeded. That is a worse state than the defect
 * this ticket fixes, and it is reachable on the first provider blip rather than in theory.
 *
 * **What it costs is nothing an attacker wants.** A denylisted token reaching this route can sign
 * the same session out again — recording a row that already exists and asking the provider to revoke
 * a family it was already asked about. Every other route stays refused, which is the whole of what
 * the denylist is for. `POST /v1/auth/refresh` needs no entry: it is public, carries no bearer
 * header at all, and is authenticated by the refresh token the sign-out revoked at the provider.
 *
 * **Method and path, and a route not in `PUBLIC_ROUTES`**: this is the narrower exemption of the
 * two — the gate still verifies the token, still attributes the caller, and still refuses a closed
 * account here. Only the denylist consult is skipped.
 */
export const DENYLIST_EXEMPT_ROUTES: ReadonlySet<string> = new Set([
  "POST /v1/auth/signout",
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
  /**
   * The verified `session_id` claim, or `undefined` when the token carries none (SONNY-237).
   *
   * Carried for the one route that acts on it: `POST /v1/auth/signout` records it on the denylist,
   * so the token it was presented with stops verifying here. Taken from the verdict rather than
   * re-parsed, for the reason `accessToken` is taken from the header rather than re-read — a second
   * reading is a second thing that can disagree with the first.
   */
  readonly providerSessionId: string | undefined;
  /**
   * The verified `exp`, as an instant. What decides how long a denylist row for this session has to
   * be kept: `auth/denylist.ts`'s `denylistedUntil` adds the tolerance this gate grants past it.
   */
  readonly accessTokenExpiresAt: Date;
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
  session: "auth.unauthenticated",
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

    // **One connection, two questions, and the denylist is asked first** (SONNY-237). Both reads sit
    // inside a single `withConnection` so a protected request still checks a connection out once —
    // the property the docstring above claims about the pool. The consult is skipped entirely for a
    // token carrying no session claim, because there is nothing to look it up by.
    const consultDenylist = !DENYLIST_EXEMPT_ROUTES.has(`${request.method} ${routeUrl}`);
    const owner = await deps.withConnection(async (client) => {
      const session = verdict.token.providerSessionId;
      if (consultDenylist && session !== undefined && (await isProviderSessionRevoked(client, session))) {
        return "session_revoked" as const;
      }
      return accountForSupabaseUser(client, verdict.token.supabaseUserId);
    });
    if (owner === "session_revoked") {
      // **`auth.token_revoked`, the same code a closed account gets, and for the same client
      // behaviour**: §7.2 makes it "clears the Keychain entry, opens sign-in", which is exactly
      // right for a token whose session was signed out. Refreshing would not help — the refresh
      // family went with the sign-out — so `auth.token_expired`, the one retryable 401, would put
      // the client into a loop against a session that is over.
      request.log.info(
        { route: `${request.method} ${routeUrl}` },
        "access token presented for a signed-out session",
      );
      return reply.status(401).send(
        errorBody("auth.token_revoked", "This session has been signed out.", request.id),
      );
    }
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
      providerSessionId: verdict.token.providerSessionId,
      accessTokenExpiresAt: verdict.token.expiresAt,
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
