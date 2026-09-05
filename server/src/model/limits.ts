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
} as const;

/**
 * How long `POST /v1/transcriptions` may spend *reading its body*, in milliseconds (SONNY-322).
 *
 * **This route is the one whose body is read inside the handler**, so it is the one route where the
 * body read is not covered by anything above. §4.4's body is `multipart/form-data`, consumed by
 * `request.parts()` in the handler; `DEADLINE_MS` above is applied by `routes/model.ts` to the
 * *upstream call* alone, and Fastify's `requestTimeout` — which `app.ts` now sets — bounds receipt of
 * the request but is enforced on a thirty-second sweep and measured landing a minute or more late,
 * so it cannot hold an interval this tight. Every other route's body is parsed by Fastify before the
 * handler runs.
 *
 * **The number is derived from `CLAIM_LEASE_SECONDS`, which is what it exists to make true.** An
 * `Idempotency-Key` claim is taken in a `preHandler` hook — before this route's body read, because
 * the body is read in the handler — and §9.2's fourth bullet promises that a key in flight is never
 * a second upstream call. The interval the lease has to cover is therefore the body read plus the
 * rest of the handler:
 *
 *     body read (30 s) + this route's total deadline (75 s) = 105 s  <  CLAIM_LEASE_SECONDS (120 s)
 *
 * That leaves fifteen seconds of margin, which is the same margin §12 gives this route between its
 * upstream and total deadlines. `idempotency/store.ts` states the relationship from the lease's side;
 * this is the constant that makes it hold, and `model.test.ts` asserts the inequality rather than
 * either number alone, so a later change to one of the three cannot quietly break it.
 *
 * **What a real caller needs, checked rather than assumed.** SONNY-130's cap is a duration enforced
 * on the Mac — `MAXIMUM_AUDIO_DURATION_SECONDS` below, 180 s, roughly 2 MB at the recorder's AAC
 * bitrate — so thirty seconds is about 560 kbit/s for the longest recording this client will send.
 * The 10 MiB byte ceiling is a backstop against a client that is not ours, and a caller trying to
 * push 10 MiB through this route slowly is the shape this deadline exists to end.
 */
export const BODY_READ_DEADLINE_MS = 30_000;

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
