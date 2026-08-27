import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import type pg from "pg";
import { pooledConnections } from "../src/db/pool.js";

/**
 * The two properties `db/pool.ts` exists for, each pinned by the test that kills its mutant
 * (PR #137 review, F6 — both mutants survived the suite as first written).
 *
 * **Why a fake pool rather than a real Postgres.** The release-on-throw property is testable either
 * way and is tested both ways — `pool.db.test.ts` drives it against a real `pg.Pool` with `max: 1`,
 * which is the stronger evidence. The idle-client-error property is not: producing one against a
 * real backend means terminating it from a second connection and then waiting for an event on a
 * timer, which is exactly the sleep-then-assert shape `CLAUDE.md` records as manufacturing mutation
 * kills. Emitting the event is deterministic and tests the same line.
 */

/** The smallest thing that behaves like the part of `pg.Pool` this module touches. */
class FakePool extends EventEmitter {
  readonly leased: FakeClient[] = [];
  ended = 0;
  connectRejectsWith: Error | undefined;

  async connect(): Promise<FakeClient> {
    if (this.connectRejectsWith) throw this.connectRejectsWith;
    const client = new FakeClient();
    this.leased.push(client);
    return client;
  }

  async end(): Promise<void> {
    this.ended += 1;
  }
}

class FakeClient {
  released = 0;
  release(): void {
    this.released += 1;
  }
}

function pooled(options: { max?: number } = {}): {
  wiring: ReturnType<typeof pooledConnections>;
  pool: FakePool;
} {
  const pool = new FakePool();
  // The allowlisted local-development shape, and it is never dialled — `FakePool.connect` ignores
  // it entirely. `npm run check:secrets` refuses any other DSN carrying a password, correctly: a
  // connection string with credentials is exactly what that pattern hunts, and it caught this file
  // on the first run after it was committed. Second time this branch has been caught by the
  // scanner's tracked-files population, which is the gotcha its own changelog entry records.
  const wiring = pooledConnections("postgres://postgres:postgres@localhost:1/db", {
    ...options,
    createPool: () => pool as unknown as pg.Pool,
  });
  return { wiring, pool };
}

describe("pooledConnections leases and returns a connection", () => {
  it("releases the connection when the callback returns", async () => {
    const { wiring, pool } = pooled();
    const answer = await wiring.withConnection(async () => "done");
    expect(answer).toBe("done");
    expect(pool.leased).toHaveLength(1);
    expect(pool.leased[0]!.released).toBe(1);
  });

  it("theConnectionIsReleasedWhenTheCallbackThrows — the `finally`, and the mutant that removed it", async () => {
    // **This is the property `db/connection.ts` calls structural**, and the whole reason
    // `withConnection` replaced a `db: () => Promise<pg.Client>` with no release: "the callback gets
    // a connection nobody else is using, and it is released on the way out **whether the callback
    // threw or not**". Deleting the `finally` leaves every failing request leaking a connection —
    // and since a route's failures are the unusual path, a pool of ten drains only under the
    // conditions nobody is watching. Nothing in the suite noticed until this test.
    const { wiring, pool } = pooled();
    const boom = new Error("the callback failed");
    await expect(wiring.withConnection(async () => Promise.reject(boom))).rejects.toBe(boom);
    expect(pool.leased).toHaveLength(1);
    expect(pool.leased[0]!.released).toBe(1);
  });

  it("releases exactly once per lease across a mix of outcomes", async () => {
    // A `finally` that also ran on the success path twice would double-release, which `pg` treats as
    // an error rather than a no-op. Counting rather than asserting truthiness is what catches it.
    const { wiring, pool } = pooled();
    await wiring.withConnection(async () => 1);
    await wiring.withConnection(async () => Promise.reject(new Error("x"))).catch(() => undefined);
    await wiring.withConnection(async () => 2);
    expect(pool.leased).toHaveLength(3);
    expect(pool.leased.map((client) => client.released)).toEqual([1, 1, 1]);
  });

  it("propagates a failure to lease at all rather than swallowing it", async () => {
    // `connectionTimeoutMillis` exists so a database that has gone away produces an error instead of
    // a hang; that is worth nothing if the error is caught here.
    const { wiring, pool } = pooled();
    pool.connectRejectsWith = new Error("timeout exceeded when trying to connect");
    await expect(wiring.withConnection(async () => 1)).rejects.toThrow("timeout exceeded");
  });
});

describe("pooledConnections survives an idle client's error", () => {
  it("theIdleClientErrorIsHandled — without this listener the process dies", async () => {
    // **`pg` emits `error` on the pool when an *idle* client fails**, with no request in flight to
    // attach it to — which every managed Postgres causes by closing idle connections, and causes to
    // all of them at once during a database deploy. An unhandled `error` event on an `EventEmitter`
    // is `ERR_UNHANDLED_ERROR`: the gateway dies, from an event whose correct handling is to log it
    // and let the pool replace the connection.
    //
    // The mutant is deleting `pool.on("error", …)`. **How it dies here is not how it would die in
    // production, and this comment claimed otherwise** (PR #137 review, N3): it said the mutant takes
    // the test process down with it. Measured, it does not — `FakePool` is a bare `EventEmitter` and
    // the emit below is synchronous inside the test body, so the throw lands in vitest's own frame
    // and is reported as `AssertionError: expected [Function] to not throw an error but 'Error:
    // Connection terminated unexpect…' was thrown`. **2 failed, 237 passed, every file ran, no
    // `ERR_UNHANDLED_ERROR` and no dead worker.** The `expect(...).not.toThrow()` below is what
    // converts it into an ordinary red test, and it is the reason this is a clean kill rather than
    // the evidence-destroying trap `CLAUDE.md` describes.
    //
    // The process death is real against a **live** `pg.Pool`, where the emit comes off a socket with
    // no test frame on the stack: an unhandled `error` on an `EventEmitter` is `ERR_UNHANDLED_ERROR`
    // and the gateway exits. That is the failure this listener exists to prevent, and it is what the
    // production consequence would be — but this test does not demonstrate it, and saying it did was
    // a claim about a mutant's death written inside the test that kills it.
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      const { pool } = pooled();
      expect(() => pool.emit("error", new Error("Connection terminated unexpectedly"))).not.toThrow();
      expect(stderr).toHaveBeenCalledTimes(1);
      const written = String(stderr.mock.calls[0]![0]);
      expect(written).toContain("postgres pool");
      expect(written).toContain("Connection terminated unexpectedly");
    } finally {
      stderr.mockRestore();
    }
  });

  it("keeps serving after an idle client's error, which is the point of not dying", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      const { wiring, pool } = pooled();
      pool.emit("error", new Error("Connection terminated unexpectedly"));
      await expect(wiring.withConnection(async () => "still here")).resolves.toBe("still here");
    } finally {
      stderr.mockRestore();
    }
  });
});

describe("pooledConnections closes", () => {
  it("ends the pool once however many times close is called", async () => {
    // Two signals in quick succession reach this, and `pg.Pool.end()` rejects on a second call.
    const { wiring, pool } = pooled();
    await wiring.close();
    await wiring.close();
    expect(pool.ended).toBe(1);
  });
});
