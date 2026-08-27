import pg from "pg";
import type { WithConnection } from "./connection.js";

/**
 * The pool-backed `WithConnection` the running gateway uses (SONNY-307).
 *
 * `connection.ts` argues the *shape*: a callback gets a connection nobody else is using and it is
 * released on the way out, so `resolve()`'s "one transaction" is a real transaction rather than a
 * `BEGIN` nested inside whatever else was open on a shared client. It then says "a pool
 * implementation is now the natural one to write". This is that implementation, and until this file
 * every implementation in the tree was a test's.
 *
 * **In its own file rather than beside the type**, deliberately: `db/connection.ts` is a type
 * declaration two lanes import, and a new file cannot conflict with a branch running in parallel.
 */

/** Tunables, all with reasons. Nothing here reads the environment; `deps.ts` owns that. */
export interface PoolOptions {
  /**
   * Connections in the pool. Ten.
   *
   * The gateway checks a connection out **once at a time per request** and never nests: `gate.ts`
   * takes one to attribute the caller and releases it before the handler runs, then the handler
   * takes its own. That is what its docstring means by "never holds two at once, which is what keeps
   * a small pool from deadlocking against itself" — a property this number depends on, so a future
   * route that calls `withConnection` inside another must raise this or, better, not do that.
   */
  readonly max?: number;
  /**
   * How long to wait for a free connection before failing the request. Five seconds.
   *
   * **Without this `pg` waits forever**, so a database that has gone away turns every request into a
   * hang: no error, no 500, no log line, just sockets accumulating until the process is killed. A
   * timeout converts that into an error the route can answer with, which is the same reasoning
   * `supabase.ts` gives for bounding every provider call.
   */
  readonly connectionTimeoutMillis?: number;
  /** How long an unused connection is kept. Thirty seconds — enough to survive ordinary bursts. */
  readonly idleTimeoutMillis?: number;
}

export interface PooledConnections {
  readonly withConnection: WithConnection;
  /** Drain on shutdown. Safe to call twice; the second call resolves immediately. */
  readonly close: () => Promise<void>;
}

/**
 * A pool over `connectionString`, and the `withConnection` that leases from it.
 *
 * **SSL is entirely the connection string's** — `sslmode=require` and friends, which `pg` parses.
 * Nothing here constructs an `ssl` object, and in particular nothing sets `rejectUnauthorized:
 * false`: a hosted Postgres reached over the public internet with certificate verification disabled
 * is an encrypted channel to whoever answered, which is the failure TLS exists to prevent. If a host
 * needs a CA, it belongs in the URL or the environment, never in a default here.
 */
export function pooledConnections(
  connectionString: string,
  options: PoolOptions = {},
): PooledConnections {
  const pool = new pg.Pool({
    connectionString,
    max: options.max ?? 10,
    connectionTimeoutMillis: options.connectionTimeoutMillis ?? 5_000,
    idleTimeoutMillis: options.idleTimeoutMillis ?? 30_000,
  });

  /**
   * **An idle client's error is emitted on the pool, and an unhandled `error` event on an
   * `EventEmitter` takes the process down.** `pg` documents this: a backend that closes an idle
   * connection — which every managed Postgres does, and which a deploy of the database does to all
   * of them at once — raises `error` on the pool with no request in flight to attach it to. Left
   * unhandled that is `ERR_UNHANDLED_ERROR` and a dead gateway, from an event whose correct handling
   * is to log it and let the pool replace the connection.
   *
   * Logged to stderr rather than through Fastify's logger: this fires with no request, and wiring
   * the app's logger in here would make the pool depend on the server it is built before.
   */
  pool.on("error", (error: Error) => {
    process.stderr.write(`postgres pool: idle client error: ${error.name}: ${error.message}\n`);
  });

  let closed = false;
  return {
    withConnection: async <T>(fn: (client: pg.Client) => Promise<T>): Promise<T> => {
      const client = await pool.connect();
      try {
        // `PoolClient` is a `Client` with `release`; the callback is handed the `Client` interface
        // deliberately, so nothing downstream can release a connection it did not lease.
        return await fn(client as unknown as pg.Client);
      } finally {
        // Released whether the callback returned or threw -- the property `connection.ts` calls
        // structural. A `finally` is what makes it so.
        client.release();
      }
    },
    close: async (): Promise<void> => {
      if (closed) return;
      closed = true;
      await pool.end();
    },
  };
}
