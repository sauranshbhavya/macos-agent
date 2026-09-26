import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect } from "vitest";
import { creditBalance } from "../src/credit/balance.js";
import { postgresCreditStore, readAgentCredits } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { catalogueOf } from "./support/credit.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * **Which rows an account has spent**, against a real Postgres (SONNY-212; spent by tokens since V2
 * plan decision 8).
 *
 * `credit.test.ts` proves the arithmetic, the catalogue and what the route hands a client, all
 * without a database. This file proves the one thing a fake could never say anything about: which
 * `agent_model_call` rows count against the pool — an open hold at what it holds, a settled call at
 * what it was charged, a released one at nothing — for this account, in this period, and nothing
 * else.
 *
 * **Every period here is a column value, never a wait**: a row's `period_start` is written by the
 * test, so no answer below depends on what day the suite runs.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "2c7f1b90-4d3e-4a11-9f22-2b6f5f2a77d1";
const OTHER_ACCOUNT = "5e8a3c21-7f4b-4c02-8d33-2b6f5f2a77d2";

describeDb("what the credit pool has spent", () => {
  let client: pg.Client;
  /** The one instant this file is written in terms of. A pinned input, not a calendar. */
  const at = new Date("2026-08-15T12:00:00Z");
  const since = periodStart(at);
  const lastPeriod = periodStart(new Date(since.getTime() - 1));

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.agent_model_call");
    await client.query("TRUNCATE sonny.entitlement");
  });

  /**
   * One model call's row, in the state given. `held` carries no charge and no settle time;
   * `settled` and `released` carry both, as the table's CHECK requires. `released` is written the
   * way `expireHolds` writes it: charged zero, with the hold still recorded.
   */
  const call = async (input: {
    readonly status: "held" | "settled" | "released";
    readonly held: number;
    readonly charged?: number;
    readonly accountId?: string;
    readonly period?: Date;
  }): Promise<void> => {
    const charged = input.status === "held" ? null : input.status === "released" ? 0 : input.charged;
    await client.query(
      `INSERT INTO sonny.agent_model_call
         (step_id, account_id, task_id, agent, tier, period_start, status, credits_held,
          credits_charged, settled_at)
       VALUES ($1, $2, $3, 'planner', 'standard', $4, $5, $6, $7, $8)`,
      [
        randomUUID(),
        input.accountId ?? ACCOUNT,
        randomUUID(),
        input.period ?? since,
        input.status,
        input.held,
        charged,
        input.status === "held" ? null : at,
      ],
    );
  };

  const spent = (accountId = ACCOUNT, period = since) =>
    readAgentCredits(client, { accountId, periodStart: period });

  itUnderHangBackstop("counts a settled call at its charge and an open hold at what it holds", async () => {
    // Settled below its hold: the charge is what the tokens cost, and the hold is forgotten.
    await call({ status: "settled", held: 50, charged: 7.25 });
    expect(await spent()).toBe(7.25);

    // An open hold counts in full, so two calls cannot both spend the same credits.
    await call({ status: "held", held: 40 });
    expect(await spent()).toBe(47.25);
  });

  itUnderHangBackstop("counts nothing for a released hold, whatever it once held", async () => {
    await call({ status: "released", held: 900 });
    expect(await spent()).toBe(0);

    // And the zero is an exclusion, not a query matching nothing: a settled row beside it counts.
    await call({ status: "settled", held: 10, charged: 3 });
    expect(await spent()).toBe(3);
  });

  itUnderHangBackstop("counts this period and not the one before it", async () => {
    await call({ status: "settled", held: 100, charged: 80, period: lastPeriod });
    await call({ status: "held", held: 60, period: lastPeriod });
    await call({ status: "settled", held: 5, charged: 4.5 });

    expect(await spent()).toBe(4.5);
    // The allowance resets because the period moves, not because anything is deleted: last
    // period's rows are still there and still add up.
    expect(await spent(ACCOUNT, lastPeriod)).toBe(140);
  });

  itUnderHangBackstop("counts this account and not another's", async () => {
    await call({ status: "settled", held: 30, charged: 20, accountId: OTHER_ACCOUNT });
    await call({ status: "held", held: 15, accountId: OTHER_ACCOUNT });
    await call({ status: "settled", held: 2, charged: 1.5 });

    expect(await spent()).toBe(1.5);
    expect(await spent(OTHER_ACCOUNT)).toBe(35);
  });

  itUnderHangBackstop("keeps a charge's six decimals through the numeric column", async () => {
    // `numeric(20, 6)` comes back from `pg` as a string; the sum must read back as the number the
    // charges add up to, not a float approximation of it.
    await call({ status: "settled", held: 1, charged: 0.100001 });
    await call({ status: "settled", held: 1, charged: 0.200002 });
    expect(await spent()).toBe(0.300003);
  });

  itUnderHangBackstop("derives the balance end to end, from real rows and a real plan row", async () => {
    const catalogue = catalogueOf({ monthlyCredits: [100, 1000] });
    const paid = catalogue.plans[1]!;
    await client.query("INSERT INTO sonny.entitlement (account_id, plan) VALUES ($1, $2)", [
      ACCOUNT,
      paid.key,
    ]);
    await call({ status: "settled", held: 40, charged: 34 });
    await call({ status: "held", held: 16 });
    await call({ status: "released", held: 500 });

    const store = postgresCreditStore(async (work) => work(client));
    const facts = await store.factsFor(ACCOUNT, at);
    expect(facts.planKey).toBe(paid.key);
    expect(facts.agentCredits).toBe(50);

    const balance = creditBalance({
      catalogue,
      planKey: facts.planKey,
      agentCredits: facts.agentCredits,
      toppedUpCredits: facts.toppedUpCredits,
      now: at,
    });
    expect(balance.credits).toEqual({ allowance: 1000, drawn: 50, remaining: 950, toppedUp: 0 });
    expect(balance.periodStart).toEqual(since);

    // A revoked plan keeps its key on the claim and loses the allowance: the same account, the same
    // rows, the default tier.
    await client.query("UPDATE sonny.entitlement SET revoked_at = now() WHERE account_id = $1", [
      ACCOUNT,
    ]);
    const revoked = await store.factsFor(ACCOUNT, at);
    expect(revoked.planKey).toBeUndefined();
    expect(
      creditBalance({
        catalogue,
        planKey: revoked.planKey,
        agentCredits: revoked.agentCredits,
        toppedUpCredits: revoked.toppedUpCredits,
        now: at,
      }).credits,
    ).toEqual({ allowance: 100, drawn: 50, remaining: 50, toppedUp: 0 });
  });
});
