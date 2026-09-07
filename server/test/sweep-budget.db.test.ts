import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect } from "vitest";
import { deferralsAfter, sweepExpiredContent, sweepOnce } from "../src/content/expiry.js";
import { contentExpiryFrom, type RetainedContent } from "../src/content/record.js";
import { insertRetainedContent } from "../src/content/store.js";
import { pooledConnections } from "../src/db/pool.js";
import { itUnderHangBackstop, beforeAllUnderHangBackstop, afterAllUnderHangBackstop, beforeEachUnderHangBackstop } from "./support/backstop.js";
import { rebuildSchema } from "./support/schema.js";

/**
 * The content sweep against the pool's own bound (SONNY-427, PR #223's F2).
 *
 * **The harness this rebuilds is the reviewer's.** `db/pool.ts` bounds every statement on the
 * gateway's pool at §12's `auth.upstream`, and the closed-account sweep leases from that pool while
 * deleting a whole account in a fixed sequence with no `LIMIT` in it. Under a bound smaller than
 * that delete the review measured four consecutive passes that each threw `57014` having removed
 * nothing, while a control converged in two — and because the account is chosen
 * `ORDER BY a.deleted_at LIMIT 1`, the one that cannot be deleted is permanently the oldest and
 * every account closed after it queues behind it for ever.
 *
 * Two properties, and they fail independently: the sweep converges under a route-sized bound because
 * it carries a budget of its own, and an account it cannot take stops obstructing the ones behind
 * it.
 *
 * Skips without `DATABASE_URL`, like every other `*.db.test.ts`.
 */

const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const OLDEST = "2c2d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7801";
const NEWER = "2c2d0c8e-1c5a-4a9f-9f6b-2b6f5f2a7802";

/**
 * The pool bound these tests run against, standing in for §12's 10 000 ms so a test costs
 * milliseconds.
 *
 * **What makes an account's delete exceed it is a lock rather than a row count, and that is a
 * measurement rather than a convenience.** A whole-account `DELETE` is cheap however big the account
 * is — Postgres marks tuples dead and leaves the TOAST to `VACUUM` — so at this container's sizes it
 * costs **1 ms at 400 rows of 4 KiB, 2 ms at 64 KiB and 8 ms at 256 KiB** (100 MB of content),
 * measured before these tests were written. Making it slow by volume would need a table nobody wants
 * to build in a suite. What does make it slow is exactly what `statement_timeout` is here to bound
 * and what `server/README.md` names as this gateway's real case: **time queued behind another
 * connection's lock**, which the timeout counts.
 */
const ROUTE_SIZED_BOUND_MS = 20;

/** Rows per account. Small, because the lock rather than the volume is what stalls the delete. */
const ROWS = 20;

/**
 * How long the convergence test lets the stalled pass run before it accepts that the pass is
 * *waiting* rather than *cancelled*.
 *
 * A hundred times `ROUTE_SIZED_BOUND_MS`, which is what a sweep with no budget of its own would have
 * died at, and a fiftieth of `SWEEP_STATEMENT_TIMEOUT_MS`, which is the budget it carries — so it
 * cannot be reached by accident from either side. It is spent on the passing path, which is what two
 * seconds of a database suite buys here.
 */
const STALL_PROOF_MS = 2_000;

function content(accountId: string, overrides: Partial<RetainedContent> = {}): RetainedContent {
  return {
    requestId: randomUUID(),
    accountId,
    taskId: "task-1",
    sessionId: "session-1",
    sessionIteration: 1,
    route: "screen.analyze",
    retention: "standard",
    expiresAt: contentExpiryFrom(new Date(), 30),
    provider: "vision",
    providerRequestId: "req_1",
    requestText: "Decide the next action.",
    voiceAudio: null,
    voiceAudioMediaType: null,
    voiceAudioFilename: null,
    screenshot: Buffer.alloc(4096, 7),
    screenshotMediaType: "image/jpeg",
    responseStatus: 200,
    responseContentType: "application/json",
    responseBody: Buffer.from('{"ok":true}'),
    occurredAt: new Date(),
    ...overrides,
  } as RetainedContent;
}

