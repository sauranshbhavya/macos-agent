/**
 * The numbers the four model routes are held to, in one place (SONNY-130).
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
  plan: 1_048_576,
  synthesize: 4_194_304,
  transcriptions: 10_485_760,
  search: 1_048_576,
} as const;

/**
 * §12's deadlines, in milliseconds.
 *
 * `upstream` bounds the call to the provider and is what produces `504 provider.timeout`. `total`
 * bounds the whole handler — the upstream call plus this server's own work around it — and exists
 * so that a hang anywhere in the handler still ends as this server's own typed failure rather than
 * as whatever the platform in front does when it gives up. The 15-second difference between them is
 * §12's, not this file's.
 */
export const DEADLINE_MS = {
  plan: { upstream: 60_000, total: 75_000 },
  synthesize: { upstream: 90_000, total: 105_000 },
  transcriptions: { upstream: 60_000, total: 75_000 },
  search: { upstream: 20_000, total: 25_000 },
} as const;

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
