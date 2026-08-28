import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Config } from "../config.js";
import type { UpstreamUsage } from "../model/upstream.js";
import {
  meteredRouteFor,
  modelForRoute,
  outcomeFor,
  type MeteredRoute,
  type MeteringEvent,
} from "./event.js";
import type { MeteringStore } from "./store.js";

/**
 * Contract §11's metering event, written for every call on every metered route (SONNY-133).
 *
 * **One app-level set of hooks, never per-route wiring**, which is the third time this repository
 * has made that choice and for the same reason each time: `auth/gate.ts` for authentication,
 * `idempotency/hook.ts` for §9.2, and now this. A route that has to remember to meter itself is a
 * route where the author who did not think about metering ships something that serves correctly,
 * passes its own tests, and is free. Coverage is *encapsulation* rather than registration order —
 * this is installed on the root instance, so every route on it and on its descendants is covered.
 *
 * **Two hooks and one listener, because the facts arrive at three different moments.**
 *
 * - `onRequest` opens a draft for a metered route and attaches the listener below. It is the
 *   earliest point at which `request.routeOptions.url` is resolved.
 * - `onSend` reads the response — its bytes, and the §7.1 error code inside it if it is a failure —
 *   and **writes the event, before the response is flushed.**
 * - **`close` on the raw response writes it too, for the one case `onSend` cannot reach**: a caller
 *   who disconnects while the handler is still running. `onSend` has not run and will not until the
 *   handler returns, and §12 says that request may already have cost money. A `written` flag on the
 *   draft makes "whichever gets there first" a rule rather than a race.
 *
 * ## Why the write is on the response path rather than after it
 *
 * `onResponse` is the obvious home — bookkeeping after the user has their answer — and it was the
 * first one. **Two measurements moved it.**
 *
 * - **A crash between the response and `onResponse` drops a billing record for a provider call that
 *   has already been paid for.** This whole ticket exists so that nothing is silently free, and a
 *   window that loses events in exactly the direction the ticket is about is the wrong one to accept
 *   for a single local `INSERT`.
 * - **`onResponse` is not awaited by the caller, so nothing downstream can know the event exists.**
 *   Measured on Node v22 against Fastify 5, both through `app.inject` and over a real socket: the
 *   client's promise resolves *before* an async `onResponse` hook finishes. That is not only a test
 *   inconvenience — it means "the client has its answer" and "the call is recorded" are unordered.
 *   It surfaced as a real red: SONNY-300's `writes at most one metering claim per key across a
 *   repeat and a re-run` passed on one run of the database suite and failed on the next, because it
 *   asks the database a question this hook was still answering.
 *
 * The cost is stated rather than hidden: every metered request now waits on one `INSERT`. That is a
 * third database round trip on a request that already makes two — the idempotency claim in
 * `preHandler` and its completion in `onSend` — beside a provider call whose deadline §12 measures
 * in tens of seconds. A write that fails is logged and never fails the response, exactly as before.
 *
 * **What the handler contributes, and why it is a deposit rather than a return value.** The
 * transport facts — status, bytes, durations, the account, the key — are the hook's, and it can read
 * every one of them without a route's help. What it cannot know is which provider served, whether an
 * upstream call was even opened, and what the provider reported. Those arrive through
 * `noteMetering`, and a route that deposits nothing still produces an event: it is the *detail* a
 * forgetful route loses, never the event. That is the same direction `DEFAULT_BODY_LIMIT_BYTES` and
 * `PUBLIC_ROUTES` fail in — the forgotten decision has to be the loud one.
 *
 * ## Which requests get an event
 *
 * | request                                             | event |
 * |-----------------------------------------------------|-------|
 * | metered route, authenticated, took the key claim     | yes, if the metering claim is free |
 * | metered route, authenticated, carried no key at all  | yes, unconditionally |
 * | metered route, authenticated, replayed from the store | no — the original wrote it |
 * | metered route, refused before the idempotency hook    | no — nothing was spent and there is no account |
 * | unauthenticated (401 at the gate)                     | no — §11's `user_id` comes from the session |
 * | an unmetered route                                    | no |
 *
 * **The third and fourth rows are the retry guarantee and are the reason this reads `ClaimState`
 * rather than calling the claim on everything.** A repeat inside the twenty-four hours never runs
 * the handler, so it costs nothing and must not be metered — and a `409 idempotency.conflict` is
 * worse than merely free: that request never took the key's claim, so metering it would take the
 * claim **out from under the request that did**, and the original's real cost would then find the
 * claim gone and go unbilled. So only a request holding the claim may spend it.
 */

