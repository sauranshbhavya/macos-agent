import type pg from "pg";
import { recordGatewaySession, type SignInMethod } from "../../src/auth/gateway-session.js";
import { providerSessionFor } from "./tokens.js";

/**
 * Record, the way a sign-in route does, that this gateway started a session for this user on this
 * account (SONNY-129) — for a database suite that creates its account by inserting rows rather than by
 * signing in through a route.
 *
 * **Why every such suite needs it now.** The gate honours only sessions the gateway started
 * (migration 0023), and an identity inserted by hand has none: a token `accessTokenFor` mints for it
 * would be refused `401 auth.token_revoked` before the route under test ran. The session id defaults to
 * `providerSessionFor(user)`, which is the one `accessTokenFor` puts in the token, so the two agree
 * without either being passed around.
 *
 * **It calls the production write rather than inserting a row itself**, so a suite that uses it also
 * exercises the statement the sign-in routes run — and inherits its refusal to record one session for
 * two accounts, which is the property a hand-written `INSERT` here would quietly not have.
 */
export async function recordSessionTheGatewayStarted(
  client: pg.Client,
  supabaseUserId: string,
  accountId: string,
  options: { readonly sessionId?: string; readonly method?: SignInMethod } = {},
): Promise<void> {
  await recordGatewaySession(
    client,
    { supabaseUserId, sessionId: options.sessionId ?? providerSessionFor(supabaseUserId) },
    accountId,
    options.method ?? "email",
  );
}
