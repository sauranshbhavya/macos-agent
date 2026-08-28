import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Config } from "../config.js";
import { meteredRouteFor, type MeteredRoute } from "../metering/event.js";
import {
  contentExpiryFrom,
  isStorable,
  requestContentOf,
  type ContentFacts,
  type DeclaredRetention,
  type RetainedContent,
} from "./record.js";
import type { ContentStore } from "./store.js";

/**
 * Contract §10's content store, filled from every call that asked to be kept (SONNY-134).
 *
 * **One app-level set of hooks, never per-route wiring**, which is the fourth time this repository
 * has made that choice and for the same reason each time: `auth/gate.ts` for authentication,
 * `idempotency/hook.ts` for §9.2, `metering/hook.ts` for §11, and now this. A route that has to
 * remember to store its own content is a route where the author who did not think about retention
 * ships something that serves correctly, passes its own tests, and quietly keeps nothing.
 *
 * ## Where the incognito guarantee actually is
 *
 * §10.1: "Enforced where the storing happens, not at the call site. A flag the client sets and the
 * server is trusted to remember to check is a request, not a guarantee." There are three layers and
 * they fail in three different ways, which is the point of having three:
 *
 * 1. **`isStorable` here**, one predicate, ahead of every write. Nothing on an incognito request is
 *    read, decoded, or sent to the database — the screenshot is never even base64-decoded a second
 *    time, because `requestContentOf` runs after this answer rather than before it.
 * 2. **A `CHECK` on the table** that admits exactly one value of `retention`. If something above
 *    this is ever wrong, the insert is refused rather than served.
 * 3. **The snapshot builder reads `sonny.retained_content` and nothing else.** A row that is not in
 *    the store cannot reach a training set through any query, filtered or not, which is §10.1's
 *    second rule — "structurally excluded from training snapshots, not filtered by a query" —
 *    reduced to a fact about which table the builder's `FROM` names.
 *
 * **Metering is untouched by any of it.** §10.1: "Incognito changes what is stored, never what is
 * billed." The metering hook runs before this one, does not consult it, and writes its event for an
 * incognito call exactly as for any other; the accepted cost is that a user reporting a misbehaving
 * incognito run cannot be diagnosed from stored data, which is the feature working.
 *
 * ## Why this writes after the response and metering writes before it
 *
 * `metering/hook.ts` moved its write off `onResponse` and onto `onSend`, deliberately, because "a
 * crash between the response and `onResponse` drops a billing record for a provider call that has
 * already been paid for". **This hook writes on `onResponse`, and the difference is not an
 * oversight.** Two things separate them:
 *
 * - **What is lost differs in kind.** A lost metering event is money the gateway spent and cannot
 *   bill for. A lost content row is a debugging copy of data the user still has on their own Mac.
 *   The first is unrecoverable, the second is a smaller corpus.
 * - **What it costs differs by three orders of magnitude.** A metering event is a row of integers.
 *   A content row can be a 1.2 MB screenshot or ten megabytes of audio, and `/v1/screen/analyze`
 *   runs up to twelve times in one session. Putting that insert ahead of the response bytes would
 *   put a multi-megabyte round trip on the critical path of every iteration of the one feature this
 *   whole row exists to make possible.
 *
 * So the ordering is: the client gets its answer, then the content is stored. The response payload
 * is still captured in `onSend`, because that is the only hook it exists in.
 *
 * **The `close` listener is the second writer, for the case `onResponse` cannot reach**: a caller
 * who disconnects while the handler is still running. A `written` flag makes "whichever gets there
 * first" a rule rather than a race, exactly as it does one file over.
 *
 * ## Which requests get a content row
 *
 * | request                                                    | row |
 * |------------------------------------------------------------|-----|
 * | metered route, authenticated, ran, `retention: "standard"`  | yes |
 * | metered route, authenticated, ran, `retention: "none"`      | no — §10.1 |
 * | metered route, authenticated, ran, no `retention` declared  | no — §2.4.2 |
 * | replayed from the idempotency store                         | no — the original stored it |
 * | `409 idempotency.conflict`                                  | no — the handler never ran |
 * | unauthenticated (401 at the gate)                           | no — nothing to attribute it to |
 * | an unmetered route                                          | no |
 *
 * **The third row is §2.4.2 arriving at the storage layer, and it is worth saying out loud.** A
 * request that declared no `retention` is a `400` on the wire, because neither default is safe. The
 * store takes the same line rather than a different one: content is kept when the caller said
 * `standard` and in no other case. So a body that failed validation before its `retention` could be
 * read contributes nothing here, while its metering event is written as usual — which is the same
 * asymmetry §10.1 already draws for incognito, reached by a second road.
 */

