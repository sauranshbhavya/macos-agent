import pg from "pg";
import { describe, expect } from "vitest";
import { buildApp } from "../src/app.js";
import { ProviderRejected, type AuthProvider, type VerifiedSession } from "../src/auth/provider.js";
import type { Config } from "../src/config.js";
import { STATEMENT_TIMEOUT_MS, pooledConnections } from "../src/db/pool.js";
import { DEADLINE_MS } from "../src/model/limits.js";
import { itUnderHangBackstop } from "./support/backstop.js";
import { testConfig } from "./support/config.js";
import { rebuildSchema } from "./support/schema.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * The pool's `statement_timeout`, against a real Postgres (SONNY-427).
 *
 * Contract §12 gives the routes whose slow work is the database a 10 s upstream and a 15 s total,
 * and until this branch nothing enforced either *inside* a query: a statement that stalled — or one
 * queued behind somebody else's lock — held the request for as long as it liked, and no deadline
 * written in JavaScript could reach in and end it. `db/pool.ts` now hands every connection §12's
 * number and Postgres cancels the statement itself.
 *
 * **Three properties, and the middle one is the one a reader is most likely to think is decoration.**
 * The bound is the contract's number; a route's own `RESET` returns to it rather than to no bound;
 * and a route blocked on a lock answers instead of waiting. The second exists because
 * `model/routing.ts`'s `withDatabaseDeadline` sets and resets this same session setting per
 * statement for the content-deletion routes, and the two shapes of applying a pool-wide bound —
 * a startup parameter, and a `SET` issued after connecting — are identical to read and differ only
 * after that `RESET` runs.
 *
 * Skips without `DATABASE_URL`, like every other `*.db.test.ts`; the run announces that once,
 * loudly, from `global-setup.ts`.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const SESSION_USER = "11111111-1111-1111-1111-111111111111";

/**
 * How long the blocked-route test waits for an answer before calling the route hung.
 *
 * **Reached only on failure, and it fails as an ordinary assertion in wording of its own** —
 * which is the whole reason it is not `itUnderHangBackstop`'s sixty seconds doing this job.
 * That deadline's wording is declared in `scripts/mutate-untrusted-failures`, correctly, so a
 * mutant whose only effect is to make this test hang would come back UNATTRIBUTED on a run where
 * the test failed for exactly the right reason — `CLAUDE.md`'s SONNY-259 case, a manufactured
 * NON-kill. The remedy that file names is the caller's: fail in wording no declaration matches.
 *
 * Thirty seconds sits **inside** the sixty, so this fires first and the backstop never sees it,
 * and it is far outside anything this can cost: the work after the cancellation is all in-process
 * — Postgres raises, `pg` rejects, the error handler answers — on top of a bound the test sets to
 * a fraction of a second. The worst a database test in this suite has been measured at under
 * deliberate load is 2527 ms (`support/backstop.ts` carries that measurement and its conditions).
 *
 * **The precondition wait below has a budget of its own rather than sharing this one** (PR #223's
 * O3). Both waits are sequential, so one number used twice makes the worst case 30 000 + 30 000 —
 * exactly `HANG_BACKSTOP_MS`, which is the one arrangement under which the sentence above stops
 * being true. Ten plus thirty leaves twenty seconds of margin, and the precondition is the wait that
 * can afford the smaller number: it is satisfied in milliseconds on any tree where the request
 * reaches Postgres at all.
 */
const ANSWER_OR_ADMIT_HUNG_MS = 30_000;

/** The precondition's own budget; see the note above on why it is not the same number. */
const BLOCK_OBSERVED_MS = 10_000;

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

const config: Config = testConfig({ databaseUrl: url });

/** `setting`, `reset_val` and `source` for `statement_timeout`, read on whatever connection. */
async function boundOn(client: pg.Client): Promise<{ setting: string; reset_val: string; source: string }> {
  const { rows } = await client.query<{ setting: string; reset_val: string; source: string }>(
    "SELECT setting, reset_val, source FROM pg_settings WHERE name = 'statement_timeout'",
  );
  return rows[0]!;
}

