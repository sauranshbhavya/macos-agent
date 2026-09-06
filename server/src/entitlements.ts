import { pathToFileURL } from "node:url";
import pg from "pg";
import { publicKeyMaterial } from "./entitlement/claim.js";
import { entitlementSigningKeyFrom } from "./entitlement/claim.js";
import { staleWindowsBefore, sweep as sweepRateLimitWindows } from "./auth/ratelimit.js";
import {
  readEntitlement,
  readPeriodUsage,
  sweepExpiredReservations,
} from "./entitlement/store.js";

/**
 * `npm run entitlements` — read and set what an account is allowed, and reclaim orphaned holds
 * (SONNY-135).
 *
 * **A command and not a surface, and not a product decision either.** Row 13 owns account and plan
 * UI; SONNY-212 owns what the plans are. What is owed *here* is the ability to put an account into a
 * state and look at it — which is what makes the founder's manual items runnable at all, since
 * nothing else in the system writes `sonny.entitlement` yet. Every value it sets comes from the
 * command line; it invents no plan, no price and no allowance, and `grant` refuses to make one up.
 *
 * The same CLI shape as `revocations.ts` and `usage.ts`, down to the `pathToFileURL` guard, which
 * `db/migrate.ts`'s own comment explains: a template-string comparison makes the whole command a
 * silent no-op under any path containing a space, and this repository's checkouts live under such
 * paths.
 */

const USAGE = `Usage: npm run entitlements -- <command> [options]

Commands:
  show <account-id>          What this account is allowed, and what it has spent this period.
  grant <account-id>         Write or replace this account's entitlement row.
      --plan <key>             An opaque plan key. Required. Not a tier this repository defines.
      --capability <key>       A capability key. Repeatable. Omit for none.
      --cap <units>            This account's own per-period cap, in metered calls.
                               Omit to fall back to the deployment's SPEND_CAP_UNITS.
  revoke <account-id>        Mark the entitlement revoked. The next claim it mints carries no
                             capabilities; the row and its plan key are kept.
  restore <account-id>       Undo a revoke.
  sweep                      Reclaim every reservation whose request never came back, and delete
                             every rate-limit window nothing counts against any more. Says how
                             many of each. Safe to run on a timer; safe to run twice.
  public-key                 The public half of ENTITLEMENT_SIGNING_KEY, base64url, as a client's
                             shipped key set holds it. Prints no private material.

Reads DATABASE_URL, and ENTITLEMENT_SIGNING_KEY for public-key alone.
`;

export type ParsedEntitlementArguments =
  | {
      readonly kind: "show" | "revoke" | "restore";
      readonly command: "show" | "revoke" | "restore";
      readonly accountId: string;
    }
  | {
      readonly kind: "grant";
      readonly accountId: string;
      readonly plan: string;
      readonly capabilities: readonly string[];
      readonly capUnits: number | null;
    }
  | { readonly kind: "sweep" }
  | { readonly kind: "public-key" }
  | { readonly kind: "help" }
  | { readonly kind: "error"; readonly message: string };

/**
 * Parse `argv`.
 *
 * **A pure function so the parsing is testable without a database**, the same split `usage.ts` makes
 * and for the same reason. Every refusal names the offending argument: a `--cap` that is not a
 * number is a typo an operator can fix, and treating it as "no cap" would silently put the account
 * on the deployment's default while the operator believed they had set one.
 */
