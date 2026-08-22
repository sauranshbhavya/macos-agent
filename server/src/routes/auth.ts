import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { classifyFailure, consumeLatest, issueCode, CODE_LIFETIME_SECONDS } from "../auth/codes.js";
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

/**
 * Which account a provider-side user belongs to — **or a refusal, never a guess** (PR #87 second
 * round, F6).
 *
 * `supabase_user_id` carries no uniqueness constraint and never can: the whole design lets several
 * identities name one Supabase user, which is what makes two `auth.users` rows resolve to one
 * account. What it does *not* license is two **live accounts** naming one Supabase user. That state
 * is the identity rule having failed somewhere upstream, and the two routes that resolve a caller
 * this way were meeting it with `ORDER BY … LIMIT 1` — picking a winner, deterministically and
 * arbitrarily. On `DELETE /v1/account` that is choosing which of a user's accounts to destroy on the
 * strength of a tiebreak; on refresh it is handing out a session for whichever account sorted first.
 *
 * So the query asks for two and refuses on two. **The `ORDER BY` is gone with the tiebreak it fed**:
 * with no winner to pick there is nothing left for a row order to decide, and leaving one in would
 * suggest this still chooses.
 *
 * `NOT i.account_closed` matches rule 1's exclusion: an identity a closed account left behind
 * attributes nobody, exactly as it signs nobody in.
 */
