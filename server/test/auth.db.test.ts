import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_ADDRESS } from "../src/auth/ratelimit.js";
import { ProviderRejected, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import { up } from "../src/db/migrate.js";

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const config: Config = {
  environment: "local", port: 0, host: "127.0.0.1", buildId: "t",
  databaseUrl: url, logLevel: "fatal", trustProxy: false,
  rateLimitSalt: "test-salt", allowUnauthenticatedAccountDelete: false, credentials: [],
};

/** A provider that records what it was asked and answers however the test needs. */
class FakeProvider implements AuthProvider {
  sent: string[] = [];
  accept = true;
  session: VerifiedSession = {
    supabaseUserId: "11111111-1111-1111-1111-111111111111",
    email: "u@example.com", emailVerified: true,
    accessToken: "at", refreshToken: "rt", expiresIn: 3600,
  };
  async sendEmailCode(email: string) { this.sent.push(email); return { providerRequestId: "p1" }; }
  async verifyEmailCode(): Promise<VerifiedSession> {
    if (!this.accept) throw new ProviderRejected("Token has expired or is invalid");
    return this.session;
  }
  async refresh(): Promise<VerifiedSession> {
    if (!this.accept) throw new ProviderRejected("refresh rejected");
    return this.session;
  }
  revokedUsers: string[] = [];
  async signOut() { if (!this.accept) throw new ProviderRejected("already gone"); }
  async signOutAllForUser(id: string) { this.revokedUsers.push(id); }
  async userFromAccessToken(token: string): Promise<string> {
    if (token !== "at") throw new ProviderRejected("bad token");
    return this.session.supabaseUserId;
  }
  async deleteUser() {}
}

describeDb("the auth endpoints", () => {
  let client: pg.Client;
  let provider: FakeProvider;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await up(client);
  });
  afterAll(async () => { await client.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.auth_rate_limit, sonny.sign_in_code_issue");
    await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
    provider = new FakeProvider();
  });

  const build = () => buildApp(config, { provider, db: async () => client });
  /** The gate `loadConfig` refuses in production. Only the deletion tests turn it on. */
  const buildWithDelete = () =>
    buildApp({ ...config, allowUnauthenticatedAccountDelete: true }, { provider, db: async () => client });

  describe("POST /v1/auth/email/start", () => {
    it("answers identically for an address with an account and one without", async () => {
      // Contract §3.6: an endpoint that answers differently is an account-existence oracle. This is
      // the assertion that keeps it from becoming one.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "known@example.com", code: "123456" } });
      const known = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "known@example.com" } });
      const unknown = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "nobody@example.com" } });
      expect(known.statusCode).toBe(unknown.statusCode);
      expect(Object.keys(known.json()).sort()).toEqual(Object.keys(unknown.json()).sort());
      expect(known.json().expires_in).toBe(unknown.json().expires_in);
      await app.close();
    });

    it("stays silent when the per-ADDRESS limit is hit — a 429 there is the oracle in slow motion", async () => {
      const app = build();
      const send = () => app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "quiet@example.com" } });
      for (let i = 0; i < CODE_REQUEST_PER_ADDRESS.max; i += 1) expect((await send()).statusCode).toBe(200);
      const over = await send();
      expect(over.statusCode).toBe(200);
      // and the send really did stop, which is the point of the limit
      expect(provider.sent.filter((e) => e === "quiet@example.com")).toHaveLength(CODE_REQUEST_PER_ADDRESS.max);
      await app.close();
    });

    it("answers 429 with Retry-After when the per-SOURCE limit is hit", async () => {
      // A fact about the caller, not about any address, so telling them is not a leak — and not
      // telling them leaves them retrying against a wall with no signal.
      const app = build();
      for (let i = 0; i < CODE_REQUEST_PER_SOURCE.max; i += 1) {
        await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: `a${i}@example.com` } });
      }
      const over = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "z@example.com" } });
      expect(over.statusCode).toBe(429);
      expect(over.json().error.code).toBe("limit.rate");
      expect(over.json().error.retryable).toBe(true);
      expect(Number(over.headers["retry-after"])).toBeGreaterThan(0);
      await app.close();
    });

    it("returns the uniform response even when the provider fails to send", async () => {
      const app = build();
      provider.sendEmailCode = async () => { throw new Error("smtp down"); };
      const response = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "fails@example.com" } });
      expect(response.statusCode).toBe(200);
      expect(response.json().expires_in).toBeGreaterThan(0);
      await app.close();
    });

    it("rejects a malformed address with the contract's envelope", async () => {
      const app = build();
      const response = await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "not-an-email" } });
      expect(response.statusCode).toBe(400);
      expect(response.json().error.code).toBe("request.invalid");
      await app.close();
    });
  });

  describe("POST /v1/auth/email/verify", () => {
    const verify = (app: ReturnType<typeof build>, code = "123456", email = "v@example.com") =>
      app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email, code } });

    it("returns the contract's token response and an account id", async () => {
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "v@example.com" } });
      const response = await verify(app);
      expect(response.statusCode).toBe(200);
      const body = response.json();
      expect(body.token_type).toBe("Bearer");
      expect(body.access_token).toBe("at");
      expect(body.refresh_token).toBe("rt");
      expect(body.expires_in).toBe(3600);
      expect(body.expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
      expect(body.user.id).toMatch(/^[0-9a-f-]{36}$/);
      await app.close();
    });

    it("gives the three distinct failures the contract requires", async () => {
      const app = build();
      // invalid: nothing was ever issued
      provider.accept = false;
      expect((await verify(app, "000000", "never@example.com")).json().error.code).toBe("auth.code_invalid");

      // used: issued, consumed by a successful verify, then replayed
      provider.accept = true;
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "used@example.com" } });
      expect((await verify(app, "123456", "used@example.com")).statusCode).toBe(200);
      provider.accept = false;
      expect((await verify(app, "123456", "used@example.com")).json().error.code).toBe("auth.code_used");

      // expired: issued, then aged past its lifetime
      provider.accept = true;
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "exp@example.com" } });
      await client.query("UPDATE sonny.sign_in_code_issue SET expires_at = now() - interval '1 minute' WHERE email_norm = 'exp@example.com'");
      provider.accept = false;
      expect((await verify(app, "123456", "exp@example.com")).json().error.code).toBe("auth.code_expired");
      await app.close();
    });

    it("does not burn a live code on a wrong guess", async () => {
      // A wrong guess must not cost the user their code — otherwise one attacker guessing locks
      // every real user out of the code they are holding.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "keep@example.com" } });
      provider.accept = false;
      await verify(app, "999999", "keep@example.com");
      provider.accept = true;
      expect((await verify(app, "123456", "keep@example.com")).statusCode).toBe(200);
      await app.close();
    });

    it("refuses a replay of a successful verify", async () => {
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "replay@example.com" } });
      expect((await verify(app, "123456", "replay@example.com")).statusCode).toBe(200);
      // The provider would happily accept it again; our own single-use record is what refuses.
      const second = await verify(app, "123456", "replay@example.com");
      expect(second.statusCode).toBe(400);
      expect(second.json().error.code).toBe("auth.code_used");
      await app.close();
    });

    it("rate-limits guessing per address", async () => {
      const app = build();
      provider.accept = false;
      for (let i = 0; i < CODE_VERIFY_PER_ADDRESS.max; i += 1) await verify(app, "000000", "brute@example.com");
      const over = await verify(app, "000000", "brute@example.com");
      expect(over.statusCode).toBe(429);
      expect(over.json().error.code).toBe("limit.rate");
      await app.close();
    });

    it("lands two sign-ins for one address on one account", async () => {
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "same@example.com" } });
      const first = await verify(app, "123456", "same@example.com");
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "same@example.com" } });
      const second = await verify(app, "123456", "same@example.com");
      expect(second.json().user.id).toBe(first.json().user.id);
      await app.close();
    });
  });

  describe("DELETE /v1/account", () => {
    it("is NOT MOUNTED unless the gate is explicitly on", async () => {
      // The finding, inverted (PR #87 F1). The previous version of this block asserted that an
      // unauthenticated caller with a header could destroy an account, and asserted it PASSED —
      // a green test blessing a destructive primitive that authenticates nothing, which would go
      // live the moment SONNY-128 mounted middleware around it. A proof of concept destroyed
      // another account with a made-up bearer token under SONNY_ENV=production.
      const app = build();
      const response = await app.inject({
        method: "DELETE", url: "/v1/account",
        headers: { authorization: "Bearer anything", "sonny-account-id": "11111111-1111-1111-1111-111111111111" },
      });
      expect(response.statusCode).toBe(404);
      expect(response.json().error.code).toBe("resource.not_found");
      await app.close();
    });

    it("REFUSES cross-account deletion — the route cannot attribute a caller", async () => {
      // With the gate on, the route still must not become a way to delete someone else's account
      // on the strength of a header. It cannot tell who is asking, so what it must not do is act
      // as though it can.
      const app = buildWithDelete();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "victim@example.com" } });
      const victim = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "victim@example.com", code: "1" } })).json().user.id;

      const attack = await app.inject({
        method: "DELETE", url: "/v1/account",
        headers: { authorization: "Bearer made-up-token", "sonny-account-id": victim },
      });
      expect(attack.statusCode).toBe(401);
      const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [victim]);
      expect(rows[0].deleted_at).toBeNull();
      await app.close();
    });

    it("refuses without a bearer token", async () => {
      const app = buildWithDelete();
      const response = await app.inject({ method: "DELETE", url: "/v1/account" });
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.unauthenticated");
      await app.close();
    });
  });

  describe("POST /v1/auth/refresh and /signout", () => {
    it("returns a rotated token pair", async () => {
      const app = build();
      const response = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(response.statusCode).toBe(200);
      expect(response.json().refresh_token).toBe("rt");
      expect(response.json().token_type).toBe("Bearer");
      await app.close();
    });

    it("answers 401 auth.token_revoked when the provider refuses — reuse past the overlap", async () => {
      const app = build();
      provider.accept = false;
      const response = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "stale" } });
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.token_revoked");
      await app.close();
    });

    it("requires a bearer token to sign out, and is idempotent once signed out", async () => {
      const app = build();
      expect((await app.inject({ method: "POST", url: "/v1/auth/signout" })).statusCode).toBe(401);
      expect((await app.inject({
        method: "POST", url: "/v1/auth/signout", headers: { authorization: "Bearer at" },
      })).statusCode).toBe(204);
      provider.accept = false;
      // An already-invalid token is a signed-out session; answering 401 would make the client's
      // retry loop the user's problem for a state they already wanted.
      expect((await app.inject({
        method: "POST", url: "/v1/auth/signout", headers: { authorization: "Bearer at" },
      })).statusCode).toBe(204);
      await app.close();
    });
  });
});
