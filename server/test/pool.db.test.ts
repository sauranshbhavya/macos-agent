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
    // No `connectionTimeoutMillis`, deliberately — see the note on the third test below. One lease
    // against an empty pool contends with nothing, so a deadline here could only ever fire because
    // the machine was slow to open a socket, which is a statement about the machine.
    const wiring = pooledConnections(url!, { max: 1 });
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
    //
    // **So this deadline stays, and it is the one place in this file where it must** (SONNY-381).
    // The other two tests dropped theirs because no assertion of theirs rested on one; here the
    // deadline *is* the oracle — without it a leaked connection is an unbounded wait, which the hang
    // backstop would report in wording `scripts/mutate-untrusted-failures` declares, turning a real
    // kill into UNATTRIBUTED. That is SONNY-315's manufactured NON-kill, and it is the failure this
    // file would trade its way into by making all three consistent. The residual cost is honest: a
    // machine slow enough to spend two seconds opening one socket can fail this test for a reason
    // that is not a leak. That has not been observed, and the alternative loses the property.
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
    // **No `connectionTimeoutMillis`, and that is the fix for SONNY-381.** A pool of two serving two
    // concurrent leases contends with nothing — the deadline is never the oracle for anything this
    // test asserts, and the only thing that can trip it is a slow socket on a busy machine. That is
    // precisely `CLAUDE.md`'s banned shape: a threshold the test races, whose failure `scripts/mutate`
    // cannot tell from a mutant being caught. It manufactured exactly that on 2026-08-31 — mutant P4
    // of SONNY-212's battery (`round` in `credit/balance.ts` replaced by the identity function) was
    // reported KILLED by this test alone, and re-run with `--only P4` against the same tree it
    // SURVIVED. A connection-pool test cannot say anything about whether credit figures are rounded,
    // and that mutant was hiding a real coverage hole, so the false kill concealed a real finding.
    //
    // What bounds the test now is `itUnderHangBackstop`, which is the one wall-clock construct that
    // may bound a test here: it cannot be reached except by a genuine failure, and its wording is
    // declared in `scripts/mutate-untrusted-failures`, so a machine that is merely busy reports
    // UNATTRIBUTED rather than a kill. Understating coverage is the safe direction; manufacturing it
    // is not. The second test above keeps its deadline for the opposite reason, recorded there.
    const wiring = pooledConnections(url!, { max: 2 });
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