/** What a route deposits as it learns it. Every field optional; a route may deposit nothing. */
export interface MeteringFacts {
  readonly provider?: string;
  readonly failedOver?: readonly string[];
  /** Set the moment a provider call is opened, before it is known whether it will answer. */
  readonly upstreamAttempted?: true;
  readonly upstreamDurationMs?: number;
  readonly usage?: UpstreamUsage | undefined;
  readonly imageBytes?: number;
  readonly imagePixelWidth?: number;
  readonly imagePixelHeight?: number;
  readonly imageMediaType?: string;
  readonly taskId?: string;
  readonly retention?: "standard" | "none";
  readonly sessionId?: string;
  readonly sessionIteration?: number;
}

/** The draft one request accumulates. Mutable by construction; nothing outside this file reads it. */
interface MeteringDraft {
  readonly route: MeteredRoute;
  facts: MeteringFacts;
  responseBytes: number | null;
  errorCode: string | undefined;
  /** Set by the first writer to reach it. `registerMetering` says why there are two. */
  written: boolean;
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set by `registerMetering` on a metered route; `null` everywhere else. */
    metering: MeteringDraft | null;
  }
}

export interface MeteringDeps {
  readonly store: MeteringStore;
}

/**
 * Add what this route has just learned to its request's metering event.
 *
 * Merges rather than replaces, so a route can deposit in stages — the parsed body's fields when it
 * has them, the provider when the call comes back — without carrying a half-built event of its own.
 * A call on a request that is not being metered is a no-op, so a shared helper used by a metered and
 * an unmetered route needs no guard of its own.
 */
export function noteMetering(request: FastifyRequest, facts: MeteringFacts): void {
  const draft = request.metering;
  if (draft === null) return;
  draft.facts = { ...draft.facts, ...facts };
}

/**
 * Run a provider call, recording that one was opened and how long it took.
 *
 * **`upstreamAttempted` is set before the call and the duration in a `finally`**, so a call that
 * throws still records both. That matters twice over: a failed call is the difference between §11's
 * `provider_error` and its `refused` (`outcomeFor` takes exactly this flag), and a provider that
 * timed out spent the route's whole upstream deadline, which is a real number worth having.
 */
export async function meteredUpstreamCall<T>(
  request: FastifyRequest,
  work: () => Promise<T>,
): Promise<T> {
  noteMetering(request, { upstreamAttempted: true });
  const startedAt = performance.now();
  try {
    return await work();
  } finally {
    noteMetering(request, { upstreamDurationMs: Math.round(performance.now() - startedAt) });
  }
}

/**
 * The longest `Sonny-Client-Version` this server stores, in characters.
 *
 * A header is caller-controlled and unbounded, and every one of them would otherwise become a `text`
 * value written on every metered request. §2.2's example is `1.0.0+412`, so nothing a conforming
 * client sends comes near this. **Truncated rather than refused**, which is the opposite call to
 * `idempotency/hook.ts`' 255-character key and deliberately so: a key that is wrong makes the
 * request's guarantee meaningless, while a client version is diagnostic and must never be the reason
 * a call fails.
 */
const MAXIMUM_CLIENT_VERSION_LENGTH = 100;

/**
 * The longest client-minted identifier this server stores, in characters.
 *
 * The same 200 the routes' own `zod` schemas enforce (`identifierField`). Bounded here as well
 * because these are read off the *unvalidated* body — a request refused at validation still gets an
 * event, and its `task_id` has been through nothing.
 */
