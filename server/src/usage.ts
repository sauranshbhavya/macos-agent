import { pathToFileURL } from "node:url";
import pg from "pg";
import {
  meteringSpan,
  routeTotals,
  screenControlSessionCosts,
  type UsageWindow,
} from "./metering/query.js";

/**
 * `npm run usage` — what the calls this gateway served actually cost, read from a terminal
 * (SONNY-133).
 *
 * **A command and not a surface, decided rather than assumed.** SONNY-131's hand-over comment
 * suggested this ticket "owns the first thing that renders" usage; the coordinator settled it
 * against that on 2026-08-28, and the ticket's own non-goal already said so. The usage UI is
 * SONNY-214's. What is owed here is the founders' pre-launch measurement — "what did screen control
 * cost me across these sessions" — answerable before any UI exists, which is what makes SONNY-17's
 * free-tier allowance and paid price answerable at all.
 *
 * **It prints no price and computes none.** Tokens, bytes, pixels, iterations and milliseconds are
 * what the table holds and all this renders. A rate or a currency here would be SONNY-17's decision
 * taken in the wrong ticket, and the number this exists to produce is the input to that decision.
 *
 * **One caveat travels with every figure this prints, and the ticket asks for it in writing.** Image
 * size drives vision token cost directly, and SONNY-114 changed what leaves the Mac — captures were
 * full-resolution lossless PNG, and a maximized window was a 1,828,535-byte body. A cost measured
 * over sessions that ran before that landed is a number about to move. The footer says so on every
 * run rather than leaving it to whoever quotes the figure to remember, and the `image bytes` and
 * `megapixels` columns are there so a reader can see which regime a session was in.
 *
 * The same CLI shape as `revocations.ts`, down to the `pathToFileURL` guard, which
 * `db/migrate.ts`'s own comment explains: a template-string comparison makes the whole command a
 * silent no-op under any path containing a space, and this repository's checkouts live under such
 * paths.
 */

const USAGE = `Usage: npm run usage -- <command> [options]

Commands:
  sessions     One row per screen-control session: iterations, tokens, image bytes,
               megapixels and outcomes. The per-session figure SONNY-17's credit weight
               is the sum of.
  routes       One row per route: calls, tokens, and what they were spent on.
  span         How many events are stored and how far back they go — usage is on the
               long clock (contract section 10.3) and nothing here ages it out.

Options:
  --account <uuid>   Only this account.
  --session <id>     Only this screen-control session.
  --task <id>        Only this task.
  --since <iso>      Only events at or after this instant, e.g. 2026-08-01T00:00:00Z.
  --until <iso>      Only events strictly before this instant.

Reads DATABASE_URL. Prints measurements only: no price, no plan, no credit weight.
`;

/** A parsed command line, or the reason it could not be parsed. */
export type ParsedUsageArguments =
  | { readonly kind: "run"; readonly command: "sessions" | "routes" | "span"; readonly window: UsageWindow }
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
  if (first !== "sessions" && first !== "routes" && first !== "span") {
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

/**
 * Bytes as a figure a person can read.
 *
 * **Two decimal places and nothing else — this said "with the exact count kept beside it" and it
 * never printed one** (corrected 2026-08-28, PR #147's review, F7, which caught it on a real report
 * where a session that sent 192 bytes printed `0.00 MB`). The exact count is in the table and is one
 * query away; what this is for is a figure a person can compare two sessions with at a glance, and a
 * byte count beside every megabyte figure would bury that. A reader who needs the byte is reading
 * `sonny.metering_event.image_bytes`, not this line.
 */
function megabytes(bytes: number): string {
  return `${(bytes / 1_000_000).toFixed(2)} MB`;
}

function outcomeSummary(outcomes: Readonly<Record<string, number | undefined>>): string {
  const entries = Object.entries(outcomes).filter(([, n]) => n !== undefined && n > 0);
  if (entries.length === 0) return "-";
  return entries.map(([outcome, n]) => `${outcome}=${n}`).join(" ");
}

/**
 * The measurement footer, printed under every report.
 *
 * Two sentences, both of which a figure from this command is wrong without: which regime the image
 * bytes came from, and that a token count of zero on the vision route is an absence rather than a
 * measurement.
 */
const FOOTER =
  "\nTwo things every figure above is read with:\n" +
  "  - Image size drives vision token cost, and SONNY-114 changed what leaves the Mac. A cost\n" +
  "    measured over sessions that ran before it is a number about to move; the image-bytes and\n" +
  "    megapixel columns are what tell the two regimes apart.\n" +
  "  - A token count of 0 on screen.analyze is an ABSENCE, not a measurement. That route reports\n" +
  "    tokens only when the provider did and estimates nothing, because the dominant term is an\n" +
  "    image. The 'no tokens' column counts those calls; size them from megapixels.\n";

export async function reportSessions(client: pg.Client, window: UsageWindow): Promise<string> {
  const sessions = await screenControlSessionCosts(client, window);
  if (sessions.length === 0) return "no screen-control sessions in this window\n";
  const lines = [`${sessions.length} screen-control session(s), newest first:\n`];
  for (const session of sessions) {
    lines.push(`session ${session.sessionId}`);
    lines.push(`  account          ${session.accountId}`);
    lines.push(`  tasks            ${session.taskIds.join(", ") || "-"}`);
    lines.push(
      `  iterations       ${session.iterations}` +
        (session.highestIteration === null ? "" : ` (highest numbered ${session.highestIteration})`),
    );
    lines.push(`  ran              ${session.firstAt.toISOString()} .. ${session.lastAt.toISOString()}`);
    lines.push(
      `  tokens           reported in ${session.reportedInputTokens}, out ${session.reportedOutputTokens}, ` +
        `total ${session.reportedTotalTokens}; estimated total ${session.estimatedTotalTokens}`,
    );
    lines.push(`  no tokens        ${session.iterationsWithoutTokens} of ${session.iterations} iteration(s)`);
    lines.push(
      `  image            ${megabytes(session.imageBytes)} over the wire, ` +
        `${(session.pixels / 1_000_000).toFixed(2)} megapixels sent`,
    );
    lines.push(`  upstream         ${session.upstreamMs} ms; whole requests ${session.wallMs} ms`);
    lines.push(`  outcomes         ${outcomeSummary(session.outcomes)}`);
    lines.push(`  providers        ${session.providers.join(", ") || "-"}`);
    // §10.1: an incognito run is metered identically and stores no content. Printed so a reader can
    // see that those sessions are in the figure rather than wonder whether they were dropped.
    lines.push(`  retention        ${session.retentions.join(", ") || "-"}`);
    lines.push("");
  }
  return `${lines.join("\n")}${FOOTER}`;
}

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
    if (total.imageBytes > 0) lines.push(`  image            ${megabytes(total.imageBytes)}`);
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
    "a metering row, and the table holds no content, so an event older than the content retention\n" +
    "window is expected rather than a leak.\n"
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
      parsed.command === "sessions"
        ? await reportSessions(client, parsed.window)
        : parsed.command === "routes"
          ? await reportRoutes(client, parsed.window)
          : await reportSpan(client, parsed.window);
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
