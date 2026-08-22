import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { CODE_REQUEST_PER_ADDRESS, CODE_REQUEST_PER_SOURCE, CODE_VERIFY_PER_ADDRESS } from "../src/auth/ratelimit.js";
import { ProviderRejected, ProviderUnavailable, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import { drainOwedRevocations, owedRevocationCount } from "../src/auth/revocation.js";
import { normalizeEmail } from "../src/auth/identity.js";
import { up } from "../src/db/migrate.js";

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

/**
 * Models the `WithConnection` contract the routes now require: a connection nobody else is using,
 * released on the way out (PR #87 R4). A pool is what a real deployment supplies, and using one here
 * is what makes `resolve()`'s "one transaction" claim actually testable — under the shared `Client`
 * these tests used before, its BEGIN nested inside whatever else was open and one COMMIT committed
 * both, so the guarantee was assumed rather than exercised.
 */
let pool: pg.Pool;
const withConnection = async <T,>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
  const conn = await pool.connect();
  try {
    return await fn(conn as unknown as pg.Client);
  } finally {
    conn.release();
  }
};

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
    // §3.2's `refresh_expires_at`, which the route emits only when the provider reports one — so a
    // fake that never reports one leaves that branch, and the field, entirely unexercised
    // (PR #87 second round, F7). Ninety days.
    refreshExpiresIn: 90 * 24 * 3600,
  };
  /**
   * **Rotation modelled, not assumed** (PR #87 second round, F7/F13). §3.3 makes the *provider*
   * responsible for retiring a rotated refresh token, and a fake that accepts any string could not
   * tell a route that handles the retirement correctly from one that does not — which is why "the
   * old one stops working" went unasserted through two review rounds. This is the platform's
   * documented behaviour standing in for it: the token most recently issued is the only one
   * accepted, and presenting an older one is `ProviderRejected`, which §3.3 says is the theft case.
   *
   * What the *route* owns, and what the test therefore pins, is the mapping of that refusal onto
   * `401 auth.token_revoked`.
   */
  liveRefreshToken = "rt";
  async sendEmailCode(email: string) { this.sent.push(email); return { providerRequestId: "p1" }; }
  async verifyEmailCode(): Promise<VerifiedSession> {
    if (!this.accept) throw new ProviderRejected("Token has expired or is invalid");
    this.liveRefreshToken = this.session.refreshToken;
    return this.session;
  }
  async refresh(presented: string): Promise<VerifiedSession> {
    if (!this.accept) throw new ProviderRejected("refresh rejected");
    if (presented !== this.liveRefreshToken) {
      throw new ProviderRejected("refresh token was already rotated away");
    }
    this.liveRefreshToken = this.session.refreshToken;
    return this.session;
  }
  revokedUsers: string[] = [];
  /** Provider-side users whose revocation raises a TRANSIENT error — not `ProviderRejected`. */
  failFor = new Set<string>();
  /** Provider-side users the provider says it has never heard of. That is a completed revocation. */
  rejectFor = new Set<string>();
  async signOut() { if (!this.accept) throw new ProviderRejected("already gone"); }
  async signOutAllForUser(id: string) {
    if (this.failFor.has(id)) throw new ProviderUnavailable("admin API timed out");
    if (this.rejectFor.has(id)) throw new ProviderRejected("no such user");
    this.revokedUsers.push(id);
  }
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
    pool = new pg.Pool({ connectionString: url, max: 8 });
  });
  afterAll(async () => { await pool.end(); await client.end(); });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.auth_rate_limit, sonny.sign_in_code_issue");
    await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
    provider = new FakeProvider();
  });

  const build = () => buildApp(config, { provider, withConnection });
  /** The gate `loadConfig` refuses in production. Only the deletion tests turn it on. */
  const buildWithDelete = () =>
    buildApp({ ...config, allowUnauthenticatedAccountDelete: true }, { provider, withConnection });

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

    it("leaves ONE live code behind when three requests arrive together", async () => {
      // PR #87 second round, F11. Invalidate-then-record as two statements is fine one request at a
      // time and wrong under concurrency: three simultaneous starts each invalidated what they could
      // see and each inserted afterwards, and none could see the other two's uncommitted inserts —
      // so the address ended with **three** live issuances where the design promises one. The
      // per-address ceiling is three, which is exactly how many an attacker can arrange.
      //
      // Serial requests never showed it, which is why every existing test passed over it. This one
      // fires them together, on separate pooled connections, which is what a real deployment does.
      const app = build();
      const results = await Promise.all(
        Array.from({ length: CODE_REQUEST_PER_ADDRESS.max }, () =>
          app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "swarm@example.com" } })),
      );
      expect(results.map((r) => r.statusCode)).toEqual([200, 200, 200]);
      expect(provider.sent.filter((e) => e === "swarm@example.com")).toHaveLength(3);

      const { rows } = await client.query<{ live: number; total: number }>(
        `SELECT count(*) FILTER (WHERE consumed_at IS NULL)::int AS live,
                count(*)::int AS total
           FROM sonny.sign_in_code_issue WHERE mailbox_key = 'swarm@example.com'`,
      );
      // Three sends really happened — the send is a network call and cannot be made transactional —
      // and exactly one of the three records is live. Which one is the newest, which is the
      // founder's own manual-test item: "request a second code before using the first, and confirm
      // which one works."
      expect(rows[0]!.total).toBe(3);
      expect(rows[0]!.live).toBe(1);
      const newest = await client.query<{ consumed_at: Date | null }>(
        `SELECT consumed_at FROM sonny.sign_in_code_issue
          WHERE mailbox_key = 'swarm@example.com' ORDER BY issued_at DESC, id DESC LIMIT 1`,
      );
      expect(newest.rows[0]!.consumed_at).toBeNull();
      await app.close();
    });

    it("leaves ONE live code when the three requests are PLUS-TAG VARIANTS of one mailbox", async () => {
      // **The test above raced one literal address, and could not fail** (PR #87 third round, F4).
      // It was written as the regression guard for the single-live-code guarantee and it was
      // structurally incapable of seeing the way that guarantee was actually broken: the code
      // lifecycle keyed on `normalizeEmail` (plus-tags kept) while the rate limit keyed on
      // `rateLimitEmailKey` (plus-tags folded), so three spellings of one inbox shared one budget
      // and each held its own live code. Same address three times exercises neither half of that.
      //
      // Reproduced before the fix: three 200s, three mails to one inbox, three live codes — a 3×
      // guessing surface against a guarantee this branch states in three places. The variants below
      // are the whole point of the test and the reason it is separate rather than a parameter.
      const app = build();
      const variants = ["victim@example.com", "victim+1@example.com", "victim+2@example.com"];
      const results = await Promise.all(variants.map((email) =>
        app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email } })));
      expect(results.map((r) => r.statusCode)).toEqual([200, 200, 200]);
      // All three passed the per-address limit, which proves they really did share one bucket —
      // otherwise this test would be racing three independent mailboxes and would prove nothing.
      expect(provider.sent).toHaveLength(3);

      const { rows } = await client.query<{ live: number; total: number; keys: number }>(
        `SELECT count(*) FILTER (WHERE consumed_at IS NULL)::int AS live,
                count(*)::int AS total,
                count(DISTINCT mailbox_key)::int AS keys
           FROM sonny.sign_in_code_issue`,
      );
      expect(rows[0]!.total).toBe(3);
      // **One key, because there is one inbox.** This is the assertion the old test had no way to
      // make: keyed the old way there were three rows under three different keys, each of them the
      // newest of its own key and therefore each live.
      expect(rows[0]!.keys).toBe(1);
      expect(rows[0]!.live).toBe(1);

      // And the identity key is untouched by the fix, which is the other half of F4: folding these
      // together for CODES must not fold them together for ACCOUNTS.
      expect(normalizeEmail("victim+1@example.com")).not.toBe(normalizeEmail("victim@example.com"));
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
      await client.query("UPDATE sonny.sign_in_code_issue SET expires_at = now() - interval '1 minute' WHERE mailbox_key = 'exp@example.com'");
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
      // live the moment SONNY-203 mounted middleware around it. A proof of concept destroyed
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

    it("SUCCEEDS for the account the token belongs to, and revokes every session on it", async () => {
      // **There was no successful-delete test at all** (PR #87 R11), which is why R1 shipped green:
      // every case asserted a refusal, so nothing ever reached the revocation path.
      const app = buildWithDelete();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "gone@example.com" } });
      const accountId = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "gone@example.com", code: "1" } })).json().user.id;

      // A second identity on the SAME account under a DIFFERENT Supabase user — the case the whole
      // identity separation exists for, and the one that made "revoke this session" insufficient.
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, supabase_user_id, link_method)
         VALUES ($1,'apple','apple-sub-del','ggg@privaterelay.appleid.com',true,true,$2,'explicit')`,
        [accountId, "99999999-9999-9999-9999-999999999999"],
      );
      provider.revokedUsers = [];

      const response = await app.inject({
        method: "DELETE", url: "/v1/account", headers: { authorization: "Bearer at" },
      });
      expect(response.statusCode).toBe(204);

      const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [accountId]);
      expect(rows[0].deleted_at).not.toBeNull();

      // BOTH Supabase users revoked, not just the caller's.
      expect(provider.revokedUsers.sort()).toEqual(
        ["11111111-1111-1111-1111-111111111111", "99999999-9999-9999-9999-999999999999"].sort(),
      );

      // Identities kept and marked, not deleted: the audit trail and the ids SONNY-196 needs survive.
      const identities = await client.query(
        "SELECT account_closed, link_method, supabase_user_id FROM sonny.identity WHERE account_id = $1 ORDER BY link_method",
        [accountId],
      );
      expect(identities.rows).toHaveLength(2);
      expect(identities.rows.every((r: { account_closed: boolean }) => r.account_closed)).toBe(true);
      expect(identities.rows.map((r: { link_method: string }) => r.link_method)).toEqual(["explicit", "primary"]);

      // And the address is free again.
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "gone@example.com" } });
      const again = await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "gone@example.com", code: "1" } });
      expect(again.json().user.id).not.toBe(accountId);
      await app.close();
    });

    it("REFUSES when the token names two live accounts, and deletes NEITHER", async () => {
      // PR #87 second round, F6. The lookup ended in `ORDER BY … LIMIT 1`, so a token that named
      // two live accounts got one of them destroyed on the strength of a tiebreak — and the caller
      // would be told 204, which is the answer for the deletion they asked for, about the account
      // they did not name. On a destructive route the only safe answer to "which one?" is to refuse.
      const app = buildWithDelete();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "amb@example.com" } });
      const first = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "amb@example.com", code: "1" } })).json().user.id;

      const second = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, supabase_user_id, link_method)
         VALUES ($1,'google','g-amb','amb@example.com',true,false,$2,'primary')`,
        [second.rows[0]!.id, "11111111-1111-1111-1111-111111111111"],
      );
      provider.revokedUsers = [];

      const response = await app.inject({
        method: "DELETE", url: "/v1/account", headers: { authorization: "Bearer at" },
      });
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.unauthenticated");

      const { rows } = await client.query(
        "SELECT deleted_at FROM sonny.account WHERE id = ANY($1::uuid[]) ORDER BY id",
        [[first, second.rows[0]!.id]],
      );
      expect(rows).toHaveLength(2);
      expect(rows.every((r: { deleted_at: Date | null }) => r.deleted_at === null)).toBe(true);
      // and nothing was revoked either — a refusal that still signed the user out would be worse
      // than useless, because it would look like the deletion had partly happened.
      expect(provider.revokedUsers).toEqual([]);
      await app.close();
    });

    it("does not let ONE provider failure strand every identity after it", async () => {
      // **PR #87 third round, F1, and this is the whole defect in one test.** The revocation loop
      // rethrew anything that was not `ProviderRejected`, so a single transient error aborted it:
      // every identity ordered after the failing one was never even attempted. Reproduced end to
      // end — account closed and committed, 500 to the caller, the third identity never revoked,
      // and the retry answering 401, because a closed account can no longer be attributed to its
      // caller. There was no retry path at all; the stranded session was permanent.
      const app = buildWithDelete();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "flaky@example.com" } });
      const accountId = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "flaky@example.com", code: "1" } })).json().user.id;

      const FAILING = "44444444-4444-4444-4444-444444444444";
      const AFTER = "55555555-5555-5555-5555-555555555555";
      for (const [subject, user] of [["apple-flaky", FAILING], ["google-flaky", AFTER]] as const) {
        await client.query(
          `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
             email_is_relay, supabase_user_id, link_method)
           VALUES ($1,$2,$3,'flaky@example.com',true,false,$4,'explicit')`,
          [accountId, subject.startsWith("apple") ? "apple" : "google", subject, user],
        );
      }
      // Transient, and deliberately NOT ProviderRejected — that is the class the old loop rethrew.
      provider.revokedUsers = [];
      provider.failFor.add(FAILING);

      const response = await app.inject({
        method: "DELETE", url: "/v1/account", headers: { authorization: "Bearer at" },
      });
      // The account really is closed, so the caller is told the thing they asked for happened.
      expect(response.statusCode).toBe(204);
      expect((await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [accountId]))
        .rows[0].deleted_at).not.toBeNull();

      // **The identity AFTER the failing one was still attempted.** This is the assertion the fix
      // is for: under the old loop `revokedUsers` stopped at the first identity.
      expect(provider.revokedUsers).toContain(AFTER);
      expect(provider.revokedUsers).toContain("11111111-1111-1111-1111-111111111111");
      expect(provider.revokedUsers).not.toContain(FAILING);

      // **And the one that failed is recorded as still owed**, which is what gives it a path to
      // completion at all. A loop that merely caught and continued would leave it nowhere.
      const owed = await client.query<{ supabase_user_id: string }>(
        `SELECT supabase_user_id FROM sonny.identity
          WHERE account_id = $1 AND provider_session_revoked_at IS NULL AND supabase_user_id IS NOT NULL`,
        [accountId],
      );
      expect(owed.rows.map((r) => r.supabase_user_id)).toEqual([FAILING]);
      expect(await owedRevocationCount(client)).toBe(1);

      // The provider recovers. Nothing about this needs the original caller, who cannot reach the
      // route any more — which is the point.
      provider.failFor.clear();
      const drained = await drainOwedRevocations(client, provider);
      expect(drained).toEqual({ revoked: 1, failed: 0, failures: [] });
      expect(provider.revokedUsers).toContain(FAILING);
      expect(await owedRevocationCount(client)).toBe(0);

      // Idempotent: a second drain finds nothing and calls nobody.
      const before = provider.revokedUsers.length;
      expect(await drainOwedRevocations(client, provider)).toEqual({ revoked: 0, failed: 0, failures: [] });
      expect(provider.revokedUsers).toHaveLength(before);
      await app.close();
    });

    it("records a revocation as done when the provider says there is no such session", async () => {
      // `ProviderRejected` is the provider saying the thing we wanted is already true. Treating it
      // as owed would mean re-calling forever for a user that does not exist; treating a TIMEOUT the
      // same way would record an event that did not happen. The two are the same `catch` and they
      // must not be the same outcome.
      const app = buildWithDelete();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "gonealready@example.com" } });
      await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "gonealready@example.com", code: "1" } });
      provider.rejectFor.add("11111111-1111-1111-1111-111111111111");

      expect((await app.inject({
        method: "DELETE", url: "/v1/account", headers: { authorization: "Bearer at" },
      })).statusCode).toBe(204);
      expect(await owedRevocationCount(client)).toBe(0);
      await app.close();
    });

    it("revokes an identity that joins the account BETWEEN attribution and the close", async () => {
      // **PR #87 second round, F2 — and this is the test that tells the two orderings apart.**
      //
      // R1's fix moved the `supabase_user_id` read to before `BEGIN`, which was right against 0003
      // (that migration DELETEd the rows at statement end, so reading afterwards read an empty
      // table and revoked nobody). Under 0004 the rows survive the close, and reading first became
      // the wrong half of the trade: an identity that joined the account after the read was never
      // revoked, so a session the user had just added outlived the account they had just deleted.
      //
      // The window is between the handler's own statements and cannot be reached from outside, so
      // it is reached from inside: `withConnection` is wrapped for this one test, and the moment the
      // handler issues its closing `UPDATE … SET deleted_at` the wrapper commits a second identity
      // onto the account from another connection first. That lands exactly in the gap. A handler
      // that read before `BEGIN` revokes one user; a handler that reads after the close revokes two.
      let planted = false;
      const interposing = async <T,>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
        const conn = await pool.connect();
        const real = conn.query.bind(conn);
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        (conn as unknown as { query: (...args: any[]) => any }).query = async (...args: any[]) => {
          const sql = typeof args[0] === "string" ? args[0] : String(args[0]?.text ?? "");
          if (!planted && sql.includes("SET deleted_at")) {
            planted = true;
            await client.query(
              `INSERT INTO sonny.identity (account_id, provider, subject, email_hint,
                 email_verified, email_is_relay, supabase_user_id, link_method)
               SELECT i.account_id,'google','g-late','late@example.com',true,false,$1,'explicit'
                 FROM sonny.identity i WHERE i.subject = 'late@example.com'`,
              ["77777777-7777-7777-7777-777777777777"],
            );
          }
          return real(...(args as Parameters<typeof real>));
        };
        try {
          return await fn(conn as unknown as pg.Client);
        } finally {
          conn.release();
        }
      };

      const app = buildApp({ ...config, allowUnauthenticatedAccountDelete: true },
        { provider, withConnection: interposing });
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "late@example.com" } });
      const accountId = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "late@example.com", code: "1" } })).json().user.id;
      provider.revokedUsers = [];

      const response = await app.inject({
        method: "DELETE", url: "/v1/account", headers: { authorization: "Bearer at" },
      });
      expect(response.statusCode).toBe(204);
      expect(planted).toBe(true);        // the interleaving really happened

      expect(provider.revokedUsers.sort()).toEqual(
        ["11111111-1111-1111-1111-111111111111", "77777777-7777-7777-7777-777777777777"].sort(),
      );
      // and the late arrival is marked closed with the rest, by the same trigger
      const { rows } = await client.query(
        "SELECT account_closed FROM sonny.identity WHERE account_id = $1", [accountId],
      );
      expect(rows).toHaveLength(2);
      expect(rows.every((r: { account_closed: boolean }) => r.account_closed)).toBe(true);
      await app.close();
    });
  });

  describe("POST /v1/auth/refresh and /signout", () => {
    it("returns a ROTATED token pair, and the OLD refresh token then stops working", async () => {
      // PR #87 R12: this AC claimed rotation was asserted and the test asserted the opposite, that
      // the response echoed the token it was given. Rotation means the new one differs.
      //
      // **And the second half of the criterion — "the old one stops working" — was still not
      // asserted after that fix** (PR #87 second round, F7). Half a criterion covered reads exactly
      // like a whole one in a green run.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "rot@example.com" } });
      await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "rot@example.com", code: "1" } });
      provider.session = { ...provider.session, accessToken: "at2", refreshToken: "rt2" };

      const response = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(response.statusCode).toBe(200);
      expect(response.json().refresh_token).toBe("rt2");
      expect(response.json().refresh_token).not.toBe("rt");
      expect(response.json().user.id).toMatch(/^[0-9a-f-]{36}$/);

      // Replaying the token that was just rotated away. §3.3 makes this the theft case past the
      // 10-second overlap; the provider refuses it and the route must answer `auth.token_revoked`,
      // which is what tells the client to clear the Keychain rather than retry.
      const replay = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(replay.statusCode).toBe(401);
      expect(replay.json().error.code).toBe("auth.token_revoked");
      await app.close();
    });

    it("emits refresh_expires_at when the provider reports one, and omits it when it does not", async () => {
      // PR #87 second round, F7. R8 added the field and nothing ever looked at it, so a change that
      // dropped it, mistyped it, or derived it from the wrong instant would have gone through every
      // green run since. §3.2 lists it, and the branch is real: the value is the provider's, so
      // when the provider does not report one the field must be **absent** rather than invented.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "exp2@example.com" } });
      const verified = await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "exp2@example.com", code: "1" } });
      expect(verified.json().refresh_expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
      // Ninety days out from the same instant the access token's own expiry was derived from.
      const access = Date.parse(verified.json().expires_at) - 3600 * 1000;
      expect(Date.parse(verified.json().refresh_expires_at)).toBe(access + 90 * 24 * 3600 * 1000);

      const refreshed = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(refreshed.json().refresh_expires_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

      // A provider that does not report one. `undefined` rather than null, and the key absent.
      provider.session = { ...provider.session, refreshExpiresIn: undefined };
      const silent = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(silent.statusCode).toBe(200);
      expect(Object.keys(silent.json())).not.toContain("refresh_expires_at");
      await app.close();
    });

    it("REFUSES a refresh when the token names two live accounts, rather than picking one", async () => {
      // PR #87 second round, F6. `supabase_user_id` carries no uniqueness constraint, so the lookup
      // ended in `ORDER BY … LIMIT 1` — a tiebreak. A refresh that tiebreaks hands the client a
      // session for whichever account sorted first, and everything downstream (entitlements,
      // metering, the retained content the user is looking at) is then keyed to it.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "two@example.com" } });
      await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "two@example.com", code: "1" } });

      // A second LIVE account naming the same Supabase user. The design allows several identities
      // per Supabase user; it does not allow them to straddle two live accounts.
      const other = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
      await client.query(
        `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
           email_is_relay, supabase_user_id, link_method)
         VALUES ($1,'google','g-two','two@example.com',true,false,$2,'primary')`,
        [other.rows[0]!.id, "11111111-1111-1111-1111-111111111111"],
      );

      const response = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.token_revoked");
      expect(response.json().error.message).toMatch(/single account/);
      await app.close();
    });

    it("REFUSES a refresh whose account has been closed", async () => {
      // PR #87 R5. This answered 200 with `user.id: null` and a working token pair, so an account
      // the user had deleted went on minting sessions with nothing to signal it.
      const app = build();
      await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "closed@example.com" } });
      const id = (await app.inject({ method: "POST", url: "/v1/auth/email/verify", payload: { email: "closed@example.com", code: "1" } })).json().user.id;
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [id]);

      const response = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refresh_token: "rt" } });
      expect(response.statusCode).toBe(401);
      expect(response.json().error.code).toBe("auth.token_revoked");
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
