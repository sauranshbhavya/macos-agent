import { pathToFileURL } from "node:url";
import pg from "pg";
import {
  accountSupportView,
  contentForRequest,
  recentContentAccesses,
  recentContentDeletions,
  type AccountSupportView,
  type ContentAccessRow,
  type ContentDeletionRow,
  type RetainedContentView,
} from "./content/query.js";

/**
 * `npm run support` — what a founder may see about a user, and the record of having seen it
 * (SONNY-134). Contract §10, requirement 9.
 *
 * **The access question is answered here rather than left to whoever has database access**, which
 * is what requirement 9 asks for in those words. Founder decision, 2026-08-28:
 *
 * - `account` reads freely: whether the account exists, whether it is closed, whether training
 *   consent was granted, which providers it signs in with, what it has been calling, and **how much
 *   content is held and of what kinds** — never the content.
 * - `content` is the one command that reads content, and it refuses to run without `--operator` and
 *   `--reason`, writes a `sonny.content_access` row whether or not it finds anything, and prints
 *   blobs as sizes rather than as bytes.
 *
 * **This is a discipline and a trace, not a boundary, and the help text says so.** Anyone who can
 * run this holds `DATABASE_URL` and can read the same rows from `psql` leaving nothing behind. A
 * tool that implied otherwise would be worse than no tool, because it would make a control look
 * like one.
 *
 * **What "entitlement state" means today, since requirement 9 names it.** §5.3's signed entitlement
 * claim is SONNY-135's and is not built, so there is no plan, no tier and no allowance to print —
 * and this command says that rather than printing an empty section that reads like "no
 * entitlements". What exists is the account: open or closed, when it was created, how it signs in,
 * and what it has spent. That is what a support question can be answered from right now, and the
 * report says which half is missing so nobody reads its silence as an answer.
 *
 * The same CLI shape as `usage.ts` and `revocations.ts`, down to the `pathToFileURL` guard, which
 * `db/migrate.ts`'s own comment explains: a template-string comparison makes the whole command a
 * silent no-op under any path containing a space, and this repository's checkouts live under such
 * paths.
 */

const USAGE = `Usage: npm run support -- <command> [options]

Commands:
  account <uuid>   Account state, how it signs in, what it has been calling, and how much
                   content is held for it. Never prints content.
  content          One request's retained content. Requires --request, --operator and
                   --reason, and writes a row to the access log before printing.
  accesses         Who has read content, and why. Newest first.
  deletions        What has been deleted and what it reached: task deletes, account
                   deletes, and every content-expiry sweep that took rows.

Options:
  --request <id>     The Sonny-Request-Id to read. Required by "content".
  --operator <name>  Who is looking. Required by "content".
  --reason <text>    Why. Required by "content", recorded verbatim.
  --account <uuid>   Narrows "deletions" to one account.
  --limit <n>        How many rows for "accesses" and "deletions". Default 20.

Reads DATABASE_URL.

This is a record, not a barrier. Anyone who can run this command holds the database
credential and can read the same rows directly, leaving no trace. What the access log
gives you is that a lookup made through this tool is one somebody can point at later.
`;

export type ParsedSupportArguments =
  | {
      readonly kind: "run";
      readonly command: "account";
      readonly accountId: string;
    }
  | {
      readonly kind: "run";
      readonly command: "content";
      readonly requestId: string;
      readonly operator: string;
      readonly reason: string;
    }
  | { readonly kind: "run"; readonly command: "accesses"; readonly limit: number }
  | {
      readonly kind: "run";
      readonly command: "deletions";
      readonly limit: number;
      readonly accountId: string | undefined;
    }
  | { readonly kind: "help" }
  | { readonly kind: "error"; readonly message: string };

/**
 * Parse `argv`.
 *
 * **A pure function so the refusals are testable without a database**, the same split `usage.ts`
 * makes and for the same reason — except that here one of the refusals is the whole access decision.
 * `content` without an operator or a reason is refused *before* a connection is opened, so the
 * ceremony cannot be skipped by a command that fails halfway through having already read the row.
 */
