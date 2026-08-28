import { pathToFileURL } from "node:url";
import pg from "pg";
import { trainingSnapshots, type SnapshotRow } from "./content/query.js";
import {
  buildTrainingSnapshot,
  isMeteredRoute,
  snapshotsHoldingTask,
  type SnapshotRequest,
} from "./content/snapshot.js";
import { sweepExpiredContent } from "./content/expiry.js";
import type { MeteredRoute } from "./metering/event.js";

/**
 * `npm run snapshots` — build the documented corpora training reads from, and trace what a deletion
 * would reach (SONNY-134). Contract §10.2 and §10.3.
 *
 * **A command rather than an endpoint, deliberately.** Nothing about building a training snapshot
 * belongs on the request path: it is an occasional act by a founder, it reads across every account,
 * and an HTTP route for it would be a route that must never be reachable by a user — which is a
 * thing to get wrong rather than a thing to have. §4.6's delete-by-task is the opposite case and is
 * a route for the opposite reason: it is the user's own act.
 *
 * **`sweep` is here too, because the clock has to be runnable by hand.** The gateway sweeps on a
 * timer (`content/expiry.ts`), which is what makes §10.3's clock real; this is what a founder runs
 * to see it work now rather than within the hour, and what runs it at all on a database no gateway
 * is currently pointed at.
 *
 * **It prints no content.** A snapshot's size, window and membership are what this reports; reading
 * what is inside one is the support lookup's job and goes through its access log.
 */

const USAGE = `Usage: npm run snapshots -- <command> [options]

Commands:
  build      Build a training snapshot from the live content store and seal it.
  list       Every snapshot: label, window, size, and whether it has an expiry.
  trace      Which snapshots hold content from one task, without deleting anything.
  sweep      Run the content-expiry sweep once, now.

Options for build:
  --label <name>          Required. The name a training run and a deletion report both quote.
  --since <iso>           Only content at or after this instant.
  --until <iso>           Only content strictly before this instant.
  --routes <a,b>          Only these routes. Default: all five.
  --expires-in-days <n>   Give this snapshot its own clock. Omit for none — contract
                          section 10.3 puts snapshots on a separately-consented lifecycle
                          and no founder has set a number, so the honest default is
                          "no expiry set" rather than one invented here.

Options for trace:
  --account <uuid>   Required.
  --task <id>        Required.

Reads DATABASE_URL.

What a build excludes, and how:
  - A user who has not granted training consent, and one whose account is closed. A join,
    plus a trigger on the member table that refuses the row anyway.
  - An incognito run. Not by a filter: the content store cannot hold one, so no query over
    it - filtered or not - can reach one.
`;

export type ParsedSnapshotArguments =
  | { readonly kind: "run"; readonly command: "build"; readonly request: SnapshotRequest }
  | { readonly kind: "run"; readonly command: "list" }
  | {
      readonly kind: "run";
      readonly command: "trace";
      readonly accountId: string;
      readonly taskId: string;
    }
  | { readonly kind: "run"; readonly command: "sweep" }
  | { readonly kind: "help" }
  | { readonly kind: "error"; readonly message: string };

function instantFrom(value: string, flag: string): Date | { error: string } {
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime())
    ? { error: `${flag} is not a date: ${JSON.stringify(value)}` }
    : parsed;
}

/**
 * Parse `argv`.
 *
 * **Every refusal names the offending argument**, which is `usage.ts`' rule and matters more here:
 * a `--since` silently read as "no bound" would build a snapshot over a wider window than anyone
 * asked for, and the corpus is the one artifact in this system that cannot be quietly corrected
 * after something has been trained on it.
 */
