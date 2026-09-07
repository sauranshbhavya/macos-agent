import pg from "pg";
import { DEADLINE_MS } from "../model/limits.js";
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

/**
 * How long any one statement issued on this pool may run, in milliseconds — **contract §12's number
 * rather than a number chosen here** (SONNY-427).
 *
 * §12's last row is *auth, account, meta, health, delete* at 10 s upstream, 15 s total, 20 s at the
 * client, and every route whose slow work is the database sits in it. On a route with a provider,
 * `upstream` bounds the one external wait and the five seconds left over to `total` are the
 * handler's own margin. On these routes the **database statement is that one external wait**, so it
 * takes that row's `upstream` and leaves the same margin — which is the derivation, and is why this
 * reads `DEADLINE_MS.auth.upstream` instead of spelling `10_000`. A literal that matched the
 * contract would be indistinguishable from wiring and would stop matching the first time §12 moved;
 * PR #212's W9 is the worked example of that going wrong one layer up, in the adapter this same row
 * bounds.
 *
 * **Routes on the longer rows are held by this too, and lose nothing.** A model route's own budget
 * is 90 s or 60 s upstream, but its *database* work is the gate's attribution read, a metering
 * write, an idempotency claim — none of which is meant to approach ten seconds. A statement that
 * does has stopped by any route's standard.
 */
export const STATEMENT_TIMEOUT_MS = DEADLINE_MS.auth.upstream;

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
  /**
   * How long one statement may run before Postgres cancels it. `STATEMENT_TIMEOUT_MS` by default,
   * and injected only by tests that need a bound they can reach inside a test's patience.
   *
   * **A parameter here rather than a value each caller supplies**, unlike the adapter's `timeoutMs`
   * one layer up: there is exactly one spelling of this number in the tree — `DEADLINE_MS.auth`'s
   * `upstream` — and the default *is* the read of it, so there is no second spelling for a deleted
   * wiring to be reproduced from. What W9 forbids is a default that duplicates a literal a caller
   * passes; nothing passes this in production.
   */
  readonly statementTimeoutMillis?: number;
  /**
   * How the pool is constructed. Injected only by tests, the same seam and the same reason as
   * `SupabaseAuthConfig.fetch`.
   *
   * **The two properties below are why this exists** (PR #137 review, F6). Both — that a connection
   * is released when the callback *throws*, and that an idle client's error does not take the
   * process down — are invisible to a test that cannot reach the pool, and both had surviving
   * mutants. Testing them against a real Postgres is possible for the first and racy for the second:
   * making a backend fail while idle means terminating it from another connection and then waiting
   * on a timer for an event, which is the sleep-then-assert shape that manufactures kills. A pool
   * the test controls makes both deterministic.
   */
  readonly createPool?: (config: pg.PoolConfig) => pg.Pool;
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
  const create = options.createPool ?? ((config: pg.PoolConfig) => new pg.Pool(config));
  const pool = create({
    connectionString,
    max: options.max ?? 10,
    connectionTimeoutMillis: options.connectionTimeoutMillis ?? 5_000,
    idleTimeoutMillis: options.idleTimeoutMillis ?? 30_000,
    /**
     * **The one bound Postgres enforces rather than this process** (SONNY-427). `pg` sends it as a
     * session setting in the startup packet, so the backend cancels the statement itself and hands
     * the connection back usable, and the cancellation covers time spent *queued behind another
     * connection's lock* — which is the case this exists for, and the one `lock_timeout` would not
     * cover, bounding only the acquisition rather than the whole statement.
     *
     * **`pg`'s own `query_timeout` was the alternative and is the wrong tool.** That one is a
     * JavaScript timer: on expiry `client.js` errors the query, sets `query.callback = () => {}`
     * with the comment "just do nothing if query completes", and outside pipeline mode leaves the
     * socket alone — so the statement keeps running on the backend, still holding its locks, on a
     * connection that then goes back to the pool for the next lessee. That is PR #212's F1 one layer
     * lower: a deadline around work holding a database connection that abandons rather than ends it.
     *
     * **It has to arrive in the startup packet and not as a `SET` after connect, and that is the
     * one thing about this line a later simplification must not undo** (SONNY-428's neighbour). A
     * route may set its own bound on a connection it has leased — `model/routing.ts`'s
     * `withDatabaseDeadline` does, per statement, for the four content-deletion routes — and clears
     * it with `RESET statement_timeout` on the way out. `RESET` restores a parameter to its
     * *reset value*, which a startup parameter sets and a session `SET` does not. So the two shapes
     * differ in production and in nothing a casual test would show. Measured on `postgres:17`,
     * reading `setting`/`reset_val`/`source` from `pg_settings` around a route's `SET 15000` and its
     * `RESET`: from the startup packet, `10000/10000/client` -> `15000/10000/session` ->
     * `10000/10000/client`, the bound restored; from a `SET` after connect, `10000/0/session` ->
     * `15000/0/session` -> **`0/0/default`**, which is byte-identical to a connection that was never
     * bounded at all. The first content deletion on a connection would take the bound off it for
     * every later lessee.
     *
     * **How the two compose, since both are session settings and the last one wins in either
     * direction.** Measured the same way with a 600 ms stand-in for this bound and
     * `SELECT pg_sleep(5)` as the work: under the default alone it is cancelled at 614 ms; under a
     * route's larger `SET 2000` at 2008 ms; under a route's smaller `SET 150` at 154 ms; after each
     * `RESET`, at 602 ms again. The control — the same statement with no bound — completes in
     * 1018 ms, which is what makes the five cancellations readings rather than a probe that cancels
     * everything. So a route's own budget governs the statements it wraps, wider or narrower, and
     * this is what governs everywhere else: the gate's attribution read, which takes its own lease
     * before any handler runs, and every route that wraps nothing.
     *
     * **A `statement_timeout` in the connection string wins over this**, because
     * `ConnectionParameters` assigns the parsed string over the config it was given. Nothing in this
     * repository sets one, and `statement-timeout.db.test.ts` reads the *effective* setting off a
     * leased connection rather than trusting that this option took.
     */
    statement_timeout: options.statementTimeoutMillis ?? STATEMENT_TIMEOUT_MS,
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
