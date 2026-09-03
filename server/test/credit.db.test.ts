import pg from "pg";
import { describe, expect } from "vitest";
import { creditBalance, periodEnd } from "../src/credit/balance.js";
import { postgresCreditStore, readScreenControlDraw } from "../src/credit/store.js";
import { periodStart } from "../src/entitlement/period.js";
import { meteredRoutes, type MeteringEvent } from "../src/metering/event.js";
import { insertMeteringEvent } from "../src/metering/store.js";
import {
  afterAllUnderHangBackstop,
  afterEachUnderHangBackstop,
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
  /**
   * **The one instant this file is written in terms of** (SONNY-396).
   *
   * Everything here used to be half pinned: the window was two calendar literals while the rows took
   * `metering_event.occurred_at`'s own `now()` default, which is the database's clock. That is a test
   * whose answer depends on what day it is, and on 2026-09-01 the answer changed — the window closed,
   * every insert landed at or after `until`, and eight tests in this file began failing every day on
   * zero rows matched, with nothing about the code under test wrong. `npm test` skips this file, so
   * the greener command saw nothing and only `npm run test:db` — the more thorough thing — went red.
   *
   * **The trap is fixing that by moving the window forward.** It buys months and reproduces the same
   * failure on a later date, for a reader with no reason to suspect a fixed date because the file will
   * have passed all along. The window was never the problem; the *mixture* was. So the clock is gone
   * instead: `insert` stamps every row it writes at `at`, the window is `at`'s own period rather than
   * two literals that happen to bracket it, and no value anywhere below comes from a clock. `at` may
   * therefore stay a literal forever — a pinned input is not a calendar.
   */
  const at = new Date("2026-08-15T12:00:00Z");

  /**
   * The period `factsFor` itself computes for `at` — `periodStart(now)` to `periodEnd(now)`, read off
   * `credit/store.ts` rather than restated. The end-to-end test below asserts the two agree by using
   * this window and that call interchangeably, so a hand-copied pair of literals drifting away from
   * the real period is one fewer thing that can happen.
   */
  const window = () => ({ accountId: ACCOUNT, since: periodStart(at), until: periodEnd(at) });

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

  /**
   * **The guard that would have caught SONNY-396, and it fires on any date rather than once a window
   * expires.** The defect was a row stamped by a clock this file does not control, so the property is
   * that no row this file leaves behind sits anywhere near the database's own `now()`. A test added
   * later that inserts without stamping — through `insert`, or with a raw `INSERT` that bypasses it —
   * fails here immediately and deterministically, rather than passing until the next calendar bound
   * runs out.
   *
   * **Deliberately not "is the window still in the future".** That guard would pass for months and
   * then ask the next reader to move the window, which is the fix this ticket exists to refuse.
   * The one reading this cannot make is a machine whose clock has been set inside `at`'s own period,
   * which fails loudly on a property it names instead of quietly on assertions that name nothing.
   */
  afterEachUnderHangBackstop(async () => {
    const { rows } = await client.query<{ stray: string }>(
      `SELECT count(*) AS stray FROM sonny.metering_event
        WHERE occurred_at BETWEEN now() - interval '10 minutes' AND now() + interval '10 minutes'`,
    );
    expect(Number(rows[0]!.stray)).toBe(0);
  });

  /**
   * Insert through the production writer, then stamp exactly those rows at `at`.
   *
   * `insertMeteringEvent` leaves `occurred_at` to the column default, which is the whole of
   * SONNY-396. The stamp is scoped to these events' own `request_id`s rather than done through
   * `backDateAllTo`, because tests below deliberately leave earlier rows in a neighbouring period and
   * a blanket update would drag them back into this one. The row count is asserted because an update
   * that matched nothing and one that worked are otherwise the same clean result — `CLAUDE.md`'s rule
   * about a zero being the answer that looks like good news.
   */
  const insert = async (...events: MeteringEvent[]): Promise<void> => {
    for (const one of events) await insertMeteringEvent(client, one);
    const stamped = await client.query("UPDATE sonny.metering_event SET occurred_at = $1 WHERE request_id = ANY($2)",
      [at, events.map((one) => one.requestId)]);
    expect(stamped.rowCount).toBe(events.length);
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
    // A null `upstream_duration_ms` **beside an outcome of `refused`** is the table's record of "no
    // provider call was opened at all": a validation refusal, an oversize capture, a route with no
    // configured adapter. A session made entirely of those is not counted as a session either, so it
    // pays no per-session weight.
    //
    // **The qualification is the correction** (PR #182's review, F2). This comment repeated
    // migration `0012`'s own enumeration, which omits the case where the duration is null because the
    // handler never got to write it — a cancellation mid-provider-call, covered by the arm below.
    // Reading a null duration as "nothing was spent" was the defect; it is only that when the
    // outcome agrees.
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

  itUnderHangBackstop("charges a cancelled iteration, whose duration never landed", async () => {
    // **PR #182's review, F2.** The metering event has a second writer — the response's `close`
    // listener — and it fires while the handler is still awaiting the provider, before
    // `meteredUpstreamCall`'s `finally` has written the duration. So this row shape is what a user
    // pressing Stop mid-run produces: the vendor was paid, `entitlement/hook.ts` charged the spend
    // cap, and `upstream_duration_ms` is NULL. A filter on the duration alone gave it away free.
    // `credit.test.ts`'s `a cancelled screen-control iteration really does write a row of this
    // shape` is what proves the row is reachable rather than invented here.
    await insert(
      event({ sessionId: "cancelled-session", sessionIteration: 1, provider: null,
              outcome: "client_cancelled", upstreamDurationMs: null }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 1,
      pixels: 1_000_000,
    });

    // And the exclusion it must not take with it: a cancellation that arrived BEFORE any provider
    // call is `refused`, not `client_cancelled` (`outcomeFor` takes exactly that branch), and it
    // still draws nothing.
    await client.query("TRUNCATE sonny.metering_event");
    await insert(
      event({ sessionId: "cancelled-early", sessionIteration: 1, provider: null,
              outcome: "refused", upstreamDurationMs: null }),
    );
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 0,
      iterations: 0,
      pixels: 0,
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
    await backDateAllTo(new Date(periodStart(at).getTime() - 1));
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

  itUnderHangBackstop("excludes the very first instant of the next period", async () => {
    // **PR #182's review, F4.** The arm above back-dates to 23:59:59.999, comfortably inside the
    // window, so it holds that an OLD row is excluded and says nothing about which side of `until`
    // the boundary falls on. `occurred_at < $4` is exclusive, and an inclusive one would count
    // midnight UTC on the 1st into the period that just closed — a real answer to give a user, at
    // the one moment they are most likely to look.
    await insert(event({ sessionId: "next-period", sessionIteration: 1 }));
    await backDateAllTo(periodEnd(at));
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 0,
      iterations: 0,
      pixels: 0,
    });

    // One millisecond earlier is the last instant this period owns, and it is counted — so the zero
    // above is a boundary and not a query matching nothing.
    await backDateAllTo(new Date(periodEnd(at).getTime() - 1));
    expect(await readScreenControlDraw(client, window())).toEqual({
      sessions: 1,
      iterations: 1,
      pixels: 1_000_000,
    });

    // And the lower bound is inclusive: the period's own first instant belongs to it.
    await backDateAllTo(periodStart(at));
    expect((await readScreenControlDraw(client, window())).iterations).toBe(1);
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
