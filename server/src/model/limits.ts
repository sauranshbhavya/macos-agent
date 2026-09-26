/**
 * The numbers the gateway's HTTP routes are held to, in one place (SONNY-130). The V2 session's own
 * budgets live with the agent.
 *
 * Three unrelated tables live here rather than beside their routes, and the reason is that each of
 * them is a *pair* of numbers that has to agree with something outside this file:
 *
 * - **Body limits** agree with `docs/sonny-backend-api-contract.md` §6.1, and with the client's own
 *   ceiling. §6.2 states the direction that matters: the server's limit must be greater than or
 *   equal to the client's, because a client that believes its payload is fine and gets a 413 has a
 *   failure it cannot explain and cannot fix by retrying.
 * - **Deadlines** agree with §12, whose governing rule is that the client's timeout is always longer
 *   than the server's total deadline — so a slow route surfaces as this server's typed
 *   `504 provider.timeout`, which the app can explain, rather than as the client's opaque transport
 *   timeout, which it cannot tell apart from a dead network. Every number below is therefore also
 *   written in `SonnyBackendTimeouts` on the Swift side, one row apart.
 * - **The audio cap** is SONNY-130's own, and it is the one number here that does not come from the
 *   contract: §4.4 records that the recorder has no maximum duration and says "the duration cap and
 *   its user-facing refusal are SONNY-130's".
 */

/** §6.1's per-route request body limits, in bytes, measured on the decoded body. */
export const BODY_LIMIT_BYTES = {
  transcriptions: 10_485_760,
} as const;

/**
 * §12's deadlines, in milliseconds.
 *
 * `upstream` bounds the call to the provider and is what produces `504 provider.timeout`. `total`
 * bounds the whole handler — the upstream call plus this server's own work around it — and exists
 * so that a hang anywhere in the handler still ends as this server's own typed failure rather than
 * as whatever the platform in front does when it gives up.
 *
 * **The margin between the two is §12's and is not one number**: fifteen seconds on
 * `transcriptions`, five on `auth`, six on `topUp`. The invariant that holds on every row is the
 * ordering, `upstream < total`, and `test/model.test.ts` asserts both the literals and the ordering
 * rather than a margin.
 */
