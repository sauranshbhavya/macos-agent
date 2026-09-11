import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import type pg from "pg";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { WithConnection } from "../src/db/connection.js";
import { STATEMENT_TIMEOUT_MS } from "../src/db/pool.js";
import type { ClaimOutcome, KeyStore } from "../src/idempotency/store.js";
import { ACCOUNT_DEADLINE_MS, DEADLINE_MS } from "../src/model/limits.js";
import { leasingUnderTotalDeadline, underTotalDeadline } from "../src/model/routing.js";
import { ProviderTimedOut } from "../src/model/upstream.js";
import { testConfig } from "./support/config.js";
import { accessTokenFor } from "./support/tokens.js";

/**
 * §12's total deadline on the three account routes whose slow work is the database (SONNY-434):
 * `GET /v1/account/entitlements`, `GET /v1/account/credits` and `PUT /v1/account/credits/auto-top-up`.
 *
 * **The same shape as `content.test.ts`'s deadline tests, for the same reason.** The fake below is a
 * Postgres that honours `statement_timeout`: a statement issued under one is cancelled with `57014`,
 * a statement issued under none runs to completion. So an unwired route answers its ordinary `200`
 * and fails on a status, loudly and attributably, rather than by handing the mapper a ready-made
 * error it would map correctly whether or not anything was bounded — `CLAUDE.md`'s held-sample
 * gotcha. **These tests drive the real Postgres stores over the fake**, not the in-memory fakes the
 * rest of the credit and entitlement suites use, because the property is where the lease is taken
 * and what it is bounded by, and an in-memory store takes no lease.
 */

const SUPABASE_USER = "3f0b7f1c-6f21-4a0e-8d55-2b6f5f2a77c1";
const ACCOUNT = "6d2c4a9e-1b3d-4f0a-9c77-2b6f5f2a77c2";
const authorization = () => `Bearer ${accessTokenFor(SUPABASE_USER)}`;

