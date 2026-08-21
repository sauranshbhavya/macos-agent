import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { classifyFailure, consumeLatest, invalidateLive, recordIssue, CODE_LIFETIME_SECONDS } from "../auth/codes.js";
import { expiryFields } from "../auth/clock.js";
import { looksLikeEmail, normalizeEmail, rateLimitEmailKey, resolve } from "../auth/identity.js";
import { ProviderRejected, ProviderUnavailable, type AuthProvider } from "../auth/provider.js";
import {
  CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_ADDRESS,
  bucketKey, consume,
} from "../auth/ratelimit.js";
import { errorBody } from "../errors.js";
import type { Config } from "../config.js";
import type pg from "pg";

/**
 * A connection **checked out for the caller alone**, and returned when the caller is done.
 *
 * **The previous shape was `db: () => Promise<pg.Client>` with no release, and it made a guarantee
 * this code depends on unenforceable** (PR #87 R4). A pool-backed implementation of that signature
 * leaks a connection per request, so the only implementation that worked was one shared `Client` —
 * and under a shared client `resolve()`'s "one transaction" is false: its `BEGIN` nests inside
 * whatever else is open on that connection, and one `COMMIT` commits both. Every test used a shared
 * client, so the property was never exercised, only assumed.
 *
 * `withConnection` makes the contract structural: the callback gets a connection nobody else is
 * using, and it is released on the way out whether the callback threw or not. A pool implementation
 * is now the natural one to write, and a shared-client implementation is the awkward one.
 */
export type WithConnection = <T>(fn: (client: pg.Client) => Promise<T>) => Promise<T>;

export interface AuthDeps {
  readonly provider: AuthProvider;
  readonly withConnection: WithConnection;
  readonly now?: () => Date;
}

const startBody = z.object({ email: z.string() });
const verifyBody = z.object({ email: z.string(), code: z.string() });

/** Source identity for the per-source limit. Never logged raw, never stored raw. */
function sourceOf(request: FastifyRequest): string {
  return request.ip;
}

function sourceHash(request: FastifyRequest, salt: string): string {
  return createHash("sha256").update(`${salt}:src:${sourceOf(request)}`).digest("hex");
}

