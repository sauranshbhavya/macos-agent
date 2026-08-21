import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { classifyFailure, consumeLatest, invalidateLive, recordIssue, CODE_LIFETIME_SECONDS } from "../auth/codes.js";
import { expiryFields } from "../auth/clock.js";
import { looksLikeEmail, normalizeEmail, resolve } from "../auth/identity.js";
import { ProviderRejected, ProviderUnavailable, type AuthProvider } from "../auth/provider.js";
import {
  CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_ADDRESS,
  bucketKey, consume,
} from "../auth/ratelimit.js";
import { errorBody } from "../errors.js";
import type { Config } from "../config.js";
import type pg from "pg";

export interface AuthDeps {
  readonly provider: AuthProvider;
  readonly db: () => Promise<pg.Client>;
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
    const client = await deps.db();

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
    const byAddress = await consume(client, bucketKey("addr", email, salt), CODE_REQUEST_PER_ADDRESS, now());
    if (!byAddress.allowed) return reply.status(200).send(uniform);

    try {
      // The newest code is the only live one -- the founder's own manual-test item. Invalidating
      // before sending means a crash after the send leaves no older code usable, which is the safe
      // direction to fail in.
      await invalidateLive(client, email, now());
      await recordIssue(client, email, sourceHash(request, salt), now());
      await deps.provider.sendEmailCode(email);
    } catch (error) {
      // Even a provider failure returns the uniform response. The user is told nothing useful
      // either way, and the alternative leaks that this address reached the send path.
      request.log.error({ err: error }, "sign-in code send failed");
    }
    return reply.status(200).send(uniform);
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
    const client = await deps.db();

    // Verification is guessing, so it is limited per address being guessed at. Without this the
    // code's own entropy is the only thing between an attacker and an account.
    const limit = await consume(client, bucketKey("verify", email, salt), CODE_VERIFY_PER_ADDRESS, now());
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
      user: { id: resolution.accountId },
      ...(resolution.linkHint ? { link_hint: resolution.linkHint } : {}),
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
    const client = await deps.db();
    const account = await client.query<{ account_id: string }>(
      "SELECT account_id FROM sonny.identity WHERE supabase_user_id = $1 LIMIT 1",
      [session.supabaseUserId],
    );
    const issued = now();
    return reply.status(200).send({
      access_token: session.accessToken,
      token_type: "Bearer",
      ...expiryFields(issued, session.expiresIn),
      refresh_token: session.refreshToken,
      user: { id: account.rows[0]?.account_id ?? null },
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
  app.delete("/v1/account", async (request, reply) => {
    const header = request.headers.authorization;
    if (!header?.startsWith("Bearer ")) {
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "A bearer token is required.", request.id),
      );
    }
    const accountId = (request.headers["sonny-account-id"] as string | undefined) ?? undefined;
    if (!accountId) {
      // The account is resolved from the session by SONNY-128's authenticated-request middleware,
      // which does not exist yet. Until it does this endpoint refuses rather than guessing, because
      // an account-deletion route that infers its subject is the worst possible place to be wrong.
      return reply.status(401).send(
        errorBody("auth.unauthenticated", "Account could not be attributed to this session.", request.id),
      );
    }
    const client = await deps.db();
    // Close the account and **release its identities** in one transaction.
    //
    // Releasing them is what lets the person sign up again with the same address. Without it the
    // unique constraint on `(provider, subject)` keeps a closed account's claim on that address
    // forever, while every read path excludes the account for being deleted — so the address
    // becomes permanently unusable by anyone, including its owner. The account row itself stays,
    // because it is the only handle the retained content is addressable by.
    await client.query("BEGIN");
    let closed;
    try {
      closed = await client.query(
        "UPDATE sonny.account SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL",
        [accountId],
      );
      await client.query("DELETE FROM sonny.identity WHERE account_id = $1", [accountId]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }
    try {
      await deps.provider.signOut(header.slice("Bearer ".length));
    } catch (error) {
      if (!(error instanceof ProviderRejected)) throw error;
    }
    // 204 whether or not a row changed: deleting an already-deleted account is the state the caller
    // asked for, and answering 404 would tell an unauthenticated prober which ids exist.
    request.log.info({ closed: closed.rowCount }, "account closed");
    return reply.status(204).send();
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
