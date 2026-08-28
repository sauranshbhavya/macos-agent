import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import {
  CODE_LIFETIME_SECONDS, callerOriginatedLatestCode, classifyFailure, consumeLatest, issueCode,
} from "../auth/codes.js";
import { accountForSupabaseUser } from "../auth/attribution.js";
import { expiryFields } from "../auth/clock.js";
import { callerOf } from "../auth/gate.js";
import { looksLikeEmail, normalizeEmail, rateLimitEmailKey, resolve } from "../auth/identity.js";
import { ProviderRejected, ProviderUnavailable, type AuthProvider } from "../auth/provider.js";
import { drainOwedRevocations } from "../auth/revocation.js";
import {
  CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_ADDRESS,
  CODE_VERIFY_PER_SOURCE,
  bucketKey, consume,
} from "../auth/ratelimit.js";
import { errorBody } from "../errors.js";
import type { Config } from "../config.js";
import { deleteContentForAccount, type DeletionOutcome } from "../content/store.js";
import { deleteStoredResponsesForAccount } from "../idempotency/store.js";
import type { WithConnection } from "../db/connection.js";

/**
 * `WithConnection` moved to `db/connection.ts` and `accountForSupabaseUser` to
 * `auth/attribution.ts` (SONNY-203), both unchanged. The authenticated-route gate needs each of
 * them, and a middleware reaching into a route module for its own dependencies is the wrong
 * direction for that dependency to point. Re-exported here so an importer of either keeps working.
 */