describeDb("the pool's statement timeout", () => {
  itUnderHangBackstop("theBoundOnALeasedConnectionIsSection12sOwnNumber", async () => {
    // **No `statementTimeoutMillis`**, so what is measured is the production default rather than
    // anything this test supplied — the sample has to traverse the mechanism to say anything about
    // it (`CLAUDE.md`, SONNY-388).
    const wiring = pooledConnections(url!, { max: 1 });
    try {
      const bound = await wiring.withConnection(boundOn);

      // The value, and that it is §12's rather than a literal that matches it. The two assertions
      // are not the same one twice: the first would still pass if `pool.ts` spelled `10_000`, and
      // the second is what says the pool reads the contract's field.
      expect(bound.setting).toBe("10000");
      expect(STATEMENT_TIMEOUT_MS).toBe(DEADLINE_MS.auth.upstream);

      // **`source: client` is the mechanism, not a curiosity.** It says the value arrived in the
      // startup packet, which is what makes `reset_val` equal to it — and `reset_val` is what
      // `RESET statement_timeout` returns to. A `SET` issued after connecting reads
      // `source: session` with `reset_val: 0`, and the test below is where that difference bites.
      expect(bound.source).toBe("client");
      expect(bound.reset_val).toBe("10000");
    } finally {
      await wiring.close();
    }
  });

  itUnderHangBackstop("aRoutesOwnResetReturnsToThisBoundRatherThanToNoBound", async () => {
    // `model/routing.ts`'s `withDatabaseDeadline` does exactly this to a connection it has leased:
    // `SET statement_timeout TO <remaining>` before each statement, `RESET statement_timeout` in a
    // `finally`. This is that sequence, and what it pins is where the connection lands afterwards —
    // because it goes straight back to the pool for the next request.
    const wiring = pooledConnections(url!, { max: 1 });
    try {
      const readings = await wiring.withConnection(async (client) => {
        const onLease = await boundOn(client);
        await client.query("SET statement_timeout TO 15000");
        const underRoute = await boundOn(client);
        await client.query("RESET statement_timeout");
        return { onLease, underRoute, afterReset: await boundOn(client) };
      });

      expect(readings.onLease.setting).toBe("10000");
      // While it is in force the route's own budget governs, wider or narrower — these are two
      // spellings of one session setting and the last one written wins.
      expect(readings.underRoute.setting).toBe("15000");
      // **The property.** Had the pool applied its bound with a `SET` after connecting, this would
      // read "0" — no bound at all — and every later request leasing this connection would run
      // unbounded, with nothing anywhere saying so.
      expect(readings.afterReset.setting).toBe("10000");
      expect(readings.afterReset.source).toBe("client");
    } finally {
      await wiring.close();
    }
  });

  itUnderHangBackstop("aRouteBlockedOnAnotherConnectionsLockAnswersInsteadOfWaitingForIt", async () => {
    // The scenario `server/README.md` already names as this gateway's real one: a migration takes
    // `ACCESS EXCLUSIVE` on `sonny.identity`, which `accountForSupabaseUser` reads on **every
    // authenticated request**, and every reader queues behind it. Nothing about it is specific to
    // migrations — a long transaction from any source does the same.
    //
    // The bound is shortened to 400 ms so the test costs a fraction of a second rather than ten
    // seconds. What that trades away is nothing this test is about: the production number is
    // asserted above, on a connection this one does not configure.
    const setup = new pg.Client({ connectionString: url });
    await setup.connect();
    await rebuildSchema(setup);

    const wiring = pooledConnections(url!, { statementTimeoutMillis: 400 });
    const app = buildApp(config, { provider: new SigningInProvider(), withConnection: wiring.withConnection });

    // Signed in first, and deliberately before the lock: signing in writes to `sonny.identity`, so
    // it would block on the lock too and the test would be measuring the wrong statement.
    await app.inject({ method: "POST", url: "/v1/auth/email/start", payload: { email: "u@example.com" } });
    await app.inject({
      method: "POST", url: "/v1/auth/email/verify", payload: { email: "u@example.com", code: "1" },
    });

    const holder = new pg.Client({ connectionString: url });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("LOCK TABLE sonny.identity IN ACCESS EXCLUSIVE MODE");

      const request = app.inject({
        method: "GET",
        url: "/v1/account/entitlements",
        headers: { authorization: `Bearer ${accessTokenFor(SESSION_USER)}` },
      });

      // **The precondition is observed rather than assumed** — that the request really did reach
      // Postgres and really is queued behind the lock. Without this the test could pass on a
      // request that failed before it ever issued a statement, which is a different bug wearing
      // this test's green.
      const blocked = await waitForABackendBlockedOnALock(setup);
      expect(blocked).toBe(true);

      // **Two branches, and which one wins is the assertion.** Under the bound the answer arrives
      // because Postgres cancelled the statement — the lock is still held, and nothing else could
      // have ended the wait. With no bound the answer cannot arrive at all while this transaction
      // is open, so the timer is the only reachable branch and it fails in its own wording.
      const outcome = await Promise.race([
        request.then((response) => ({ kind: "answered" as const, response })),
        new Promise<{ kind: "hung" }>((resolve) =>
          setTimeout(() => resolve({ kind: "hung" }), ANSWER_OR_ADMIT_HUNG_MS).unref(),
        ),
      ]);

      expect(
        outcome.kind,
        "the route was still waiting on the lock when this test gave up: no statement bound is in force on the pool",
      ).toBe("answered");

      // Still held. The wait ended because the statement was cancelled, not because the lock lifted.
      const { rows } = await setup.query<{ n: string }>(
        "SELECT count(*)::text AS n FROM pg_locks WHERE relation = 'sonny.identity'::regclass AND mode = 'AccessExclusiveLock' AND granted",
      );
      expect(rows[0]!.n).toBe("1");

      // §7.1's envelope, at §7.2's case 6: a statement timeout is a backend failure, not a provider
      // one. Nothing maps `57014`, so this is the root handler answering — the point of the bound is
      // that the route answers at all, not that it answers something new.
      const answered = outcome.kind === "answered" ? outcome.response : undefined;
      expect(answered?.statusCode).toBe(500);
      const body = answered?.json() as { error: { code: string; retryable: boolean; request_id: string } };
      expect(body.error.code).toBe("server.error");
      expect(body.error.retryable).toBe(true);
      expect(body.error.request_id).not.toBe("");
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
      await holder.end();
      await app.close();
      await wiring.close();
      await setup.end();
    }
  });
});

/**
 * Poll until some backend is waiting on a lock, reading Postgres's own view of it.
 *
 * A progress signal rather than a clock: the caller's request has to have *reached* the database
 * before anything this test asserts means anything. Bounded so a precondition that never arrives
 * fails the assertion above it rather than hanging here — `CLAUDE.md`'s rule that a wait whose own
 * precondition never arrived must bail before asserting.
 */
async function waitForABackendBlockedOnALock(client: pg.Client): Promise<boolean> {
  const giveUpAt = Date.now() + BLOCK_OBSERVED_MS;
  for (;;) {
    const { rows } = await client.query<{ n: string }>(
      "SELECT count(*)::text AS n FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND state = 'active'",
    );
    if (rows[0]!.n !== "0") return true;
    if (Date.now() >= giveUpAt) return false;
    await new Promise((resolve) => setTimeout(resolve, 10).unref());
  }
}
