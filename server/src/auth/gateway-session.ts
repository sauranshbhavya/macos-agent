import type pg from "pg";
import { verifyAccessToken, type SupabaseJwtPolicy } from "./token.js";

/**
 * The provider sessions this gateway started, and the one question the gate asks of them
 * (SONNY-129, migration 0023).
 *
 * **Why this exists.** The gate used to trust any token the project signed, by its `sub`. Supabase
 * links sign-ins with the same verified address into one provider-side user and mints a session for
 * that user to anyone who asks it directly, so once a second sign-in method is enabled a session this
 * gateway never saw can name a user that belongs to somebody else's account. Migration 0023's header
 * carries the case in full. The answer is that the gate accepts a session only when one of this
 * gateway's own sign-in routes started it, and this file is where "started it" is written and read.
 */

/** Which sign-in route started a session. The migration's `CHECK` holds the same two values. */
export type SignInMethod = "email" | "google";

/** What the sign-in route learned from the token Supabase just minted. */
export interface MintedSession {
  readonly supabaseUserId: string;
  readonly sessionId: string;
}

/**
 * Read the session a freshly minted access token belongs to, **verified exactly as the gate will
 * verify every later token of it**, or `undefined` when that cannot be done.
 *
 * **Verified rather than decoded, and the reason is what failing here buys.** The token came from
 * the provider over TLS a moment ago, so decoding its claims would be as trustworthy as the tokens
 * themselves. But a token this gateway cannot verify is a session that will be refused on every
 * request it makes — SONNY-280 found the real project provisioned with a signing key the gateway
 * does not accept — and finding that out at sign-in turns "signed in, and then every request says
 * sign in again" into one clear failure at the moment it can still be reported.
 *
 * **`sub` must match the user the provider said it signed in.** A mismatch is a provider answer this
 * gateway does not understand, and recording either id would be recording a guess.
 */
export function mintedSessionOf(
  accessToken: string,
  expectedSupabaseUserId: string,
  policy: SupabaseJwtPolicy,
  now: Date,
): MintedSession | undefined {
  const verdict = verifyAccessToken(accessToken, policy, now);
  if (!verdict.ok) return undefined;
  const { supabaseUserId, providerSessionId } = verdict.token;
  if (providerSessionId === undefined || supabaseUserId !== expectedSupabaseUserId) return undefined;
  return { supabaseUserId, sessionId: providerSessionId };
}

/**
 * Record that this gateway started `session` for `accountId`.
 *
 * **One statement, and a conflicting row is an error rather than a no-op.** A provider session id is
 * minted once, so the only honest repeat is the same session for the same user and account — which
 * the `DO UPDATE ... WHERE` arm accepts and returns — and a repeat naming anything else is a provider
 * answer this gateway cannot explain. It throws, the route answers `500`, and no token is handed out
 * for a session whose row says something different.
 */
export async function recordGatewaySession(
  client: pg.Client,
  session: MintedSession,
  accountId: string,
  method: SignInMethod,
): Promise<void> {
  const { rows } = await client.query<{ session_id: string }>(
    `INSERT INTO sonny.gateway_session (session_id, supabase_user_id, account_id, method)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (session_id) DO UPDATE SET session_id = EXCLUDED.session_id
       WHERE sonny.gateway_session.supabase_user_id = EXCLUDED.supabase_user_id
         AND sonny.gateway_session.account_id = EXCLUDED.account_id
     RETURNING session_id`,
    [session.sessionId, session.supabaseUserId, accountId, method],
  );
  if (rows.length !== 1) {
    throw new Error(
      "a provider session id this gateway already recorded arrived again for a different user or " +
        "account; refusing to record it twice",
    );
  }
}

/**
 * Whether this gateway started `sessionId` for this provider-side user **and** this account.
 *
 * All three are compared, never the session alone. The user, so a row can admit only tokens for the
 * user it was written for. The account, so a session started for one account stops opening anything
 * the moment attribution resolves its user to another — an identity that moved, or a state this
 * gateway refuses to create and a migration measured absent.
 */
export async function isGatewaySession(
  client: pg.Client,
  sessionId: string,
  supabaseUserId: string,
  accountId: string,
): Promise<boolean> {
  const { rows } = await client.query(
    `SELECT 1 FROM sonny.gateway_session
      WHERE session_id = $1 AND supabase_user_id = $2 AND account_id = $3`,
    [sessionId, supabaseUserId, accountId],
  );
  return rows.length === 1;
}
