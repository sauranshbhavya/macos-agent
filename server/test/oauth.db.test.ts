import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect } from "vitest";
import { buildApp } from "../src/app.js";
import { accountForSupabaseUser } from "../src/auth/attribution.js";
import { isGatewaySession, recordGatewaySession } from "../src/auth/gateway-session.js";
import { normalizeEmail, resolve } from "../src/auth/identity.js";
import { OAUTH_REDIRECT_URL } from "../src/auth/oauth.js";
import {
  ProviderRejected, ProviderUnavailable,
  type AuthProvider, type OAuthProviderName, type OAuthSession, type VerifiedSession,
} from "../src/auth/provider.js";
import { OAUTH_EXCHANGE_PER_SOURCE } from "../src/auth/ratelimit.js";
import type { Config } from "../src/config.js";
import { down, up } from "../src/db/migrate.js";
import { testConfig } from "./support/config.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor } from "./support/tokens.js";
import {
  afterAllUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop, itUnderHangBackstop,
} from "./support/backstop.js";

/**
 * Sign in with Google, the guard that keeps one provider-side user on one account, and the gate that
 * honours only sessions this gateway started (SONNY-129) — against a real Postgres, through the real
 * routes.
 *
 * **Why a database suite.** Every property below lives in a table: which account an identity sits on,
 * which Supabase user it names, which sessions were recorded, and what `accountForSupabaseUser` answers
 * over all of that. A fake connection would prove the routes issue statements; these tests prove what
 * the statements leave behind.
 *
 * **The fake provider behaves the way Supabase does in the two respects this ticket is about.** It
 * signs everyone in as whichever Supabase user the test names — which is what automatic linking does
 * to two sign-ins on one verified address — and it mints a **fresh session id per sign-in**, the way a
 * real provider does, so no test here passes because two sign-ins happened to share one.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

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

const USER_A = "a1a1a1a1-0000-4000-8000-000000000001";
const USER_B = "b2b2b2b2-0000-4000-8000-000000000002";
const CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

class GoogleAndEmailProvider implements AuthProvider {
  /** The Supabase user every sign-in comes back as — the knob that stands for automatic linking. */
  supabaseUserId = USER_A;
  google = { subject: "google-sub-1", email: "person@example.com", emailVerified: true };
  exchange: "ok" | "rejected" | "unavailable" = "ok";
  /** Mint the access token under a key the gateway does not accept. */
  unverifiableToken = false;
  readonly exchanges: { authCode: string; codeVerifier: string }[] = [];
  readonly signedOut: string[] = [];
  readonly sessionsMinted: string[] = [];

  private minted(): VerifiedSession {
    const sessionId = randomUUID();
    this.sessionsMinted.push(sessionId);
    const accessToken = this.unverifiableToken
      ? accessTokenFor(this.supabaseUserId, { sessionId }).replace(/\.[^.]*$/, ".not-the-signature")
      : accessTokenFor(this.supabaseUserId, { sessionId });
    return {
      supabaseUserId: this.supabaseUserId,
      email: this.google.email,
      emailVerified: true,
      accessToken,
      refreshToken: `rt-${sessionId}`,
      expiresIn: 3600,
    };
  }

  oauthAuthorizeUrl(provider: OAuthProviderName, redirectTo: string, codeChallenge: string): string {
    return `https://project-ref.supabase.co/auth/v1/authorize?provider=${provider}` +
      `&redirect_to=${encodeURIComponent(redirectTo)}&code_challenge=${codeChallenge}`;
  }
  async exchangeOAuthCode(
    provider: OAuthProviderName, authCode: string, codeVerifier: string,
  ): Promise<OAuthSession> {
    this.exchanges.push({ authCode, codeVerifier });
    if (this.exchange === "rejected") throw new ProviderRejected("flow_state_not_found");
    if (this.exchange === "unavailable") throw new ProviderUnavailable("supabase exchangeOAuthCode could not be reached");
    return { ...this.minted(), identity: { provider, ...this.google } };
  }
  async sendEmailCode(_email: string) { return { providerRequestId: "p1" }; }
  async verifyEmailCode(_email: string, _code: string): Promise<VerifiedSession> { return this.minted(); }
  async refresh(_token: string): Promise<VerifiedSession> { return this.minted(); }
  async signOut(accessToken: string) { this.signedOut.push(accessToken); }
  async userFromAccessToken(_accessToken: string): Promise<string> {
    throw new ProviderRejected("the gate verifies locally; this seam is not on the request path");
  }
  async signOutAllForUser(_id: string) {}
  async deleteUser() {}
}

