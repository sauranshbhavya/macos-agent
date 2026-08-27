import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { errorBody } from "../errors.js";
import { fingerprintOf } from "./fingerprint.js";
import { UNAUTHENTICATED_SCOPE, type KeyStore, type StoredResponse } from "./store.js";

/**
 * Contract §9's `Idempotency-Key`, honoured for every `POST` this server has or will have
 * (SONNY-300).
 *
 * **One app-level pair of hooks, never per-route wiring**, and that is the same reasoning
 * `auth/gate.ts` gives for the gate: a route added by a later ticket whose author does not think
 * about idempotency would otherwise be a route where a client retry double-bills, serving correctly
 * and passing its own tests. `registerModelRoutes` (SONNY-130), SONNY-131's vision route and
 * SONNY-132's router inherit this by existing on this instance. Coverage is *encapsulation*, not
 * registration order — `gate.ts`'s docstring carries the seven wirings that were measured, and this
 * is installed on the same root instance for the same reason.
 *
 * **Two hooks, because the claim and the capture happen at different moments.**
 * `preHandler` is the earliest point at which the caller is known (the gate's `onRequest` has run)
 * and a JSON body has been parsed, and it is before the handler — which is what §9.2 bullet 4's
 * "rather than a second upstream call" requires. `onSend` is where the response exists and has not
 * yet been flushed, so a client that received a response is guaranteed to find it stored.
 *
 * ## What it does with each of §9.2's four sentences
 *
 * | request                                  | answer                                              |
 * |------------------------------------------|-----------------------------------------------------|
 * | first use of a key                       | claimed, handler runs, response stored for 24 h     |
 * | repeat inside 24 h, same body            | the stored response, byte for byte                  |
 * | repeat while the first is still running  | `409 idempotency.conflict`, `retryable: true`       |
 * | same key, different body                 | `409 idempotency.conflict`, `retryable: false`      |
 *
 * ## The one place this departs from §9.2 as written, and why
 *
 * A stored response that is a **retryable failure** is released rather than replayed, so a retry
 * with the same key actually re-runs. §9.2 read literally would replay it, which makes every
 * retryable row in §9.3's table safe but useless: a `429 limit.rate` would become a twenty-four-hour
 * ban on that operation, and a `503` during a deploy would freeze every operation in flight for a
 * day. Founder decision, 2026-08-28, taken on this ticket with the alternatives written out.
 * `releaseClaim` carries what keeps the money guarantee intact across the re-attempt.
 *
 * ## What a `POST` carrying no key gets
 *
 * Served, and logged. §9.1 makes the header the client's obligation and `SonnyBackendClient` sends
 * it on every `POST`; refusing here would enforce §9.1 server-side at the cost of a mechanical
 * change across every existing `POST` test and both in-flight route lanes, for a case no shipping
 * client reaches. Founder decision, 2026-08-28. The cost is stated rather than hidden: such a
 * request has no at-most-once metering guarantee, because there is no key for one to be about.
 */

/** §9.2's header. Compared case-insensitively by Fastify, which lower-cases every header name. */
const HEADER = "idempotency-key";

/**
 * The longest key this server will store.
 *
 * A header is caller-controlled and unbounded, and every one of them becomes a primary-key value
 * here. 255 is far past a UUID's 36 characters — §9.1 says the key *is* a UUID — so nothing a
 * conforming client sends comes near it, and a key past it is a client bug answered with a contract
 * code rather than by a database error surfacing as `500 server.error`.
 */
const MAXIMUM_KEY_LENGTH = 255;

/**
 * The largest response body this server will store for replay, in bytes.
 *
 * Contract §6.3 caps a response at 1 MiB, so nothing conforming exceeds this. A response past it is
 * *released* rather than stored — the key becomes re-claimable and a repeat re-runs — which is the
 * same handling a retryable failure gets and for the same reason: the alternative is a `completed`
 * row that cannot answer the repeat it exists to answer.
 */
const MAXIMUM_STORED_RESPONSE_BYTES = 1024 * 1024;

