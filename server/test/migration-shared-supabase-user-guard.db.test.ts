import pg from "pg";
import { describe, expect } from "vitest";
import { resolve } from "../src/auth/identity.js";
import { down, up } from "../src/db/migrate.js";
import { rebuildSchema } from "./support/schema.js";
import {
  afterAllUnderHangBackstop, beforeAllUnderHangBackstop, itUnderHangBackstop,
} from "./support/backstop.js";

/**
 * Migration 0023's guard: it refuses to apply while any Supabase user backs two live accounts
 * (SONNY-129).
 *
 * **Why the guard exists at all.** Two live accounts naming one `supabase_user_id` is the lockout
 * SONNY-129 found — `accountForSupabaseUser` answers `ambiguous` and every token for that user is
 * refused, with no route able to recover it. Both sign-in routes now refuse to create that state, and
 * nothing should already be in it, because no route that could produce it was ever served; but
 * "should" is not a measurement. The migration is the one thing that runs against every database this
 * gateway has, so applying it is the measurement that the state is absent there.
 *
 * **A file of its own, and its name says migrations**, because it has to drive `down()` and `up()` —
 * the state it tests is only reachable by rolling 0023 back — and `schema.test.ts` lets only a suite
 * about migrations reach the runner. `oauth.db.test.ts` holds everything else SONNY-129 pins.
 */
const url = process.env["DATABASE_URL"];
const describeDb = url ? describe : describe.skip;

const USER_A = "a1a1a1a1-0000-4000-8000-000000000001";

describeDb("migration 0023's guard", () => {
  let client: pg.Client;

  beforeAllUnderHangBackstop(async () => {
    client = new pg.Client({ connectionString: url });
    await client.connect();
    await rebuildSchema(client);
  });
  afterAllUnderHangBackstop(async () => { await client.end(); });

  itUnderHangBackstop("refuses to apply while any Supabase user backs two live accounts, and applies once it does not", async () => {
    // Rolled back to 0022, the broken state seeded — the only way to reach it now — and forward again.
    expect(await down(client)).toBe("0024_a_task_lives_on_the_gateway");
    expect(await down(client)).toBe("0023_the_gate_honours_only_sessions_the_gateway_started");
    try {
      const one = await resolve(client, {
        provider: "email", subject: "one@example.com", email: "one@example.com", emailVerified: true, supabaseUserId: USER_A,
      });
      await resolve(client, {
        provider: "email", subject: "two@example.com", email: "two@example.com", emailVerified: true, supabaseUserId: USER_A,
      });
      await expect(up(client)).rejects.toThrow(/backs two live accounts/);
      // Nothing half-applied: the table is still absent.
      const table = await client.query("SELECT to_regclass('sonny.gateway_session') AS t");
      expect(table.rows[0].t).toBeNull();

      // Resolve the state — close one of the two accounts — and the same migration applies.
      await client.query("UPDATE sonny.account SET deleted_at = now() WHERE id = $1", [one.accountId]);
      expect(await up(client)).toEqual([
        "0023_the_gate_honours_only_sessions_the_gateway_started",
        "0024_a_task_lives_on_the_gateway",
      ]);
    } finally {
      // Whatever happened above, leave the schema at its head for the tests after this one.
      await client.query("TRUNCATE sonny.identity, sonny.account CASCADE");
      if ((await client.query("SELECT to_regclass('sonny.agent_task') AS t")).rows[0].t === null) {
        await up(client);
      }
    }
  });
});
