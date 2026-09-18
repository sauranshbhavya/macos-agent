import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import OpenAI from "openai";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import { runTask, type RunReport } from "./agent.ts";
import { JevActionModel } from "./actionModel/jev.ts";
import { OpenAITextHelper } from "./actionModel/textHelper.ts";
import { loadConfig } from "./config.ts";
import { OpenAICoordinator } from "./coordinator.ts";
import { McpDriver } from "./driver/mcpDriver.ts";
import { Executor } from "./executor.ts";
import { findTask, TASKS } from "./tasks.ts";

/**
 * `npm run task -- <task-id | all>`. Runs the task(s) against the real driver and writes one JSON
 * report per run under RUNS_DIR, stamped with the tree it ran at.
 */

function usage(): never {
  console.error(`usage: npm run task -- <task-id | all>\n\ntasks:\n${TASKS.map((t) => `  ${t.id.padEnd(12)} ${t.goal}`).join("\n")}`);
  process.exit(2);
}

function treeStamp(): { sha: string; dirty: boolean } {
  try {
    const sha = execFileSync("git", ["rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
    const status = execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim();
    return { sha, dirty: status.length > 0 };
  } catch {
    return { sha: "unknown", dirty: true };
  }
}

function summarise(report: RunReport): string {
  const t = report.totals;
  const lines = [
    `${report.task.id}: ${report.status.toUpperCase()} — ${report.reason}`,
    `  wall ${report.wallMs} ms | actions ${t.actions} | coordinator ${t.coordinatorCalls} calls / ${t.coordinatorMs} ms | jev ${t.jevCalls} calls / ${t.jevMs} ms | text ${t.textCalls} calls / ${t.textMs} ms | driver ${t.driverMs} ms | observe ${t.observeMs} ms`,
    `  rungs: ax ${t.rungs.ax}, px ${t.rungs.px}, foreground ${t.rungs.foreground}; exhausted ${t.exhausted}; truncated snapshots ${t.truncatedSnapshots}`,
    `  human check: ${report.task.humanCheck}`,
  ];
  return lines.join("\n");
}

const selection = process.argv[2];
if (selection === undefined || selection === "--help") usage();
const tasks = selection === "all" ? [...TASKS] : [findTask(selection) ?? usage()];

const config = loadConfig();
const stamp = treeStamp();
const runsDir = resolve(config.RUNS_DIR);
mkdirSync(runsDir, { recursive: true });

const openai = new OpenAI({ apiKey: config.OPENAI_API_KEY, ...(config.OPENAI_BASE_URL ? { baseURL: config.OPENAI_BASE_URL } : {}) });
const typesafe = new TypeSafeClient({ apiKey: config.TYPESAFE_API_KEY, defaultModel: config.TYPESAFE_MODEL, timeout: 20_000 });
const driver = await McpDriver.open();

try {
  for (const task of tasks) {
    const startedAt = new Date().toISOString().replace(/[:.]/g, "-");
    const snapshotDir = resolve(runsDir, `${task.id}-${startedAt}-snapshots`);
    mkdirSync(snapshotDir, { recursive: true });
    const executor = new Executor({
      driver,
      actionModel: new JevActionModel(typesafe),
      textHelper: new OpenAITextHelper(openai, config.TEXT_MODEL),
      settings: {
        maxActions: config.MAX_ACTIONS,
        minOperationConfidence: config.MIN_OPERATION_CONFIDENCE,
        waitMs: 500,
        settleMs: 150,
      },
      // Every snapshot a decision was made on, so a wrong pick can be read against what was offered.
      onObserve: (state, n) => writeFileSync(resolve(snapshotDir, `${String(n).padStart(3, "0")}.json`), JSON.stringify(state, null, 1)),
    });
    const report = await runTask(task, {
      driver,
      coordinator: new OpenAICoordinator(openai, config.COORDINATOR_MODEL),
      executor,
      settings: { maxCoordinatorTurns: config.MAX_COORDINATOR_TURNS, windowWaitMs: 10_000, frontAtLaunch: true },
      log: (line) => console.log(line),
    });
    const file = resolve(runsDir, `${task.id}-${startedAt}.json`);
    writeFileSync(file, JSON.stringify({ tree: stamp, models: { coordinator: config.COORDINATOR_MODEL, text: config.TEXT_MODEL, jev: config.TYPESAFE_MODEL }, ...report }, null, 2));
    console.log(`\n${summarise(report)}\n  report: ${file}\n`);
  }
} finally {
  await driver.close();
}