/** The draft one request accumulates. Mutable by construction; nothing outside this file reads it. */
interface ContentDraft {
  readonly route: MeteredRoute;
  facts: ContentFacts;
  responseStatus: number | null;
  responseContentType: string | null;
  responseBody: Buffer | null;
  /** Set by the first writer to reach it. `registerContent` says why there are two. */
  written: boolean;
  /**
   * Called once this request's retention decision has been carried out, whichever way it went.
   *
   * **It is resolved on the paths that store nothing as well as on the path that stores**, and that
   * is the whole reason it exists rather than a promise around the insert. `contentWritesSettled`
   * has to be able to answer "this request's content decision is done" for an incognito run, where
   * there is no write to wait for and the honest answer is still not "immediately, before the hook
   * has run".
   */
  settle: () => void;
}

declare module "fastify" {
  interface FastifyRequest {
    /** Set by `registerContent` on a content-bearing route; `null` everywhere else. */
    content: ContentDraft | null;
  }
  interface FastifyInstance {
    /**
     * Resolves once every content write this instance has started has finished, successfully or
     * not.
     *
     * **This exists because the write happens after the response, and that has two consequences
     * rather than one.** The one it was added for is shutdown: a container told to stop closes the
     * server, and without this the writes for the last requests in flight would be abandoned
     * mid-statement — content silently missing for exactly the calls made during a deploy, which is
     * the least visible way to lose data on a clock. `server.ts` awaits it after `app.close()`.
     *
     * The second is that it makes the behaviour testable at all. `app.inject`'s promise resolves
     * before an `onResponse` hook finishes — measured on Node v22 against Fastify 5 and recorded in
     * `metering/hook.ts`, which is half of why the metering write is not here — so a test asserting
     * "nothing was stored" would otherwise be asserting that nothing had been stored *yet*, and
     * would pass for an incognito run and for a storable one alike. Waiting on a signal the writer
     * publishes is the rule `CLAUDE.md` states for exactly this shape; a `setTimeout` here would be
     * a bet on a wall clock the rest of the suite shares.
     */
    contentWritesSettled: () => Promise<void>;
  }
}

export interface ContentDeps {
  readonly store: ContentStore;
}

/**
 * Add what this route or adapter has just learned to its request's content draft.
 *
 * Merges rather than replaces, so a route can deposit in stages. A call on a request that is not
 * being stored is a no-op, so a shared helper used by a content route and an unmetered one needs no
 * guard of its own — the same contract `noteMetering` offers.
 */
export function noteContent(request: FastifyRequest, facts: ContentFacts): void {
  const draft = request.content;
  if (draft === null) return;
  draft.facts = { ...draft.facts, ...facts };
}

/**
 * The longest provider error body this server keeps, in characters.
 *
 * A provider's error body is content and belongs on the content clock (§10.3), which is what this
 * whole column exists for — but it is also a string a third party controls, arriving on a path that
 * fires when things are already going wrong. Bounded rather than refused, for `metering/hook.ts`'
 * reason about the client version: this is diagnostic, and it must never be why anything fails.
 * Eight kilobytes is far past any provider error envelope observed and far short of a body that
 * could be used to fill the table.
 */
export const MAXIMUM_PROVIDER_ERROR_BODY = 8192;

/** §2.4's `retention`, read off the parsed body — the one field this hook must not guess at. */
function declaredRetention(body: unknown): DeclaredRetention {
  if (typeof body !== "object" || body === null) return undefined;
  const value = (body as Record<string, unknown>)["retention"];
  return value === "standard" || value === "none" ? value : undefined;
}

/**
 * What this request declared, as **every** part of the gateway that stores anything must read it.
 *
 * **Exported because a second storing place exists and did not know about retention at all** (PR
 * #148's review, F1). `sonny.idempotency_key` keeps the served response body for twenty-four hours,
 * which makes it the one place outside `sonny.retained_content` holding response content — and
 * `idempotency/hook.ts` had no notion of the field, so an incognito POST carrying an
 * `Idempotency-Key` stored the model's reply verbatim, outside the content clock, outside consent,
 * and outside what a per-task delete could reach. Requirement 6's own words are "enforced where the
 * storing happens", and that is a storing place.
 *
 * **One function rather than two readings of the same field**, because the failure mode of two is
 * the worst available: the two stores would disagree about what the user asked for, and the one that
 * got it wrong would be the one nobody was looking at. The deposited value wins over the body's for
 * `/v1/transcriptions`, whose body the hook cannot read — `ContentFacts.retention` carries that
 * reasoning.
 *
 * `undefined` for a route that carries no content draft at all, which is every non-content POST —
 * the auth routes — and is why the idempotency hook withholds a body only on an explicit `"none"`
 * rather than on anything that is not `"standard"`.
 */
