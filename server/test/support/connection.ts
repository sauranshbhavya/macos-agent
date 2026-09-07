import type pg from "pg";
import type { WithConnection } from "../../src/db/connection.js";

/**
 * The three statements the auth path issues, faked, for the suites that have no database and are not
 * about the gate.
 *
 * **Eleven files held a byte-identical copy of this before SONNY-237**, differing only in the words
 * of the error message, and one of them mapping two users to two accounts. Each answered
 * `accountForSupabaseUser` and threw on anything else — which is the right shape and is why the
 * duplication was survivable: a query the suite did not expect fails loudly rather than returning a
 * plausible row. What made eleven copies stop being survivable is the gate growing a *second* read.
 * Adding the denylist consult turned every one of them into an `unexpected query` and eleven files
 * red at once, and the next read after it would do the same again.
 *
 * **Three statements and not two, and the third one is why this docstring changed** (PR #215's F3).
 * `revokeProviderSession` — what `POST /v1/auth/signout` writes — opens with
 * `WITH pruned AS (DELETE FROM sonny.revoked_provider_session …)`, so a dispatch keyed on the table
 * name alone matched the **write** as well as the consult and answered it with an empty result set.
 * Nothing was wrong in what any suite asserted; what was gone, silently and for exactly the newest
 * statement, was the loudness this fake exists for. Two of the eleven suites drive that path —
 * `authdeadlines.test.ts`'s sign-out deadline test and `entitlement.test.ts`'s. **Throwing on it
 * would be the wrong repair**: the sign-out legitimately writes now, so it gets a branch of its own
 * that says so, matched on the `INSERT` and tested before the consult because the write's own text
 * contains the consult's table name.
 *
 * **The loudness is preserved and is the point.** Anything that is none of those three still throws,
 * naming the suite, so a route reaching for the database through this fake is a failure rather than
 * an empty result set. The `where` argument is that message's subject and is why it is required
 * rather than defaulted.
 */
export interface SignedInConnectionOptions {
  /**
   * Which account a Supabase user id attributes to. A bare string is every caller; a function is for
   * a suite that signs two callers in — `idempotency.test.ts` is the one that does.
   */
  readonly account: string | ((supabaseUserId: unknown) => string);
  /** Names the suite in the `unexpected query` message, e.g. `"outside the billing store"`. */
  readonly where: string;
}

export function signedInConnectionTo(options: SignedInConnectionOptions): WithConnection {
  return async (work) => {
    const client = {
      query: async (text: string, values: readonly unknown[] = []) => {
        // **The write is tested first, and the order is load-bearing rather than tidy.** Its own
        // text contains `FROM sonny.revoked_provider_session` — that is the prune's `DELETE` — so a
        // consult-first dispatch answers the write as a consult and reports no rows, which is what
        // F3 found. Answered rather than thrown, because the sign-out route really does write here.
        if (text.includes("INSERT INTO sonny.revoked_provider_session")) {
          return { rows: [] };
        }
        // Nothing in these suites is signed out. A suite that wants a denylisted session drives the
        // gate through its own recorder — `denylist.test.ts` does, deliberately — because what such
        // a test asserts is which statements were issued rather than what they answered.
        if (text.includes("FROM sonny.revoked_provider_session")) {
          return { rows: [] };
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