describeDb("Sign in with Google, one provider-side user per account, and sessions the gateway started", () => {
  let client: pg.Client;
  let provider: GoogleAndEmailProvider;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
    pool = new pg.Pool({ connectionString: url, max: 8 });
  });
  afterAllUnderHangBackstop(async () => { await pool.end(); await client.end(); });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.auth_rate_limit, sonny.sign_in_code_issue, sonny.revoked_provider_session");
    await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
    provider = new GoogleAndEmailProvider();
  });

  const build = () => buildApp(config, { provider, withConnection });
  const googleSignIn = (app: ReturnType<typeof build>, body: Record<string, unknown> = {}) =>
    app.inject({
      method: "POST", url: "/v1/auth/oauth/google",
      payload: { auth_code: "0b8f1c52-code", code_verifier: VERIFIER, ...body },
    });
  const emailSignIn = async (app: ReturnType<typeof build>, email: string) => {
    await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email } });
    return app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email, code: "123456" } });
  };
  /** A protected route that touches nothing but the gate. */
  const protectedCall = (app: ReturnType<typeof build>, token: string) =>
    app.inject({ method: "GET", url: "/v1/account/credits", headers: { authorization: `Bearer ${token}` } });
  const accountCount = async () =>
    (await client.query<{ n: number }>("SELECT count(*)::int AS n FROM sonny.account")).rows[0]!.n;

  describe("POST /v1/auth/oauth/google/start", () => {
    itUnderHangBackstop("answers the provider's authorize URL with the fixed redirect and the caller's challenge", async () => {
      const app = build();
      const response = await app.inject({
        method: "POST", url: "/v1/auth/oauth/google/start", payload: { code_challenge: CHALLENGE },
      });
      expect(response.statusCode).toBe(200);
      const authorize = new URL(response.json().authorize_url);
      expect(authorize.searchParams.get("provider")).toBe("google");
      // The redirect is the gateway's constant, never a request field.
      expect(authorize.searchParams.get("redirect_to")).toBe(OAUTH_REDIRECT_URL);
      expect(authorize.searchParams.get("code_challenge")).toBe(CHALLENGE);
      await app.close();
    });

    itUnderHangBackstop("refuses anything that is not an S256 challenge, and a redirect it was not asked for changes nothing", async () => {
      const app = build();
      for (const code_challenge of ["", "short", `${CHALLENGE}x`, CHALLENGE.replace("-", "+"), 43]) {
        const refused = await app.inject({
          method: "POST", url: "/v1/auth/oauth/google/start", payload: { code_challenge },
        });
        expect(refused.statusCode).toBe(400);
        expect(refused.json().error.code).toBe("request.invalid");
      }
      // A caller-supplied redirect is ignored rather than honoured: the destination is not a parameter.
      const answered = await app.inject({
        method: "POST", url: "/v1/auth/oauth/google/start",
        payload: { code_challenge: CHALLENGE, redirect_to: "https://attacker.example/steal" },
      });
      expect(new URL(answered.json().authorize_url).searchParams.get("redirect_to")).toBe(OAUTH_REDIRECT_URL);
      await app.close();
    });
  });

  describe("POST /v1/auth/oauth/google", () => {
    itUnderHangBackstop("signs a new person in: one account, the Google identity keyed on its sub, the session recorded, the token honoured", async () => {
      const app = build();
      const response = await googleSignIn(app);
      expect(response.statusCode).toBe(200);
      const body = response.json();
      expect(body.token_type).toBe("Bearer");
      expect(body.user.id).toMatch(/^[0-9a-f-]{36}$/);
      // The provider's address comes back for display; nothing on the client decides from it.
      expect(body.user.email).toBe("person@example.com");
      expect(body.link_hint).toBeUndefined();
      expect(provider.exchanges).toEqual([{ authCode: "0b8f1c52-code", codeVerifier: VERIFIER }]);

      const identity = await client.query(
        "SELECT account_id, provider, subject, supabase_user_id FROM sonny.identity",
      );
      expect(identity.rows).toEqual([
        { account_id: body.user.id, provider: "google", subject: "google-sub-1", supabase_user_id: USER_A },
      ]);
      const sessions = await client.query("SELECT session_id, supabase_user_id, account_id, method FROM sonny.gateway_session");
      expect(sessions.rows).toEqual([
        { session_id: provider.sessionsMinted[0], supabase_user_id: USER_A, account_id: body.user.id, method: "google" },
      ]);
      expect((await protectedCall(app, body.access_token)).statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("lands the same Google identity on the same account the second time", async () => {
      const app = build();
      const first = await googleSignIn(app);
      const second = await googleSignIn(app);
      expect(second.statusCode).toBe(200);
      expect(second.json().user.id).toBe(first.json().user.id);
      expect(await accountCount()).toBe(1);
      // Two sign-ins, two sessions, both honoured.
      expect((await protectedCall(app, first.json().access_token)).statusCode).toBe(200);
      expect((await protectedCall(app, second.json().access_token)).statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("refuses a body that is not a code and a verifier, before the provider is asked", async () => {
      const app = build();
      for (const body of [
        { code_verifier: VERIFIER.slice(0, 42) },
        { code_verifier: `${VERIFIER}!` },
        { auth_code: "has a space" },
        { auth_code: "" },
        { auth_code: undefined },
      ]) {
        const refused = await googleSignIn(app, body);
        expect(refused.statusCode).toBe(400);
        expect(refused.json().error.code).toBe("request.invalid");
      }
      expect(provider.exchanges).toEqual([]);
      await app.close();
    });

    itUnderHangBackstop("answers the provider's refusal as auth.code_invalid and its absence as provider.unavailable, creating nothing", async () => {
      const app = build();
      provider.exchange = "rejected";
      const rejected = await googleSignIn(app);
      expect(rejected.statusCode).toBe(400);
      expect(rejected.json().error.code).toBe("auth.code_invalid");
      provider.exchange = "unavailable";
      const unavailable = await googleSignIn(app);
      expect(unavailable.statusCode).toBe(502);
      expect(unavailable.json().error.code).toBe("provider.unavailable");
      expect(await accountCount()).toBe(0);
      await app.close();
    });

    itUnderHangBackstop("refuses to hand out a session whose token the gateway cannot verify, and ends it", async () => {
      // The case `mintedSessionOf` exists for: a project signing with a key the gateway does not hold.
      // Before this ticket that sign-in "succeeded" and every request after it was refused.
      const app = build();
      provider.unverifiableToken = true;
      const response = await googleSignIn(app);
      expect(response.statusCode).toBe(500);
      expect(response.json().error.code).toBe("server.error");
      expect(await accountCount()).toBe(0);
      expect((await client.query("SELECT 1 FROM sonny.gateway_session")).rows).toHaveLength(0);
      expect(provider.signedOut).toHaveLength(1);
      await app.close();
    });

    itUnderHangBackstop("limits attempts per source, and says so with a Retry-After", async () => {
      const app = build();
      provider.exchange = "rejected";
      for (let attempt = 0; attempt < OAUTH_EXCHANGE_PER_SOURCE.max; attempt += 1) {
        expect((await googleSignIn(app)).statusCode).toBe(400);
      }
      const limited = await googleSignIn(app);
      expect(limited.statusCode).toBe(429);
      expect(limited.json().error.code).toBe("limit.rate");
      expect(Number(limited.headers["retry-after"])).toBeGreaterThan(0);
      // The refused attempt never reached the provider.
      expect(provider.exchanges).toHaveLength(OAUTH_EXCHANGE_PER_SOURCE.max);
      await app.close();
    });

    itUnderHangBackstop("still flags a verified address match under a DIFFERENT Supabase user, and does not flag an unverified one", async () => {
      // Rule 2 is untouched: where Supabase did NOT link the two (different users), a verified match
      // creates the second account and says why. The guard only refuses a SHARED user.
      const app = build();
      provider.supabaseUserId = USER_A;
      await emailSignIn(app, "person@example.com");
      provider.supabaseUserId = USER_B;
      const flagged = await googleSignIn(app);
      expect(flagged.statusCode).toBe(200);
      expect(flagged.json().link_hint).toBe("verified_email_matches_existing_account");

      await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
      provider.supabaseUserId = USER_A;
      await emailSignIn(app, "person@example.com");
      provider.supabaseUserId = USER_B;
      provider.google = { ...provider.google, subject: "google-sub-2", emailVerified: false };
      const unflagged = await googleSignIn(app);
      expect(unflagged.statusCode).toBe(200);
      expect(unflagged.json().link_hint).toBeUndefined();
      await app.close();
    });

    itUnderHangBackstop("serves no Apple route: Sign in with Apple was dropped from v1 (SONNY-521)", async () => {
      const app = build();
      const response = await app.inject({ method: "POST", url: "/v1/auth/oauth/apple", payload: {} });
      expect(response.statusCode).toBe(404);
      await app.close();
    });
  });

  describe("one provider-side user never backs two live accounts (the founders' option A)", () => {
    itUnderHangBackstop("the rule alone, EMAIL then GOOGLE on one Supabase user, makes attribution ambiguous — which is why the guard exists", async () => {
      // A characterization of `resolve()` without the guard, measured rather than argued: SONNY-129's
      // finding, reproduced. If this ever stops holding, the guard's reason has moved and its doc
      // comment needs re-reading.
      const email = await resolve(client, {
        provider: "email", subject: normalizeEmail("dual@example.com"), email: "dual@example.com",
        emailVerified: true, supabaseUserId: USER_A,
      });
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ accountId: email.accountId });
      const google = await resolve(client, {
        provider: "google", subject: "google-sub-1", email: "dual@example.com", emailVerified: true,
        supabaseUserId: USER_A,
      });
      expect(google.accountId).not.toBe(email.accountId);
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ ambiguous: true });
    });

    itUnderHangBackstop("the rule alone, GOOGLE then EMAIL on one Supabase user, reaches the same ambiguity — the reverse order, run", async () => {
      const google = await resolve(client, {
        provider: "google", subject: "google-sub-1", email: "dual@example.com", emailVerified: true,
        supabaseUserId: USER_A,
      });
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ accountId: google.accountId });
      const email = await resolve(client, {
        provider: "email", subject: normalizeEmail("dual@example.com"), email: "dual@example.com",
        emailVerified: true, supabaseUserId: USER_A,
      });
      expect(email.accountId).not.toBe(google.accountId);
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ ambiguous: true });
    });

    itUnderHangBackstop("refuses GOOGLE after an EMAIL account on the same Supabase user: 409, nothing created, the first account still whole", async () => {
      const app = build();
      const byEmail = await emailSignIn(app, "person@example.com");
      expect(byEmail.statusCode).toBe(200);
      const refused = await googleSignIn(app);
      expect(refused.statusCode).toBe(409);
      expect(refused.json().error.code).toBe("auth.account_exists");
      expect(await accountCount()).toBe(1);
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ accountId: byEmail.json().user.id });
      // The refused session was ended at the provider and never recorded.
      const refusedSession = provider.sessionsMinted[1]!;
      expect(provider.signedOut).toHaveLength(1);
      expect(await isGatewaySession(client, refusedSession, USER_A, byEmail.json().user.id)).toBe(false);
      // And the email account's own session still works — nothing was locked.
      expect((await protectedCall(app, byEmail.json().access_token)).statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("refuses an EMAIL code after a GOOGLE account on the same Supabase user: the reverse order, refused the same way", async () => {
      const app = build();
      const byGoogle = await googleSignIn(app);
      expect(byGoogle.statusCode).toBe(200);
      const refused = await emailSignIn(app, "person@example.com");
      expect(refused.statusCode).toBe(409);
      expect(refused.json().error.code).toBe("auth.account_exists");
      expect(await accountCount()).toBe(1);
      expect(await accountForSupabaseUser(client, USER_A)).toEqual({ accountId: byGoogle.json().user.id });
      expect((await protectedCall(app, byGoogle.json().access_token)).statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("answers a user ALREADY in the broken state the way the gate does, and creates nothing more", async () => {
      // Seeded by hand, since no route can produce it any more.
      await resolve(client, {
        provider: "email", subject: "one@example.com", email: "one@example.com", emailVerified: true, supabaseUserId: USER_A,
      });
      await resolve(client, {
        provider: "email", subject: "two@example.com", email: "two@example.com", emailVerified: true, supabaseUserId: USER_A,
      });
      const app = build();
      const refused = await googleSignIn(app);
      expect(refused.statusCode).toBe(401);
      expect(refused.json().error.code).toBe("auth.token_revoked");
      expect(await accountCount()).toBe(2);
      await app.close();
    });

    itUnderHangBackstop("holds the per-user lock across the guard: a sign-in waits while another holds it", async () => {
      // **What makes the guard and `resolve()` one step.** Two sign-ins for one brand-new user, run
      // at once, would both find the user unowned and both create an account — the lockout, by timing.
      // Held here from a second connection, the lock must stop the route before it decides anything.
      const holder = new pg.Client({ connectionString: url });
      await holder.connect();
      try {
        await holder.query("SELECT pg_advisory_lock(hashtext($1))", [`sonny.sign_in:${USER_A}`]);
        const app = build();
        let settled = false;
        const pending = googleSignIn(app).then((response) => { settled = true; return response; });

        // Wait until the route is really blocked on that lock, rather than sleeping and hoping.
        let waiting = false;
        for (let poll = 0; poll < 200 && !waiting; poll += 1) {
          const { rows } = await holder.query(
            "SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted",
          );
          waiting = rows.length > 0;
          if (!waiting) await new Promise((resolveWait) => setTimeout(resolveWait, 25));
        }
        expect(waiting).toBe(true);
        expect(settled).toBe(false);
        expect(await accountCount()).toBe(0);

        await holder.query("SELECT pg_advisory_unlock(hashtext($1))", [`sonny.sign_in:${USER_A}`]);
        const response = await pending;
        expect(response.statusCode).toBe(200);
        expect(await accountCount()).toBe(1);
        await app.close();
      } finally {
        await holder.end();
      }
    });
  });

  describe("the gate honours only sessions the gateway started", () => {
    itUnderHangBackstop("refuses a session minted at the provider directly — the recycled-mailbox route around every sign-in rule", async () => {
      // A Google-first account. Then someone who can sign in as the same Supabase user without going
      // through this gateway — the new owner of a recycled mailbox, asking Supabase for an email code
      // directly — holds a token the project really signed, for the right user, carrying a session the
      // gateway never started.
      const app = build();
      const owner = await googleSignIn(app);
      expect(owner.statusCode).toBe(200);
      const direct = accessTokenFor(USER_A, { sessionId: randomUUID() });

      const refused = await protectedCall(app, direct);
      expect(refused.statusCode).toBe(401);
      expect(refused.json().error.code).toBe("auth.token_revoked");
      // Refresh asks the same question, so the direct session cannot be kept alive through Sonny.
      provider.supabaseUserId = USER_A;
      const directRefresh = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "direct" } });
      expect(directRefresh.statusCode).toBe(401);
      expect(directRefresh.json().error.code).toBe("auth.token_revoked");
      // Control: the owner's own session, which the gateway started, is untouched.
      expect((await protectedCall(app, owner.json().access_token)).statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("refuses a recorded session once attribution resolves its user to a different account", async () => {
      const app = build();
      const signedIn = await googleSignIn(app);
      const sessionId = provider.sessionsMinted[0]!;
      // Move the identity to another live account — what an identity moving looks like to the gate.
      const other = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query("UPDATE sonny.identity SET account_id = $1", [other.rows[0]!.id]);
      const refused = await protectedCall(app, accessTokenFor(USER_A, { sessionId }));
      expect(refused.statusCode).toBe(401);
      expect(refused.json().error.code).toBe("auth.token_revoked");
      expect(signedIn.statusCode).toBe(200);
      await app.close();
    });

    itUnderHangBackstop("records one session once, accepts the identical repeat, and refuses it for anyone else", async () => {
      const account = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      const another = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      const session = { supabaseUserId: USER_A, sessionId: randomUUID() };
      await recordGatewaySession(client, session, account.rows[0]!.id, "google");
      await recordGatewaySession(client, session, account.rows[0]!.id, "google");
      await expect(recordGatewaySession(client, session, another.rows[0]!.id, "google")).rejects.toThrow(
        /already recorded arrived again/,
      );
      await expect(
        recordGatewaySession(client, { ...session, supabaseUserId: USER_B }, account.rows[0]!.id, "google"),
      ).rejects.toThrow(/already recorded arrived again/);
      expect(await isGatewaySession(client, session.sessionId, USER_A, account.rows[0]!.id)).toBe(true);
      expect(await isGatewaySession(client, session.sessionId, USER_B, account.rows[0]!.id)).toBe(false);
      expect(await isGatewaySession(client, session.sessionId, USER_A, another.rows[0]!.id)).toBe(false);
    });
  });

  describe("migration 0023's guard", () => {
    itUnderHangBackstop("refuses to apply while any Supabase user backs two live accounts, and applies once it does not", async () => {
      // Rolled back to 0022, the broken state seeded — the only way to reach it now — and forward again.
      expect(await down(client)).toBe("0023_the_gate_honours_only_sessions_the_gateway_started");
      try {
        const one = await resolve(client, {
          provider: "email", subject: "one@example.com", email: "one@example.com", emailVerified: true, supabaseUserId: USER_A,
        });
        await resolve(client, {
          provider: "email", subject: "two@example.com", email: "two@example.com", emailVerified: true, supabaseUserId: USER_A,
        });
        await expect(up(client)).rejects.toThrow(/backs two live accounts/);
        // Nothing half-applied: the table is still absent.
        const table = await client.query("SELECT to_regclass('sonny.gateway_session') AS t");
        expect(table.rows[0].t).toBeNull();

        // Resolve the state — close one of the two accounts — and the same migration applies.
        await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [one.accountId]);
        expect(await up(client)).toEqual(["0023_the_gate_honours_only_sessions_the_gateway_started"]);
      } finally {
        // Whatever happened above, leave the schema at its head for the tests after this one.
        await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
        if ((await client.query("SELECT to_regclass('sonny.gateway_session') AS t")).rows[0].t === null) {
          await up(client);
        }
      }
    });
  });
});
