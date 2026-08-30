import pg from "pg";
import { describe, expect } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { ProviderRejected, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor } from "./support/tokens.js";
import { testConfig } from "./support/config.js";
import { afterAllUnderHangBackstop, beforeAllUnderHangBackstop, beforeEachUnderHangBackstop, itUnderHangBackstop } from "./support/backstop.js";

/**
 * The second half of the gate: attribution (SONNY-203).
 *
 * `token.test.ts` proves a token is what it claims to be. Nothing there touches a database, and a
 * perfectly valid token is still not a caller — it names a Supabase user, and this gateway's
 * question is which *Sonny account* that is. These are the cases where the two answers differ, and
 * every one of them is a token this gateway itself would sign.
 *
 * **The one to read first is "a token that outlived its account".** Access tokens are self-contained
 * and this gateway verifies them locally, so it cannot un-issue one; what it can do — and does, on
 * every request — is refuse a caller whose account is closed. That is the answer to "a valid token
 * replayed after revocation" for the case this system controls.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const SESSION_USER = "11111111-1111-1111-1111-111111111111";
const STRANGER = "cccccccc-cccc-cccc-cccc-cccccccccccc";

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

/** Enough provider to sign someone in. Everything this file asserts happens after that. */
class SigningInProvider implements AuthProvider {
  session: VerifiedSession = {
    supabaseUserId: SESSION_USER,
    email: "u@example.com", emailVerified: true,
    accessToken: "provider-issued", refreshToken: "rt", expiresIn: 3600,
  };
  async sendEmailCode(_email: string) { return { providerRequestId: "p1" }; }
  async verifyEmailCode(_email: string, _code: string): Promise<VerifiedSession> { return this.session; }
  async refresh(_token: string): Promise<VerifiedSession> { return this.session; }
  async signOut(_accessToken: string) {}
  async userFromAccessToken(_accessToken: string): Promise<string> {
    throw new ProviderRejected("the gate verifies locally; this seam is not on the request path");
  }
  revokedUsers: string[] = [];
  async signOutAllForUser(id: string) { this.revokedUsers.push(id); }
  async deleteUser() {}
}