describeDb("the content sweep under the pool's statement bound", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => {
    await client.end();
  });
  beforeEachUnderHangBackstop(async () => {
    await client.query("DELETE FROM sonny.retained_content WHERE account_id = ANY($1::uuid[])", [
      [OLDEST, NEWER],
    ]);
    await client.query("DELETE FROM sonny.content_deletion WHERE account_id = ANY($1::uuid[])", [
      [OLDEST, NEWER],
    ]);
    await client.query("DELETE FROM sonny.account WHERE id = ANY($1::uuid[])", [[OLDEST, NEWER]]);
    // Closed, oldest first, which is the order the sweep takes them in.
    await client.query(
      `INSERT INTO sonny.account (id, deleted_at) VALUES ($1, now() - interval '2 days'),
                                                        ($2, now() - interval '1 day')`,
      [OLDEST, NEWER],
    );
  });

  const rowsFor = async (accountId: string): Promise<number> => {
    const { rows } = await client.query<{ n: string }>(
      "SELECT count(*)::text AS n FROM sonny.retained_content WHERE account_id = $1",
      [accountId],
    );
    return Number(rows[0]!.n);
  };

  const fill = async (accountId: string, rows: number): Promise<void> => {
    for (let i = 0; i < rows; i += 1) await insertRetainedContent(client, content(accountId));
  };

  itUnderHangBackstop("fourPassesConvergeWhenTheRouteBoundIsSmallerThanTheAccountsDelete", async () => {
    await fill(OLDEST, ROWS);

    const wiring = pooledConnections(url!, { statementTimeoutMillis: ROUTE_SIZED_BOUND_MS });
    const holder = new pg.Client({ connectionString: url });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("SELECT 1 FROM sonny.retained_content WHERE account_id = $1 FOR UPDATE", [
        OLDEST,
      ]);

      // **The control, on the same pool the sweep will use, run first.** It issues the account's own
      // whole-account `DELETE` with no budget of its own and requires Postgres to cancel it. Without
      // it the assertions below could pass because the delete was cheap rather than because the
      // sweep carries a budget — the reading that would agree just as warmly with the defect still
      // present. It also proves the lock is really held, so nothing after it is guesswork.
      const control = await wiring.withConnection(async (c) => {
        await c.query("BEGIN");
        try {
          await c.query("DELETE FROM sonny.retained_content WHERE account_id = $1", [OLDEST]);
          return "completed";
        } catch (error) {
          return (error as { code?: string }).code ?? "unknown";
        } finally {
          await c.query("ROLLBACK").catch(() => {});
        }
      });
      expect(
        control,
        "the pool's bound did not stop this account's delete, so nothing below is a measurement",
      ).toBe("57014");
      expect(await rowsFor(OLDEST)).toBe(ROWS);

      // **Pass 1 is the discriminating one, and what discriminates is which of two things happens
      // first.** Under the fix the sweep carries its own budget, so it queues behind the lock and is
      // still queued when the lock lifts. Under a sweep running at the pool's bound it is cancelled
      // at that bound and the pass is over — with nothing deleted — while the lock is still held.
      // So the assertion names the winning branch rather than checking a status afterwards, which is
      // the only shape that tells the two apart: eventual convergence cannot, because once the lock
      // lifts a later pass succeeds either way.
      //
      // **The wait is reached on the healthy path and is a bound rather than a threshold.** It is
      // `STALL_PROOF_MS` — a hundred times the pool bound the sweep would have died at, and a
      // fiftieth of the budget it actually carries — so both directions have two orders of magnitude
      // of margin, and the way it can be wrong is a false *failure* on the clean tree rather than a
      // mutant reading as caught.
      const firstPass = sweepOnce(wiring);
      const raced = await Promise.race([
        firstPass.then(() => "settled while the lock was still held"),
        new Promise<string>((resolve) =>
          setTimeout(() => resolve("still waiting for the lock"), STALL_PROOF_MS).unref(),
        ),
      ]);
      expect(
        raced,
        "the sweep gave up while the lock was held: it is running at the pool's bound, not its own",
      ).toBe("still waiting for the lock");

      // Only now, with the sweep proved to be waiting rather than cancelled, does the lock lift.
      await holder.query("ROLLBACK");

      const passes: string[] = [describePass(await firstPass)];
      for (let pass = 2; pass <= 4; pass += 1) passes.push(describePass(await sweepOnce(wiring)));

      // **The property.** Not merely that four passes converge — under the defect the lock lifts
      // after pass 1 and passes 2 to 4 would converge too, so eventual convergence cannot tell the
      // two apart. What can is that the pass which met the stall is the pass that did the work.
      expect(passes[0], `four passes: ${passes.join(" | ")}`).toBe(`rows=${ROWS} failed=none`);
      expect(passes.slice(1)).toEqual([
        "rows=0 failed=none",
        "rows=0 failed=none",
        "rows=0 failed=none",
      ]);
      expect(await rowsFor(OLDEST)).toBe(0);
    } finally {
      await holder.query("ROLLBACK").catch(() => {});
      await holder.end();
      await wiring.close();
    }
  });

  itUnderHangBackstop("anAccountTheSweepCannotTakeStopsBlockingTheOnesBehindIt", async () => {
    await fill(OLDEST, ROWS);
    await fill(NEWER, 2);

    // The oldest account's rows are locked by another transaction, so its `DELETE` cannot proceed —
    // the shape a real stall has, and the one a bigger budget alone cannot fix. The sweep runs on a
    // client whose bound is set here rather than by `sweepOnce`, so the stall resolves in
    // milliseconds instead of at the sweeper's real budget.
    const holder = new pg.Client({ connectionString: url });
    await holder.connect();
    try {
      await holder.query("BEGIN");
      await holder.query("SELECT 1 FROM sonny.retained_content WHERE account_id = $1 FOR UPDATE", [
        OLDEST,
      ]);

      await client.query(`SET statement_timeout TO ${ROUTE_SIZED_BOUND_MS}`);
      let deferred: ReadonlySet<string> = new Set();

      const first = await sweepExpiredContent(client, [...deferred]);
      expect(first.closedAccountFailure?.accountId).toBe(OLDEST);
      expect(first.closedAccountId).toBeUndefined();
      deferred = deferralsAfter(deferred, first);
      expect([...deferred]).toEqual([OLDEST]);

      // **The property.** With the oldest deferred, the pass behind it moves. Under the shipped
      // ordering the same account is selected again for ever and this account is never reached.
      const second = await sweepExpiredContent(client, [...deferred]);
      expect(second.closedAccountId).toBe(NEWER);
      expect(second.closedAccountRows).toBe(2);
      expect(await rowsFor(NEWER)).toBe(0);
      expect(await rowsFor(OLDEST)).toBe(ROWS);

      // And once nothing else is left, the deferral is released rather than becoming permanent.
      const third = await sweepExpiredContent(client, [...deferred]);
      expect(third.closedAccountId).toBeUndefined();
      expect([...deferralsAfter(deferred, third)]).toEqual([]);
    } finally {
      await client.query("RESET statement_timeout").catch(() => {});
      await holder.query("ROLLBACK").catch(() => {});
      await holder.end();
    }
  });

  itUnderHangBackstop("theSweepersBudgetIsPutBackSoTheConnectionReturnsBoundedByThePool", async () => {
    // The sweep sets a session bound on a connection it shares with every route. If it did not put
    // it back, the next lessee would run under 105 s instead of §12's 10 s — which is why the pool's
    // value arrives in the startup packet, so a `RESET` returns to it rather than to no bound.
    const wiring = pooledConnections(url!, { max: 1 });
    try {
      await sweepOnce(wiring);
      const after = await wiring.withConnection(async (c) => {
        const { rows } = await c.query<{ setting: string; source: string }>(
          "SELECT setting, source FROM pg_settings WHERE name = 'statement_timeout'",
        );
        return rows[0]!;
      });
      expect(after).toEqual({ setting: "10000", source: "client" });
    } finally {
      await wiring.close();
    }
  });
});

/** One line per pass, so a failure message says what four passes actually did. */
function describePass(result: Awaited<ReturnType<typeof sweepOnce>>): string {
  if (result === undefined) return "skipped";
  return `rows=${result.closedAccountRows} failed=${result.closedAccountFailure?.accountId ?? "none"}`;
}