class UnusedAuthProvider implements AuthProvider {
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

const alwaysClaims: KeyStore = {
  claim: async (): Promise<ClaimOutcome> => ({ kind: "claimed", token: randomUUID() }),
  complete: async () => {},
  release: async () => {},
};

/** The milliseconds out of a `SET statement_timeout TO <n>`, refusing anything else. */
function budgetOf(statement: string): number {
  const value = statement.toUpperCase().split(" TO ")[1];
  if (value === undefined) throw new Error(`not a statement_timeout: ${statement}`);
  return Number(value);
}

function budgetsSet(record: readonly string[]): number[] {
  return record
    .filter((statement) => statement.toUpperCase().startsWith("SET STATEMENT_TIMEOUT"))
    .map(budgetOf);
}

/**
 * A connection whose every store statement is cancelled when a `statement_timeout` is in force and
 * completes when none is. `completing` names statements that complete either way, with the rows
 * they answer — the consent write, for the test that needs one lease to succeed before the next.
 */
function stallingConnection(
  record: string[],
  completing: (text: string) => { rows: unknown[] } | undefined = () => undefined,
): WithConnection {
  return async (work) => {
    let timeoutMs: number | undefined;
    const client = {
      query: async (text: string, values: readonly unknown[] = []) => {
        record.push(text.trim());
        const statement = text.trim().toUpperCase();
        if (statement.startsWith("SET STATEMENT_TIMEOUT")) {
          timeoutMs = Number(statement.split(" TO ")[1]);
          return { rows: [] };
        }
        if (statement === "RESET STATEMENT_TIMEOUT") {
          timeoutMs = undefined;
          return { rows: [] };
        }
        if (statement === "BEGIN" || statement === "COMMIT" || statement === "ROLLBACK") {
          return { rows: [] };
        }
        // The gate's own reads, answered as `support/connection.ts` answers them; what this fake
        // exists to control is the statements after the gate.
        if (text.includes("INSERT INTO sonny.revoked_provider_session")) return { rows: [] };
        // The admit hook's rate-limit counter, which every authenticated request increments before
        // any handler runs: one request in the window, allowed.
        if (text.includes("INSERT INTO sonny.auth_rate_limit")) return { rows: [{ count: 1 }] };
        if (text.includes("FROM sonny.revoked_provider_session")) return { rows: [] };
        if (text.includes("FROM sonny.identity")) {
          void values;
          return { rows: [{ account_id: ACCOUNT }] };
        }
        const answered = completing(text);
        if (answered !== undefined) return answered;
        // The route's own work: cancelled under a bound, completed under none.
        if (timeoutMs === undefined) return { rows: [], rowCount: 0 };
        throw Object.assign(new Error("canceling statement due to statement timeout"), {
          code: "57014",
        });
      },
    };
    return work(client as unknown as pg.Client);
  };
}

function buildOver(withConnection: WithConnection) {
  // No `entitlementStore` or `creditStore` override: the real Postgres stores, over the fake.
  return buildApp(
    testConfig({ credentials: [{ provider: "openai", keys: ["sk-test-openai-key"] }] }),
    { provider: new UnusedAuthProvider(), withConnection },
    { idempotencyStore: alwaysClaims },
  );
}

afterEach(() => {
  vi.useRealTimers();
});

describe("§12's total deadline on the three account routes (SONNY-434)", () => {
  /**
   * The population §12 names, by the request that reaches each. **A hand-written list**, so a
   * fourth database-bound account route is covered only once it is added here — nothing derives
   * this from the app, and the sentence that used to stand here claimed otherwise (PR #235's fresh
   * review, F5).
   */
  const ROUTES = [
    { name: "GET /v1/account/entitlements", method: "GET" as const, url: "/v1/account/entitlements" },
    { name: "GET /v1/account/credits", method: "GET" as const, url: "/v1/account/credits" },
    {
      name: "PUT /v1/account/credits/auto-top-up",
      method: "PUT" as const,
      url: "/v1/account/credits/auto-top-up",
      payload: { enabled: true },
    },
  ];

  for (const route of ROUTES) {
    it(`${route.name} answers §7.2's 504 when its store is cancelled inside §12's budget`, async () => {
      const record: string[] = [];
      const app = buildOver(stallingConnection(record));
      const response = await app.inject({
        method: route.method,
        url: route.url,
        headers: { authorization: authorization() },
        ...(route.payload ? { payload: route.payload } : {}),
      });

      expect(response.statusCode).toBe(504);
      expect(response.json().error.code).toBe("provider.timeout");
      expect(response.json().error.retryable).toBe(true);

      // The budget handed to Postgres for the first statement is the pool's own ten seconds and not
      // the row's fifteen: what is left of the total is wider, and the smaller of the two governs
      // (PR #235's fresh review, F1 — the first draft asserted a band just under the total, which
      // is exactly the fifteen-second statement the review measured).
      const [first] = budgetsSet(record);
      if (first === undefined) throw new Error("the route set no statement_timeout at all");
      expect(first).toBe(STATEMENT_TIMEOUT_MS);
      expect(STATEMENT_TIMEOUT_MS).toBeLessThan(ACCOUNT_DEADLINE_MS.total);

      // And the connection went back clean.
      expect(record).toContain("RESET statement_timeout");
    });

    it(`${route.name} answers 500 server.error, not a dressed-up timeout, when its store fails for another reason`, async () => {
      // PR #235's fresh review, F5(b): a route that mapped *every* store error to `504
      // provider.timeout` survived the whole suite. A plain failure — no `57014`, no code at all —
      // is the root handler's `500 server.error`, which is what "a bug here is a logged 500 and
      // never a dressed-up timeout" in `routes/entitlements.ts` promises.
      const record: string[] = [];
      const app = buildOver(
        stallingConnection(record, () => {
          throw new Error("the store fell over for a reason that is not a timeout");
        }),
      );
      const response = await app.inject({
        method: route.method,
        url: route.url,
        headers: { authorization: authorization() },
        ...(route.payload ? { payload: route.payload } : {}),
      });

      expect(response.statusCode).toBe(500);
      expect(response.json().error.code).toBe("server.error");
      expect(response.json().error.code).not.toBe("provider.timeout");
      // The bound was applied and cleared around the failing statement all the same.
      expect(record).toContain("RESET statement_timeout");
    });
  }

  it("the consent switch's two leases share one budget rather than each starting §12's total afresh", async () => {
    // Only `Date` is faked, so the request runs on real timers and the clock alone is ours.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-11T10:00:00Z"));
    const record: string[] = [];
    const app = buildOver(
      stallingConnection(record, (text) => {
        if (!text.includes("INSERT INTO sonny.auto_topup_consent")) return undefined;
        // The write completes, and six seconds pass inside it — six rather than the four the first
        // draft used, because the pool's ten-second ceiling caps the first lease at ten, and a step
        // under five seconds would read `[10000, 10000]`, indistinguishable from two fresh totals.
        vi.setSystemTime(Date.now() + 6_000);
        return { rows: [{ opted_in_at: new Date() }] };
      }),
    );

    const response = await app.inject({
      method: "PUT",
      url: "/v1/account/credits/auto-top-up",
      headers: { authorization: authorization() },
      payload: { enabled: true },
    });

    // The re-read is the second lease; its first statement is the one cancelled.
    expect(response.statusCode).toBe(504);
    // First lease: the pool's ten seconds, the smaller of it and the whole total. Second lease: what
    // was left of the total — nine seconds — not a fresh ten and not a fresh fifteen.
    expect(budgetsSet(record)).toEqual([STATEMENT_TIMEOUT_MS, ACCOUNT_DEADLINE_MS.total - 6_000]);
  });

  it("the charge route's reads stay on the pool's bound: no budget is declared and no statement_timeout is set", async () => {
    const record: string[] = [];
    const app = buildOver(stallingConnection(record));
    const response = await app.inject({
      method: "POST",
      url: "/v1/account/credits/top-up",
      headers: { authorization: authorization(), "idempotency-key": randomUUID() },
    });

    // The deployment sells no pack, so the charge refuses after its read — and the read ran to
    // completion, under no bound this route set: the decision recorded in `routes/credits.ts`.
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("topup.not_permitted");
    expect(budgetsSet(record)).toEqual([]);
    expect(record.some((statement) => statement.includes("FROM sonny.entitlement"))).toBe(true);
  });

  it("the constant is §12's last row's total and nothing else", () => {
    expect(ACCOUNT_DEADLINE_MS).toEqual({ total: DEADLINE_MS.auth.total });
  });
});

describe("leasingUnderTotalDeadline, apart from the routes", () => {
  it("outside a declared deadline the lease is the bare lease: no budget, no SET, no RESET", async () => {
    const record: string[] = [];
    const bounded = leasingUnderTotalDeadline(stallingConnection(record));

    const rows = await bounded(async (client) => (await client.query("SELECT 1")).rows);

    expect(rows).toEqual([]);
    expect(record).toEqual(["SELECT 1"]);
  });

  it("inside one, each lease is bounded by what is left of the request's budget", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-11T10:00:00Z"));
    const record: string[] = [];
    const bounded = leasingUnderTotalDeadline(
      stallingConnection(record, (text) => (text === "SELECT 1" ? { rows: [] } : undefined)),
    );

    await underTotalDeadline({ total: 10_000 }, async () => {
      await bounded(async (client) => client.query("SELECT 1"));
      vi.setSystemTime(Date.now() + 2_500);
      await bounded(async (client) => client.query("SELECT 1"));
    });

    expect(budgetsSet(record)).toEqual([10_000, 7_500]);
    expect(record.filter((statement) => statement === "RESET statement_timeout")).toHaveLength(2);
  });

  it("time spent waiting for a pooled connection comes out of the budget, not on top of it", async () => {
    // PR #235's review, F1: the wrapper anchors its deadline once it is entered, which is after the
    // pool wait, so a remainder computed before the wait handed Postgres a budget the wait had spent.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-11T10:00:00Z"));
    const record: string[] = [];
    const slowPool = stallingConnection(record, (text) => (text === "SELECT 1" ? { rows: [] } : undefined));
    const waiting: WithConnection = async (work) => {
      // Four hundred milliseconds queued for a free connection.
      vi.setSystemTime(Date.now() + 400);
      return slowPool(work);
    };
    const bounded = leasingUnderTotalDeadline(waiting);

    await underTotalDeadline({ total: 1_000 }, async () => {
      await bounded(async (client) => client.query("SELECT 1"));
    });

    expect(budgetsSet(record)).toEqual([600]);
  });

  it("inside a budget wider than the pool's bound, each statement is bounded by the pool's bound", async () => {
    // PR #235's fresh review, F1: the remainder of a fifteen-second budget is fifteen seconds, and a
    // `SET` of fifteen is a fifteen-second statement, not a ten-second one capped by the pool.
    const record: string[] = [];
    const bounded = leasingUnderTotalDeadline(
      stallingConnection(record, (text) => (text === "SELECT 1" ? { rows: [] } : undefined)),
    );

    await underTotalDeadline({ total: 30_000 }, async () => {
      await bounded(async (client) => client.query("SELECT 1"));
    });

    expect(budgetsSet(record)).toEqual([STATEMENT_TIMEOUT_MS]);
  });

  it("a ceiling a caller supplies is honoured, and one of nothing is refused where it is wired", async () => {
    const record: string[] = [];
    const fake = stallingConnection(record, (text) => (text === "SELECT 1" ? { rows: [] } : undefined));
    const bounded = leasingUnderTotalDeadline(fake, { perStatementMs: 250 });

    await underTotalDeadline({ total: 1_000 }, async () => {
      await bounded(async (client) => client.query("SELECT 1"));
    });

    expect(budgetsSet(record)).toEqual([250]);
    // `SET statement_timeout TO 0` is no timeout at all, so a zero ceiling is a configuration error
    // and not a tighter bound.
    expect(() => leasingUnderTotalDeadline(fake, { perStatementMs: 0 })).toThrow();
  });

  it("a wait for a pooled connection that outlasts the budget ends at the budget, and the connection that arrives afterwards runs nothing", async () => {
    // PR #235's fresh review, F3, in the reviewer's shape: a small budget, and a pool with nothing
    // to hand over until the test says so. The rejection is the lease's own timer; nothing here
    // races a clock against another party.
    // The pool hands its connection over half a second in; the budget is fifty milliseconds. Under
    // the fix the caller is answered at the budget and the hand-over finds nobody waiting; with the
    // wait unbounded the hand-over arrives, the work runs, and the promise resolves instead — a
    // clean assertion failure rather than a hang, which is why the hand-over is scheduled at all.
    let released = 0;
    let ran = 0;
    let handedOver!: () => void;
    const connectionFree = new Promise<void>((resolve) => {
      handedOver = resolve;
    });
    const heldEmpty: WithConnection = async (work) => {
      await connectionFree;
      try {
        return await work({
          query: async () => {
            ran += 1;
            return { rows: [] };
          },
        } as unknown as pg.Client);
      } finally {
        released += 1;
      }
    };
    const bounded = leasingUnderTotalDeadline(heldEmpty);
    setTimeout(handedOver, 500);

    await expect(
      underTotalDeadline({ total: 50 }, () => bounded(async (client) => client.query("SELECT 1"))),
    ).rejects.toBeInstanceOf(ProviderTimedOut);
    // Answered while the pool still had nothing: it was the wait that ended, not any work.
    expect(released).toBe(0);
    expect(ran).toBe(0);

    await vi.waitFor(() => expect(released).toBe(1));
    // The lease the pool finally granted went straight back, with no statement issued on it.
    expect(ran).toBe(0);
  });

  it("the pool's own connect timeout inside a budget is a timeout, and outside one it is untouched", async () => {
    // `pg-pool` gives up on a wait with this exact wording and no code; inside a declared budget that
    // wait is the wait the budget bounds, so it answers as §12's 504 rather than the root handler's
    // 500 (PR #235's fresh review, F3: measured at 5003 ms as a `500`).
    // Both of `pg-pool`'s wordings: one for a wait in its queue, one for a new client's connect.
    for (const wording of ["timeout exceeded when trying to connect", "Connection terminated due to connection timeout"]) {
      const bounded = leasingUnderTotalDeadline(async () => {
        throw new Error(wording);
      });
      await expect(
        underTotalDeadline({ total: 1_000 }, () => bounded(async (client) => client.query("SELECT 1"))),
      ).rejects.toBeInstanceOf(ProviderTimedOut);
    }
    const poolGaveUp = () => new Error("timeout exceeded when trying to connect");

    const outside = poolGaveUp();
    const bare = leasingUnderTotalDeadline(async () => {
      throw outside;
    });
    await expect(bare(async (client) => client.query("SELECT 1"))).rejects.toBe(outside);
  });

  it("any other failure of the lease inside a budget is not dressed as a timeout", async () => {
    const refused = new Error("connect ECONNREFUSED");
    const bounded = leasingUnderTotalDeadline(async () => {
      throw refused;
    });
    await expect(
      underTotalDeadline({ total: 1_000 }, () => bounded(async (client) => client.query("SELECT 1"))),
    ).rejects.toBe(refused);
  });

  it("a budget already spent refuses before taking a connection at all", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-11T10:00:00Z"));
    let leases = 0;
    const bounded = leasingUnderTotalDeadline(async (work) => {
      leases += 1;
      return work({ query: async () => ({ rows: [] }) } as unknown as pg.Client);
    });

    await expect(
      underTotalDeadline({ total: 1_000 }, async () => {
        vi.setSystemTime(Date.now() + 1_000);
        return bounded(async (client) => client.query("SELECT 1"));
      }),
    ).rejects.toBeInstanceOf(ProviderTimedOut);
    expect(leases).toBe(0);
  });
});
