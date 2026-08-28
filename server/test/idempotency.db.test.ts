import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { WithConnection } from "../src/db/connection.js";
import { up } from "../src/db/migrate.js";
import {
  CLAIM_LEASE_SECONDS,
  type ClaimOutcome,
  RESPONSE_TTL_SECONDS,
  UNAUTHENTICATED_SCOPE,
  claimKey,
  claimMeteringEvent,
  completeClaim,
  deleteStoredResponsesForAccount,
  meteringEventClaimed,
  pruneExpiredResponses,
  releaseClaim,
  postgresKeyStore,
} from "../src/idempotency/store.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * The SQL under contract §9.2, against a real Postgres (SONNY-300).
 *
 * `idempotency.test.ts` proves the *decisions* — which answer each outcome produces — against a
 * store the test controls. This file proves the store: the state machine, the two clocks, the
 * scoping, and the one guarantee that is only true if a `UPDATE … WHERE … IS NULL` is atomic. None
 * of that is TypeScript behaviour, and a fake would prove nothing about it.
 *
 * **Every expiry here is produced by back-dating a row, never by waiting.** A test that slept past a
 * lease would be betting on a wall clock it shares with the rest of the suite, which is the shape
 * `CLAUDE.md` records as manufacturing false results; and one that compared two timestamps written
 * in the same instant could not fail at all. Back-dating makes both deterministic.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const SUPABASE_USER = "0f6c2c4e-8f2a-4a0f-9a11-2b6f5f2a77aa";
const ACCOUNT = "8a1d0c8e-1c5a-4a9f-9f6b-2b6f5f2a77ab";
const OTHER_ACCOUNT = "9b9b9b9b-4c4c-4d4d-8e8e-5f5f5f5f5f5f";
const KEY = "6f1b8a2c-0000-4000-8000-abcdefabcdef";

const claim = (fingerprint = "POST /v1/plan\nsha256:aaa", accountScope = ACCOUNT) => ({
  accountScope,
  key: KEY,
  route: "POST /v1/plan",
  fingerprint,
});
const at = (accountScope = ACCOUNT) => ({ accountScope, key: KEY });
/**
 * Assert a claim was granted and hand back its fencing token.
 *
 * Every writer now needs the token, so this replaces the bare `toEqual({ kind: "claimed" })` the
 * suite used before fencing — and asserts the token is a real one rather than an empty string, which
 * a mutant that dropped `gen_random_uuid()` would otherwise slip past.
 */
const grantedTo = (outcome: ClaimOutcome): string => {
  expect(outcome.kind).toBe("claimed");
  if (outcome.kind !== "claimed") throw new Error("unreachable");
  expect(outcome.token).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  return outcome.token;
};

/** Scope, key and a claim's fencing token — what `completeClaim` and `releaseClaim` now take. */
const heldBy = (token: string, accountScope = ACCOUNT) => ({ accountScope, key: KEY, token });
const response = (body: string, status = 200) => ({
  status,
  body: Buffer.from(body, "utf8"),
  contentType: "application/json; charset=utf-8",
  requestId: "original-request-id",
});