const MAXIMUM_IDENTIFIER_LENGTH = 200;

function boundedString(value: unknown, limit: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  return trimmed.slice(0, limit);
}

/** The `{ error: { code } }` §7.1 puts on every failure, or `undefined` if this is not one. */
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

/**
 * §2.4's client-supplied fields, read tolerantly off the parsed body.
 *
 * **Read here rather than only deposited by handlers, because a refused request has no handler to
 * deposit them.** A body that fails `.strict()` validation still produced a `400` that has to be
 * attributable, and `task_id`, `retention` and `session_id` are exactly what attributes it. Every
 * value is type-checked and bounded, so a body that carries a number where a string belongs
 * contributes nothing rather than a surprise.
 *
 * `/v1/transcriptions` is the one route this cannot serve: §4.4's body is `multipart/form-data`,
 * consumed inside the handler, so `request.body` is undefined there and the handler deposits its
 * `meta` part instead.
 */
function clientFieldsOf(body: unknown): MeteringFacts {
  if (typeof body !== "object" || body === null) return {};
  const record = body as Record<string, unknown>;
  const facts: {
    taskId?: string;
    retention?: "standard" | "none";
    sessionId?: string;
    sessionIteration?: number;
  } = {};

  const taskId = boundedString(record["task_id"], MAXIMUM_IDENTIFIER_LENGTH);
  if (taskId !== null) facts.taskId = taskId;

  const retention = record["retention"];
  if (retention === "standard" || retention === "none") facts.retention = retention;

  const sessionId = boundedString(record["session_id"], MAXIMUM_IDENTIFIER_LENGTH);
  if (sessionId !== null) facts.sessionId = sessionId;

  const iteration = record["session_iteration"];
  if (typeof iteration === "number" && Number.isInteger(iteration) && iteration > 0) {
    facts.sessionIteration = iteration;
  }
  return facts;
}

/**
 * The request's declared body size, or `null` when it declared none.
 *
 * §11 asks for the *decoded* size, and this is it: nothing in this gateway decodes a
 * `Content-Encoding` — no compression plugin is installed, and §6.4 records that request
 * decompression is unimplemented and owned by SONNY-317 — so a body's declared length is the body
 * this server read. **`null` rather than `0` when the header is absent**, because a chunked request
 * would otherwise be recorded as an empty one.
 */
function declaredRequestBytes(request: FastifyRequest): number | null {
  const declared = Number(request.headers["content-length"]);
  return Number.isFinite(declared) && declared >= 0 ? declared : null;
}

/**
 * Did the caller go away before this server answered? Read only on the `close` path.
 *
 * **`reply.sent` — Fastify's own record of whether a reply was handed to the socket — and not one of
 * Node's writable flags, every one of which was measured and rejected.** On Node v22, at the moment
 * the response emits `close` after a real client abort: `writableEnded` and `writableFinished` are
 * both **true** when the handler happened to finish first, because a write into a socket the kernel
 * has not yet torn down succeeds locally; and under `app.inject` `writableFinished` is **false** on
 * every request, because `light-my-request`'s mock response never sets it. So both flags say
 * "cancelled" for requests that were not and "fine" for requests that were.
 *
 * `reply.sent` is false exactly when this server has not produced an answer, which is the property
 * §12 is actually about. It is **not** consulted from `onSend`, where it is false by construction
 * for every request — a reply being assembled has not been sent — and where the answer is known
 * anyway: a server that is writing a response has not lost its caller.
 *
 * **What this deliberately does not catch**, stated because the gap is real: a caller that
 * disconnects *after* the handler finished and the reply went out is recorded as `ok`. From the
 * server's side that is what happened — the work was done and the answer was produced — and the cost
 * is recorded either way, which is the hole §12 exists to close ("silently free cancellations would
 * be a hole in the spend cap"). What is lost is a label in a sub-millisecond race, not a bill.
 */