export function parseEntitlementArguments(argv: readonly string[]): ParsedEntitlementArguments {
  const first = argv[0];
  if (first === undefined || first === "--help" || first === "-h" || first === "help") {
    return { kind: "help" };
  }
  if (first === "sweep") return { kind: "sweep" };
  if (first === "public-key") return { kind: "public-key" };
  if (first !== "show" && first !== "grant" && first !== "revoke" && first !== "restore") {
    return { kind: "error", message: `unknown command ${JSON.stringify(first)}` };
  }
  const accountId = argv[1];
  if (accountId === undefined || accountId.startsWith("--")) {
    return { kind: "error", message: `${first} needs an account id` };
  }
  if (first !== "grant") return { kind: first, command: first, accountId };

  let plan: string | undefined;
  let capUnits: number | null = null;
  const capabilities: string[] = [];
  for (let index = 2; index < argv.length; index += 1) {
    const flag = argv[index]!;
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      return { kind: "error", message: `${flag} needs a value` };
    }
    index += 1;
    switch (flag) {
      case "--plan":
        plan = value;
        break;
      case "--capability":
        capabilities.push(value);
        break;
      case "--cap": {
        const units = Number(value);
        if (!Number.isInteger(units) || units < 0) {
          return { kind: "error", message: `--cap is not a whole number of units: ${value}` };
        }
        capUnits = units;
        break;
      }
      default:
        return { kind: "error", message: `unknown option ${JSON.stringify(flag)}` };
    }
  }
  // **Refused rather than defaulted.** A plan key this command chose would be a tier this repository
  // invented, which is the one thing the ticket's never-touch list names twice.
  if (plan === undefined) return { kind: "error", message: "grant needs --plan" };
  return { kind: "grant", accountId, plan, capabilities, capUnits };
}

export async function grant(
  client: pg.Client,
  input: {
    accountId: string;
    plan: string;
    capabilities: readonly string[];
    capUnits: number | null;
  },
): Promise<void> {
  await client.query(
    `INSERT INTO sonny.entitlement (account_id, plan, capabilities, cap_units, updated_at)
          VALUES ($1, $2, $3, $4, now())
     ON CONFLICT (account_id) DO UPDATE
        SET plan = excluded.plan,
            capabilities = excluded.capabilities,
            cap_units = excluded.cap_units,
            -- A grant clears a revocation: an operator writing a fresh plan onto a cancelled
            -- account means to restore it, and leaving revoked_at set would mint capability-less
            -- claims for an account the operator can see capabilities on.
            revoked_at = NULL,
            -- And it clears an outstanding payment failure, for the same reason one sentence
            -- further on (SONNY-380, PR #206's F2). A comped account is current by definition: the
            -- operator is the payer now, and nothing at the provider is going to resolve a failure
            -- recorded against a card the account is no longer being billed on. Leaving these set
            -- cost two things and the second is worse. paymentStateFor answers past_due, so the
            -- comped customer reads Past due with an Update payment button INDEFINITELY -- only a
            -- newer billing delivery clears the column, and for an account being comped one may
            -- never arrive. And claimFactsFor compares grace_until against now, so a deadline left
            -- in the past empties the capabilities on every read: the grant three lines above did
            -- not restore access at all. The two columns move together because migration 0018's
            -- entitlement_grace_is_whole CHECK requires it -- clearing one alone is a constraint
            -- violation rather than a partial fix.
            -- (No backticks in this comment, deliberately: it lives inside a template literal, and
            -- one would end the string. The compiler says only "',' expected".)
            past_due_since = NULL,
            grace_until = NULL,
            updated_at = now()`,
    [input.accountId, input.plan, [...input.capabilities], input.capUnits],
  );
}

export async function setRevoked(
  client: pg.Client,
  accountId: string,
  revoked: boolean,
): Promise<boolean> {
  const result = await client.query(
    `UPDATE sonny.entitlement
        SET revoked_at = $2,
            -- Cleared in both directions, and neither is the same argument (SONNY-380, PR
            -- #206's F2). Revoking: a revoked account is not past due, it is over, and leaving the
            -- column set makes the line read Past due with an Update payment control for an
            -- account the operator has just ended -- the opposite of what they did. Un-revoking:
            -- an operator restoring access is grant's case under another name, and the reasoning
            -- there applies word for word.
            --
            -- Unconditional rather than keyed on the revoked flag, and the two versions DO differ
            -- on a row that exists (PR #206's F7). The reason first written here was that the
            -- keyed version is unreachable, on the grounds that no row this gateway writes carries
            -- revoked_at and past_due_since together -- which is true, and is about the wrong set.
            -- Where the two differ is any row with past_due_since set that reaches this with
            -- revoked false: a row written by writeFor's past_due arm is exactly that, revoked_at
            -- null and past_due_since set, and restore <account-id> is a first-class operator
            -- command that reaches it. So the keyed version is reachable, and clearing is the
            -- intended answer there too, for the un-revoking reason above: an operator restoring a
            -- past-due account is comping it, and a grace deadline left behind would have
            -- claimFactsFor empty the capabilities the restore exists to hand back.
            -- anOperatorRestoreEndsAnOutstandingPaymentFailure is what holds that direction; R7
            -- cannot, because it reverts the whole statement and the revoke test alone kills it.
            past_due_since = NULL,
            grace_until = NULL,
            updated_at = now()
      WHERE account_id = $1`,
    [accountId, revoked ? new Date() : null],
  );
  return (result.rowCount ?? 0) > 0;
}