export function parseSupportArguments(argv: readonly string[]): ParsedSupportArguments {
  const first = argv[0];
  if (first === undefined || first === "--help" || first === "-h" || first === "help") {
    return { kind: "help" };
  }

  const flags = new Map<string, string>();
  const positional: string[] = [];
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument.startsWith("--")) {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) {
        return { kind: "error", message: `${argument} needs a value` };
      }
      flags.set(argument.slice(2), value);
      index += 1;
    } else {
      positional.push(argument);
    }
  }

  const limitText = flags.get("limit");
  if (limitText !== undefined && !/^\d+$/.test(limitText)) {
    return { kind: "error", message: `--limit is not a number: ${JSON.stringify(limitText)}` };
  }
  const limit = limitText === undefined ? 20 : Number(limitText);
  if (limit < 1) return { kind: "error", message: "--limit must be at least 1" };

  switch (first) {
    case "account": {
      const accountId = positional[0];
      if (accountId === undefined) return { kind: "error", message: "account needs an account id" };
      return { kind: "run", command: "account", accountId };
    }
    case "content": {
      const requestId = flags.get("request");
      const operator = flags.get("operator");
      const reason = flags.get("reason");
      // **Three refusals rather than one message listing three flags**, so an operator who left one
      // out is told which. Each is the access decision, not an argument-parsing nicety: a lookup
      // with no name against it and no stated reason is exactly the lookup this command exists to
      // stop being the normal way of doing things.
      if (requestId === undefined) return { kind: "error", message: "content needs --request" };
      if (operator === undefined || operator.trim().length === 0) {
        return { kind: "error", message: "content needs --operator: who is looking" };
      }
      if (reason === undefined || reason.trim().length === 0) {
        return { kind: "error", message: "content needs --reason: why, recorded verbatim" };
      }
      return {
        kind: "run",
        command: "content",
        requestId,
        operator: operator.trim(),
        reason: reason.trim(),
      };
    }
    case "accesses":
      return { kind: "run", command: "accesses", limit };
    case "deletions":
      return { kind: "run", command: "deletions", limit, accountId: flags.get("account") };
    default:
      return { kind: "error", message: `unknown command ${JSON.stringify(first)}` };
  }
}

function instant(value: Date | null): string {
  return value === null ? "-" : value.toISOString();
}

const ENTITLEMENTS_NOTE =
  "\nEntitlement plan, tier and allowance are not shown because they do not exist yet: the signed\n" +
  "entitlement claim of contract section 5.3 is SONNY-135's and is not built. What is above is the\n" +
  "whole of what this gateway knows about this account.\n";

export function reportAccount(view: AccountSupportView | undefined, accountId: string): string {
  if (view === undefined) return `no account ${accountId}\n`;
  const lines = [
    `account          ${view.accountId}`,
    `created          ${instant(view.createdAt)}`,
    `state            ${view.deletedAt === null ? "open" : `closed ${instant(view.deletedAt)}`}`,
    `training consent ${view.trainingConsent ? "granted" : "not granted"}` +
      `${view.trainingConsentUpdatedAt === null ? "" : ` (${instant(view.trainingConsentUpdatedAt)})`}`,
    `signs in with    ${
      view.identities.length === 0
        ? "-"
        : view.identities
            .map((entry) => `${entry.provider}${entry.accountClosed ? " (closed)" : ""}`)
            .join(", ")
    }`,
    "",
    `usage            ${view.usage.events} event(s), ${instant(view.usage.oldest)} to ${instant(
      view.usage.newest,
    )}`,
  ];
  for (const route of view.usage.byRoute) {
    const outcomes = Object.entries(route.outcomes)
      .map(([outcome, count]) => `${outcome} ${count}`)
      .join(", ");
    lines.push(`  ${route.route.padEnd(20)} ${route.calls} call(s)  ${outcomes}`);
  }
  lines.push(
    "",
    `content          ${view.content.rows} call(s) retained, ${instant(
      view.content.oldest,
    )} to ${instant(view.content.newest)}`,
    `  next expiry    ${instant(view.content.nextExpiry)}`,
    `  voice audio    ${view.content.withVoiceAudio}`,
    `  screenshots    ${view.content.withScreenshot}`,
    `  provider error ${view.content.withProviderError}`,
  );
  lines.push(
    "",
    `training snapshots ${
      view.snapshots.length === 0
        ? "none"
        : view.snapshots.map((entry) => `${entry.label} (${entry.rows})`).join(", ")
    }`,
  );
  return `${lines.join("\n")}\n${ENTITLEMENTS_NOTE}`;
}