describeDb("the idempotency key store", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await up(client);
  });
  afterAll(async () => {
    await client.end();
  });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.idempotency_key");
  });

  /** Move a row's clocks into the past, which is how every expiry in this file is produced. */
  const backDate = async (column: string, seconds: number) => {
    await client.query(
      `UPDATE sonny.idempotency_key
          SET ${column} = now() - make_interval(secs => $1)
        WHERE account_scope = $2 AND idempotency_key = $3`,
      [seconds, ACCOUNT, KEY],
    );
  };

  it("gives the key to the first request that asks", async () => {
    grantedTo(await claimKey(client, claim()));

    const { rows } = await client.query(
      `SELECT state, route, request_fingerprint, metering_claimed_at,
              (lease_expires_at > now()) AS lease_live
         FROM sonny.idempotency_key WHERE account_scope = $1 AND idempotency_key = $2`,
      [ACCOUNT, KEY],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      state: "in_flight",
      route: "POST /v1/plan",
      request_fingerprint: "POST /v1/plan\nsha256:aaa",
      metering_claimed_at: null,
      lease_live: true,
    });
  });

  it("refuses a second request while the first is still in flight, naming what remains of the lease", async () => {
    await claimKey(client, claim());
    const second = await claimKey(client, claim());

    expect(second.kind).toBe("in_flight");
    // Bounded on both sides: a fresh claim's lease is the full window, and it is never reported as 0
    // — a client reading 0 would spend its one retry on a request that is certainly still running.
    if (second.kind !== "in_flight") throw new Error("unreachable");
    expect(second.retryAfterSeconds).toBeGreaterThan(0);
    expect(second.retryAfterSeconds).toBeLessThanOrEqual(CLAIM_LEASE_SECONDS);
  });

  it("returns the stored response, byte for byte, to a repeat inside the window", async () => {
    const token = grantedTo(await claimKey(client, claim()));
    await completeClaim(client, heldBy(token), response('{"output_text":"the answer"}'));

    const repeat = await claimKey(client, claim());

    expect(repeat.kind).toBe("replay");
    if (repeat.kind !== "replay") throw new Error("unreachable");
    expect(repeat.response.body.toString("utf8")).toBe('{"output_text":"the answer"}');
    expect(repeat.response.status).toBe(200);
    expect(repeat.response.contentType).toBe("application/json; charset=utf-8");
    expect(repeat.response.requestId).toBe("original-request-id");
  });

  it("starts the twenty-four hours at completion, not at the claim", async () => {
    const token = grantedTo(await claimKey(client, claim()));
    await completeClaim(client, heldBy(token), response("{}"));

    const { rows } = await client.query(
      `SELECT ROUND(EXTRACT(EPOCH FROM (response_expires_at - now()))) AS remaining
         FROM sonny.idempotency_key WHERE account_scope = $1 AND idempotency_key = $2`,
      [ACCOUNT, KEY],
    );
    // §9.2's number, read off the row rather than off the constant that wrote it.
    expect(Number(rows[0].remaining)).toBeGreaterThan(RESPONSE_TTL_SECONDS - 10);
    expect(Number(rows[0].remaining)).toBeLessThanOrEqual(RESPONSE_TTL_SECONDS);
    expect(RESPONSE_TTL_SECONDS).toBe(86_400);
  });

  it("stops replaying once the twenty-four hours have passed, and lets the key run again", async () => {
    const token = grantedTo(await claimKey(client, claim()));
    await completeClaim(client, heldBy(token), response("{}"));
    await backDate("response_expires_at", 1);

    grantedTo(await claimKey(client, claim()));
  });

  it("takes the key back from a holder that outlived its lease", async () => {
    // A process killed mid-request would otherwise hold its key against every retry forever. Its row
    // is indistinguishable from a live one from any other process's side, so the lease is what
    // decides.
    await claimKey(client, claim());
    await backDate("lease_expires_at", 1);

    grantedTo(await claimKey(client, claim()));
  });

  describe("a different body under the same key", () => {
    // §9.2's third guarantee does not depend on what state the row is in, so each state is asked.
    it("conflicts while the first request is in flight", async () => {
      await claimKey(client, claim());
      expect(await claimKey(client, claim("POST /v1/plan\nsha256:bbb"))).toEqual({ kind: "conflict" });
    });

    it("conflicts against a stored response", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await completeClaim(client, heldBy(token), response("{}"));
      expect(await claimKey(client, claim("POST /v1/plan\nsha256:bbb"))).toEqual({ kind: "conflict" });
    });

    it("conflicts against a released key, which is otherwise free", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await releaseClaim(client, heldBy(token));
      // Free to the same body...
      expect(await claimKey(client, claim("POST /v1/plan\nsha256:bbb"))).toEqual({ kind: "conflict" });
    });

    it("conflicts even after the response window has passed", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await completeClaim(client, heldBy(token), response("{}"));
      await backDate("response_expires_at", 1);
      expect(await claimKey(client, claim("POST /v1/plan\nsha256:bbb"))).toEqual({ kind: "conflict" });
    });
  });

  it("gives a released key straight back to the same body", async () => {
    const token = grantedTo(await claimKey(client, claim()));
    await releaseClaim(client, heldBy(token));

    grantedTo(await claimKey(client, claim()));
  });

  it("keeps one account's key entirely separate from another's", async () => {
    const mineToken = grantedTo(await claimKey(client, claim("POST /v1/plan\nsha256:aaa", ACCOUNT)));
    await completeClaim(client, heldBy(mineToken, ACCOUNT), response('{"mine":true}'));

    // The same key under a different scope is a *fresh claim*, never the first account's response —
    // which is the property that stops a stored answer crossing between callers.
    const theirToken = grantedTo(
      await claimKey(client, claim("POST /v1/plan\nsha256:aaa", OTHER_ACCOUNT)),
    );
    await completeClaim(client, heldBy(theirToken, OTHER_ACCOUNT), response('{"theirs":true}'));

    // And each replays its own.
    const mine = await claimKey(client, claim("POST /v1/plan\nsha256:aaa", ACCOUNT));
    const theirs = await claimKey(client, claim("POST /v1/plan\nsha256:aaa", OTHER_ACCOUNT));
    if (mine.kind !== "replay" || theirs.kind !== "replay") throw new Error("expected two replays");
    expect(mine.response.body.toString("utf8")).toBe('{"mine":true}');
    expect(theirs.response.body.toString("utf8")).toBe('{"theirs":true}');
  });

  it("conflicts within a scope without conflicting across one", async () => {
    await claimKey(client, claim("POST /v1/plan\nsha256:aaa", ACCOUNT));
    // A different body under the same key and the same account: the conflict §9.2 asks for.
    expect(await claimKey(client, claim("POST /v1/plan\nsha256:zzz", ACCOUNT))).toEqual({
      kind: "conflict",
    });
    // The same different body under another account is simply that account's first request.
    grantedTo(await claimKey(client, claim("POST /v1/plan\nsha256:zzz", OTHER_ACCOUNT)));
  });

  it("holds an unauthenticated key in a scope no account can reach", async () => {
    await claimKey(client, claim("POST /v1/auth/email/start\nsha256:aaa", UNAUTHENTICATED_SCOPE));
    grantedTo(await claimKey(client, claim("POST /v1/auth/email/start\nsha256:aaa", ACCOUNT)));
  });

  /**
   * A holder whose lease expired, finishing after its successor took the key.
   *
   * **Both orderings are here, and only one of them was before** (PR #142's review, F1). The suite
   * covered the ghost finishing after the successor had already *completed*, which `state =
   * 'in_flight'` alone is enough to refuse. The ordering that actually misbehaved is the successor
   * still being **in flight** — then the state guard matches the successor's row, and the ghost's
   * write lands on a claim that is not its own. `claim_token` is what tells the two apart, and each
   * of the three tests below fails without it.
   */
  describe("a superseded holder finishing late", () => {
    /** Claim, let the lease lapse, let a successor take it. Returns both claims' tokens. */
    const ghostAndSuccessor = async () => {
      const ghost = grantedTo(await claimKey(client, claim()));
      await backDate("lease_expires_at", 1);
      const successor = grantedTo(await claimKey(client, claim()));
      expect(successor).not.toBe(ghost);
      return { ghost, successor };
    };

    it("cannot complete over a successor that has already completed", async () => {
      const { ghost, successor } = await ghostAndSuccessor();
      await completeClaim(client, heldBy(successor), response('{"from":"the successor"}'));

      await completeClaim(client, heldBy(ghost), response('{"from":"the ghost"}'));

      const repeat = await claimKey(client, claim());
      if (repeat.kind !== "replay") throw new Error("expected a replay");
      expect(repeat.response.body.toString("utf8")).toBe('{"from":"the successor"}');
    });

    it("cannot complete over a successor that is still in flight, discarding its real answer", async () => {
      // Direction B of the measured failure. Without the token the ghost's body is stored and
      // replayed for twenty-four hours, and the successor's own completion then matches nothing
      // because the row is no longer `in_flight` — its real answer is dropped silently.
      const { ghost, successor } = await ghostAndSuccessor();

      await completeClaim(client, heldBy(ghost), response('{"from":"the ghost"}'));

      // The row is untouched: still the successor's claim, still in flight.
      const { rows } = await client.query(
        `SELECT state, response_body, claim_token FROM sonny.idempotency_key
          WHERE account_scope = $1 AND idempotency_key = $2`,
        [ACCOUNT, KEY],
      );
      expect(rows[0].state).toBe("in_flight");
      expect(rows[0].response_body).toBeNull();
      expect(rows[0].claim_token).toBe(successor);

      // And the successor's own answer still lands.
      await completeClaim(client, heldBy(successor), response('{"from":"the successor"}'));
      const repeat = await claimKey(client, claim());
      if (repeat.kind !== "replay") throw new Error("expected a replay");
      expect(repeat.response.body.toString("utf8")).toBe('{"from":"the successor"}');
    });

    it("cannot release a successor that is still in flight, freeing the key under it", async () => {
      // Direction A, and the one that defeats §9.2 bullet 4: without the token the ghost's release
      // frees the successor's claim, and a third request claims and calls the provider while the
      // successor is still running.
      const { ghost, successor } = await ghostAndSuccessor();

      await releaseClaim(client, heldBy(ghost));

      const third = await claimKey(client, claim());
      expect(third.kind).toBe("in_flight");
      const { rows } = await client.query(
        `SELECT state, claim_token FROM sonny.idempotency_key
          WHERE account_scope = $1 AND idempotency_key = $2`,
        [ACCOUNT, KEY],
      );
      expect(rows[0].state).toBe("in_flight");
      expect(rows[0].claim_token).toBe(successor);
    });
  });

  describe("the metering claim — §9.2's second guarantee, which is the one that costs money", () => {
    it("is given to exactly one caller, ever", async () => {
      await claimKey(client, claim());

      expect(await claimMeteringEvent(client, at())).toBe(true);
      expect(await claimMeteringEvent(client, at())).toBe(false);
      expect(await claimMeteringEvent(client, at())).toBe(false);
    });

    it("survives the release a retryable failure performs, so the re-attempt cannot bill again", async () => {
      // **This is the whole reason `releaseClaim` does not clear `metering_claimed_at`.** The
      // founder decision of 2026-08-28 lets a retryable failure re-run; what keeps that from being a
      // double charge is that the second attempt finds the claim already taken.
      const token = grantedTo(await claimKey(client, claim()));
      expect(await claimMeteringEvent(client, at())).toBe(true);

      await releaseClaim(client, heldBy(token));
      grantedTo(await claimKey(client, claim()));

      expect(await claimMeteringEvent(client, at())).toBe(false);
    });

    it("survives the response expiring, so a key reused after a day still cannot bill twice", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await claimMeteringEvent(client, at());
      await completeClaim(client, heldBy(token), response("{}"));
      await backDate("response_expires_at", 1);

      grantedTo(await claimKey(client, claim()));
      expect(await claimMeteringEvent(client, at())).toBe(false);
    });

    it("survives a lease being taken from a dead holder", async () => {
      await claimKey(client, claim());
      await claimMeteringEvent(client, at());
      await backDate("lease_expires_at", 1);

      grantedTo(await claimKey(client, claim()));
      expect(await claimMeteringEvent(client, at())).toBe(false);
    });

    it("survives pruning, which clears payloads and never rows", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await claimMeteringEvent(client, at());
      await completeClaim(client, heldBy(token), response("{}"));
      await backDate("response_expires_at", 1);

      expect(await pruneExpiredResponses(client)).toBe(1);
      expect(await meteringEventClaimed(client, at())).toBe(true);
      expect(await claimMeteringEvent(client, at())).toBe(false);
    });

    it("is given to exactly one of two callers racing for it", async () => {
      await claimKey(client, claim());
      const second = new pg.Client({ connectionString: url });
      await second.connect();
      try {
        const results = await Promise.all([
          claimMeteringEvent(client, at()),
          claimMeteringEvent(second, at()),
        ]);
        expect(results.filter(Boolean)).toHaveLength(1);
      } finally {
        await second.end();
      }
    });

    it("reports three states apart, because a keyless request is not an already-metered one", async () => {
      // SONNY-133 must not read `false` as "already metered"; `null` is "no row for this key".
      expect(await meteringEventClaimed(client, at())).toBeNull();
      await claimKey(client, claim());
      expect(await meteringEventClaimed(client, at())).toBe(false);
      await claimMeteringEvent(client, at());
      expect(await meteringEventClaimed(client, at())).toBe(true);
    });
  });

  it("gives the key to exactly one of two requests racing for a key nobody has used", async () => {
    // The reason the claim inserts before it selects: `SELECT … FOR UPDATE` locks nothing when there
    // is no row, so two first-attempts would both find nothing and one would fail on the primary
    // key. `INSERT … ON CONFLICT DO NOTHING` makes the loser wait and then read the winner's row.
    const second = new pg.Client({ connectionString: url });
    await second.connect();
    try {
      const outcomes = await Promise.all([
        claimKey(client, claim()),
        claimKey(second, claim()),
      ]);
      expect(outcomes.filter((outcome) => outcome.kind === "claimed")).toHaveLength(1);
      expect(outcomes.filter((outcome) => outcome.kind === "in_flight")).toHaveLength(1);
    } finally {
      await second.end();
    }
  });

  describe("pruning and account deletion", () => {
    it("clears an expired payload and frees the key, leaving the row", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await completeClaim(client, heldBy(token), response("{}"));
      await backDate("response_expires_at", 1);

      expect(await pruneExpiredResponses(client)).toBe(1);

      const { rows } = await client.query(
        `SELECT state, response_body, response_status, response_expires_at
           FROM sonny.idempotency_key WHERE account_scope = $1 AND idempotency_key = $2`,
        [ACCOUNT, KEY],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        state: "released",
        response_body: null,
        response_status: null,
        response_expires_at: null,
      });
    });

    it("leaves a payload that is still inside its window", async () => {
      const token = grantedTo(await claimKey(client, claim()));
      await completeClaim(client, heldBy(token), response("{}"));

      expect(await pruneExpiredResponses(client)).toBe(0);
      const repeat = await claimKey(client, claim());
      expect(repeat.kind).toBe("replay");
    });

    it("drops one account's stored responses and keeps its metering claims", async () => {
      const mineToken = grantedTo(await claimKey(client, claim("POST /v1/plan\nsha256:aaa", ACCOUNT)));
      await claimMeteringEvent(client, at(ACCOUNT));
      await completeClaim(
        client,
        heldBy(mineToken, ACCOUNT),
        response('{"content":"the user asked something"}'),
      );
      const theirToken = grantedTo(
        await claimKey(client, claim("POST /v1/plan\nsha256:aaa", OTHER_ACCOUNT)),
      );
      await completeClaim(
        client,
        heldBy(theirToken, OTHER_ACCOUNT),
        response('{"content":"someone else"}'),
      );

      expect(await deleteStoredResponsesForAccount(client, ACCOUNT)).toBe(1);

      expect(await meteringEventClaimed(client, at(ACCOUNT))).toBe(true);
      expect((await claimKey(client, claim("POST /v1/plan\nsha256:aaa", ACCOUNT))).kind).toBe("claimed");
      // The other account is untouched.
      expect((await claimKey(client, claim("POST /v1/plan\nsha256:aaa", OTHER_ACCOUNT))).kind).toBe("replay");
    });
  });
});