export type { WithConnection };

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
    // **Two keys, deliberately, and which one each thing takes is the whole of F4** (PR #87 third
    // round). `email` is the IDENTITY key — plus-tags kept, because merging two addresses merges
    // two accounts — and only `resolve()` and the rate limits' address bucket see it in that role.
    // `mailbox` folds plus-tags away, because a code is delivered to an inbox rather than to an
    // identity, and every code-lifecycle call takes it. Keyed the other way, `victim+1@x` and
    // `victim+2@x` shared one rate-limit budget while each holding its own live code.
    const mailbox = rateLimitEmailKey(email);
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
    const byAddress = await consume(client, bucketKey("addr", mailbox, salt), CODE_REQUEST_PER_ADDRESS, now());
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
      await issueCode(client, mailbox, sourceHash(request, salt), now());
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
    // **Two keys, deliberately, and which one each thing takes is the whole of F4** (PR #87 third
    // round). `email` is the IDENTITY key — plus-tags kept, because merging two addresses merges
    // two accounts — and only `resolve()` and the rate limits' address bucket see it in that role.
    // `mailbox` folds plus-tags away, because a code is delivered to an inbox rather than to an
    // identity, and every code-lifecycle call takes it. Keyed the other way, `victim+1@x` and
    // `victim+2@x` shared one rate-limit budget while each holding its own live code.
    const mailbox = rateLimitEmailKey(email);
    return deps.withConnection(async (client) => {

    // **Per source FIRST, and this route had no source limit at all** (PR #87 fifth round, F1).
    // The per-address limit below is keyed on the address being probed, so it never binds when every
    // probe names a new one: 200 distinct addresses from one source, 0 refused, against
    // `email/start`'s 192 of 200 in the same run. Disclosed with a 429 for the same reason
    // `email/start`'s is — it is a fact about the caller's own behaviour, not about any address.
    const bySource = await consume(
      client, bucketKey("verifysrc", sourceOf(request), salt), CODE_VERIFY_PER_SOURCE, now());
    if (!bySource.allowed) {
      return reply
        .status(429)
        .header("Retry-After", String(bySource.retryAfterSeconds))
        .send(errorBody("limit.rate", "Too many sign-in attempts from this source.", request.id, {
          retryable: true, retryAfterSeconds: bySource.retryAfterSeconds,
        }));
    }

    // Verification is guessing, so it is limited per address being guessed at. Without this the
    // code's own entropy is the only thing between an attacker and an account.
    const limit = await consume(client, bucketKey("verify", mailbox, salt), CODE_VERIFY_PER_ADDRESS, now());
    if (!limit.allowed) {
      // **The refusal itself is disclosed only to the caller who asked for the code** (PR #87 sixth
      // round). Answering 429 to everyone made the *count* readable: probe a mailbox and see how
      // many attempts you get before the wall — 4 for one the victim had verified at, 5 for an
      // untouched one — which is recent activity at an address the attacker neither caused nor
      // could otherwise observe. Same channel class as the previous round's oracle, on the same
      // route, one layer down. `email/start` has always made this asymmetry the other way round for
      // exactly this reason: its per-ADDRESS refusal is silent and its per-SOURCE one is not.
      //
      // The same question as the disclosure gate, so the two cannot drift: originator gets the
      // helpful 429, everyone else gets the answer a wrong code would have produced.
      if (await callerOriginatedLatestCode(client, mailbox, now(), sourceHash(request, salt))) {
        return reply
          .status(429)
          .header("Retry-After", String(limit.retryAfterSeconds))
          .send(errorBody("limit.rate", "Too many attempts for this address.", request.id, {
            retryable: true, retryAfterSeconds: limit.retryAfterSeconds,
          }));
      }
      // **What this closes and what it does not.** The body and status now match a wrong guess
      // exactly. The *timing* does not: this path skips the provider call, which in production is a
      // network round trip, so a refusal is measurably faster. That residual is real, it is the same
      // trade `email/start`'s silent per-address refusal already makes — it skips the send — and it
      // is recorded rather than claimed closed.
      return reply.status(400).send(
        errorBody(
          await classifyFailure(client, mailbox, now(), sourceHash(request, salt)),
          "Sign-in code was not accepted.", request.id,
        ),
      );
    }

    let session;
    try {
      session = await deps.provider.verifyEmailCode(email, parsed.data.code);
    } catch (error) {
      if (error instanceof ProviderRejected) {
        // The caller's own source hash decides whether the distinct codes are disclosed at all
        // (PR #87 fifth round, F1) — same function, same salt, as the one written at issuance.
        const code = await classifyFailure(client, mailbox, now(), sourceHash(request, salt));
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
    if (!(await consumeLatest(client, mailbox, now()))) {
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
   * behind with no key to find it by.** This endpoint marks `deleted_at`, revokes the session, and
   * *then* reaches everything filed under the account. That ordering is deliberate: the account row
   * is the only handle those records are addressable by, so removing it first would orphan them
   * permanently. Marking it closed keeps the handle while making the account unusable — every read
   * path in this file already excludes `deleted_at IS NOT NULL`, so no sign-in, no link and no
   * refresh can resurrect it.
   *
   * **The content half is SONNY-134's and has now landed.** This comment used to end "it does not
   * claim to have deleted content … until [the retention ticket] lands a closed account's content is
   * retained and unreachable", which was true when SONNY-127 wrote it and stopped being true on
   * 2026-08-28. What the wipe reaches is enumerated rather than described in general, because a
   * privacy wipe is exactly the place a summary hides a gap:
   *
   * - **`sonny.retained_content`** — every request and response body, every capture, every recording
   *   the account ever sent, on the content clock or not.
   * - **`sonny.training_snapshot_member`** — the copies training reads from. This is the half that
   *   cannot be retrofitted: a member carries a copy rather than a pointer, so deleting the live
   *   content alone would leave the account's data in a sealed training set with nothing pointing at
   *   it. `sonny.content_deletion` records which snapshots lost rows.
   * - **`sonny.idempotency_key`'s stored responses** — SONNY-319, filed by SONNY-300 and closed
   *   here. That table holds one response body per key for twenty-four hours, which makes it the one
   *   place in this gateway holding response content outside the route that produced it, and the
   *   ticket asked whether a wipe must take those immediately or may leave them to expire. It takes
   *   them: a wipe that left a day of response bodies behind would be a wipe with an asterisk. The
   *   rows themselves and their `metering_claimed_at` claims survive, which is what makes taking the
   *   payloads free — a deleted claim would hand the same key a second metering event.
   *
   * **What it deliberately does not reach is usage**, and that is requirement 8's own wording
   * ("content, usage history where the law or the promise requires it, and snapshot lineage") read
   * against §10.3's two clocks. `sonny.metering_event` holds no content at all — 0012's header and
   * its own column-set test are what make that checkable rather than asserted — and it is the record
   * of what this account was billed for. Deleting a screenshot is what the user asked for; erasing
   * the accounting is not, and would leave a real financial record unanswerable.
   *
   * **Note the client-side counterpart, and do not conflate the three.** `LocalDataDeletionService`
   * wipes the Mac's local stores and deliberately leaves the Keychain encryption key alone.
   * "Delete my data", "sign out" and "reset the encryption identity" are three different actions
   * with three different blast radii; §3.3 says so and this route is only the first of them.
   */
  // **Mounted unconditionally, and the flag that used to gate it is gone** (SONNY-203).
  //
  // `ALLOW_UNAUTHENTICATED_ACCOUNT_DELETE` existed for one reason: nothing verified a token, so this
  // route's own attribution rested on `AuthProvider.userFromAccessToken`, a seam with no adapter
  // behind it. A destructive primitive trusting a check that does not exist is a landmine that arms
  // itself the moment someone routes it, so the route was kept off by default and refused outright
  // in production. Verification now exists and the gate applies it before this handler runs, so both
  // the flag and its production refusal are deleted rather than defaulted off.
  //
  // **The caller is the gate's, derived from the verified token — never a header and never a body
  // field** (PR #87 F1, whose first version took the account id from `Sonny-Account-Id` and verified
  // nothing: any caller who could reach the port could destroy any account whose id they could
  // guess, reproduced against a running server with a made-up bearer token). The two refusals this
  // handler used to make itself — no bearer token, and a token attributable to no single live
  // account — are the gate's now, answered identically for every protected route.
  app.delete("/v1/account", async (request, reply) => {
    const accountId = callerOf(request).accountId;
    return deps.withConnection(async (client) => {
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
      //
      // **This transaction used to also read the identities, and the read is gone rather than
      // moved** (PR #87 third round, F1). Two rounds were spent getting its *position* right —
      // before `BEGIN` was correct against 0003 and wrong under 0004, then inside the transaction
      // after the close, with a three-case enumeration of what could slip through the gap. The
      // third round removed the gap instead of guarding it: the work is now derived from committed
      // state *after* this transaction ends, out of `provider_session_revoked_at`, so there is no
      // window for anything to arrive in and nothing left to enumerate. **An ordering that has to
      // be argued for is a weaker thing than an ordering that cannot matter.**
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }

    // **After the close, and it CANNOT abort partway** (PR #87 third round, F1).
    //
    // This was a bare loop that rethrew anything other than `ProviderRejected`, so one transient
    // provider error meant every identity ordered after it was never attempted — and because the
    // close had already committed, `accountForSupabaseUser` could no longer attribute this caller to
    // the account, so the route was unreachable and the failure was permanent. Reproduced: account
    // closed and committed, 500 to the caller, the third identity never revoked, the retry 401.
    //
    // `drainOwedRevocations` catches and continues, and — the part that actually fixes it — leaves
    // `provider_session_revoked_at` NULL on whatever it could not do, so the work outlives this
    // request. `npm run revocations` is what surfaces the residual afterwards.
    //
    // **Two corrections to what this comment used to say** (PR #87 fifth round, F8). It named
    // `npm run revoke-pending`, which has never existed. And it said "the drain at the top of this
    // handler", which is not where this call is and not what it does: it runs after the close, and
    // it is scoped to `{ accountId }` — this account, never a backlog. Nothing drains anything
    // else, and the command reports rather than revokes, because no adapter exists to call.
    const outcome = await drainOwedRevocations(client, deps.provider, { accountId });

    // **The wipe, after the close and after the drain** — see this handler's doc comment for what it
    // reaches and what it deliberately does not.
    //
    // **After the close, so nothing can arrive behind it.** Every content-bearing route is
    // authenticated and the gate refuses a closed account, so once `deleted_at` is committed no
    // further content can be written for this account and the wipe cannot race a request that is
    // still storing something. Running it before the close would leave exactly that window.
    //
    // **It catches and continues, for the reason the drain above catches and continues, and the
    // failure is recoverable for the same kind of reason.** A throw here would be a 500 after a
    // committed close — and the caller cannot retry, because `accountForSupabaseUser` no longer
    // attributes them to the account and the gate answers 401. That is the exact permanent failure
    // PR #87's third round removed from the revocation path, and reintroducing it on the content
    // path would be worse: the account would be closed, its content still stored, and no request
    // able to reach it.
    //
    // So what makes this safe is not this call succeeding. It is that content belonging to a closed
    // account is **swept**: `sweepClosedAccountContent` runs on the same timer as the content clock
    // and takes anything a wipe like this one could not. That also covers the accounts closed before
    // this branch existed, which SONNY-127's own comment recorded as "retained and unreachable".
    let wiped: DeletionOutcome | undefined;
    try {
      const storedResponses = await deleteStoredResponsesForAccount(client, accountId);
      wiped = await deleteContentForAccount(client, accountId, storedResponses);
    } catch (error) {
      request.log.error(
        { err: error, requestId: request.id },
        "account closed, but its retained content could not be deleted in this request; " +
          "the closed-account sweep will take it",
      );
    }

    // 204 whether or not a row changed: deleting an already-deleted account is the state the caller
    // asked for, and answering 404 would tell an unauthenticated prober which ids exist.
    //
    // **204 even when a revocation failed, and that is a decision rather than an oversight.** The
    // thing the caller asked for — their account closed — did happen and is committed; a 500 would
    // describe an outcome that is not the one on disk, and it would invite a retry that cannot
    // succeed, because the account is closed and no longer attributable to them. The failure is not
    // swallowed: it is a row in the database with nothing recorded against it, an error line here,
    // and work for the next drain. What the caller cannot do about it, they are not asked to.
    if (outcome.failed > 0) {
      request.log.error(
        { owed: outcome.failed, revoked: outcome.revoked, reasons: outcome.failures.map((f) => f.reason) },
        "account closed, but provider-side revocation is still owed for some identities",
      );
    }
    request.log.info(
      {
        closed: closed.rowCount,
        revoked: outcome.revoked,
        owed: outcome.failed,
        // `undefined` where the wipe failed, which is a different fact from zero and reads as one.
        contentRows: wiped?.contentRows,
        snapshotRows: wiped?.snapshotRows,
        snapshots: wiped?.snapshotsTouched,
        storedResponses: wiped?.storedResponses,
      },
      "account closed",
    );
    return reply.status(204).send();
    });
  });

  /**
   * `POST /v1/auth/signout` — revoke the family server-side, return 204.
   *
   * **The bearer check here was a check on the header's shape and nothing else** (SONNY-203). It is
   * the gate's now, so the token reaching the provider is one this gateway has verified, and the
   * caller is attributable to a live account. What this route does with the token is the one
   * legitimate use of the raw string: hand it back to the provider that issued it.
   *
   * **What signing out does and does not end.** It revokes the refresh-token family, so no new
   * access token can be minted; the access token in the user's hand stays valid until its own `exp`
   * plus `EXPIRY_SKEW_TOLERANCE_SECONDS`, because it is self-contained and this gateway verifies it
   * locally rather than asking the provider. `auth/gate.ts` states that residual in full, tolerance
   * included (PR #104's adversarial review, F9).
   */
  app.post("/v1/auth/signout", async (request, reply) => {
    try {
      await deps.provider.signOut(callerOf(request).accessToken);
    } catch (error) {
      if (!(error instanceof ProviderRejected)) throw error;
      // An already-invalid token is a signed-out session. Answering 401 would make the client's
      // retry loop the user's problem for a state it already wanted.
    }
    return reply.status(204).send();
  });
}