export function parseSnapshotArguments(argv: readonly string[]): ParsedSnapshotArguments {
  const first = argv[0];
  if (first === undefined || first === "--help" || first === "-h" || first === "help") {
    return { kind: "help" };
  }
  if (first !== "build" && first !== "list" && first !== "trace" && first !== "sweep") {
    return { kind: "error", message: `unknown command ${JSON.stringify(first)}` };
  }
  if (first === "list") return { kind: "run", command: "list" };
  if (first === "sweep") return { kind: "run", command: "sweep" };

  const flags = new Map<string, string>();
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (!argument.startsWith("--")) {
      return { kind: "error", message: `unexpected argument ${JSON.stringify(argument)}` };
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      return { kind: "error", message: `${argument} needs a value` };
    }
    flags.set(argument.slice(2), value);
    index += 1;
  }

  if (first === "trace") {
    const accountId = flags.get("account");
    const taskId = flags.get("task");
    if (accountId === undefined) return { kind: "error", message: "trace needs --account" };
    if (taskId === undefined) return { kind: "error", message: "trace needs --task" };
    return { kind: "run", command: "trace", accountId, taskId };
  }

  const label = flags.get("label");
  if (label === undefined || label.trim().length === 0) {
    return { kind: "error", message: "build needs --label" };
  }

  const request: {
    label: string;
    since?: Date;
    until?: Date;
    routes?: MeteredRoute[];
    expiresAt?: Date;
  } = { label: label.trim() };

  for (const [flag, key] of [
    ["since", "since"],
    ["until", "until"],
  ] as const) {
    const value = flags.get(flag);
    if (value === undefined) continue;
    const parsed = instantFrom(value, `--${flag}`);
    if (parsed instanceof Date) request[key] = parsed;
    else return { kind: "error", message: parsed.error };
  }

  const routesText = flags.get("routes");
  if (routesText !== undefined) {
    const names = routesText.split(",").map((name) => name.trim()).filter((name) => name.length > 0);
    const unknown = names.filter((name) => !isMeteredRoute(name));
    if (unknown.length > 0 || names.length === 0) {
      return { kind: "error", message: `--routes names no known route: ${routesText}` };
    }
    request.routes = names.filter(isMeteredRoute);
  }

  const days = flags.get("expires-in-days");
  if (days !== undefined) {
    if (!/^\d+$/.test(days) || Number(days) < 1) {
      return { kind: "error", message: `--expires-in-days is not a positive number: ${days}` };
    }
    request.expiresAt = new Date(Date.now() + Number(days) * 24 * 60 * 60 * 1000);
  }

  return { kind: "run", command: "build", request };
}

function instant(value: Date | null): string {
  return value === null ? "-" : value.toISOString();
}

export function reportSnapshots(rows: readonly SnapshotRow[]): string {
  if (rows.length === 0) return "no training snapshots\n";
  return `${rows
    .map(
      (row) =>
        `${row.label}\n` +
        `  id          ${row.snapshotId}\n` +
        `  created     ${instant(row.createdAt)}\n` +
        `  sealed      ${instant(row.sealedAt)}\n` +
        `  expires     ${row.expiresAt === null ? "no expiry set" : instant(row.expiresAt)}\n` +
        `  members     ${row.memberCount}\n` +
        `  routes      ${row.routes.length === 0 ? "all" : row.routes.join(", ")}\n` +
        `  builder     ${row.builderVersion}`,
    )
    .join("\n\n")}\n`;
}

async function main(): Promise<void> {
  const parsed = parseSnapshotArguments(process.argv.slice(2));
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
    if (parsed.command === "build") {
      const result = await buildTrainingSnapshot(client, parsed.request);
      process.stdout.write(
        `built ${result.label} (${result.snapshotId}) with ${result.memberCount} member(s)\n`,
      );
    } else if (parsed.command === "list") {
      process.stdout.write(reportSnapshots(await trainingSnapshots(client)));
    } else if (parsed.command === "trace") {
      const held = await snapshotsHoldingTask(client, {
        accountId: parsed.accountId,
        taskId: parsed.taskId,
      });
      process.stdout.write(
        held.length === 0
          ? "this task is in no training snapshot\n"
          : `${held.map((entry) => `${entry.label}  ${entry.rows} row(s)  ${entry.snapshotId}`).join("\n")}\n`,
      );
    } else {
      const result = await sweepExpiredContent(client);
      process.stdout.write(
        `swept: ${result.contentRows} expired content row(s), ` +
          `${result.closedAccountRows} row(s) from a closed account, ` +
          `${result.snapshots} snapshot(s)\n`,
      );
    }
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts`,
// `revocations.ts`, `usage.ts` and `support.ts`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
