import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import type pg from "pg";
import { buildApp } from "../src/app.js";
import type { AuthProvider, VerifiedSession } from "../src/auth/provider.js";
import type { WithConnection } from "../src/db/connection.js";
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
   * The population §12 names, by the request that reaches each. A fourth database-bound account
   * route arriving without the budget is what this list exists to fail on.
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

      // The budget handed to Postgres is §12's total for this row, minus the real time that had
      // elapsed — at most the total, and within a band of it no ordinary machine load can reach.
      const [first] = budgetsSet(record);
      if (first === undefined) throw new Error("the route set no statement_timeout at all");
      expect(first).toBeLessThanOrEqual(ACCOUNT_DEADLINE_MS.total);
      expect(first).toBeGreaterThan(ACCOUNT_DEADLINE_MS.total - 5_000);

      // And the connection went back clean.
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
        // The write completes, and four seconds pass inside it.
        vi.setSystemTime(Date.now() + 4_000);
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
    // First lease: the whole total. Second lease: what was left of it — not a fresh total.
    expect(budgetsSet(record)).toEqual([ACCOUNT_DEADLINE_MS.total, ACCOUNT_DEADLINE_MS.total - 4_000]);
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
