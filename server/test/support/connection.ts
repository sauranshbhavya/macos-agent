import type pg from "pg";
import type { WithConnection } from "../../src/db/connection.js";

/**
 * The gate's two reads, faked, for the suites that have no database and are not about the gate.
 *
 * **Eleven files held a byte-identical copy of this before SONNY-237**, differing only in the words
 * of the error message, and one of them mapping two users to two accounts. Each answered
 * `accountForSupabaseUser` and threw on anything else — which is the right shape and is why the
 * duplication was survivable: a query the suite did not expect fails loudly rather than returning a
 * plausible row. What made eleven copies stop being survivable is the gate growing a *second* read.
 * Adding the denylist consult turned every one of them into an `unexpected query` and eleven files
 * red at once, and the next read after it would do the same again.
 *
 * **The loudness is preserved and is the point.** Anything that is neither of the gate's two queries
 * still throws, naming the suite, so a route reaching for the database through this fake is a
 * failure rather than an empty result set. The `where` argument is that message's subject and is why
 * it is required rather than defaulted.
 */
export interface SignedInConnectionOptions {
  /**
   * Which account a Supabase user id attributes to. A bare string is every caller; a function is for
   * a suite that signs two callers in — `idempotency.test.ts` is the one that does.
   */
  readonly account: string | ((supabaseUserId: unknown) => string);
  /** Names the suite in the `unexpected query` message, e.g. `"outside the billing store"`. */
  readonly where: string;
  /**
   * Provider-side session ids this fake reports as denylisted (SONNY-237). Empty by default, which
   * is the state every suite but the gate's own denylist tests wants: nothing is signed out.
   */
  readonly revokedProviderSessions?: ReadonlySet<string>;
}

export function signedInConnectionTo(options: SignedInConnectionOptions): WithConnection {
  const revoked = options.revokedProviderSessions ?? new Set<string>();
  return async (work) => {
    const client = {
      query: async (text: string, values: readonly unknown[] = []) => {
        if (text.includes("FROM sonny.revoked_provider_session")) {
          return { rows: revoked.has(values[0] as string) ? [{ "?column?": 1 }] : [] };
        }
        if (!text.includes("FROM sonny.identity")) {
          throw new Error(`unexpected query ${options.where}: ${text}`);
        }
        const account =
          typeof options.account === "string" ? options.account : options.account(values[0]);
        return { rows: [{ account_id: account }] };
      },
    };
    return work(client as unknown as pg.Client);
  };
}