/**
 * The three behaviours the ticket names, end to end through the real app and the real store.
 *
 * Everything above drives the store directly. This drives `buildApp` — the gate that names the
 * account, the fingerprint taken from a parsed body, the hooks in their real places — over the same
 * Postgres, so the wiring is proved rather than assumed.
 */
describeDb("contract §9.2 end to end, over a real Postgres", () => {
  let pool: pg.Pool;
  let client: pg.Client;
  let upstreamCalls = 0;

  const withConnection: WithConnection = async (work) => {
    const connection = await pool.connect();
    try {
      return await work(connection as unknown as pg.Client);
    } finally {
      connection.release();
    }
  };

  class GateOnlyProvider implements AuthProvider {
    async sendEmailCode() {
      return { providerRequestId: undefined };
    }
    async verifyEmailCode(): Promise<VerifiedSession> {
      throw new Error("not used here");
    }
    async refresh(): Promise<VerifiedSession> {
      throw new Error("not used here");
    }
    async signOut() {}
    async userFromAccessToken(): Promise<string> {
      throw new Error("not used here");
    }
    async signOutAllForUser() {}
    async deleteUser() {}
  }

  beforeAll(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await up(client);
    pool = new pg.Pool({ connectionString: url, max: 8 });
  });
  afterAll(async () => {
    await pool.end();
    await client.end();
  });
  beforeEach(async () => {
    await client.query("TRUNCATE sonny.idempotency_key");
    // Every request in this block is on a metered route now (SONNY-133), so each leaves a metering
    // row behind. Truncated here rather than left to the line below, because `sonny.metering_event`
    // deliberately has **no** foreign key to `sonny.account` — 0012's header argues it, and the
    // consequence is that the CASCADE below does not reach it. Without this, a count in one test
    // reads the rows of every test before it.
    await client.query("TRUNCATE sonny.metering_event");
    await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
    await client.query("INSERT INTO sonny.account (id) VALUES ($1)", [ACCOUNT]);
    await client.query(
      `INSERT INTO sonny.identity (account_id, provider, subject, email_hint, email_verified,
         email_is_relay, supabase_user_id, link_method)
       VALUES ($1, 'email', $2, 'signed-in@example.com', true, false, $3, 'primary')`,
      [ACCOUNT, SUPABASE_USER, SUPABASE_USER],
    );
    upstreamCalls = 0;
    vi.unstubAllGlobals();
    vi.stubGlobal("fetch", async () => {
      upstreamCalls += 1;
      return new Response(
        JSON.stringify({
          output: [{ content: [{ type: "output_text", text: `{"call":${upstreamCalls}}` }] }],
          usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3 },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });
  });

  const build = () =>
    buildApp(
      testConfig({
        databaseUrl: url,
        credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }],
      }),
      { provider: new GateOnlyProvider(), withConnection },
      { idempotencyStore: postgresKeyStore(withConnection) },
    );

  const planBody = (text: string) => ({
    task_id: "task-1",
    retention: "standard" as const,
    messages: [{ role: "user" as const, text }],
    response_schema_name: "Plan",
    response_schema: { type: "object" },
  });

  const post = (app: ReturnType<typeof build>, key: string, text = "hello") =>
    app.inject({
      method: "POST",
      url: "/v1/plan",
      headers: {
        authorization: `Bearer ${accessTokenFor(SUPABASE_USER)}`,
        "idempotency-key": key,
      },
      payload: planBody(text),
    });

  it("returns the stored response to a repeat, and calls the provider once", async () => {
    const app = build();

    const first = await post(app, KEY);
    const second = await post(app, KEY);

    expect(first.statusCode).toBe(200);
    expect(second.statusCode).toBe(200);
    expect(second.body).toBe(first.body);
    expect(second.headers["sonny-request-id"]).toBe(first.headers["sonny-request-id"]);
    // The guarantee, in one number: one logical operation, one upstream call.
    expect(upstreamCalls).toBe(1);
    await app.close();
  });

  it("answers 409 idempotency.conflict when the same key carries a different body", async () => {
    const app = build();

    await post(app, KEY, "the first command");
    const conflicting = await post(app, KEY, "a different command");

    expect(conflicting.statusCode).toBe(409);
    expect(conflicting.json()["error"]["code"]).toBe("idempotency.conflict");
    expect(conflicting.json()["error"]["retryable"]).toBe(false);
    expect(upstreamCalls).toBe(1);
    await app.close();
  });

  it("writes at most one metering claim per key across a repeat and a re-run", async () => {
    // The store's own tests prove the claim is one-shot. This proves the key a *request* creates is
    // the key SONNY-133 finds — the two halves have to name the same row, and nothing else in this
    // suite would notice if the hook scoped or spelled it differently.
    //
    // **Rewritten by SONNY-133, the ticket that made it checkable** (2026-08-28). It used to take
    // the claim itself and assert it was *available* — the only assertion on offer while nothing
    // consumed it. The gateway consumes it now, so this is the stronger claim the test was always
    // reaching for: the row a request creates is the row the metering hook claimed, under the same
    // scope and the same key, and one logical operation leaves exactly one event.
    const app = build();
    await post(app, KEY);

    // Taken during the request, by the gateway, rather than by this test.
    expect(await meteringEventClaimed(client, at())).toBe(true);

    // A repeat replays the stored response and runs nothing, so it changes neither the claim nor the
    // count. `claimMeteringEvent` answering false is §9.2's second bullet from the outside: whatever
    // asks next, this key's one event is spoken for.
    await post(app, KEY);
    expect(await meteringEventClaimed(client, at())).toBe(true);
    expect(await claimMeteringEvent(client, at())).toBe(false);

    const { rows } = await client.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM sonny.metering_event WHERE idempotency_key = $1",
      [KEY],
    );
    expect(rows[0]!.n).toBe(1);
    await app.close();
  });

  it("scopes the row to the signed-in account rather than to the request", async () => {
    const app = build();
    await post(app, KEY);

    const { rows } = await client.query(
      "SELECT account_scope, route FROM sonny.idempotency_key WHERE idempotency_key = $1",
      [KEY],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].account_scope).toBe(ACCOUNT);
    expect(rows[0].route).toBe("POST /v1/plan");
    await app.close();
  });
});