async function accountForSupabaseUser(
  client: pg.Client,
  supabaseUserId: string,
): Promise<{ accountId: string } | { ambiguous: boolean }> {
  const owned = await client.query<{ account_id: string }>(
    `SELECT DISTINCT i.account_id
       FROM sonny.identity i
       JOIN sonny.account a ON a.id = i.account_id
      WHERE i.supabase_user_id = $1 AND NOT i.account_closed AND a.deleted_at IS NULL
      LIMIT 2`,
    [supabaseUserId],
  );
  if (owned.rows.length === 1) return { accountId: owned.rows[0]!.account_id };
  return { ambiguous: owned.rows.length > 1 };
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
      // **The SEND is not transactional, and that failure mode is bounded on purpose** (PR #87
      // R18). It is a network call and cannot join a database transaction, so a crash after it
      // leaves a sent code with no issuance record — which classifies as `auth.code_invalid` and
      // costs the user one retry. It happens first precisely so that a failed send leaves the
      // user's existing code working.
      //
      // **The two database steps ARE transactional**, and this comment used to say wrapping them
      // would not help (PR #87 second round, F11). That was true of the crash it was reasoning
      // about and false of the race it was not: separately, three concurrent starts for one address
      // left three live codes. `issueCode` takes them together under a per-address lock. The half-
      // written state the old wording described — an invalidated older code with no newer record —
      // is gone with it.
      // `issueCode` is the invalidate-and-record pair as one locked transaction (PR #87 second
      // round, F11): as two statements, concurrent starts for one address each invalidated nothing
      // of each other's and left up to three live codes behind.
      await deps.provider.sendEmailCode(email);
      await issueCode(client, email, sourceHash(request, salt), now());
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
    // Filtered (PR #87 F8): a token whose account has been closed must not refresh. `LIMIT 1` over
    // an unfiltered `supabase_user_id` could hand back a session for something the user deleted.
    const owner = await accountForSupabaseUser(client, session.supabaseUserId);
    // **A refresh for a closed account is a revoked session, not a successful one** (PR #87 R5).
    // The previous version answered 200 with `user.id: null` and a working token pair, so an
    // account the user had deleted kept minting sessions and the client had no way to tell.
    //
    // **An ambiguous one is refused the same way** (PR #87 second round, F6), rather than served
    // whichever account sorted first. `auth.token_revoked` is the right code for both: §7's table
    // makes it "clears the Keychain entry, opens sign-in", and signing in again is exactly the
    // recovery — `resolve()` keys on `(provider, subject)`, so it lands on one account without a
    // tiebreak. Refusing costs the user a sign-in; guessing spends their session on an account that
    // may not be the one they are looking at.
    if (!("accountId" in owner)) {
      return reply.status(401).send(
        errorBody(
          "auth.token_revoked",
          owner.ambiguous
            ? "This session cannot be attributed to a single account."
            : "This session no longer belongs to an active account.",
          request.id,
        ),
      );
    }
    const accountId = owner.accountId;

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
  // SONNY-203 supplies authenticated-request middleware this route cannot tell who is asking, and
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
    // then to an account through `sonny.identity`, which is precisely what SONNY-203's middleware
    // will do for every authenticated route; when it lands, this block is what it replaces.
    // (SONNY-128 until the second review round — that ticket is the client half and may not touch
    // `server/` at all, which is the planning gap F5 found and SONNY-203 was created to close.)
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
    const owner = await accountForSupabaseUser(client, supabaseUserId);
    if (!("accountId" in owner)) {
      // A valid token that names no live account, or — the ambiguous case (PR #87 second round,
      // F6) — one that names two. 401 rather than 404: the caller is not attributable to anything
      // this route may act on, and saying which id does or does not exist is a leak. **Two live
      // accounts is the one case where picking a winner would have destroyed the wrong one**, so
      // this route refuses rather than tiebreaking; it is not attributable, which is what the code
      // already says.
      return reply.status(401).send(
        errorBody(
          "auth.unauthenticated",
          owner.ambiguous
            ? "This session names more than one account; none was deleted."
            : "Account could not be attributed to this session.",
          request.id,
        ),
      );
    }
    const accountId = owner.accountId;

    await client.query("BEGIN");
    let closed;
    let identities;
    try {
      closed = await client.query(
        "UPDATE sonny.account SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL",
        [accountId],
      );
      // Identities are marked closed by the `account_close_marks_identities` trigger (0004), not
      // deleted and not touched here. Keeping them keeps `link_method` — the audit trail — and the
      // `supabase_user_id`s that `provider.deleteUser` and SONNY-196 both need, which is the same
      // reasoning that keeps the account row itself.
      //
      // **Read INSIDE the transaction, AFTER the close** (PR #87 second round, F2). R1's fix moved
      // this read before `BEGIN`, which was right against 0003 — that migration DELETEd the rows at
      // statement end, so reading afterwards read an empty table and revoked nobody. Under 0004 the
      // rows survive, and reading first became the wrong half of the trade: an identity that joined
      // this account between the read and the close was never revoked, so a session the user had
      // just added outlived the account.
      //
      // Reading here is race-free rather than merely luckier, and the enumeration is worth spelling
      // out because a claim like that is only as good as the list it rests on. Three ways a row
      // this read must see could appear or change, and what stops each:
      //
      //   1. **An identity attaching to this account.** Both paths in this codebase that do it —
      //      `resolve()`'s rule 2 and `linkExplicitly` — take `SELECT … FOR SHARE` on the account
      //      row first, which conflicts with the `FOR NO KEY UPDATE` the `UPDATE` above holds. So
      //      either they committed before the close and this read sees them, or they block and find
      //      the account closed when they wake.
      //   2. **An existing identity's `supabase_user_id` changing** under `resolve()`'s rule 1,
      //      which takes no account lock. It is serialised anyway: the close trigger updates every
      //      identity row on this account at the end of the statement above, so a rule-1 update of
      //      one of those rows blocks on it and then re-evaluates its own `NOT account_closed` and
      //      matches nothing.
      //   3. **Raw SQL from outside this file** — a retention sweep, an operator's `INSERT`. That
      //      takes no `FOR SHARE` and is NOT covered. It is out of reach of any lock this handler
      //      can take, and is named here rather than papered over.
      identities = await client.query<{ supabase_user_id: string }>(
        `SELECT DISTINCT supabase_user_id FROM sonny.identity
          WHERE account_id = $1 AND supabase_user_id IS NOT NULL`,
        [accountId],
      );
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