export function retentionOf(request: FastifyRequest): DeclaredRetention {
  return request.content?.facts.retention ?? declaredRetention(request.body);
}

function boundedIdentifier(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed.slice(0, 200);
}

/** §2.4's keys, read off the *unvalidated* body — the same tolerance `clientFieldsOf` applies. */
function keysOf(body: unknown): {
  taskId: string | null;
  sessionId: string | null;
  sessionIteration: number | null;
} {
  if (typeof body !== "object" || body === null) {
    return { taskId: null, sessionId: null, sessionIteration: null };
  }
  const record = body as Record<string, unknown>;
  const iteration = record["session_iteration"];
  return {
    taskId: boundedIdentifier(record["task_id"]),
    sessionId: boundedIdentifier(record["session_id"]),
    sessionIteration:
      typeof iteration === "number" && Number.isInteger(iteration) && iteration > 0
        ? iteration
        : null,
  };
}

export function registerContent(app: FastifyInstance, config: Config, deps?: ContentDeps): void {
  app.decorateRequest("content", null);

  /**
   * Requests whose retention decision has not been carried out yet.
   *
   * **An entry is added when the draft opens, not when a write starts**, and getting that wrong is
   * the difference between a working signal and one that answers "nothing pending" before the hook
   * has run at all. The write happens in `onResponse`, and `app.inject` resolves before that fires,
   * so a set populated at write time would be empty exactly when a caller asks — and every "nothing
   * was stored" assertion would pass without having waited for anything.
   *
   * Entries remove themselves, so the set is empty whenever nothing is pending rather than growing
   * for the life of the process.
   */
  const pending = new Set<Promise<void>>();
  app.decorate("contentWritesSettled", async () => {
    // Snapshotted rather than awaited in place: a request that arrives while this is waiting is one
    // the caller had not asked about, and waiting for those too would make this unable to finish on
    // a busy server.
    await Promise.allSettled([...pending]);
  });

  app.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
    const routeUrl = request.routeOptions.url;
    // No route matched; the not-found handler owns the answer. The same guard, and the same reason,
    // as the gate's, the idempotency hook's and the metering hook's.
    if (routeUrl === undefined) return;
    const route = meteredRouteFor(request.method, routeUrl);
    if (route === undefined) return;
    let settle!: () => void;
    const decided = new Promise<void>((resolve) => {
      settle = resolve;
    });
    pending.add(decided);
    void decided.finally(() => pending.delete(decided));
    request.content = {
      route,
      facts: {},
      responseStatus: null,
      responseContentType: null,
      responseBody: null,
      written: false,
      settle,
    };
    reply.raw.on("close", () => {
      void writeContent(request, reply);
    });
  });

  /**
   * Capture the response, which exists in this hook and nowhere later.
   *
   * `onResponse` is where the write happens and it has no payload to read, so the bytes are taken
   * here and held on the draft — the same split `metering/hook.ts` makes for `responseBytes`, one
   * hook earlier.
   *
   * **A payload this hook cannot measure is stored as no response rather than as an empty one.** No
   * route produces a stream today; the distinction is the same one the idempotency hook draws about
   * a payload it cannot store, and it fails toward "we did not keep it" rather than toward a row
   * that claims the server answered with nothing.
   */
  app.addHook("onSend", async (request: FastifyRequest, reply: FastifyReply, payload: unknown) => {
    const draft = request.content;
    if (draft === null) return payload;
    const body =
      typeof payload === "string"
        ? Buffer.from(payload, "utf8")
        : Buffer.isBuffer(payload)
          ? payload
          : undefined;
    draft.responseStatus = reply.statusCode;
    draft.responseContentType = reply.getHeader("content-type")?.toString() ?? null;
    draft.responseBody = body ?? null;
    return payload;
  });

  app.addHook("onResponse", async (request: FastifyRequest, reply: FastifyReply) => {
    await writeContent(request, reply);
  });

  /**
   * Build this request's content row and store it, at most once.
   *
   * The guard is the first line rather than the caller's, so neither writer has to know about the
   * other. Every refusal below returns before the store is asked anything at all.
   */
  async function writeContent(request: FastifyRequest, reply: FastifyReply): Promise<void> {
    const draft = request.content;
    if (draft === null || draft.written) return;
    draft.written = true;
    try {
      await decide(request, reply, draft);
    } finally {
      // Whichever way the decision went — stored, refused, or failed — this request is done, and
      // `contentWritesSettled` must be able to say so. In a `finally` because a throw here would
      // otherwise leave a caller waiting on a promise nothing resolves.
      draft.settle();
    }
  }

  /** The decision itself. Every refusal returns before the store is asked anything at all. */
  async function decide(
    request: FastifyRequest,
    _reply: FastifyReply,
    draft: ContentDraft,
  ): Promise<void> {

    // **The retention answer comes first, ahead of every other check**, so that an incognito
    // request is refused before this function reads a body, decodes a capture, or looks at a store.
    // §10.1's guarantee is about what happens, not only about what is written.
    //
    // The deposited value is consulted before the body's, for `/v1/transcriptions`, whose body the
    // hook cannot read at all — `ContentFacts.retention` carries the reasoning and the failure it
    // prevents.
    const declared = retentionOf(request);
    if (!isStorable(declared)) return;

    if (!deps) {
      // Unreachable on every deployment this repository builds, and said plainly rather than dressed
      // up: a content route is authenticated (it is absent from `PUBLIC_ROUTES`), and an
      // authenticated deployment has a database, which is what supplies this store. Logged at
      // `warn` rather than `error` — unlike a lost metering event, nothing was spent that cannot be
      // recovered; what is lost is a debugging copy.
      request.log.warn(
        { route: draft.route },
        "content route served with no content store configured; nothing was retained",
      );
      return;
    }

    const account = request.auth?.accountId;
    // Refused at the gate, before any account existed to file the content under. There is nothing
    // to attribute it to and no deletion path could ever reach it, so it is not stored.
    if (account === undefined) return;

    // Only a request that actually ran the handler produced content. A replay served the original's
    // stored response and the original stored its own content; both `409`s never reached a handler
    // at all. The same `ClaimState` reading `metering/hook.ts` makes, for a different reason: there
    // it is about not spending a claim, here it is about not storing the same content twice.
    const claim = request.idempotency;
    if (claim === null || claim.kind === "replayed") return;

    const keys = keysOf(request.body);
    const facts = draft.facts;
    const requestContent = requestContentOf(draft.route, request.body);
    const occurredAt = new Date();
    const content: RetainedContent = {
      // **The declared value, not a literal and not a narrowed one** (PR #148's review, F3). The
      // guard above has already refused everything but `"standard"`; binding what was *checked*
      // rather than what it must have been is what turns the table's CHECK from decoration into the
      // backstop this hook's own header claims it is. `record.ts` carries the full reasoning.
      retention: declared,
      requestId: request.id,
      accountId: account,
      taskId: keys.taskId,
      sessionId: keys.sessionId,
      sessionIteration: keys.sessionIteration,
      route: draft.route,
      expiresAt: contentExpiryFrom(occurredAt, config.contentRetentionDays),
      provider: facts.provider ?? null,
      providerRequestId: facts.providerRequestId ?? null,
      requestText: requestContent.requestText,
      voiceAudio: facts.voiceAudio ?? null,
      voiceAudioMediaType: facts.voiceAudioMediaType ?? null,
      voiceAudioFilename: facts.voiceAudioFilename ?? null,
      screenshot: requestContent.screenshot,
      screenshotMediaType: requestContent.screenshotMediaType,
      responseStatus: draft.responseStatus,
      responseContentType: draft.responseContentType,
      responseBody: draft.responseBody,
      providerErrorStatus: facts.providerErrorStatus ?? null,
      providerErrorBody:
        facts.providerErrorBody === undefined
          ? null
          : facts.providerErrorBody.slice(0, MAXIMUM_PROVIDER_ERROR_BODY),
    };

    try {
      await deps.store.write(content);
    } catch (error) {
      // **A retention write never fails the response**, which is the same call `metering/hook.ts`
      // and `idempotency/hook.ts` both make — and here it cannot fail one anyway, because by this
      // point the response has already been sent. What is lost is the stored copy, logged with the
      // request id, which §2.3 makes the join key: the metering event for the same call is still
      // there and still says what it cost.
      request.log.error(
        { err: error, route: draft.route, requestId: request.id },
        "content could not be retained for this request",
      );
    }
  }
}