/**
 * The §7.2 codes a repeat must be allowed to re-run rather than have replayed at it.
 *
 * **Keyed on `code` and never on status**, which is §9.3's own rule and is load-bearing here: 502
 * carries both `provider.unavailable` (retryable) and `provider.rejected` (not), so a status-keyed
 * set would either freeze the recoverable case or re-run the one guaranteed to fail identically.
 *
 * **`auth.token_expired` is in the set and is unreachable today, and that is stated rather than
 * dressed up as a prevented failure** (PR #142's review, F4). This comment used to say a stored one
 * "would answer the refreshed request with the failure that prompted the refresh, permanently" —
 * nothing can store one. That code is produced only by the auth gate, in an `onRequest` hook
 * (`auth/gate.ts`), and `onRequest` runs strictly before `preHandler`, so a request refused that way
 * never claims a key and never reaches this set. It stays in the set defensively: §3.3 makes it the
 * single 401 a client answers by refreshing once and retrying *the original request* with the same
 * key, so the day any handler answers it after a claim, releasing is the behaviour that keeps the
 * refresh-and-retry working. Same standard as the `!deps` branch below, which says plainly that it is
 * unreachable rather than describing a failure it prevents.
 *
 * The rest of the set is reachable now: `limit.rate` from the sign-in limiter, `provider.unavailable`
 * and `provider.timeout` from the model routes, `server.error` from the root error handler.
 * `server.unavailable` is produced nowhere yet, which is forward-looking in the same way.
 */
const RELEASE_ON_CODES: ReadonlySet<string> = new Set([
  "limit.rate",
  "provider.unavailable",
  "provider.timeout",
  "server.error",
  "server.unavailable",
  "auth.token_expired",
]);

/**
 * What `preHandler` left for `onSend`. `null` on every request that claimed no key.
 *
 * **A union rather than one shape with optional fields**, so the invariant is the compiler's: a
 * request that took a claim always has the fencing token that claim needs, and a replay — which took
 * no claim and writes nothing — cannot be handed to a writer at all. The earlier shape carried
 * `token: string | undefined` beside a `replayed` boolean and needed a non-null assertion at the one
 * place it mattered, which is exactly the kind of pairing that rots when a third case arrives.
 */
type ClaimState =
  | {
      readonly kind: "claimed";
      readonly accountScope: string;
      readonly key: string;
      /**
       * The fencing token of the claim this request took, so `onSend` writes to *that* claim.
       *
       * Scope and key alone identify the row but not the claim, and a row can be on its second or
       * third claim by the time this request's `onSend` runs; `store.ts` carries what that costs
       * without the token.
       */
      readonly token: string;
    }
  | {
      readonly kind: "replayed";
      /** The stored response's `Sonny-Request-Id`, re-stamped on the way out. */
      readonly requestId: string | undefined;
    };

declare module "fastify" {
  interface FastifyRequest {
    idempotency: ClaimState | null;
  }
}

export interface IdempotencyDeps {
  readonly store: KeyStore;
}

function conflict(
  request: FastifyRequest,
  reply: FastifyReply,
  message: string,
  options: { retryable: boolean; retryAfterSeconds?: number },
): FastifyReply {
  if (options.retryAfterSeconds !== undefined) {
    // §2.3 lists `Retry-After` on `429` and `503`; §9.2 bullet 4 asks for one here too, and the
    // client reads it through the same path either way.
    void reply.header("Retry-After", String(options.retryAfterSeconds));
  }
  return reply.status(409).send(
    errorBody("idempotency.conflict", message, request.id, {
      retryable: options.retryable,
      retryAfterSeconds: options.retryAfterSeconds ?? null,
    }),
  );
}

/**
 * Send a stored response back byte for byte.
 *
 * **The stored `Sonny-Request-Id` replaces this exchange's own**, and `0011`'s header argues it:
 * §2.3 makes that header the join key to the metering event and the retained content, a replay has
 * exactly one of each, and they are the original's.
 *
 * **That swap is not done here, and the first version of this function did it here and was wrong.**
 * `app.ts` sets `Sonny-Request-Id` from `request.id` in an `onSend` hook of its own, registered
 * before this module's — and Fastify runs `onSend` hooks in registration order — so a header set at
 * `preHandler` is overwritten on the way out by the repeat's own id. The test caught it as a real
 * UUID where `original-id` was expected. The swap therefore happens in the `onSend` hook below,
 * which runs after `app.ts`'s and is the last writer.
 *
 * The body is sent as a `Buffer` so Fastify serializes nothing: a replay that re-encoded the stored
 * bytes would not be the same response, and §9.2 says the stored one.
 */
function replay(reply: FastifyReply, stored: StoredResponse): FastifyReply {
  if (stored.contentType !== undefined) void reply.header("Content-Type", stored.contentType);
  return reply.status(stored.status).send(stored.body);
}

/** The `{ error: { code } }` envelope §7.1 puts on every failure, or `undefined` if this is not one. */
function errorCodeOf(status: number, payload: unknown): string | undefined {
  if (status < 400) return undefined;
  const text =
    typeof payload === "string"
      ? payload
      : Buffer.isBuffer(payload)
        ? payload.toString("utf8")
        : undefined;
  if (text === undefined) return undefined;
  try {
    const parsed: unknown = JSON.parse(text);
    const code = (parsed as { error?: { code?: unknown } })?.error?.code;
    return typeof code === "string" ? code : undefined;
  } catch {
    return undefined;
  }
}

