/**
 * How a V2 session ends. Each goodbye reason has one WebSocket close code, so the Mac can tell from
 * the code alone whether to reconnect at once, refresh its token first, or stop.
 */
export type GoodbyeReason = "draining" | "replaced" | "signed_out" | "auth_expired";

export const CLOSE_CODE = {
  /** A deploy is restarting the gateway. Reconnect after the pause the goodbye names. */
  draining: 1012,
  /** A newer session from the same device took over. Don't reconnect. */
  replaced: 4409,
  /** The account or its sign-in session ended. Sign in again. */
  signed_out: 4403,
  /** The access token expired or a reauth was refused. Refresh, then reconnect. */
  auth_expired: 4401,
  /** The Mac broke the protocol: no hello in time, a binary frame, or a message before hello. */
  protocol: 4400,
  /** The account sent messages faster than its rate. Reconnect with backoff. */
  rate_limited: 4429,
  /**
   * The gateway could not handle a message, or a message before it never arrived. The Mac ignores
   * error frames, so closing is how it hears this: it reconnects, the welcome says what the gateway
   * has, and the Mac sends everything after that again.
   */
  internal: 1011,
} as const;

/** The shortest a Mac waits before reconnecting to a draining gateway. */
export const DRAIN_RECONNECT_AFTER_MS = 1000;
/**
 * How far past that each Mac's wait is spread, so a deploy doesn't bring every Mac back in the same
 * second, all of them wanting a database connection for hello at once.
 */
export const DRAIN_RECONNECT_SPREAD_MS = 4000;

export function drainReconnectAfterMs(random: () => number = Math.random): number {
  return DRAIN_RECONNECT_AFTER_MS + Math.floor(random() * DRAIN_RECONNECT_SPREAD_MS);
}
