import { DEADLINE_MS } from "../model/limits.js";

/**
 * When a spend period starts, and how long a hold survives without being settled (SONNY-135).
 *
 * Both are computed here rather than inside a SQL statement, so both are testable against an
 * injected clock instead of against `now()` on a database nobody can move.
 */

/**
 * The start of the period `at` falls in: **the UTC calendar month**.
 *
 * **A boundary rather than a billing cycle, and the distinction is the whole of why this is not
 * SONNY-212's decision.** A real billing period runs from a subscription's own anchor date, which
 * needs a subscription record — row 13's, and nothing writes one today. What the cap mechanism needs
 * before that exists is *some* period the counter resets on, and a calendar month is the one choice
 * that needs no record at all: it is derivable from the instant alone, it is the same for every
 * account, and it is what a user reading "you are out for this period" would assume.
 *
 * When subscriptions land, this becomes the fallback for an account that has none, and the anchored
 * period becomes the answer for one that does. The single call site is `store.ts`'s reserve, so that
 * is a change in one place.
 *
 * **UTC and not the user's zone**, for the reason §3.5 gives about every other instant on this wire:
 * the server owns the clock. A period boundary in local time would move with a laptop's timezone,
 * so a user crossing a date line would reset — or lose — a period by flying.
 */
export function periodStart(at: Date): Date {
  return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), 1));
}

/**
 * How long an unsettled hold is left alone before the sweep may reclaim it: **300 seconds**.
 *
 * **Derived from this gateway's own longest request deadline, which is what changed with the host.**
 * The original motivation for this window was Supabase Edge Functions terminating a request at 150 s
 * (`docs/sonny-row-12-host-decision.md` §4.3), and SONNY-125's hand-over on this ticket says
 * explicitly that the platform cut "is gone with the VM decision, so the window should now be
 * derived from the gateway's own request deadline instead". It is: §12's longest total deadline is
 * **105,000 ms** — `synthesize` and `screenAnalyze` — and this is that with a wide margin.
 *
 * **The direction that matters is the floor, not the ceiling.** A window *shorter* than a request's
 * own deadline would let the sweep reclaim a hold belonging to a request that is still running, and
 * that request would then settle against a reservation already given back — a double spend, and in
 * the direction that costs the founder money. So the window has to exceed the longest deadline by
 * enough to cover a process that is slow to die, not merely to equal it. Being generous the other
 * way costs only that a crashed request's hold sits unusable for a few minutes.
 *
 * `LONGEST_TOTAL_DEADLINE_MS` is read off `DEADLINE_MS` rather than written as a literal, so a route
 * whose deadline grows past this window fails `theSweepWindowClearsTheLongestRouteDeadline` instead
 * of silently acquiring the double-spend above.
 */
export const RESERVATION_TTL_SECONDS = 300;

/** The longest `total` in §12's table, in milliseconds. Computed, so a new route cannot be missed. */
export const LONGEST_TOTAL_DEADLINE_MS = Math.max(
  ...Object.values(DEADLINE_MS).map((deadline) => deadline.total),
);

export function reservationExpiry(at: Date): Date {
  return new Date(at.getTime() + RESERVATION_TTL_SECONDS * 1000);
}
