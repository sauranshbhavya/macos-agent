import type pg from "pg";

/**
 * A connection **checked out for the caller alone**, and returned when the caller is done.
 *
 * **The previous shape was `db: () => Promise<pg.Client>` with no release, and it made a guarantee
 * this code depends on unenforceable** (PR #87 R4). A pool-backed implementation of that signature
 * leaks a connection per request, so the only implementation that worked was one shared `Client` —
 * and under a shared client `resolve()`'s "one transaction" is false: its `BEGIN` nests inside
 * whatever else is open on that connection, and one `COMMIT` commits both. Every test used a shared
 * client, so the property was never exercised, only assumed.
 *
 * `withConnection` makes the contract structural: the callback gets a connection nobody else is
 * using, and it is released on the way out whether the callback threw or not. A pool implementation
 * is now the natural one to write, and a shared-client implementation is the awkward one.
 *
 * **Moved here from `routes/auth.ts` by SONNY-203**, unchanged. The authenticated-route gate takes a
 * connection to attribute its caller, and a middleware importing its own dependency type out of a
 * route module is the wrong direction for that dependency to point.
 */
export type WithConnection = <T>(fn: (client: pg.Client) => Promise<T>) => Promise<T>;