export async function describeAccount(
  client: pg.Client,
  accountId: string,
  now: Date,
): Promise<string> {
  const record = await readEntitlement(client, accountId);
  const usage = await readPeriodUsage(client, accountId, now);
  const lines = [
    `account ${accountId}`,
    `  plan             ${record.plan}`,
    `  capabilities     ${record.capabilities.join(", ") || "-"}`,
    `  cap              ${record.capUnits === null ? "(deployment default)" : record.capUnits}`,
    `  revoked          ${record.revokedAt === null ? "no" : record.revokedAt.toISOString()}`,
  ];
  if (usage === undefined) {
    lines.push("  this period      nothing spent and nothing held");
  } else {
    lines.push(
      `  this period      ${usage.spent} spent, ${usage.reserved} held, of ${usage.capUnits} ` +
        `(period opened ${usage.periodStart.toISOString()})`,
    );
  }
  // Said on every read, because the number above is a call count and the temptation to read it as
  // money is exactly what this row's never-touch list exists to prevent.
  lines.push(
    "",
    "Units are metered calls, not money and not credits. What a call costs in credits is",
    "SONNY-212's, and this gateway holds no price of any kind.",
  );
  return `${lines.join("\n")}\n`;
}

async function main(): Promise<void> {
  const parsed = parseEntitlementArguments(process.argv.slice(2));
  if (parsed.kind === "help") {
    process.stdout.write(USAGE);
    return;
  }
  if (parsed.kind === "error") {
    process.stderr.write(`${parsed.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (parsed.kind === "public-key") {
    const encoded = process.env["ENTITLEMENT_SIGNING_KEY"];
    const keyId = process.env["ENTITLEMENT_SIGNING_KEY_ID"];
    if (!encoded || !keyId) {
      process.stderr.write("ENTITLEMENT_SIGNING_KEY and ENTITLEMENT_SIGNING_KEY_ID are not set\n");
      process.exit(78);
    }
    const key = entitlementSigningKeyFrom(encoded, keyId);
    process.stdout.write(`${key.keyId}  ${publicKeyMaterial(key)}\n`);
    return;
  }

  const url = process.env["DATABASE_URL"];
  if (!url) {
    process.stderr.write("DATABASE_URL is not set\n");
    process.exit(78);
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    switch (parsed.kind) {
      case "show":
        process.stdout.write(await describeAccount(client, parsed.accountId, new Date()));
        return;
      case "grant":
        await grant(client, parsed);
        process.stdout.write(await describeAccount(client, parsed.accountId, new Date()));
        return;
      case "revoke":
      case "restore": {
        const found = await setRevoked(client, parsed.accountId, parsed.kind === "revoke");
        if (!found) {
          // An account with no row is already entitled to nothing, so a revoke is a no-op — but
          // saying "done" would let an operator believe they had acted on the right id after a typo.
          process.stderr.write(`no entitlement row for account ${parsed.accountId}\n`);
          process.exitCode = 1;
          return;
        }
        process.stdout.write(await describeAccount(client, parsed.accountId, new Date()));
        return;
      }
      case "sweep": {
        const now = new Date();
        const reclaimed = await sweepExpiredReservations(client, now);
        // **Both sweeps, one command** (PR #152's review, F4). The rate-limit table's own sweep had
        // no caller outside a test, and this branch multiplied what it holds — a row per account per
        // minute rather than one per sign-in attempt. Two mechanisms with nothing scheduling either
        // is how a table grows forever; one command is something an operator can put on a timer.
        const windows = await sweepRateLimitWindows(client, staleWindowsBefore(now));
        process.stdout.write(
          `${reclaimed} expired hold(s) reclaimed\n` +
            `${windows} stale rate-limit window(s) deleted\n`,
        );
        return;
      }
    }
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
