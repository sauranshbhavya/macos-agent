import type { Config } from "../config.js";

/**
 * What the server records per HTTP model call — contract §11 — as a type, a route map and one pure
 * decision (SONNY-133).
 *
 * **This module produces the measurement and never a price.** Everything here is a token count, a
 * byte count, a duration or an outcome. Credits are charged elsewhere, by tokens, on the V2 agents'
 * own ledger (`agent/credits.ts`).
 */

/**
 * The routes a metering row is written for. Only `transcription` remains: it is the Mac's one direct
 * model route. The model calls inside a task are recorded as `sonny.agent_model_call` rows instead.
 */
export const meteredRoutes = ["transcription"] as const;
export type MeteredRoute = (typeof meteredRoutes)[number];

/** §11's `outcome` enum, exactly. */
export const meteringOutcomes = [
  "ok",
  "provider_error",
  "server_error",
  "refused",
  "client_cancelled",
] as const;
export type MeteringOutcome = (typeof meteringOutcomes)[number];

/**
 * Which `METHOD path` is which §11 route.
 *
 * **A map rather than a per-route call, for the reason `auth/gate.ts` and `idempotency/hook.ts`
 * both give.** A route that has to remember to meter itself is a route where the author who did not
 * think about metering ships something that serves correctly, passes its own tests and is free. The
 * hook reads this map, so a route is metered by being in it — and
 * `everyPostRouteIsEitherMeteredOrDeclaredUnmetered` walks the built app's real route table, so a
 * new `POST` fails that test until somebody classifies it either way.
 *
 * `POST /v1/transcriptions` maps to `transcription` because §11's enum is singular there.
 */
export const METERED_ROUTES: ReadonlyMap<string, MeteredRoute> = new Map([
  ["POST /v1/transcriptions", "transcription" as const],
]);

/**
 * The `POST`s this gateway serves that deliberately meter nothing, and why each one does not.
 *
 * Auth routes cost this gateway a Supabase call and no provider tokens, they run before a caller has
 * an account to attribute anything to (five of the six are public), and §11's `route` enum has no
 * value for them. `DELETE /v1/account` is a `DELETE` and never reaches the hook. Listed rather than
 * left implicit so that the population scan can require *every* `POST` to be one thing or the other:
 * an unlisted new route is an unanswered question rather than a silent free one.
 */
export const UNMETERED_POST_ROUTES: ReadonlySet<string> = new Set([
  "POST /v1/auth/email/start",
  "POST /v1/auth/email/verify",
  // SONNY-129's two. The first builds a URL and calls nothing; the second is one Supabase call,
  // exactly like `email/verify` beside it.
  "POST /v1/auth/oauth/google/start",
  "POST /v1/auth/oauth/google",
  "POST /v1/auth/refresh",
  "POST /v1/auth/signout",
  /**
   * SONNY-215's top-up, and the one entry here that costs real money while metering nothing.
   *
   * **The two are different currencies and merging them is what SONNY-212 and SONNY-213 each
   * declined.** §11's event records what a call cost this gateway in *provider* tokens, and this
   * route opens no provider call of that kind — what it opens is a charge at the payment provider,
   * whose record is `sonny.credit_topup` and whose amount is the user's rather than the founders'.
   * Metering it would put a payment into the table the credit balance is derived from, so a top-up
   * would draw down the allowance it just bought.
   */
  "POST /v1/account/credits/top-up",
]);

export function meteredRouteFor(method: string, routeUrl: string): MeteredRoute | undefined {
  return METERED_ROUTES.get(`${method} ${routeUrl}`);
}

/**
 * The §7.2 codes that mean an upstream provider was reached and did not produce a usable answer.
 *
 * **Keyed on `code`, never on status** — §9.3's own rule, and load-bearing here for the same reason
 * it is there: `502` carries both `provider.unavailable` and `provider.rejected`, and `504` is a
 * timeout while `500` is this gateway's bug. A status-keyed mapping would file the gateway's own
 * 500s as provider failures and make failover accounting a fiction.
 */
const PROVIDER_FAILURE_CODES: ReadonlySet<string> = new Set([
  "provider.unavailable",
  "provider.timeout",
  "provider.rejected",
]);

/** The codes that mean this gateway itself failed. §7.2 case 6. */
const SERVER_FAILURE_CODES: ReadonlySet<string> = new Set(["server.error", "server.unavailable"]);

export interface OutcomeInput {
  readonly status: number;
  /** The `{ error: { code } }` §7.1 puts on every failure, or `undefined` on a success. */
  readonly errorCode: string | undefined;
  /** Whether the handler actually opened a call to a provider. */
  readonly upstreamAttempted: boolean;
  /** Whether the caller's socket was gone by the time the response was finished. */
  readonly clientGone: boolean;
}