export const DEADLINE_MS = {
  transcriptions: { upstream: 60_000, total: 75_000 },
  /**
   * §12's last row — "auth, account, meta, health, delete" — at the numbers that table states
   * (SONNY-425). It is the only row here that is not one route, and the reason it is one entry is
   * that §12 writes it as one: every route it covers gets the same budget.
   *
   * **What applies it, and what deliberately does not, because the row names more routes than the
   * code wires.** `routes/auth.ts` applies it to all five of its handlers. Three routes it names are
   * not wired and each is a different reason, stated here rather than left to be re-derived from
   * the absence:
   *
   * - `GET /v1/health` and `GET /v1/meta` await nothing at all — no database, no provider — so a
   *   deadline around them is a timer that cannot fire. §12 carries that in prose beside its table.
   * - **Three `/v1/account/*` routes are wired by a second shape** (SONNY-434).
   *   `routes/entitlements.ts`, and the read and the consent switch in
   *   `routes/credits.ts`, wait on the database rather than on a provider, and their stores lease
   *   connections internally, so the handler holds no client for `withDatabaseDeadline` to wrap.
   *   They take `ACCOUNT_DEADLINE_MS` below through `underTotalDeadline`, a request-scoped budget
   *   every lease inside the handler reads, beneath which the per-statement bound `db/pool.ts` sets
   *   (SONNY-427) still holds — each statement takes the smaller of the two; `model/routing.ts`
   *   carries the reasoning. Outside that scope, and everywhere else, the pool's bound governs alone.
   * - **`POST /v1/account/credits/top-up` is not database-bound at all**: it charges at the
   *   payment provider, so this row was never its. It has its own row below (SONNY-430).
   *
   * **`upstream` is enforced at the adapter as well as at the wrapper, and that is not a
   * duplication.** `auth/deps.ts` builds the Supabase adapter with `timeoutMs` read from this field,
   * so the per-request `AbortSignal.timeout` inside `auth/supabase.ts` *is* §12's number rather than
   * a literal that happened to match it; the wrapper's own signal then bounds the route's whole
   * upstream budget, which is a different quantity on `DELETE /v1/account` — that handler drains
   * every identity on the account, so without a shared signal its upstream time is N times the
   * adapter's bound.
   */
  auth: { upstream: 10_000, total: 15_000 },
  /**
   * §12's own row for `POST /v1/account/credits/top-up` (SONNY-430) — **the one route here that
   * charges a card**, and the reason it is not in the `auth` row above.
   *
   * ## Where the 24 comes from, and why it is not 36
   *
   * The charge is a draft order and then a finalize, each bounded at `TOPUP_CHARGE_TIMEOUT_MS`
   * (12 s) in `billing/polar.ts` — **so this is that constant doubled, and `topup.test.ts` holds the
   * relation** rather than these being two literals that agree today. A third HTTP call exists, the
   * read-back the finalize makes on a `412`, and SONNY-430 made it share the finalize's budget
   * instead of taking a fresh one; before that a single top-up could spend 36 s.
   *
   * **36 was not available as a row, which is what settled the ticket's either/or.**
   * `SonnyBackendTimeouts.topUp` on the Mac is 40 s and its own comment derives that from two calls
   * at twelve seconds. A 36 s upstream wants a total near 42 s, which is longer than the client's 40
   * and inverts this table's governing rule — and moving the client's number is a change on the app
   * half. The other direction, folding the charge into `auth`'s 10 s, was rejected as the money-unsafe
   * one: three calls inside 10 s is about 3.3 s each, and `TOPUP_CHARGE_TIMEOUT_MS` argues that even
   * eight is not obviously above a healthy card authorisation, so every second cut turns a slow-but-
   * working charge into an abort mid-flight — which is recorded `unconfirmed`, granting nothing for
   * money that may have moved. A bound must not manufacture that state on healthy traffic.
   *
   * ## The six seconds of margin, and what enforces each column
   *
   * `total` covers `attemptTopUp` — the customer lookup, the outstanding query, the claim, the
   * order-id write, the charge and the settle — and 30 s leaves the client's 40 s ten seconds of
   * headroom for it. **Two database reads sit outside it and are named rather than implied**
   * (PR #220's F4): `routes/credits.ts` awaits `position()` before the wrapper and again after it, so
   * the route's worst-case answer is this number plus those two round trips. This gateway sets no
   * statement timeout — the `auth` row above and SONNY-427 both say so — so that remainder is not
   * bounded by anything here; in practice it is milliseconds, and the honest statement is that the
   * bound is on the charge rather than on the handler. An earlier version of this sentence listed
   * both reads among the seven things `total` covers, which is the enumerate-before-you-subtract
   * shape in the file that defines the number.
   *
   * **`upstream` is enforced at the adapter and `total` at the route**, which is the same split the
   * `auth` row's last paragraph describes — and it is that row's *mechanism* too, not just its shape:
   * `billing/polar.ts` reads `TOPUP_CHARGE_TIMEOUT_MS` off this field (`upstream / 2`, two calls being
   * what a top-up makes), exactly as `auth/deps.ts` passes `DEADLINE_MS.auth.upstream` into the
   * Supabase adapter. **That arrow used to point the other way and the sentence was unbacked**
   * (PR #220's F1): the adapter held a `12_000` of its own and this field had no production reader,
   * so a mutant tripling the budget at its use site passed all 1295 tests — and 36 s of upstream under
   * a 30 s total inverts the two, cutting every slow charge off mid-flight. What differs from the
   * `auth` row is the answer when `total` elapses:
   * `routes/credits.ts` sends `502 topup.unconfirmed` and **not** `504 provider.timeout`, because a
   * charge may be in flight at that instant and `provider.timeout` is marked retryable — telling a
   * client to retry is how PR #196's F1 bought a second pack. §12 records two auth routes that
   * likewise do not answer `504` on their deadline; this is the third, and for the sharpest reason.
   */
  topUp: { upstream: 24_000, total: 30_000 },
} as const;

