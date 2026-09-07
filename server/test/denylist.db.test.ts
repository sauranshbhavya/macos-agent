import pg from "pg";
import { describe, expect } from "vitest";
import { buildApp } from "../src/app.js";
import { EXPIRY_SKEW_TOLERANCE_SECONDS } from "../src/auth/clock.js";
import { revokedProviderSessionCount } from "../src/auth/denylist.js";
import {
  ProviderRejected, ProviderUnavailable, type AuthProvider, type VerifiedSession,
} from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor, claimsFor, providerSessionFor, signToken } from "./support/tokens.js";
import { testConfig } from "./support/config.js";
import {
  afterAllUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";

/**
 * A sign-out stops the access token already in the user's hand (SONNY-237).
 *
 * `denylist.test.ts` asserts what the gate asks and in what order, against a fake that can be made
 * to say anything. This file is the other half and the one the ticket is about: a real sign-out over
 * HTTP, a real row in a real table, and the same token refused afterwards on a protected route.
 *
 * **What was broken.** A Supabase access token is self-contained, so this gateway verifies it
 * locally and cannot un-issue one; `POST /v1/auth/signout` revoked the *refresh* family at the
 * provider and left the access token verifying until its own `exp` — an hour on Supabase's default.
 * On a shared or borrowed Mac that is a working session left behind by someone who pressed Sign out.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const SESSION_USER = "11111111-1111-1111-1111-111111111111";
const SECOND_DEVICE_SESSION = "5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e";

let pool: pg.Pool;
const withConnection = async <T,>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
  const conn = await pool.connect();
  try {
    return await fn(conn as unknown as pg.Client);
  } finally {
    conn.release();
  }
};

const config: Config = testConfig({ databaseUrl: url });

/** Enough provider to sign someone in and out, and to fail on demand. */
class SigningProvider implements AuthProvider {
  signOutCalls: string[] = [];
  signOutFails: Error | undefined;
  session: VerifiedSession = {
    supabaseUserId: SESSION_USER,
    email: "u@example.com", emailVerified: true,
    accessToken: "provider-issued", refreshToken: "rt", expiresIn: 3600,
  };
  async sendEmailCode(_email: string) { return { providerRequestId: "p1" }; }
  async verifyEmailCode(_email: string, _code: string): Promise<VerifiedSession> { return this.session; }
  async refresh(_token: string): Promise<VerifiedSession> { return this.session; }
  async signOut(accessToken: string) {
    this.signOutCalls.push(accessToken);
    if (this.signOutFails) throw this.signOutFails;
  }
  async userFromAccessToken(_accessToken: string): Promise<string> {
    throw new ProviderRejected("the gate verifies locally; this seam is not on the request path");
  }
  async signOutAllForUser() {}
  async deleteUser() {}
}

describeDb("a sign-out, against a real denylist", () => {
  let client: pg.Client;
  let provider: SigningProvider;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
    pool = new pg.Pool({ connectionString: url, max: 8 });
  });
  afterAllUnderHangBackstop(async () => { await pool.end(); await client.end(); });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.auth_rate_limit, sonny.sign_in_code_issue");
    await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
    // The denylist references the account tree nowhere, so a `CASCADE` there does not reach it.
    await client.query("TRUNCATE sonny.revoked_provider_session");
    provider = new SigningProvider();
  });

  const build = () => buildApp(config, { provider, withConnection });
  const signIn = async (app: ReturnType<typeof build>, email: string): Promise<string> => {
    await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email } });
    const verified = await app.inject({
      method: "POST", url: "/v1/auth/email/verify", payload: { email, code: "1" },
    });
    return verified.json().user.id as string;
  };
  const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
  /** A protected route that touches nothing but the gate. `DELETE /v1/account` would close it. */
  const protectedCall = (app: ReturnType<typeof build>, token: string) =>
    app.inject({ method: "GET", url: "/v1/account/credits", headers: bearer(token) });

  itUnderHangBackstop("refuses the very token the sign-out was made with", async () => {
    const app = build();
    await signIn(app, "signer@example.com");
    const token = accessTokenFor(SESSION_USER);

    // Before: the token works. Without this the test could pass against a gate that refuses
    // everything, which is the shape a denylist defect is easiest to hide in.
    expect((await protectedCall(app, token)).statusCode).toBe(200);

    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(token) }))
      .statusCode).toBe(204);

    const after = await protectedCall(app, token);
    expect(after.statusCode).toBe(401);
    expect(after.json().error.code).toBe("auth.token_revoked");
    expect(await revokedProviderSessionCount(client)).toBe(1);
    await app.close();
  });

  itUnderHangBackstop("leaves the same user's OTHER session working", async () => {
    // One user, two devices: signing out on one must not sign the other out. That is the whole
    // reason the adapter asks Supabase for `?scope=local`, and the denylist has to agree with it or
    // the gateway undoes at its own gate what the provider was careful not to do.
    const app = build();
    await signIn(app, "twodevices@example.com");
    const thisMac = accessTokenFor(SESSION_USER);
    const otherMac = accessTokenFor(SESSION_USER, { sessionId: SECOND_DEVICE_SESSION });

    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(thisMac) }))
      .statusCode).toBe(204);

    expect((await protectedCall(app, thisMac)).statusCode).toBe(401);
    expect((await protectedCall(app, otherMac)).statusCode).toBe(200);
    const { rows } = await client.query<{ session_id: string }>(
      "SELECT session_id FROM sonny.revoked_provider_session",
    );
    expect(rows.map((r) => r.session_id)).toEqual([providerSessionFor(SESSION_USER)]);
    await app.close();
  });

  itUnderHangBackstop("keeps the row until the token's exp PLUS the skew tolerance", async () => {
    // The retention the founders decided on 2026-08-30, read off the row rather than off the code
    // that wrote it. `exp` alone would be thirty seconds short, and those thirty seconds are exactly
    // the window `clock.ts` grants a token past its own claim — so the token would verify while the
    // table had forgotten it.
    const app = build();
    await signIn(app, "retention@example.com");
    const issued = new Date();
    const token = accessTokenFor(SESSION_USER, { now: issued, lifetimeSeconds: 3600 });
    const exp = new Date((Math.floor(issued.getTime() / 1000) + 3600) * 1000);

    await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(token) });

    const { rows } = await client.query<{ expires_at: Date }>(
      "SELECT expires_at FROM sonny.revoked_provider_session WHERE session_id = $1",
      [providerSessionFor(SESSION_USER)],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]!.expires_at.getTime() - exp.getTime()).toBe(EXPIRY_SKEW_TOLERANCE_SECONDS * 1000);
    await app.close();
  });

  itUnderHangBackstop("prunes a row whose token has expired, and only that row", async () => {
    // The other half of the retention decision: a row that can no longer authorise anything is
    // dropped. The prune rides on the next write, so this plants a dead row, signs a live session
    // out, and reads what survived.
    const app = build();
    await signIn(app, "prune@example.com");
    await client.query(
      `INSERT INTO sonny.revoked_provider_session (session_id, revoked_at, expires_at)
       VALUES ($1, now() - interval '2 hours', now() - interval '1 hour')`,
      [SECOND_DEVICE_SESSION],
    );
    expect(await revokedProviderSessionCount(client)).toBe(1);

    await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(accessTokenFor(SESSION_USER)),
    });

    const { rows } = await client.query<{ session_id: string }>(
      "SELECT session_id FROM sonny.revoked_provider_session",
    );
    expect(rows.map((r) => r.session_id)).toEqual([providerSessionFor(SESSION_USER)]);
    await app.close();
  });

  itUnderHangBackstop("leaves another session's LIVE row alone while pruning the dead one", async () => {
    // **The property the prune's `WHERE` actually carries, and the one a battery found missing.**
    // `prunes a row whose token has expired, and only that row` reads as if it covers this and does
    // not: with the boundary widened to every row, that test still ends with exactly the row it
    // asserts, because the row it planted was the one meant to go. What tells the two apart is a
    // *live* row belonging to somebody else — under a prune that drops everything, signing one user
    // out un-revokes every other signed-out session in the system, which is the same defect this
    // ticket exists to fix, arriving through the fix.
    const app = build();
    await signIn(app, "bystander@example.com");
    const first = accessTokenFor(SESSION_USER, { sessionId: SECOND_DEVICE_SESSION });
    const second = accessTokenFor(SESSION_USER);

    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(first) }))
      .statusCode).toBe(204);
    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(second) }))
      .statusCode).toBe(204);

    const { rows } = await client.query<{ session_id: string }>(
      "SELECT session_id FROM sonny.revoked_provider_session ORDER BY session_id",
    );
    expect(rows.map((r) => r.session_id).sort())
      .toEqual([SECOND_DEVICE_SESSION, providerSessionFor(SESSION_USER)].sort());
    // And the property in the terms a user meets it in: the first session is still refused.
    expect((await protectedCall(app, first)).statusCode).toBe(401);
    expect((await protectedCall(app, second)).statusCode).toBe(401);
    await app.close();
  });

  itUnderHangBackstop("re-revokes a session whose own row has already expired", async () => {
    // **The prune and the upsert touch one row in one statement, and this is the case that finds
    // out.** One user signing out twice more than a token lifetime apart, with no other sign-out in
    // between to have pruned the row, so the prune's `DELETE` and the insert's `ON CONFLICT` are
    // both about the same `session_id`.
    //
    // **`revoked_at` is what tells the two possible mechanisms apart, and the version of this test
    // that did not read it passed under both** (PR #215's F2). `DO UPDATE` sets only the columns it
    // names, so a genuine insert restamps `revoked_at` and an update on the pruned tuple cannot —
    // and asserting one row with a future `expires_at`, which is all this test used to do, is true
    // either way. What actually happens is the update, and this branch then chose to make it
    // restamp: `denylist.ts` carries the reasoning, which is that "the first ask" is not a meaning
    // the storage can keep across a prune while "the most recent ask" is.
    //
    // The `2000` plant is far enough from anything the run produces that a stale value cannot be
    // mistaken for a fresh one, and `signedOutAt` below is the assertion the mechanism decides.
    const app = build();
    await signIn(app, "twice@example.com");
    const plantedRevokedAt = new Date("2000-01-01T00:00:00.000Z");
    await client.query(
      `INSERT INTO sonny.revoked_provider_session (session_id, revoked_at, expires_at)
       VALUES ($1, $2, now() - interval '2 hours')`,
      [providerSessionFor(SESSION_USER), plantedRevokedAt],
    );
    const beforeSignOut = Date.now();

    const answered = await app.inject({
      method: "POST", url: "/v1/auth/signout",
      headers: bearer(accessTokenFor(SESSION_USER)),
    });

    expect(answered.statusCode).toBe(204);
    const { rows } = await client.query<{ revoked_at: Date; expires_at: Date }>(
      "SELECT revoked_at, expires_at FROM sonny.revoked_provider_session WHERE session_id = $1",
      [providerSessionFor(SESSION_USER)],
    );
    // One row, and its window is the new token's rather than the dead one's.
    expect(rows).toHaveLength(1);
    expect(rows[0]!.expires_at.getTime()).toBeGreaterThan(Date.now());
    // And the row says it was signed out just now rather than in 2000, which is the half the
    // previous version of this test could not see.
    const signedOutAt = rows[0]!.revoked_at.getTime();
    expect(signedOutAt).not.toBe(plantedRevokedAt.getTime());
    expect(signedOutAt).toBeGreaterThanOrEqual(beforeSignOut - 1000);
    await app.close();
  });

  itUnderHangBackstop("never shortens a row a second sign-out presents an older token for", async () => {
    // `session_id` survives a refresh, so two tokens of one session can be presented at different
    // times with different expiries. Taking the later of the two is what keeps the row covering
    // every token this gateway has been shown; `EXCLUDED.expires_at` alone would let an older token
    // shorten the window a newer one had already earned.
    const app = build();
    await signIn(app, "greatest@example.com");
    const now = new Date();
    const longLived = accessTokenFor(SESSION_USER, { now, lifetimeSeconds: 7200 });
    const shortLived = accessTokenFor(SESSION_USER, { now, lifetimeSeconds: 60 });

    await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(longLived) });
    const first = await client.query<{ expires_at: Date }>(
      "SELECT expires_at FROM sonny.revoked_provider_session",
    );
    await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(shortLived) });
    const second = await client.query<{ expires_at: Date }>(
      "SELECT expires_at FROM sonny.revoked_provider_session",
    );

    expect(second.rows).toHaveLength(1);
    expect(second.rows[0]!.expires_at.getTime()).toBe(first.rows[0]!.expires_at.getTime());
    // The control: the two tokens really do carry different expiries, so the equality above is the
    // GREATEST holding rather than two identical values agreeing.
    const expected = (Math.floor(now.getTime() / 1000) + 7200 + EXPIRY_SKEW_TOLERANCE_SECONDS) * 1000;
    expect(second.rows[0]!.expires_at.getTime()).toBe(expected);
    await app.close();
  });

  itUnderHangBackstop("records the row even when the provider cannot be reached", async () => {
    // The local half is the one this gateway can guarantee, and it must not be lost to a provider
    // blip: a user who pressed Sign out should not keep a working access token because Supabase was
    // down. The refresh family stays live and the caller is told so with a 502.
    const app = build();
    await signIn(app, "unreachable@example.com");
    const token = accessTokenFor(SESSION_USER);
    provider.signOutFails = new ProviderUnavailable("admin API timed out");

    const answered = await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(token),
    });
    expect(answered.statusCode).toBe(502);
    expect(answered.json().error.code).toBe("provider.unavailable");

    expect(await revokedProviderSessionCount(client)).toBe(1);
    expect((await protectedCall(app, token)).statusCode).toBe(401);
    await app.close();
  });

  itUnderHangBackstop("still lets the retry of a failed sign-out through to the provider", async () => {
    // **The regression the exemption exists for.** §9.3 makes a 502 retryable, and the retry carries
    // the same token — which the first attempt has already denylisted. Without
    // `DENYLIST_EXEMPT_ROUTES` that retry meets a 401 at the gate and the provider-side revocation
    // becomes unreachable by anyone: the local half succeeding would have closed the only path to
    // the remote half.
    const app = build();
    await signIn(app, "retry@example.com");
    const token = accessTokenFor(SESSION_USER);
    provider.signOutFails = new ProviderUnavailable("admin API timed out");
    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(token) }))
      .statusCode).toBe(502);

    provider.signOutFails = undefined;
    const retried = await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(token),
    });

    expect(retried.statusCode).toBe(204);
    // The provider was reached twice with the caller's own token, which is the property: the retry
    // was not swallowed by this gateway's own record of the first attempt.
    expect(provider.signOutCalls).toEqual([token, token]);
    // And every other route stays refused, so the exemption is one route wide.
    expect((await protectedCall(app, token)).statusCode).toBe(401);
    await app.close();
  });

  itUnderHangBackstop("cannot deny a token that carries no session claim, and says so", async () => {
    // The residual, pinned in both directions rather than described. GoTrue omits `session_id`
    // (`omitempty`) and handles the absence itself, so this is a token the provider mints. The
    // sign-out succeeds, the provider is reached, nothing is recorded, and the token keeps working —
    // which is the state before this ticket, surviving for exactly this shape.
    const app = build();
    await signIn(app, "nosession@example.com");
    const claims = claimsFor(SESSION_USER);
    delete claims["session_id"];
    const token = signToken({ alg: "HS256", typ: "JWT" }, claims);

    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(token) }))
      .statusCode).toBe(204);

    expect(provider.signOutCalls).toEqual([token]);
    expect(await revokedProviderSessionCount(client)).toBe(0);
    expect((await protectedCall(app, token)).statusCode).toBe(200);
    await app.close();
  });
});
