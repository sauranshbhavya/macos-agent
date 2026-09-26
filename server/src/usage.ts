import { pathToFileURL } from "node:url";
import pg from "pg";
import {
  meteringSpan,
  routeTotals,
  type UsageWindow,
} from "./metering/query.js";

/**
 * `npm run usage` — what the transcription calls this gateway served measured, read from a terminal
 * (SONNY-133). The V2 agents' model calls are on `sonny.agent_model_call`, not here.
 *
 * **It prints no price and computes none.** Tokens, audio seconds and milliseconds are what the
 * table holds and all this renders.
 *
 * The same CLI shape as `revocations.ts`, down to the `pathToFileURL` guard, which
 * `db/migrate.ts`'s own comment explains: a template-string comparison makes the whole command a
 * silent no-op under any path containing a space, and this repository's checkouts live under such
 * paths.
 */

const USAGE = `Usage: npm run usage -- <command> [options]

Commands:
  routes       One row per route: calls, tokens, and what they were spent on.
  span         How many events are stored and how far back they go — usage is on the
               long clock (contract section 10.3) and nothing here ages it out.

Options:
  --account <uuid>   Only this account.
  --session <id>     Only events carrying this session id.
  --task <id>        Only this task.
  --since <iso>      Only events at or after this instant, e.g. 2026-08-01T00:00:00Z.
  --until <iso>      Only events strictly before this instant.

Reads DATABASE_URL. Prints measurements only: no price, no plan, no credit weight.
`;

/** A parsed command line, or the reason it could not be parsed. */
export type ParsedUsageArguments =
  | { readonly kind: "run"; readonly command: "routes" | "span"; readonly window: UsageWindow }
  | { readonly kind: "help" }
  | { readonly kind: "error"; readonly message: string };

/**
 * Parse `argv` into a command and a window.
 *
 * **A pure function so the parsing is testable without a database**, which is the same split
 * `metering/event.ts` makes with `outcomeFor`. Every refusal below names the offending argument: a
 * `--since` that is not a date is a typo an operator can fix, and silently treating it as "no bound"
 * would answer a question nobody asked with a number that looks right.
 */
export function parseUsageArguments(argv: readonly string[]): ParsedUsageArguments {
  const first = argv[0];
  if (first === undefined || first === "--help" || first === "-h" || first === "help") {
    return { kind: "help" };
  }
  if (first !== "routes" && first !== "span") {
    return { kind: "error", message: `unknown command ${JSON.stringify(first)}` };
  }

  const window: {
    accountId?: string;
    sessionId?: string;
    taskId?: string;
    since?: Date;
    until?: Date;
  } = {};
  for (let index = 1; index < argv.length; index += 1) {
    const flag = argv[index]!;
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      return { kind: "error", message: `${flag} needs a value` };
    }
    index += 1;
    switch (flag) {
      case "--account":
        window.accountId = value;
        break;
      case "--session":
        window.sessionId = value;
        break;
      case "--task":
        window.taskId = value;
        break;
      case "--since":
      case "--until": {
        const instant = new Date(value);
        if (Number.isNaN(instant.getTime())) {
          return { kind: "error", message: `${flag} is not a date: ${JSON.stringify(value)}` };
        }
        if (flag === "--since") window.since = instant;
        else window.until = instant;
        break;
      }
      default:
        return { kind: "error", message: `unknown option ${JSON.stringify(flag)}` };
    }
  }
  return { kind: "run", command: first, window };
}

function outcomeSummary(outcomes: Readonly<Record<string, number | undefined>>): string {
  const entries = Object.entries(outcomes).filter(([, n]) => n !== undefined && n > 0);
  if (entries.length === 0) return "-";
  return entries.map(([outcome, n]) => `${outcome}=${n}`).join(" ");
}

/** The measurement footer, printed under every report. */
const FOOTER =
  "\nA call with no token count recorded no usage at all (it was refused, or failed before an\n" +
  "answer). That is an absence, not a measurement of zero.\n";

export async function reportRoutes(client: pg.Client, window: UsageWindow): Promise<string> {
  const totals = await routeTotals(client, window);
  if (totals.length === 0) return "no metered calls in this window\n";
  const lines = ["calls by route:\n"];
  for (const total of totals) {
    lines.push(`${total.route}`);
    lines.push(`  calls            ${total.calls} (${total.callsWithoutTokens} with no token count)`);
    lines.push(
      `  tokens           reported ${total.reportedTotalTokens}, estimated ${total.estimatedTotalTokens}`,
    );
    if (total.audioSeconds > 0) lines.push(`  audio            ${total.audioSeconds.toFixed(1)} s`);
    lines.push(`  upstream         ${total.upstreamMs} ms`);
    lines.push(`  outcomes         ${outcomeSummary(total.outcomes)}`);
    lines.push("");
  }
  return `${lines.join("\n")}${FOOTER}`;
}

export async function reportSpan(client: pg.Client, window: UsageWindow): Promise<string> {
  const span = await meteringSpan(client, window);
  if (span.events === 0) return "no metering events in this window\n";
  const days =
    span.oldest === null ? 0 : (Date.now() - span.oldest.getTime()) / (24 * 60 * 60 * 1000);
  return (
    `${span.events} metering event(s)\n` +
    `  oldest           ${span.oldest?.toISOString() ?? "-"} (${days.toFixed(1)} days ago)\n` +
    `  newest           ${span.newest?.toISOString() ?? "-"}\n` +
    "\nUsage is on the long clock (contract section 10.3). Nothing in this gateway deletes or ages\n" +
    "a metering row, and the table holds no content, so an old event is expected rather than a\n" +
    "leak.\n"
  );
}

async function main(): Promise<void> {
  const parsed = parseUsageArguments(process.argv.slice(2));
  if (parsed.kind === "help") {
    process.stdout.write(USAGE);
    return;
  }
  if (parsed.kind === "error") {
    process.stderr.write(`${parsed.message}\n\n${USAGE}`);
    process.exit(2);
  }

  const url = process.env["DATABASE_URL"];
  if (!url) {
    process.stderr.write("DATABASE_URL is not set\n");
    process.exit(78);
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    const report =
      parsed.command === "routes" ? await reportRoutes(client, parsed.window) : await reportSpan(client, parsed.window);
    process.stdout.write(report);
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts` and
// `revocations.ts`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
