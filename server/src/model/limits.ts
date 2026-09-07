/**
 * The numbers the five model routes are held to, in one place (SONNY-130; the vision row is
 * SONNY-131's).
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

/**
 * The image ceiling `RedactedCaptureEncoder` encodes down to, in bytes — **the client's number,
 * written here because §6.1's body limit is derived from it rather than chosen** (SONNY-131).
 *
 * `VisionCaptureEgressPolicy.default.maximumImageBytes` on the Mac is the same 3,000,000, and
 * `OpenCodeVisionModelClient`'s successor refuses above it before a request body is built. §6.1
 * states the relation the two sides have to keep: "This number and SONNY-114's are one number. If
 * `maximumImageBytes` ever moves, this limit is re-derived in the same change."
 *
 * **So this file holds the ceiling and derives the body limit from it**, rather than holding two
 * independent literals that can drift apart silently. `screenAnalyzeBodyLimitFrom` below is that
 * derivation, and `test/screen.test.ts` asserts the shipped limit is what it produces.
 */
export const MAXIMUM_IMAGE_BYTES = 3_000_000;

/**
 * How much of `/v1/screen/analyze`'s body is *not* the image, in bytes.
 *
 * §6.1's derivation: base64 turns 3,000,000 bytes into exactly 4,000,000 characters, and what sits
 * beside it is the prompt — 4,673 characters on the shipping fixture SONNY-114 measured at
 * `e260575`, growing by roughly one history line per iteration across at most twelve — plus about
 * 120 bytes of JSON envelope. 200,000 is far more than that and is where §6.1's "roughly 190,000
 * bytes of headroom" comes from.
 *
 * **`e260575` is deliberately non-ancestral and is kept verbatim**, which §6.1 already records for
 * the same figure: it is SONNY-114's pre-rebase head, and a measurement taken on one tree cannot be
 * restated at another by renaming its SHA. It is a timestamp on a branch, and the number beside it
 * is true of that branch at that moment. `git merge-base --is-ancestor e260575 origin/main` exits 1
 * by design, not by neglect.
 *
 * **Deliberately not generous.** §6.1: "Every byte of headroom above what the client can actually
 * produce is a byte that eliminates hosts for nothing."
 */
export const SCREEN_ANALYZE_ENVELOPE_HEADROOM_BYTES = 200_000;

/** How long a base64 encoding of `bytes` bytes is, exactly: `ceil(n / 3) * 4`. */
export function base64Length(bytes: number): number {
  return Math.ceil(bytes / 3) * 4;
}

/** §6.1's `/v1/screen/analyze` limit, from the client's ceiling rather than from a literal. */
export function screenAnalyzeBodyLimitFrom(imageBytes: number): number {
  return base64Length(imageBytes) + SCREEN_ANALYZE_ENVELOPE_HEADROOM_BYTES;
}

/** §6.1's per-route request body limits, in bytes, measured on the decoded body. */
export const BODY_LIMIT_BYTES = {
  plan: 1_048_576,
  synthesize: 4_194_304,
  transcriptions: 10_485_760,
  search: 1_048_576,
  /** 4,200,000 — and it is `screenAnalyzeBodyLimitFrom(MAXIMUM_IMAGE_BYTES)`, not a coincidence. */
  screenAnalyze: screenAnalyzeBodyLimitFrom(MAXIMUM_IMAGE_BYTES),
} as const;

/**
 * §6.3's response ceiling, in bytes.
 *
 * **Enforced on `/v1/screen/analyze` and nowhere else yet**, which is a scope statement rather than a
 * claim about the gateway. §6.3 caps *every* response at 1 MiB "so an unexpected provider reply
 * cannot become an unbounded client-side allocation"; the four text routes live in
 * `routes/model.ts`, which is on SONNY-131's never-touch list, so this ticket could not reach them.
 * The vision route is the one SONNY-130's own hand-over note called "the one whose replies are least
 * predictable", so it is also the one worth having first. **SONNY-316** carries the other four.
 */
export const RESPONSE_LIMIT_BYTES = 1_048_576;