/**
 * How long `POST /v1/transcriptions` may spend *reading its body*, in milliseconds (SONNY-322).
 *
 * **This route is the one whose body is read inside the handler**, so it is the one route where the
 * body read is not covered by anything above. §4.4's body is `multipart/form-data`, consumed by
 * `request.parts()` in the handler; `DEADLINE_MS` above is applied by `routes/model.ts` to the
 * *upstream call* alone, and Fastify's `requestTimeout` — which `app.ts` sets — bounds receipt of the
 * request but is enforced on a thirty-second sweep and measured landing a minute or more late, so it
 * cannot hold an interval this tight. Every other route's body is parsed by Fastify before the
 * handler runs.
 *
 * **Ninety seconds, which is §12's client timeout for this route — the founders' decision of
 * 2026-09-05, option A on PR #208's F4.** The first version of this constant was 30 s, derived from
 * the idempotency lease alone, and that derivation asked the wrong question: it held
 * `CLAIM_LEASE_SECONDS` fixed and solved for the upload, when the lease is this repository's own
 * constant — fixed by nothing outside the gateway, buying only how soon a key held by a *killed*
 * process becomes re-claimable — while §12's 90 s is a number the shipping client actually waits
 * (`SonnyBackendClient`'s `transcription = 90`). At 30 s the gateway gave up at a third of the budget
 * its own client was prepared to spend, **inverting §12's governing rule** that the client's timeout
 * is always longer than the server's, on the one route where an upload is the slow part. On a weak
 * hotspot — where somebody dictating a command on the move actually is — a three-minute recording
 * could not get through at all: the Mac's own ceiling is roughly two megabytes for 185 seconds
 * (`AudioCommandRecorder`), so 30 s demanded about 533 kbit/s sustained upstream and 90 s asks about
 * 178 kbit/s.
 *
 * **The lease moved to make room, rather than this number being tuned against it.** The arithmetic
 * is the same shape at both ends, and it is the shape rather than either literal that
 * `model.test.ts` asserts:
 *
 *     body read (90 s) + this route's total deadline (75 s) = 165 s  <  CLAIM_LEASE_SECONDS (180 s)
 *
 * Fifteen seconds of margin — the same margin §12 gives this route between its upstream and total
 * deadlines. Every other row sits much further inside the lease, so this row is the tight one and
 * the one the lease is sized for.
 * `idempotency/store.ts` states the relationship from the lease's side and carries the cost the
 * founders accepted with it: a process killed mid-request now holds its key for a minute longer
 * before a repeat can take it.
 */
export const BODY_READ_DEADLINE_MS = 90_000;

/**
 * The longest recording this gateway will transcribe, in seconds — **SONNY-130's cap, and the
 * number the client's own refusal is built from.**
 *
 * `AudioCommandRecorder` records AAC mono 44.1 kHz with **no maximum duration**, so a hotkey that
 * sticks — or a user who walks away holding it — is an upload with no ceiling, billed to the
 * founder the moment it goes through this gateway rather than through the user's own key.
 *
 * **180 seconds, derived rather than picked.** It is what a spoken *command* can plausibly need:
 * ordinary speech runs 2–3 words a second, so three minutes is 350–500 words, which is longer than
 * any command Sonny can act on and longer than the longest thing a user would dictate into a
 * `create_local_draft` step. Anything past it is not a command, it is a recorder nobody stopped.
 *
 * **Why the byte limit is not this limit.** The two are enforced in different units on purpose,
 * because each side can only measure one of them honestly. The Mac knows the duration — it is the
 * side holding the recorder — and refuses there, before a byte is sent. This server never receives
 * a duration it could trust (a client-supplied one would be a client-trust decision on the field
 * that decides the bill, which §2.4.1 forbids in general), so it enforces §6.1's byte ceiling
 * instead. The two are ordered the way §6.2 requires: at the AAC bitrate this recorder produces,
 * 180 seconds is roughly 2 MB, so the client's cap binds an order of magnitude before this
 * server's 10 MiB does — the byte limit is the backstop for a client that is not ours, or is
 * broken, and never the thing an ordinary user meets.
 */
export const MAXIMUM_AUDIO_DURATION_SECONDS = 180;

/**
 * §12's last row applied to the three account routes whose slow work is the database (SONNY-434):
 * `GET /v1/account/entitlements`, `GET /v1/account/credits` and `PUT /v1/account/credits/auto-top-up`.
 *
 * Derived from `DEADLINE_MS.auth` rather than written as a second pair of literals that could
 * drift, and `total` alone because none of the three reaches a provider, so an `upstream` here would
 * bound nothing. What applies it is `underTotalDeadline` in `model/routing.ts`, a budget the request
 * carries to every lease its stores take, because those stores lease internally and the handler
 * never holds a client for the deletion routes' wrapper to bound.
 *
 * **`POST /v1/account/credits/top-up` is not on this constant**, though it reads the same store: it
 * has its own row above (`topUp`) and its own answer when that elapses, and its reads before and
 * after the charge stay on the pool's per-statement bound, exactly as before this constant existed.
 */
export const ACCOUNT_DEADLINE_MS = { total: DEADLINE_MS.auth.total } as const;