/**
 * Which of §11's five outcomes this exchange was.
 *
 * **A pure function so the decision is testable apart from the wiring**, the same split
 * `idempotency/hook.ts` makes with `errorCodeOf`. Every branch below is reachable from a real
 * request on a real route, and `metering.test.ts` drives each one through the whole app.
 *
 * The order is the argument:
 *
 * 1. **A caller who went away is judged on whether anything was spent, before anything else.** §12:
 *    "A cancelled request may still have cost money. If the server observed the upstream call
 *    complete, it writes a metering event with `outcome: client_cancelled`. Silently free
 *    cancellations would be a hole in the spend cap." So a cancellation that reached a provider is
 *    `client_cancelled`, and one that arrived before any provider was called spent nothing and is a
 *    `refused` — the same treatment the 400s get and for the same reason. It comes first because a
 *    cancelled request has no meaningful status: the reply was never sent, so `reply.statusCode` is
 *    still the default 200 and a status test would call it `ok`.
 *    **`upstreamAttempted` is "a call was opened", not "a call completed"**, which is deliberately
 *    wider than §12's sentence: a provider that has read the request and is composing an answer has
 *    already been paid for the input tokens, and the gateway cannot tell that state apart from one
 *    where nothing was spent. The wider reading errs toward recording a cost that happened; the
 *    narrower one would silently drop exactly the case §12 says not to.
 * 2. **Success is success.** Any 2xx or 3xx is `ok`, whatever else was going on.
 * 3. **This gateway's own failure beats a provider's**, because `server.error` is a 500 and a naive
 *    status test would file every 5xx together.
 * 4. **Nothing spent is `refused`.** A validation 400, a 413 over the body limit, and the
 *    `502 provider.unavailable` a route with no configured adapter answers — all of them before any
 *    upstream call. The last is the least obvious: without the `upstreamAttempted` gate, a
 *    deployment missing a credential would record a provider failure per request against a provider
 *    it never called.
 *
 *    **A `409 idempotency.conflict` would land here too, and the hook never asks** (corrected
 *    2026-08-28, PR #147's review, F5 — this list named it as if it did). Both 409 paths leave
 *    `request.idempotency` as `null`, and `metering/hook.ts` returns on that before it builds an
 *    event: a conflicting request never took the key's claim, so metering it would take the claim
 *    out from under the request that is doing the work. So the answer this function gives for that
 *    input is real — `metering.test.ts` drives it — and nothing in the gateway consults it.
 * 5. **Everything left with a provider code is a provider failure**, and anything else is a refusal.
 */
export function outcomeFor(input: OutcomeInput): MeteringOutcome {
  if (input.clientGone) return input.upstreamAttempted ? "client_cancelled" : "refused";
  if (input.status < 400) return "ok";
  if (input.errorCode !== undefined && SERVER_FAILURE_CODES.has(input.errorCode)) {
    return "server_error";
  }
  // A 5xx with no readable envelope is this gateway's, not a provider's: every provider failure this
  // server produces carries one of §7.2's codes, and a body that could not be parsed for a code came
  // from somewhere other than `errorBody`.
  if (input.errorCode === undefined && input.status >= 500) return "server_error";
  if (!input.upstreamAttempted) return "refused";
  if (input.errorCode !== undefined && PROVIDER_FAILURE_CODES.has(input.errorCode)) {
    return "provider_error";
  }
  return "refused";
}

/**
 * The model identifier this deployment serves `route` with when `provider` answers, read from the
 * same `Config` the adapter was built from. `undefined` when no provider answered or the provider is
 * one this gateway has no model setting for.
 */
export function modelForRoute(
  config: Config,
  route: MeteredRoute,
  provider: string | undefined,
): string | undefined {
  if (route === "transcription" && provider === "openai") return config.openAITranscriptionModel;
  return undefined;
}

/**
 * One row of `sonny.metering_event`. Every field the §11 table names, and nothing that is content.
 *
 * `null` is used rather than `undefined` throughout, because each of these is written to a column
 * and the two would otherwise be one more thing to normalise at the boundary.
 */
export interface MeteringEvent {
  readonly requestId: string;
  readonly idempotencyKey: string | null;
  readonly accountId: string;
  readonly route: MeteredRoute;
  readonly provider: string | null;
  readonly failedOver: readonly string[];
  readonly model: string | null;
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly totalTokens: number | null;
  readonly tokenSource: "reported" | "estimated" | null;
  readonly imageBytes: number | null;
  readonly imagePixelWidth: number | null;
  readonly imagePixelHeight: number | null;
  readonly imageMediaType: string | null;
  readonly audioDurationSeconds: number | null;
  readonly requestBytes: number | null;
  readonly responseBytes: number | null;
  readonly durationMs: number;
  readonly upstreamDurationMs: number | null;
  readonly outcome: MeteringOutcome;
  readonly taskId: string | null;
  readonly sessionId: string | null;
  readonly sessionIteration: number | null;
  readonly retention: "standard" | "none" | null;
  readonly clientVersion: string | null;
}