function clientWentAway(reply: FastifyReply): boolean {
  return reply.sent !== true;
}

function tokenCount(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function registerMetering(
  app: FastifyInstance,
  config: Config,
  deps?: MeteringDeps,
): void {
  app.decorateRequest("metering", null);

  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    const routeUrl = request.routeOptions.url;
    // No route matched. The not-found handler owns the answer and there is nothing to meter — the
    // same guard, and the same reason, as the gate's and the idempotency hook's.
    if (routeUrl === undefined) return;
    const route = meteredRouteFor(request.method, routeUrl);
    if (route === undefined) return;
    request.metering = {
      route,
      facts: {},
      responseBytes: null,
      errorCode: undefined,
      written: false,
    };
    // The second writer. See this module's header for why it exists and why it is not redundant
    // with `onResponse`.
    reply.raw.on("close", () => {
      void writeEvent(request, reply, clientWentAway(reply));
    });
  });

  app.addHook("onSend", async (request: FastifyRequest, reply: FastifyReply, payload: unknown) => {
    const draft = request.metering;
    if (draft === null) return payload;
    const body =
      typeof payload === "string"
        ? Buffer.from(payload, "utf8")
        : Buffer.isBuffer(payload)
          ? payload
          : undefined;
    // `null` for a payload this hook cannot measure — a stream, from a route a later ticket adds.
    // The same distinction `idempotency/hook.ts` draws about a payload it cannot store, and no route
    // produces one today.
    draft.responseBytes = body === undefined ? null : body.byteLength;
    draft.errorCode = body === undefined ? undefined : errorCodeOf(reply.statusCode, body);
    // `clientGone: false` rather than a predicate: a server assembling a response has a caller.
    await writeEvent(request, reply, false);
    return payload;
  });

  /**
   * Build this request's event and write it, at most once.
   *
   * The guard is the first line rather than the caller's, so neither writer has to know about the
   * other, and a third one — should a later ticket find another moment a request can end at — is one
   * more call rather than a new invariant.
   *
   * `clientGone` is a parameter rather than something read here, because the two callers know
   * different things: `onSend` is a server writing a response and cannot have lost its caller, and
   * the `close` listener is the only place `reply.sent` answers anything.
   */
  async function writeEvent(
    request: FastifyRequest,
    reply: FastifyReply,
    clientGone: boolean,
  ): Promise<void> {
    const draft = request.metering;
    if (draft === null || draft.written) return;
    draft.written = true;
    if (!deps) {
      // Unreachable on every deployment this repository builds, and said plainly rather than dressed
      // up: a metered route is authenticated (it is absent from `PUBLIC_ROUTES`), and an
      // authenticated deployment has a database, which is what supplies this store. Logged at
      // `error` because if it ever does happen, the calls are being served for free.
      request.log.error(
        { route: draft.route },
        "metered route served with no metering store configured; the call is unrecorded",
      );
      return;
    }

    const account = request.auth?.accountId;
    if (account === undefined) {
      // Refused at the gate, before any account existed to attribute the call to. §11's `user_id`
      // comes "from the authenticated session", so there is no event to write; nothing was spent
      // either, since the gate's `onRequest` runs before the body is parsed.
      return;
    }

    // Only a request holding this key's claim may spend it, and a keyless request has no claim to
    // hold. Everything else — a replay, a conflict, an over-long key — wrote nothing and must not
    // take a claim the request that *did* the work is going to need.
    //
    // **The key that gates the write and the key that is recorded on the event are two values**, and
    // they differ in exactly one shape: a deployment with no key store, where the client sent a
    // header and there is no row anywhere for a claim to be about. Gating on it would ask a store
    // that holds nothing; recording it is still true and is what a support lookup would join on.
    //
    // **That shape is unreachable on every deployment this repository builds, and it is said plainly
    // rather than dressed up as a prevented failure** — the standard `idempotency/hook.ts` sets for
    // its own `!deps` branch, which is the only thing that produces it. All five metered routes are
    // authenticated, so a deployment serving one has `auth`, and a deployment with `auth` has a key
    // store. The two values are kept apart because the distinction is real and free, not because a
    // test can drive the second.
    const claim = request.idempotency;
    let claimKey: string | null;
    let recordedKey: string | null;
    if (claim === null) return;
    else if (claim.kind === "claimed") {
      claimKey = claim.key;
      recordedKey = claim.key;
    } else if (claim.kind === "unguaranteed") {
      claimKey = null;
      recordedKey = claim.key ?? null;
    } else return;

    const facts = { ...clientFieldsOf(request.body), ...draft.facts };
    const usage = facts.usage;
    const provider = facts.provider ?? null;
    const event: MeteringEvent = {
      requestId: request.id,
      idempotencyKey: recordedKey,
      accountId: account,
      route: draft.route,
      provider,
      failedOver: facts.failedOver ?? [],
      model: modelForRoute(config, draft.route, provider ?? undefined) ?? null,
      inputTokens: tokenCount(usage?.inputTokens),
      outputTokens: tokenCount(usage?.outputTokens),
      totalTokens: tokenCount(usage?.totalTokens),
      tokenSource: usage?.source ?? null,
      imageBytes: facts.imageBytes ?? null,
      imagePixelWidth: facts.imagePixelWidth ?? null,
      imagePixelHeight: facts.imagePixelHeight ?? null,
      imageMediaType: facts.imageMediaType ?? null,
      audioDurationSeconds: tokenCount(usage?.audioDurationSeconds),
      requestBytes: declaredRequestBytes(request),
      responseBytes: draft.responseBytes,
      // Fastify's own measurement of this exchange, in milliseconds and from the moment the request
      // arrived. Rounded because §11 says `int` and a fractional millisecond is noise.
      durationMs: Math.round(reply.elapsedTime),
      upstreamDurationMs: facts.upstreamDurationMs ?? null,
      outcome: outcomeFor({
        status: reply.statusCode,
        errorCode: draft.errorCode,
        upstreamAttempted: facts.upstreamAttempted === true,
        clientGone,
      }),
      taskId: facts.taskId ?? null,
      sessionId: facts.sessionId ?? null,
      sessionIteration: facts.sessionIteration ?? null,
      retention: facts.retention ?? null,
      clientVersion: boundedString(
        request.headers["sonny-client-version"],
        MAXIMUM_CLIENT_VERSION_LENGTH,
      ),
    };

    try {
      const written = await deps.store.write(event, claimKey);
      if (written === "already_claimed") {
        // §9.2 working rather than a failure: this key's one event belongs to an earlier attempt.
        // Logged at `info` because it is the visible trace of a retry going unbilled, which is a
        // thing an operator reading a cost question will want to be able to see.
        request.log.info(
          { route: draft.route },
          "metering event already claimed for this idempotency key; this attempt is unbilled",
        );
      } else if (written === "written_without_claim") {
        // The event is recorded and unprotected, because the key named no row. `store.ts` argues
        // that this cannot be reached from here — a claim was granted, so a row exists, and nothing
        // deletes one — so it is logged at `error`: the money is safe and an invariant above this is
        // not.
        request.log.error(
          { route: draft.route, requestId: request.id },
          "metering event written with no idempotency row to claim; a repeat could bill twice",
        );
      }
    } catch (error) {
      // **A bookkeeping write never fails the response.** The handler has already done its work —
      // possibly an upstream call that cost money — and turning that into a 500 because a row could
      // not be written would be the worst of both, which is the same call `idempotency/hook.ts`
      // makes for the same reason. What is lost is the event, which is why it is logged at `error`
      // with the request id: §2.3 makes that the join key, so a lost event is recoverable by hand
      // from the log rather than gone without a trace.
      request.log.error(
        { err: error, route: draft.route, requestId: request.id },
        "metering event could not be written for this request",
      );
    }
  }
}