/**
 * §12's deadlines, in milliseconds.
 *
 * `upstream` bounds the call to the provider and is what produces `504 provider.timeout`. `total`
 * bounds the whole handler — the upstream call plus this server's own work around it — and exists
 * so that a hang anywhere in the handler still ends as this server's own typed failure rather than
 * as whatever the platform in front does when it gives up.
 *
 * **The margin between the two is §12's and is not one number.** It is fifteen seconds on `plan`,
 * `synthesize`, `transcriptions` and `screenAnalyze`, and **five** on `search` — which the five
 * literals below disprove any other claim about. This said "the 15-second difference" until PR #139's G1, the
 * third and last site of a wrong figure F2 corrected in the two others; the invariant that does hold
 * on every row is the ordering, `upstream < total`, and `test/model.test.ts` asserts both the
 * literals and the ordering rather than a margin.
 */
export const DEADLINE_MS = {
  plan: { upstream: 60_000, total: 75_000 },
  synthesize: { upstream: 90_000, total: 105_000 },
  transcriptions: { upstream: 60_000, total: 75_000 },
  search: { upstream: 20_000, total: 25_000 },
  /**
   * §12's longest budget, shared with `synthesize`, and it is the row SONNY-130 left for this
   * ticket. A vision call carries megabytes upstream and waits on a large model, and a session
   * spends up to twelve of them in sequence.
   */
  screenAnalyze: { upstream: 90_000, total: 105_000 },
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
   * - **The four content-deletion routes in `routes/tasks.ts` are wired now, and not by this
   *   wrapper** (SONNY-428). They were on SONNY-425's never-touch list while PR #207 held that file.
   *   They reach no provider and every one of them holds a pooled connection, so `withDeadlines` is
   *   forbidden for them by PR #212's F1 and the `upstream` half of this row has nothing to bound:
   *   they take `CONTENT_DELETION_DEADLINE_MS` below, through `withDatabaseDeadline`.
   * - Three of the four account routes (`routes/entitlements.ts`, and the read and the consent
   *   switch in `routes/credits.ts`) wait on the database rather than on a provider, and
   *   `db/pool.ts` sets no statement timeout — so bounding those is a wider change than one route's
   *   wrapper and is filed rather than half-made here (SONNY-427).
   * - **`POST /v1/account/credits/top-up` is the fourth and is not database-bound at all**: it
   *   charges at the payment provider, spending `TOPUP_CHARGE_TIMEOUT_MS` up to three times in
   *   sequence, so its upstream work can outlast this row several times over. It is **SONNY-430**
   *   (2026-09-06), and it is named separately because it was folded into the sentence above until
   *   PR #212's F4 — the lane's own enumeration had the exception and every record after it dropped
   *   the exception rather than the enumeration, which is `CLAUDE.md`'s enumerate-before-you-subtract
   *   rule failing at its last step instead of its first.
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
 * deadlines. **The JSON routes sit 75 seconds inside the lease rather than fifteen**, so this row is
 * the tight one and the one the lease is sized for; an earlier version of this line said the margins
 * were the same, which was true only while the lease was 120.
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
 * §12's last row applied to the four content-deletion routes in `routes/tasks.ts` (SONNY-428).
 *
 * **Derived from `DEADLINE_MS.auth` rather than written as a second pair of literals**, because §12
 * refuses these routes a row of their own in as many words: "SONNY-404's three deletes are in that
 * last row and take no row of their own: they are the same database work as 4.6's, over more rows
 * or over fewer columns, and none of them calls a provider." Two literals that have to stay equal
 * are two literals that can drift, and the table `test/model.test.ts` asserts whole is the one
 * place §12's numbers live.
 *
 * **`total` alone, and the missing `upstream` is the point rather than an omission.** Every other
 * consumer of that row is bounding a call to a provider; these four reach no provider at all, so an
 * `upstream` field here would be a number nothing applies — and `withDatabaseDeadline` takes
 * `{ total }` precisely so a caller cannot wire a signal that bounds nothing. What binds these
 * routes is the whole-handler deadline, enforced against Postgres rather than against a socket.
 */
export const CONTENT_DELETION_DEADLINE_MS = { total: DEADLINE_MS.auth.total } as const;
