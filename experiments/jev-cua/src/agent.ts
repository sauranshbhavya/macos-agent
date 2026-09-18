import { screenSummary, stepsSummary, type Coordinator, type CoordinatorCall, type Plan, type Verdict } from "./coordinator.ts";
import type { Driver } from "./driver/driver.ts";
import type { WindowRecord, WindowState } from "./driver/types.ts";
import { frontmost, type Executor, type InstructionOutcome } from "./executor.ts";
import type { RecentAction } from "./actionModel/jev.ts";

/**
 * The whole run: launch the task's app, let the coordinator plan, hand instructions to the
 * executor one at a time, let the coordinator judge after each, stop on done / failed / budget.
 */

export interface Task {
  readonly id: string;
  readonly goal: string;
  readonly app: { readonly bundleId: string; readonly urls?: readonly string[] };
  /** What a person checks on screen afterwards; the run does not verify it. */
  readonly humanCheck: string;
}

export interface InstructionRecord {
  readonly turn: number;
  readonly instruction: string;
  readonly outcome: InstructionOutcome;
  readonly review: { readonly verdict: Verdict; readonly call: CoordinatorCall } | null;
}

export type RunStatus = "done" | "failed" | "turn_budget" | "action_budget" | "error";

export interface RunReport {
  readonly task: Task;
  readonly status: RunStatus;
  readonly reason: string;
  readonly plan: { readonly plan: Plan; readonly call: CoordinatorCall } | null;
  readonly instructions: readonly InstructionRecord[];
  readonly totals: RunTotals;
  readonly finalScreen: string | null;
  readonly startedAt: string;
  readonly wallMs: number;
}

export interface RunTotals {
  readonly actions: number;
  readonly coordinatorCalls: number;
  readonly coordinatorMs: number;
  readonly jevCalls: number;
  readonly jevMs: number;
  readonly textCalls: number;
  readonly textMs: number;
  readonly driverMs: number;
  readonly observeMs: number;
  readonly rungs: { readonly ax: number; readonly px: number; readonly foreground: number };
  readonly exhausted: number;
  readonly truncatedSnapshots: number;
}

export interface AgentSettings {
  readonly maxCoordinatorTurns: number;
  readonly windowWaitMs: number;
}

export interface AgentDeps {
  readonly driver: Driver;
  readonly coordinator: Coordinator;
  readonly executor: Executor;
  readonly settings: AgentSettings;
  readonly sleep?: (ms: number) => Promise<void>;
  readonly log?: (line: string) => void;
}

const defaultSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export async function runTask(task: Task, deps: AgentDeps): Promise<RunReport> {
  const started = performance.now();
  const startedAt = new Date().toISOString();
  const sleep = deps.sleep ?? defaultSleep;
  const log = deps.log ?? (() => undefined);
  const instructions: InstructionRecord[] = [];
  let plan: RunReport["plan"] = null;
  let lastState: WindowState | null = null;

  const finish = (status: RunStatus, reason: string): RunReport => ({
    task,
    status,
    reason,
    plan,
    instructions,
    totals: totals(instructions, plan),
    finalScreen: lastState ? screenSummary(lastState) : null,
    startedAt,
    wallMs: Math.round(performance.now() - started),
  });

  try {
    const launched = await deps.driver.launchApp(task.app.bundleId, task.app.urls);
    const window = await waitForWindow(deps.driver, launched.pid, launched.windows, deps.settings.windowWaitMs, sleep);
    if (window === null) return finish("error", `${task.app.bundleId} launched (pid ${launched.pid}) but showed no window`);
    log(`launched ${task.app.bundleId} pid ${launched.pid} window ${window.window_id}`);

    lastState = await deps.driver.windowState(launched.pid, window.window_id, { screenshot: false });
    plan = await deps.coordinator.plan(task.goal, screenSummary(lastState));
    log(`plan (${plan.call.latencyMs} ms): ${plan.plan.instructions.map((i, n) => `${n + 1}. ${i}`).join(" | ")}`);

    const queue = [...plan.plan.instructions];
    const history: RecentAction[] = [];
    let actionsUsed = 0;
    let windowId = window.window_id;
    let instruction = queue.shift();
    if (instruction === undefined) return finish("failed", "the coordinator planned no instructions");

    for (let turn = 1; turn <= deps.settings.maxCoordinatorTurns; turn += 1) {
      log(`turn ${turn}: ${instruction}`);
      const outcome = await deps.executor.runInstruction({
        pid: launched.pid,
        windowId,
        goal: task.goal,
        instruction,
        actionsUsed,
        history: [...history],
      });
      actionsUsed += outcome.actionsSpent;
      lastState = outcome.state;
      windowId = outcome.state.window_id;
      for (const step of outcome.steps) {
        if (step.outcome === "control" && step.operation !== "WAIT") continue;
        history.push({
          operation: step.operation,
          target: step.targetLabel,
          text: step.text?.value ?? null,
          effect: step.attempts.at(-1)?.effect ?? null,
          windowChanged: step.windowChanged,
        });
      }
      log(`  ${outcome.status}: ${outcome.note} (${outcome.steps.length} steps, ${outcome.actionsSpent} actions)`);

      if (outcome.status === "budget") {
        instructions.push({ turn, instruction, outcome, review: null });
        return finish("action_budget", outcome.note);
      }
      if (outcome.status === "refused") {
        instructions.push({ turn, instruction, outcome, review: null });
        return finish("error", outcome.note);
      }

      const review = await deps.coordinator.review({
        goal: task.goal,
        plan: plan.plan,
        instruction,
        outcome,
        stepsSummary: stepsSummary(outcome),
        screen: screenSummary(outcome.state),
        remainingInstructions: [...queue],
        turnsLeft: deps.settings.maxCoordinatorTurns - turn,
      });
      instructions.push({ turn, instruction, outcome, review });
      log(`  coordinator (${review.call.latencyMs} ms): ${review.verdict.verdict} — ${review.verdict.assessment}`);

      if (review.verdict.verdict === "done") return finish("done", review.verdict.assessment);
      if (review.verdict.verdict === "failed") return finish("failed", review.verdict.assessment);
      const next = review.verdict.next_instruction ?? "";
      if (queue[0] === next) queue.shift();
      instruction = next;
    }
    return finish("turn_budget", `the run's ${deps.settings.maxCoordinatorTurns}-turn coordinator budget is spent`);
  } catch (error) {
    return finish("error", error instanceof Error ? error.message : String(error));
  }
}

/** An app launched in the background may take a moment to show a window; poll rather than guess. */
export async function waitForWindow(
  driver: Driver,
  pid: number,
  initial: readonly WindowRecord[],
  timeoutMs: number,
  sleep: (ms: number) => Promise<void>,
): Promise<WindowRecord | null> {
  const deadline = performance.now() + timeoutMs;
  let windows = initial;
  for (;;) {
    const front = frontmost(windows);
    if (front !== null) return front;
    if (performance.now() >= deadline) return null;
    await sleep(250);
    windows = await driver.listWindows(pid);
  }
}

export function totals(records: readonly InstructionRecord[], plan: RunReport["plan"]): RunTotals {
  const t = {
    actions: 0,
    coordinatorCalls: plan ? 1 : 0,
    coordinatorMs: plan?.call.latencyMs ?? 0,
    jevCalls: 0,
    jevMs: 0,
    textCalls: 0,
    textMs: 0,
    driverMs: 0,
    observeMs: 0,
    rungs: { ax: 0, px: 0, foreground: 0 },
    exhausted: 0,
    truncatedSnapshots: 0,
  };
  for (const record of records) {
    t.actions += record.outcome.actionsSpent;
    if (record.review) {
      t.coordinatorCalls += 1;
      t.coordinatorMs += record.review.call.latencyMs;
    }
    for (const step of record.outcome.steps) {
      t.jevCalls += 1;
      t.jevMs += step.modelMs;
      t.observeMs += step.observeMs;
      if (step.truncated > 0) t.truncatedSnapshots += 1;
      if (step.text) {
        t.textCalls += 1;
        t.textMs += step.text.latencyMs;
      }
      if (step.outcome === "exhausted") t.exhausted += 1;
      const settled = step.attempts.at(-1);
      if (settled && step.outcome === "settled") t.rungs[settled.rung] += 1;
      for (const attempt of step.attempts) t.driverMs += attempt.driverMs;
    }
  }
  return t;
}
