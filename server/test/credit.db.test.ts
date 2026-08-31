import pg from "pg";
import { describe, expect } from "vitest";
import { creditBalance } from "../src/credit/balance.js";
import { postgresCreditStore, readScreenControlDraw } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import { meteredRoutes, type MeteringEvent } from "../src/metering/event.js";
import { insertMeteringEvent } from "../src/metering/store.js";
import {
  afterAllUnderHangBackstop,
  beforeAllUnderHangBackstop,
  beforeEachUnderHangBackstop,
  itUnderHangBackstop,
} from "./support/backstop.js";
import { catalogueOf } from "./support/credit.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * **Which rows draw**, against a real Postgres (SONNY-212).
 *
 * `credit.test.ts` proves the arithmetic, the catalogue and what the route hands a client, all
 * without a database. This file proves the one thing a fake could never say anything about: that the
 * pool is drawn on by screen control and by nothing else, that an iteration which reached no
 * provider is free, and that a period is a period. Those are properties of one SQL statement over a
 * table row 12 writes, and a fake that appeared to exclude the four unpaid routes would be a suite
 * believing it had tested an exclusion.
 *
 * **Every age here is produced by back-dating a row, never by waiting** — `metering.db.test.ts`'s
 * rule, and `CLAUDE.md`'s: a test that slept past a period boundary would be betting on a wall clock
 * it shares with the rest of the suite.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const ACCOUNT = "2c7f1b90-4d3e-4a11-9f22-2b6f5f2a77d1";
const OTHER_ACCOUNT = "5e8a3c21-7f4b-4c02-8d33-2b6f5f2a77d2";

/** One iteration's row. Only the columns this ticket's query reads carry meaningful values. */
function event(overrides: Partial<MeteringEvent> = {}): MeteringEvent {
  return {
    requestId: `request-${Math.random().toString(36).slice(2)}`,
    idempotencyKey: null,
    accountId: ACCOUNT,
    route: "screen.analyze",
    provider: "vision",
    failedOver: [],
    model: "a-vision-model",
    inputTokens: null,
    outputTokens: null,
    totalTokens: null,
    tokenSource: null,
    imageBytes: 500_000,
    imagePixelWidth: 1000,
    imagePixelHeight: 1000,
    imageMediaType: "image/jpeg",
    audioDurationSeconds: null,
    requestBytes: 600_000,
    responseBytes: 400,
    durationMs: 3000,
    upstreamDurationMs: 2900,
    outcome: "ok",
    taskId: "task-1",
    sessionId: "session-1",
    sessionIteration: 1,
    retention: "standard",
    clientVersion: "1.0.0+412",
    ...overrides,
  };
}

