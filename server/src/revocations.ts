import { pathToFileURL } from "node:url";
import pg from "pg";
import { owedRevocationCount } from "./auth/revocation.js";

/**
 * `npm run revocations` — what provider-side revocation is still owed, and for which accounts.
 *
 * **Why this exists as a command rather than as a background job** (PR #87 third round, F1). When
 * `DELETE /v1/account` cannot revoke an identity's provider-side sessions — a timeout, a provider
 * outage — the account still closes, and the debt is recorded as a NULL
 * `provider_session_revoked_at` on a closed identity. That record is what makes eventual completion
 * possible; it is not, by itself, eventual completion. Something has to look.
 *
 * The route drains its own account on the way through, which covers the ordinary case completely: a
 * provider that recovers within the same request is never seen. What it cannot cover is a provider
 * that is down for longer than one request, because the account is closed by then and no caller can
 * reach the route again — that is the shape of the defect this whole mechanism is for.
 *
 * **What this command does NOT do today, stated plainly: it does not revoke.** `drainOwedRevocations`
 * is written, exported and tested, and it needs an `AuthProvider` to call. **No concrete adapter
 * exists** — `provider.ts` is a seam with a test fake behind it, blocked on the same founder-owned
 * Resend/Supabase work as the rest of this ticket. So today this reports the debt and exits 1 when
 * there is any, which is a real operational signal a deployment can alert on. Wiring the drain to a
 * schedule is one call, and it belongs to the ticket that lands the adapter.
 */
export interface OwedByAccount {
  readonly accountId: string;
  readonly identities: number;
}

export async function owedByAccount(client: pg.Client): Promise<readonly OwedByAccount[]> {
  const { rows } = await client.query<{ account_id: string; n: number }>(
    `SELECT account_id, count(*)::int AS n
       FROM sonny.identity
      WHERE account_closed
        AND provider_session_revoked_at IS NULL
        AND supabase_user_id IS NOT NULL
      GROUP BY account_id
      ORDER BY account_id`,
  );
  return rows.map((row) => ({ accountId: row.account_id, identities: row.n }));
}

async function main(): Promise<void> {
  const url = process.env["DATABASE_URL"];
  if (!url) {
    process.stderr.write("DATABASE_URL is not set\n");
    process.exit(78);
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    const total = await owedRevocationCount(client);
    if (total === 0) {
      process.stdout.write("no provider-side revocation is owed\n");
      return;
    }
    // Account ids only. A provider-side user id names a person at the provider, and a report that
    // gets pasted into a chat window should not carry one.
    process.stdout.write(`${total} provider-side revocation(s) owed:\n`);
    for (const row of await owedByAccount(client)) {
      process.stdout.write(`  account ${row.accountId}  ${row.identities} identity/identities\n`);
    }
    process.stdout.write(
      "\nThese accounts are closed and their provider-side sessions may still be live.\n" +
        "Draining them needs a real AuthProvider adapter, which does not exist yet.\n",
    );
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts`, where a
// template-string comparison made the whole command a silent no-op under any path with a space.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