describeDb("the gate, attributing a verified token to an account", () => {
  let client: pg.Client;
  let provider: SigningInProvider;

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
    provider = new SigningInProvider();
  });

  const build = () => buildApp(config, { provider, withConnection });
  const signIn = async (app: ReturnType<typeof build>, email: string): Promise<string> => {
    await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email } });
    const verified = await app.inject({
      method: "POST", url: "/v1/auth/email/verify", payload: { email, code: "1" },
    });
    return verified.json().user.id as string;
  };
  const bearer = (user: string) => ({ authorization: `Bearer ${accessTokenFor(user)}` });

  itUnderHangBackstop("acts for the account the sub resolves to, and for no other", async () => {
    const app = build();
    const mine = await signIn(app, "mine@example.com");

    // A second, entirely separate account and Supabase user.
    const other = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
    await client.query(
      `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
         email_is_relay, supabase_user_id, link_method)
       VALUES ($1,'google','g-other','other@example.com',true,false,$2,'primary')`,
      [other.rows[0]!.id, STRANGER],
    );

    expect((await app.inject({ method: "DELETE", url: "/v1/account", headers: bearer(SESSION_USER) }))
      .statusCode).toBe(204);

    // Mine closed, theirs untouched — the account acted on came from the token, and the request
    // carried no account id anywhere.
    const { rows } = await client.query(
      "SELECT id, deleted_at FROM sonny.account WHERE id = ANY($1::uuid[])",
      [[mine, other.rows[0]!.id]],
    );
    const byId = new Map(rows.map((r: { id: string; deleted_at: Date | null }) => [r.id, r.deleted_at]));
    expect(byId.get(mine)).not.toBeNull();
    expect(byId.get(other.rows[0]!.id)).toBeNull();
    await app.close();
  });

  itUnderHangBackstop("IGNORES Sonny-Account-Id on a valid token — the victim survives, the caller's own account closes", async () => {
    // **F1 of PR #104's adversarial review: the branch's headline property had no test that could
    // fail.** Two tests sent `sonny-account-id`, and both sent a token that fails verification
    // (`Bearer anything`, `Bearer made-up-token`), so the gate refused before the line that picks
    // the account was ever reached. Replacing `accountId: owner.accountId` in `gate.ts` with
    // `request.headers["sonny-account-id"] ?? owner.accountId` — PR #87's F1 defect, reintroduced in
    // one line — left the suite at 244 passed (244) while destroying the wrong account.
    //
    // So this is the case that was missing: a **valid** token, a **real** second account, and the
    // header naming it. It was written before the fix it guards existed anywhere else, run against
    // that exact mutant, and watched go red — a test nobody has seen fail is a test nobody knows
    // the failure mode of.
    const app = build();
    const attacker = await signIn(app, "attacker@example.com");

    const victimAccount = await client.query<{ id: string }>(
      "INSERT INTO sonny.account DEFAULT VALUES RETURNING id",
    );
    const victim = victimAccount.rows[0]!.id;
    await client.query(
      `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
         email_is_relay, supabase_user_id, link_method)
       VALUES ($1,'email','victim@example.com','victim@example.com',true,false,$2,'primary')`,
      [victim, STRANGER],
    );

    const response = await app.inject({
      method: "DELETE",
      url: "/v1/account",
      headers: { ...bearer(SESSION_USER), "sonny-account-id": victim },
    });
    expect(response.statusCode).toBe(204);

    const state = async (id: string) =>
      (await client.query<{ deleted_at: Date | null }>(
        "SELECT deleted_at FROM sonny.account WHERE id = $1", [id],
      )).rows[0]!.deleted_at;
    // The victim is the whole assertion: named in the request, untouched by it.
    expect(await state(victim)).toBeNull();
    // And the caller's own account is the one that closed, so this is not merely "nothing happened".
    expect(await state(attacker)).not.toBeNull();
    await app.close();
  });

  itUnderHangBackstop("IGNORES a Sonny-Account-Id naming nothing at all, rather than failing or acting on it", async () => {
    // The other half of the same mutant. A header-reading gate that fell back to the token only
    // when the header was absent would still pass the test above if it refused an unknown id — this
    // one requires the header to be ignored outright, whatever it names. An account id that names
    // no row would also be a Postgres `22P02` if it were ever bound as a uuid.
    const app = build();
    const mine = await signIn(app, "ignored@example.com");
    const response = await app.inject({
      method: "DELETE",
      url: "/v1/account",
      headers: { ...bearer(SESSION_USER), "sonny-account-id": "not-even-a-uuid" },
    });
    expect(response.statusCode).toBe(204);
    expect((await client.query("SELECT deleted_at FROM sonny.account WHERE id = $1", [mine]))
      .rows[0].deleted_at).not.toBeNull();
    await app.close();
  });

  itUnderHangBackstop("refuses a perfectly valid token whose sub names no identity here", async () => {
    // Signed by this gateway's own secret, correct issuer, correct audience, unexpired — and it
    // still attributes nobody. A token is not a caller until the database says whose it is.
    const app = build();
    await signIn(app, "known@example.com");
    const response = await app.inject({
      method: "DELETE", url: "/v1/account", headers: bearer(STRANGER),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.token_revoked");
    expect(response.json().error.retryable).toBe(false);
    await app.close();
  });

  itUnderHangBackstop("refuses a token that OUTLIVED its account — the revoked-and-replayed case", async () => {
    // The property that matters most here, and the one the local-verification decision makes
    // load-bearing. The token below is minted before the deletion and is still inside its hour, so
    // it verifies perfectly afterwards; every protected route refuses it anyway, because the
    // account it names is closed. That is checked on each request rather than remembered.
    const app = build();
    await signIn(app, "closing@example.com");
    const token = accessTokenFor(SESSION_USER);

    expect((await app.inject({
      method: "DELETE", url: "/v1/account", headers: { authorization: `Bearer ${token}` },
    })).statusCode).toBe(204);

    for (const route of [
      { method: "DELETE" as const, url: "/v1/account" },
      { method: "POST" as const, url: "/v1/auth/signout" },
    ]) {
      const replay = await app.inject({ ...route, headers: { authorization: `Bearer ${token}` } });
      expect(`${route.method} ${route.url} -> ${replay.statusCode}`)
        .toBe(`${route.method} ${route.url} -> 401`);
      expect(replay.json().error.code).toBe("auth.token_revoked");
    }
    await app.close();
  });

  itUnderHangBackstop("refuses a token that names TWO live accounts rather than picking one", async () => {
    // `supabase_user_id` carries no uniqueness constraint and never can. Two live accounts naming
    // one Supabase user is the identity rule having failed upstream, and a gate that tiebreaks
    // there acts for an account the caller may not be looking at.
    const app = build();
    await signIn(app, "amb@example.com");
    const second = await client.query<{ id: string }>("INSERT INTO sonny.account DEFAULT VALUES RETURNING id");
    await client.query(
      `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
         email_is_relay, supabase_user_id, link_method)
       VALUES ($1,'google','g-amb','amb@example.com',true,false,$2,'primary')`,
      [second.rows[0]!.id, SESSION_USER],
    );

    const response = await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(SESSION_USER),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.token_revoked");
    expect(response.json().error.message).toMatch(/single account/);
    await app.close();
  });

  itUnderHangBackstop("refuses a token whose identity was released by a closed account", async () => {
    // `account_closed` on the identity is the other half of the same exclusion: an identity a closed
    // account left behind attributes nobody, exactly as it signs nobody in. Set here directly so the
    // gate's own predicate is what is being tested rather than the deletion route's sequencing.
    const app = build();
    await signIn(app, "released@example.com");
    await client.query("UPDATE sonny.identity SET account_closed = true WHERE supabase_user_id = $1",
      [SESSION_USER]);
    const response = await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(SESSION_USER),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.token_revoked");
    await app.close();
  });

  itUnderHangBackstop("refuses on the ACCOUNT's deleted_at even when the identity's flag says otherwise", async () => {
    // **Half the attribution predicate was untested** (PR #104's adversarial review, F7). Dropping
    // `AND a.deleted_at IS NULL` while keeping `NOT i.account_closed` left the suite at 244 passed,
    // because the `account_close_marks_identities` trigger keeps the two in step along the one path
    // every other test walks. They are not the same check: `i.account_closed` is a denormalised copy
    // and `a.deleted_at` is the fact.
    //
    // The state below is produced by correcting the copy back by hand — which is exactly the case
    // the second predicate exists for, alongside an identity inserted for an already-closed account
    // and any future migration that touches the flag. A plain `UPDATE ... SET account_closed` does
    // not re-fire the trigger, which is declared `BEFORE INSERT OR UPDATE OF account_id` (0005).
    const app = build();
    const accountId = await signIn(app, "stale-flag@example.com");
    await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [accountId]);
    const corrected = await client.query(
      "UPDATE sonny.identity SET account_closed = false WHERE supabase_user_id = $1", [SESSION_USER]);
    expect(corrected.rowCount).toBe(1);
    // The state really is the one being tested: account gone, flag saying live.
    const { rows } = await client.query(
      `SELECT a.deleted_at, i.account_closed FROM sonny.identity i
         JOIN sonny.account a ON a.id = i.account_id WHERE i.supabase_user_id = $1`, [SESSION_USER]);
    expect(rows[0].deleted_at).not.toBeNull();
    expect(rows[0].account_closed).toBe(false);

    const response = await app.inject({
      method: "POST", url: "/v1/auth/signout", headers: bearer(SESSION_USER),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.token_revoked");
    await app.close();
  });

  itUnderHangBackstop("does not consult the provider to verify — the seam stays off the request path", async () => {
    // The founder decision is symmetric verification with the project's secret, which is a local
    // operation. `userFromAccessToken` throws in this fake precisely so that a middleware that
    // reached for it would fail loudly rather than quietly adding a network round trip, and its
    // availability, to every authenticated request.
    const app = build();
    await signIn(app, "local@example.com");
    expect((await app.inject({ method: "POST", url: "/v1/auth/signout", headers: bearer(SESSION_USER) }))
      .statusCode).toBe(204);
    await app.close();
  });

  itUnderHangBackstop("refuses an expired token before it ever reaches the database", async () => {
    // Ordering, and it is a denial-of-service property as much as a correctness one: an
    // unauthenticated flood must cost an HMAC rather than a connection from the pool.
    const app = build();
    await signIn(app, "stale@example.com");
    const expired = accessTokenFor(SESSION_USER, { now: new Date(Date.now() - 7200 * 1000) });
    const response = await app.inject({
      method: "DELETE", url: "/v1/account", headers: { authorization: `Bearer ${expired}` },
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("auth.token_expired");
    // The account is untouched, which is what "before the database" means from outside.
    const { rows } = await client.query("SELECT deleted_at FROM sonny.account WHERE deleted_at IS NULL");
    expect(rows).toHaveLength(1);
    await app.close();
  });
});