export function registerAuth(app: FastifyInstance, config: Config, deps: AuthDeps): void {
  const now = deps.now ?? (() => new Date());
  const salt = config.rateLimitSalt;

  /**
   * `POST /v1/auth/email/start` — request a sign-in code.
   *
   * **The response is identical whether or not that address has an account**, per contract §3.6. An
   * endpoint that answers differently is an account-existence oracle, so every branch below that
   * could reveal existence — unknown address, rate-limited address, provider failure — returns the
   * same 200 shape. Only the per-source limit answers 429, because that is a fact about the caller
   * rather than about the address.
   */
  app.post("/v1/auth/email/start", async (request, reply) => {
    const parsed = startBody.safeParse(request.body);
    if (!parsed.success || !looksLikeEmail(parsed.data.email)) {
      return reply.status(400).send(
        errorBody("request.invalid", "A valid email address is required.", request.id),
      );
    }
    const email = normalizeEmail(parsed.data.email);
    return deps.withConnection(async (client) => {

    // Per source first. A caller over their own ceiling is told so: it is their own behaviour, and
    // hiding it would leave them retrying against a wall with no signal.
    const bySource = await consume(client, bucketKey("src", sourceOf(request), salt), CODE_REQUEST_PER_SOURCE, now());
    if (!bySource.allowed) {
      return reply
        .status(429)
        .header("Retry-After", String(bySource.retryAfterSeconds))
        .send(errorBody("limit.rate", "Too many sign-in requests from this source.", request.id, {
          retryable: true, retryAfterSeconds: bySource.retryAfterSeconds,
        }));
    }

    const uniform = { request_id: request.id, expires_in: CODE_LIFETIME_SECONDS };

    // Per address second, and its refusal is SILENT. Answering 429 here would tell the caller that
    // this particular address has been asked for recently, which is the oracle in a slower form.
    const byAddress = await consume(client, bucketKey("addr", rateLimitEmailKey(email), salt), CODE_REQUEST_PER_ADDRESS, now());
    if (!byAddress.allowed) return reply.status(200).send(uniform);

    try {
      // **Send first, invalidate only on success** (PR #87 F9). Invalidating first meant a provider
      // failure — which still returns 200, because the response must not reveal anything — killed
      // the code the user was already holding and told them nothing. They would type a valid code
      // and be refused, with no new mail arriving. Now a failed send leaves the previous code
      // working, which is the safe direction: at worst two codes are briefly live, and the older
      // one is invalidated the moment a send actually succeeds.
      // **These three steps are not transactional, and the failure modes are bounded on purpose**
      // (PR #87 R18). The send is a network call and cannot join a database transaction, so a crash
      // between them leaves either a sent code with no issuance record — which classifies as
      // `auth.code_invalid` and costs the user one retry — or an invalidated older code with no
      // newer record, same outcome. Wrapping the two database steps in a transaction would not help:
      // the send is the one that cannot be rolled back, and it happens first precisely so that a
      // failed send leaves the user's existing code working.
      await deps.provider.sendEmailCode(email);
      await invalidateLive(client, email, now());
      await recordIssue(client, email, sourceHash(request, salt), now());
    } catch (error) {
      // Even a provider failure returns the uniform response. The user is told nothing useful
      // either way, and the alternative leaks that this address reached the send path.
      // Message and name only, never the error object (PR #87 F11). The real Supabase and Resend
      // adapters raise errors carrying request URLs — which contain the project ref — and response
      // bodies. Fastify's `redact` list below covers known keys; this covers the one call site that
      // was handing it an arbitrary provider object.
      request.log.error(
        { err_name: (error as Error)?.name, err_message: (error as Error)?.message },
        "sign-in code send failed",
      );
    }
    return reply.status(200).send(uniform);
    });
  });

  /**
   * `POST /v1/auth/email/verify` — exchange a code for tokens.
   *
   * Returns the contract's §3.2 token response, or one of three distinct failures derived from our
   * own issuance record, because Supabase returns one `otp_expired` for all three.
   */
  app.post("/v1/auth/email/verify", async (request, reply) => {
    const parsed = verifyBody.safeParse(request.body);
    if (!parsed.success || !looksLikeEmail(parsed.data.email)) {
      return reply.status(400).send(
        errorBody("request.invalid", "A valid email address and code are required.", request.id),
      );
    }
    const email = normalizeEmail(parsed.data.email);
    return deps.withConnection(async (client) => {

    // Verification is guessing, so it is limited per address being guessed at. Without this the
    // code's own entropy is the only thing between an attacker and an account.
    const limit = await consume(client, bucketKey("verify", rateLimitEmailKey(email), salt), CODE_VERIFY_PER_ADDRESS, now());
    if (!limit.allowed) {
      return reply
        .status(429)
        .header("Retry-After", String(limit.retryAfterSeconds))
        .send(errorBody("limit.rate", "Too many attempts for this address.", request.id, {
          retryable: true, retryAfterSeconds: limit.retryAfterSeconds,
        }));
    }

    let session;
    try {
      session = await deps.provider.verifyEmailCode(email, parsed.data.code);
    } catch (error) {
      if (error instanceof ProviderRejected) {
        const code = await classifyFailure(client, email, now());
        return reply.status(400).send(errorBody(code, "Sign-in code was not accepted.", request.id));
      }
      if (error instanceof ProviderUnavailable) {
        return reply.status(502).send(
          errorBody("provider.unavailable", "Sign-in is temporarily unavailable.", request.id, { retryable: true }),
        );
      }
      throw error;
    }

    // Consume our own record only after the provider accepted, so a wrong guess never burns the
    // user's live code. If this returns false the code was already consumed concurrently: another
    // request won the race and this one must not also mint a session.
    if (!(await consumeLatest(client, email, now()))) {
      return reply.status(400).send(
        errorBody("auth.code_used", "Sign-in code was already used.", request.id),
      );
    }

    const resolution = await resolve(client, {
      provider: "email",
      subject: email,
      email,
      emailVerified: true, // possession of the mailbox is what this flow proves
      supabaseUserId: session.supabaseUserId,
    });

    const issued = now();
    return reply.status(200).send({
      access_token: session.accessToken,
      token_type: "Bearer",
      ...expiryFields(issued, session.expiresIn),
      refresh_token: session.refreshToken,
      ...(session.refreshExpiresIn !== undefined
        ? { refresh_expires_at: expiryFields(issued, session.refreshExpiresIn).expires_at }
        : {}),
      user: { id: resolution.accountId },
      ...(resolution.linkHint ? { link_hint: resolution.linkHint } : {}),
    });
    });
  });

  /** `POST /v1/auth/refresh` — rotation, overlap and reuse detection are the provider's (§3.3). */
  app.post("/v1/auth/refresh", async (request, reply) => {
    const parsed = z.object({ refresh_token: z.string().min(1) }).safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send(errorBody("request.invalid", "A refresh token is required.", request.id));
    }
    let session;
    try {
      session = await deps.provider.refresh(parsed.data.refresh_token);
    } catch (error) {
      if (error instanceof ProviderRejected) {
        // Reuse past the overlap window is treated as theft by the provider, which revokes the
        // family. `auth.token_revoked` is the contract's code for it, and the client's response is
        // to clear the Keychain entry and sign in again rather than retry.
        return reply.status(401).send(
          errorBody("auth.token_revoked", "Refresh token is no longer valid.", request.id),
        );
      }
      throw error;
    }
    return deps.withConnection(async (client) => {
    // Filtered and ordered (PR #87 F8). `supabase_user_id` carries no uniqueness constraint and
    // never can — the whole design allows several identities to name one Supabase user — so a bare
    // `LIMIT 1` returned an arbitrary row, and one of them could belong to a closed account. A
    // refresh that resolves to a closed account hands the caller a session for something the user
    // asked to delete.
    const account = await client.query<{ account_id: string }>(
      `SELECT i.account_id
         FROM sonny.identity i
         JOIN sonny.account a ON a.id = i.account_id
        WHERE i.supabase_user_id = $1 AND a.deleted_at IS NULL
        ORDER BY i.linked_at ASC, i.id ASC
        LIMIT 1`,
      [session.supabaseUserId],
    );
    // **A refresh for a closed account is a revoked session, not a successful one** (PR #87 R5).
    // The previous version answered 200 with `user.id: null` and a working token pair, so an
    // account the user had deleted kept minting sessions and the client had no way to tell.
    const accountId = account.rows[0]?.account_id;
    if (!accountId) {
      return reply.status(401).send(
        errorBody("auth.token_revoked", "This session no longer belongs to an active account.", request.id),
      );
    }

    const issued = now();
    return reply.status(200).send({
      access_token: session.accessToken,
      token_type: "Bearer",
      ...expiryFields(issued, session.expiresIn),
      refresh_token: session.refreshToken,
      // §3.2 lists `refresh_expires_at` and nothing was sending it (PR #87 R8). The provider owns
      // the refresh token's life, so it is reported only when the provider tells us; inventing a
      // value would be a client scheduling against a number the server made up.
      ...(session.refreshExpiresIn !== undefined
        ? { refresh_expires_at: expiryFields(issued, session.refreshExpiresIn).expires_at }
        : {}),
      user: { id: accountId },
    });
    });
  });

  /**
   * `DELETE /v1/account` — close the account server-side.
   *
   * **Sequencing, stated because the ticket requires it and because getting it wrong leaves content
   * behind with no key to find it by.** This endpoint marks `deleted_at` and revokes the session; it
   * does **not** reach retained content or training snapshots, which are
   * `feature/row-12-retention`'s. That is deliberate ordering rather than an omission: the account
   * row is the only handle those records are addressable by, so removing it first would orphan them
   * permanently. Marking it closed keeps the handle while making the account unusable — every read
   * path in this file already excludes `deleted_at IS NOT NULL`, so no sign-in, no link and no
   * refresh can resurrect it.
   *
   * **This ticket must not implement a deletion that silently leaves content behind, and it does not
   * claim to have deleted content.** The retention ticket sweeps what hangs off `deleted_at`, and
   * until it lands a closed account's content is retained and unreachable. Recorded on both tickets.
   */
  // Mounted only where the gate is on, and `loadConfig` refuses the gate in production. Until
  // SONNY-128 supplies authenticated-request middleware this route cannot tell who is asking, and
  // an unauthenticated destructive primitive that merely happens to be unrouted is a landmine that
  // arms itself the moment someone routes it.
  if (config.allowUnauthenticatedAccountDelete) app.delete("/v1/account", async (request, reply) => {
    const header = request.headers.authorization;
    if (!header?.startsWith("Bearer ")) {
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "A bearer token is required.", request.id),
      );
    }
    // **Attributed from the token, never from a header** (PR #87 F1). The first version took the
    // account id from `Sonny-Account-Id` and verified nothing, so any caller who could reach the
    // port could destroy any account whose id they could guess — reproduced against a running
    // server with a made-up bearer token. The token is now resolved to a provider-side user and
    // then to an account through `sonny.identity`, which is precisely what SONNY-128's middleware
    // will do for every authenticated route; when it lands, this block is what it replaces.
    return deps.withConnection(async (client) => {
    let supabaseUserId: string;
    try {
      supabaseUserId = await deps.provider.userFromAccessToken(header.slice("Bearer ".length));
    } catch (error) {
      if (error instanceof ProviderRejected) {
        return reply.status(401).send(
          errorBody("auth.unauthenticated", "Access token is not valid.", request.id),
        );
      }
      throw error;
    }
    const owned = await client.query<{ account_id: string }>(
      `SELECT i.account_id
         FROM sonny.identity i
         JOIN sonny.account a ON a.id = i.account_id
        WHERE i.supabase_user_id = $1 AND a.deleted_at IS NULL
        ORDER BY i.linked_at ASC, i.id ASC
        LIMIT 1`,
      [supabaseUserId],
    );
    const accountId = owned.rows[0]?.account_id;
    if (!accountId) {
      // A valid token that names no live account. 401 rather than 404: the caller is not attributable
      // to anything this route may act on, and saying which id does or does not exist is a leak.
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "Account could not be attributed to this session.", request.id),
      );
    }
    // **Read the ids BEFORE the close, and revoke every one of them** (PR #87 R1).
    //
    // The previous version read them after the closing UPDATE and revoked **nobody** — reproduced
    // as 0 rows. Its comment said the read happened "before the commit that releases them", which
    // was wrong twice over: the trigger fires at **statement end**, not at commit, so the rows were
    // already gone by the next statement in the same transaction; and under 0004 nothing releases
    // them at all any more, they are marked. Reading first is kept regardless, because it does not
    // depend on which of those is true.
    const identities = await client.query<{ supabase_user_id: string }>(
      `SELECT DISTINCT supabase_user_id FROM sonny.identity
        WHERE account_id = $1 AND supabase_user_id IS NOT NULL`,
      [accountId],
    );

    await client.query("BEGIN");
    let closed;
    try {
      closed = await client.query(
        "UPDATE sonny.account SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL",
        [accountId],
      );
      // Identities are marked closed by the `account_close_marks_identities` trigger (0004), not
      // deleted and not touched here. Keeping them keeps `link_method` — the audit trail — and the
      // `supabase_user_id`s that `provider.deleteUser` and SONNY-196 both need, which is the same
      // reasoning that keeps the account row itself.
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }

    // After the close, so a revocation cannot leave the account open with its sessions gone.
    for (const row of identities.rows) {
      try {
        await deps.provider.signOutAllForUser(row.supabase_user_id);
      } catch (error) {
        if (!(error instanceof ProviderRejected)) throw error;
      }
    }

    // 204 whether or not a row changed: deleting an already-deleted account is the state the caller
    // asked for, and answering 404 would tell an unauthenticated prober which ids exist.
    request.log.info({ closed: closed.rowCount }, "account closed");
    return reply.status(204).send();
    });
  });

  /** `POST /v1/auth/signout` — revoke the family server-side, return 204. */
  app.post("/v1/auth/signout", async (request, reply) => {
    const header = request.headers.authorization;
    if (!header?.startsWith("Bearer ")) {
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "A bearer token is required.", request.id),
      );
    }
    try {
      await deps.provider.signOut(header.slice("Bearer ".length));
    } catch (error) {
      if (!(error instanceof ProviderRejected)) throw error;
      // An already-invalid token is a signed-out session. Answering 401 would make the client's
      // retry loop the user's problem for a state it already wanted.
    }
    return reply.status(204).send();
  });
}
