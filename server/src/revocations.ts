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
 * **What this command does NOT do today: it does not revoke — and the reason changed with SONNY-307**
 * (PR #137 review, F2). This paragraph used to say no concrete adapter existed and that the block was
 * the founder's Resend domain. Both are now wrong: `src/auth/supabase.ts` is a real adapter, and
 * Resend was never the blocker for anything here.
 *
 * What actually blocks it is one method. `drainOwedRevocations` calls `signOutAllForUser`, and the
 * operation that needs — revoke every session of user X, given X's id and no token of theirs — **is
 * not in Supabase Auth's API at all**: `/logout` derives the user from the caller's own bearer token,
 * and the whole `/admin/*` surface carries no session route. So the adapter raises
 * `ProviderUnavailable` there, on purpose, and the debt stays owed rather than being stamped as done.
 * **SONNY-313 holds the two ways to close it and the choice is a founder's.** Meanwhile this reports
 * the debt and exits 1 when there is any, which is a real operational signal a deployment can alert
 * on. Wiring the drain to a schedule is one call and belongs to whichever ticket that decision lands.
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
    // **This said "needs a real AuthProvider adapter, which does not exist yet" until SONNY-307**,
    // which is the branch that wrote one — an operator reading this would have gone off to build
    // something that was already in the tree beside it (PR #137 review, F2). The adapter exists; the
    // reason these cannot be drained is narrower and is a property of Supabase, so the operator is
    // pointed at the decision that unblocks it rather than at work already done.
    process.stdout.write(
      "\nThese accounts are closed and their provider-side sessions may still be live.\n" +
        "The Supabase adapter exists (src/auth/supabase.ts) and cannot drain these: Supabase Auth\n" +
        "exposes no endpoint that revokes a user's sessions from their id alone, so\n" +
        "signOutAllForUser fails and the debt is kept rather than written off.\n" +
        "SONNY-313 holds the two ways to close it, and the choice is a founder's:\n" +
        "  (a) delete the provider-side user, which takes its sessions with it, or\n" +
        "  (b) have the gateway mint a token for that user and sign it out globally.\n" +
        "Until one is chosen this count is expected to grow, and it is a real signal: every\n" +
        "line above is an account someone closed whose provider-side sessions are still live.\n",
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