export function registerIdempotency(app: FastifyInstance, deps?: IdempotencyDeps): void {
  app.decorateRequest("idempotency", null);

  app.addHook("preHandler", async (request: FastifyRequest, reply: FastifyReply) => {
    if (request.method !== "POST") return;
    const routeUrl = request.routeOptions.url;
    // No route matched; the not-found handler owns the answer and there is nothing to be idempotent
    // about. Same guard, and same reason, as the gate's.
    if (routeUrl === undefined) return;

    const header = request.headers[HEADER];
    const key = typeof header === "string" ? header.trim() : undefined;
    if (key === undefined || key.length === 0) {
      // Founder decision of 2026-08-28: served, not refused. Logged at `warn` because the only
      // client this gateway has sends the header on every POST, so an absence is news.
      request.log.warn(
        { route: `POST ${routeUrl}` },
        "POST carries no Idempotency-Key; served without the section 9.2 guarantees",
      );
      return;
    }
    if (key.length > MAXIMUM_KEY_LENGTH) {
      return reply.status(400).send(
        errorBody("request.invalid", "Idempotency-Key is longer than this server stores.", request.id),
      );
    }

    if (!deps) {
      // Unreachable on every deployment this repository builds: a health-only gateway mounts no auth
      // route, and `registerAuthGate` answers 401 to every other POST before this hook runs. Logged
      // at `error` and served rather than refused, because a refusal here could not be reached by a
      // test honestly and would be a guess about a shape that does not exist.
      request.log.error(
        { route: `POST ${routeUrl}` },
        "Idempotency-Key presented with no key store configured; served without its guarantees",
      );
      return;
    }

    const accountScope = request.auth?.accountId ?? UNAUTHENTICATED_SCOPE;
    const fingerprint = fingerprintOf(request, `POST ${routeUrl}`);
    const outcome = await deps.store.claim({
      accountScope,
      key,
      route: `POST ${routeUrl}`,
      fingerprint,
    });

    switch (outcome.kind) {
      case "claimed":
        request.idempotency = { kind: "claimed", accountScope, key, token: outcome.token };
        return;
      case "replay":
        request.idempotency = { kind: "replayed", requestId: outcome.response.requestId };
        request.log.info({ route: `POST ${routeUrl}` }, "idempotency key replayed a stored response");
        return replay(reply, outcome.response);
      case "in_flight":
        return conflict(request, reply, "This idempotency key is in use by a request still in flight.", {
          retryable: true,
          retryAfterSeconds: outcome.retryAfterSeconds,
        });
      case "conflict":
        return conflict(request, reply, "This idempotency key was used with a different request body.", {
          retryable: false,
        });
    }
  });

  app.addHook("onSend", async (request: FastifyRequest, reply: FastifyReply, payload: unknown) => {
    const claim = request.idempotency;
    if (claim !== null && claim.kind === "replayed") {
      // The last writer of this header, after `app.ts`'s own `onSend` has stamped the repeat's id.
      // A replay carries the original exchange's join key — see `replay` above for why.
      if (claim.requestId !== undefined) void reply.header("Sonny-Request-Id", claim.requestId);
      return payload;
    }
    if (!deps || claim === null) return payload;

    const status = reply.statusCode;
    const body =
      typeof payload === "string"
        ? Buffer.from(payload, "utf8")
        : Buffer.isBuffer(payload)
          ? payload
          : undefined;

    // A payload this hook cannot read is a payload it cannot store — a stream, most likely, from a
    // route a later ticket adds. Released rather than stored, so a repeat re-runs instead of meeting
    // a `completed` row with nothing in it.
    const code = body === undefined ? undefined : errorCodeOf(status, body);
    const storable =
      body !== undefined &&
      body.byteLength <= MAXIMUM_STORED_RESPONSE_BYTES &&
      (code === undefined || !RELEASE_ON_CODES.has(code));

    try {
      const fenced = { accountScope: claim.accountScope, key: claim.key, token: claim.token };
      if (storable && body !== undefined) {
        await deps.store.complete(fenced, {
          status,
          body,
          contentType: reply.getHeader("content-type")?.toString(),
          requestId: request.id,
        });
      } else {
        await deps.store.release(fenced);
      }
    } catch (error) {
      // **The response is never failed by a bookkeeping write.** The handler has already done its
      // work — possibly an upstream call that cost money — and turning that into a 500 because a row
      // could not be updated would be the worst of both. The row stays `in_flight` and its lease
      // expires, so the key is re-claimable within `CLAIM_LEASE_SECONDS` rather than forever.
      request.log.error({ err: error }, "idempotency record could not be written for this response");
    }
    return payload;
  });
}
