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
} as const;

/** How long a Mac should wait before reconnecting to a draining gateway. */
export const DRAIN_RECONNECT_AFTER_MS = 1000;