export function reportContent(
  view: RetainedContentView | undefined,
  requestId: string,
): string {
  if (view === undefined) {
    return (
      `no retained content for request ${requestId}\n\n` +
      "That is not necessarily a gap. Content is kept for thirty days, an incognito run stores none\n" +
      "at all, and a deleted task's content is gone on purpose. The lookup itself has been recorded.\n"
    );
  }
  const lines = [
    `request          ${view.requestId}`,
    `account          ${view.accountId}`,
    `route            ${view.route}`,
    `task             ${view.taskId ?? "-"}`,
    `session          ${view.sessionId ?? "-"}${
      view.sessionIteration === null ? "" : ` iteration ${view.sessionIteration}`
    }`,
    `occurred         ${instant(view.occurredAt)}`,
    `expires          ${instant(view.expiresAt)}`,
    `provider         ${view.provider ?? "-"}  request id ${view.providerRequestId ?? "-"}`,
    "",
    "request text",
    view.requestText === null || view.requestText === undefined
      ? "  -"
      : JSON.stringify(view.requestText, null, 2)
          .split("\n")
          .map((line) => `  ${line}`)
          .join("\n"),
  ];
  // **Blobs as sizes.** A terminal cannot render either, and printing a megabyte of base64 into a
  // scrollback that outlives the lookup would be a worse outcome than not answering. Exporting one
  // is a different act and does not have a command.
  lines.push(
    "",
    `voice audio      ${
      view.voiceAudioBytes === null
        ? "-"
        : `${view.voiceAudioBytes} bytes ${view.voiceAudioMediaType ?? ""}`.trim()
    }`,
    `screenshot       ${
      view.screenshotBytes === null
        ? "-"
        : `${view.screenshotBytes} bytes ${view.screenshotMediaType ?? ""}`.trim()
    }`,
    "",
    `response         ${view.responseStatus ?? "-"}`,
    view.responseBody === null
      ? "  -"
      : view.responseBody
          .split("\n")
          .map((line) => `  ${line}`)
          .join("\n"),
  );
  if (view.providerErrorBody !== null || view.providerErrorStatus !== null) {
    lines.push(
      "",
      `provider error   ${view.providerErrorStatus ?? "-"}`,
      view.providerErrorBody === null
        ? "  -"
        : view.providerErrorBody
            .split("\n")
            .map((line) => `  ${line}`)
            .join("\n"),
    );
  }
  return `${lines.join("\n")}\n\nThis lookup is recorded in sonny.content_access.\n`;
}

export function reportAccesses(rows: readonly ContentAccessRow[]): string {
  if (rows.length === 0) return "no content lookups recorded\n";
  return `${rows
    .map(
      (row) =>
        `${instant(row.occurredAt)}  ${row.operator}  ${row.requestId}  ` +
        `${row.found ? "found" : "nothing"}  ${row.reason}`,
    )
    .join("\n")}\n`;
}

export function reportDeletions(rows: readonly ContentDeletionRow[]): string {
  if (rows.length === 0) {
    return (
      "no deletions recorded\n\n" +
      "For an expiry sweep that is the expected answer until content is old enough to expire; the\n" +
      "sweep logs every pass and records a row only when it takes something.\n"
    );
  }
  return `${rows
    .map((row) => {
      const target =
        row.reason === "task"
          ? `task ${row.taskId ?? "-"}`
          : row.reason === "account"
            ? `account ${row.accountId ?? "-"}`
            : row.reason;
      const snapshots =
        row.snapshotsTouched.length === 0
          ? ""
          : `  snapshots ${row.snapshotsTouched.join(",")}`;
      const responses = row.storedResponses === 0 ? "" : `  responses ${row.storedResponses}`;
      return (
        `${instant(row.occurredAt)}  ${row.reason.padEnd(15)} ${target}  ` +
        `content ${row.contentRows}  snapshot rows ${row.snapshotRows}${snapshots}${responses}`
      );
    })
    .join("\n")}\n`;
}

async function main(): Promise<void> {
  const parsed = parseSupportArguments(process.argv.slice(2));
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
    if (parsed.command === "account") {
      process.stdout.write(
        reportAccount(await accountSupportView(client, parsed.accountId), parsed.accountId),
      );
    } else if (parsed.command === "content") {
      const view = await contentForRequest(client, {
        requestId: parsed.requestId,
        operator: parsed.operator,
        reason: parsed.reason,
      });
      process.stdout.write(reportContent(view, parsed.requestId));
    } else if (parsed.command === "accesses") {
      process.stdout.write(reportAccesses(await recentContentAccesses(client, parsed.limit)));
    } else {
      process.stdout.write(
        reportDeletions(
          await recentContentDeletions(client, {
            accountId: parsed.accountId,
            limit: parsed.limit,
          }),
        ),
      );
    }
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts`,
// `revocations.ts` and `usage.ts`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
