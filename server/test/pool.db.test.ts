import { describe, expect } from "vitest";
import { pooledConnections } from "../src/db/pool.js";
import { itUnderHangBackstop } from "./support/backstop.js";

/**
 * `pooledConnections` against a real `pg.Pool` and a real Postgres (PR #137 review, F6).
 *
 * **`pool.test.ts` pins the same release property against a fake pool and this file is not a
 * duplicate of it.** The fake proves the `finally` runs; this proves the thing the `finally` is
 * *for* — that the connection genuinely goes back and the next caller gets it. With `max: 1` a
 * leaked connection is not a slow leak here, it is the next lease failing, so the property is
 * observable rather than inferred.
 *
 * Skips without `DATABASE_URL`, like every other `*.db.test.ts`; the run announces that once,
 * loudly, from `global-setup.ts`.
 */

const url = process.env["DATABASE_URL"];

describe.skipIf(!url)("pooledConnections against a real Postgres", () => {
  itUnderHangBackstop("leases, returns a value, and gives the connection back", async () => {
    const wiring = pooledConnections(url!, { max: 1, connectionTimeoutMillis: 2_000 });
    try {
      const answer = await wiring.withConnection(async (client) => {
        const { rows } = await client.query<{ n: number }>("SELECT 1::int AS n");
        return rows[0]!.n;
      });
      expect(answer).toBe(1);
    } finally {
      await wiring.close();
    }
  });

  itUnderHangBackstop("theOnlyConnectionComesBackAfterTheCallbackThrows — with max 1 a leak is the next lease failing", async () => {
    // The real cost of a missing `finally`, made observable. The pool holds exactly one connection
    // and `connectionTimeoutMillis` is two seconds, so if the failed callback keeps it the second
    // lease cannot be served and this test fails with a timeout instead of passing. Nothing here
    // waits on a clock to decide the assertion: the second `withConnection` either gets a connection
    // or it does not.
    const wiring = pooledConnections(url!, { max: 1, connectionTimeoutMillis: 2_000 });
    try {
      const boom = new Error("the callback failed");
      await expect(wiring.withConnection(async () => Promise.reject(boom))).rejects.toBe(boom);

      const answer = await wiring.withConnection(async (client) => {
        const { rows } = await client.query<{ n: number }>("SELECT 2::int AS n");
        return rows[0]!.n;
      });
      expect(answer).toBe(2);
    } finally {
      await wiring.close();
    }
  });

  itUnderHangBackstop("gives each caller a connection nobody else is using, which is what makes a transaction one", async () => {
    // `db/connection.ts`'s whole argument: under a shared client `resolve()`'s BEGIN nests inside
    // whatever else is open on that connection and one COMMIT commits both. Two concurrent leases
    // from a pool of two must land on different backends.
    const wiring = pooledConnections(url!, { max: 2, connectionTimeoutMillis: 2_000 });
    try {
      const backendPid = async (): Promise<number> =>
        wiring.withConnection(async (client) => {
          const { rows } = await client.query<{ pid: number }>("SELECT pg_backend_pid() AS pid");
          return rows[0]!.pid;
        });
      const [first, second] = await Promise.all([
        wiring.withConnection(async (client) => {
          const { rows } = await client.query<{ pid: number }>("SELECT pg_backend_pid() AS pid");
          // Held while the other lease is taken, so the two cannot be the same backend.
          await client.query("SELECT pg_sleep(0.05)");
          return rows[0]!.pid;
        }),
        backendPid(),
      ]);
      expect(first).not.toBe(second);
    } finally {
      await wiring.close();
    }
  });
});