describeDb("what draws on the credit pool", () => {
  let client: pg.Client;
  const at = new Date("2026-08-15T12:00:00Z");
  const window = () => ({
    accountId: ACCOUNT,
    since: new Date("2026-08-01T00:00:00Z"),
    until: new Date("2026-09-01T00:00:00Z"),
  });

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("TRUNCATE sonny.metering_event");
    await client.query("TRUNCATE sonny.entitlement");
  });

  const insert = async (...events: MeteringEvent[]): Promise<void> => {
    for (const one of events) await insertMeteringEvent(client, one);
  };

  /** Move every row already written into a chosen instant, rather than sleeping to reach one. */
  const backDateAllTo = async (when: Date): Promise<void> => {
    await client.query("UPDATE sonny.metering_event SET occurred_at = $1", [when]);
  };

  itUnderHangBackstop("draws on screen control and on nothing else", async () => {
    // Every other route, each carrying a session id it has no business carrying — a client bug, and
    // the one shape that could inflate a screen-control figure if the query trusted the column
    // instead of the route. `screenControlSessionCosts` guards the same way for the same reason.
    const unpaid = meteredRoutes.filter((route) => route !== "screen.analyze");
    expect(unpaid).toHaveLength(4);
    await insert(
      ...unpaid.map((route, index) =>
        event({ route, sessionId: `bogus-session-${index}`, sessionIteration: 1 }),
      ),
    );

    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 0,
      iterations: 0,
      pixels: 0,
    });

    // And the paid line does draw, so the zero above is an exclusion rather than a query that
    // matches nothing — `CLAUDE.md`'s rule about a clean zero being the answer that looks like good
    // news.
    await insert(event({ sessionId: "session-real", sessionIteration: 1 }));
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 1,
      pixels: 1_000_000,
    });
  });

  itUnderHangBackstop("charges nothing for an iteration that reached no provider", async () => {
    // `upstream_duration_ms IS NULL` is the table's record of "no provider call was opened at all":
    // a validation refusal, an oversize capture, a route with no configured adapter. A session made
    // entirely of those is not counted as a session either, so it pays no per-session weight.
    await insert(
      event({ sessionId: "refused-session", sessionIteration: 1, upstreamDurationMs: null,
              provider: null, outcome: "refused" }),
      event({ sessionId: "refused-session", sessionIteration: 2, upstreamDurationMs: null,
              provider: null, outcome: "refused" }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 0,
      iterations: 0,
      pixels: 0,
    });

    // A failed provider call DOES draw, and this is the case `provider` would have got wrong: the
    // router writes no attribution for a call that threw, so the column is null while the vendor was
    // reached and may well have billed for it.
    await insert(
      event({ sessionId: "failed-session", sessionIteration: 1, provider: null,
              outcome: "provider_error", upstreamDurationMs: 4000 }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 1,
      pixels: 1_000_000,
    });
  });

  itUnderHangBackstop("counts sessions distinctly and iterations individually", async () => {
    await insert(
      ...[1, 2, 3].map((n) => event({ sessionId: "session-a", sessionIteration: n })),
      ...[1, 2].map((n) => event({ sessionId: "session-b", sessionIteration: n })),
      // A row with no session at all cannot join one, so it is excluded like the unpaid routes.
      event({ sessionId: null, sessionIteration: null }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 2,
      iterations: 5,
      pixels: 5_000_000,
    });
  });

  itUnderHangBackstop("sums the pixels each iteration actually sent", async () => {
    await insert(
      event({ sessionId: "session-a", sessionIteration: 1, imagePixelWidth: 2406, imagePixelHeight: 1354 }),
      event({ sessionId: "session-a", sessionIteration: 2, imagePixelWidth: 800, imagePixelHeight: 600 }),
      // A row whose dimensions never arrived contributes no pixels and is still an iteration.
      event({ sessionId: "session-a", sessionIteration: 3, imagePixelWidth: null, imagePixelHeight: null }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 3,
      pixels: 2406 * 1354 + 800 * 600,
    });
  });

  itUnderHangBackstop("counts this period and not the one before it", async () => {
    await insert(...[1, 2].map((n) => event({ sessionId: "last-month", sessionIteration: n })));
    await backDateAllTo(new Date("2026-07-31T23:59:59.999Z"));
    await insert(event({ sessionId: "this-month", sessionIteration: 1 }));

    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 1,
      pixels: 1_000_000,
    });
    // The allowance resets because the window moves, not because anything is deleted: the rows are
    // still there, and §10.3's long clock is what keeps them.
    const { rows } = await client.query<{ count: string }>(
      "SELECT count(*) AS count FROM sonny.metering_event",
    );
    expect(Number(rows[0]!.count)).toBe(3);
  });

  itUnderHangBackstop("counts this account and not another's", async () => {
    await insert(
      event({ accountId: OTHER_ACCOUNT, sessionId: "theirs", sessionIteration: 1 }),
      event({ sessionId: "mine", sessionIteration: 1 }),
    );
    expect((await readScreenControlDraw(client, window())).sessions).toBe(1);
  });

  itUnderHangBackstop("derives runs left end to end, from real rows and a real plan row", async () => {
    const catalogue = catalogueOf({
      runCredits: 50,
      monthlyCredits: [100, 1000],
      weights: { perSession: 10, perIteration: 5, perMegapixel: 1 },
    });
    const paid = catalogue.plans[1]!;
    await client.query("INSERT INTO sonny.entitlement (account_id, plan) VALUES ($1, $2)", [
      ACCOUNT,
      paid.key,
    ]);
    await insert(...[1, 2, 3, 4].map((n) => event({ sessionId: "session-a", sessionIteration: n })));

    const store = postgresCreditStore(async (work) => work(client));
    const facts = await store.factsFor(ACCOUNT, at);
    expect(facts.planKey).toBe(paid.key);
    expect(facts.draw).toEqual({ sessions: 1, iterations: 4, pixels: 4_000_000 });

    // 10 per session + 5 x 4 iterations + 1 x 4 megapixels = 34 credits of 1000, so 966 remain and
    // one run is 50 of them.
    const balance = creditBalance({ catalogue, planKey: facts.planKey, draw: facts.draw, now: at });
    expect(balance.credits.drawn).toBe(34);
    expect(balance.runsLeft).toBe(19);
    expect(balance.runsIncluded).toBe(20);
    expect(balance.periodStart).toEqual(periodStart(at));

    // A revoked plan keeps its key on the claim and loses the allowance: the same account, the same
    // rows, the default tier.
    await client.query("UPDATE sonny.entitlement SET revoked_at = now() WHERE account_id = $1", [
      ACCOUNT,
    ]);
    const revoked = await store.factsFor(ACCOUNT, at);
    expect(revoked.planKey).toBeUndefined();
    expect(
      creditBalance({ catalogue, planKey: revoked.planKey, draw: revoked.draw, now: at }).runsLeft,
    ).toBe(1);
  });
});
