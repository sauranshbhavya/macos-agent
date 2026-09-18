import { screenSummary, stepsSummary, type Coordinator, type CoordinatorCall, type Plan, type Verdict } from "./coordinator.ts";
import type { Driver } from "./driver/driver.ts";
import { DriverRefusal, type WindowRecord, type WindowState } from "./driver/types.ts";
import { rankWindows, resolveWindow, type Executor, type InstructionOutcome } from "./executor.ts";
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
  /** `jev`: no coordinator; the goal is the instruction and Jev's DONE is the verdict. `coordinator`: plan, run, judge, repeat. */
  readonly judge: "jev" | "coordinator";
  readonly maxCoordinatorTurns: number;
  readonly windowWaitMs: number;
  /**
   * Bring the app to the front once, right after launch. cua's Known limits: a SwiftUI window on a
   * non-current Space returns a stripped tree — Calculator answered "0 AXWindow elements" the moment
   * it sat on another Space (SONNY-517, 2026-09-17) — and fronting switches to its Space. It also
   * lets the founder watch. Every action after it still uses background delivery.
   */
  readonly frontAtLaunch: boolean;
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
    if (deps.settings.frontAtLaunch) {
      await sleep(750);
      const fronted = await frontApp(deps.driver, launched.pid, await deps.driver.listWindows(launched.pid), sleep);
      await sleep(500);
      log(fronted === null ? `could not bring ${task.app.bundleId} to the front; carrying on` : `brought ${task.app.bundleId} to the front (window ${fronted})`);
    }
    const first = await waitForWindow(deps.driver, launched.pid, deps.settings.frontAtLaunch ? [] : launched.windows, deps.settings.windowWaitMs, sleep);
    if (first === null) return finish("error", `${task.app.bundleId} launched (pid ${launched.pid}) but none of its windows resolved to an accessibility tree`);
    lastState = first;
    log(`launched ${task.app.bundleId} pid ${launched.pid} window ${first.window_id} (${first.elements.length} elements)`);

    if (deps.settings.judge === "jev") {
      // jev-ultrafast's loop: the whole goal every step, no reasoning model anywhere in it.
      const outcome = await deps.executor.runInstruction({ pid: launched.pid, windowId: first.window_id, goal: task.goal, instruction: task.goal, actionsUsed: 0, history: [] });
      lastState = outcome.state;
      instructions.push({ turn: 1, instruction: task.goal, outcome, review: null });
      log(`  ${outcome.status}: ${outcome.note} (${outcome.steps.length} steps, ${outcome.actionsSpent} actions)`);
      switch (outcome.status) {
        case "done":
          return finish("done", outcome.note);
        case "budget":
          return finish("action_budget", outcome.note);
        case "refused":
          return finish("error", outcome.note);
        default:
          return finish("failed", outcome.note);
      }
    }

    plan = await deps.coordinator.plan(task.goal, screenSummary(lastState));
    log(`plan (${plan.call.latencyMs} ms): ${plan.plan.instructions.map((i, n) => `${n + 1}. ${i}`).join(" | ")}`);

    const queue = [...plan.plan.instructions];
    const history: RecentAction[] = [];
    let actionsUsed = 0;
    let windowId = first.window_id;
    let instruction = queue.shift();
    if (instruction === undefined) return finish("failed", "the coordinator planned no instructions");

    let blockedInARow = 0;
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
      // The coordinator is told to fail after a repeated stall and did not: TextEdit's first live
      // run spent eleven turns alternating two instructions Jev answered BLOCKED to at once. Three
      // blocked answers in a row with nothing acted on is the loop's own stop, whatever it says.
      blockedInARow = outcome.status === "blocked" && outcome.actionsSpent === 0 ? blockedInARow + 1 : 0;
      if (blockedInARow >= 3) {
        instructions.push({ turn, instruction, outcome, review: null });
        return finish("failed", "the action model answered BLOCKED to three instructions in a row without acting");
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

/**
 * Best-effort fronting: the driver refuses an app with several windows unless one is named
 * (`ambiguous_window_target`) and refuses a window it cannot verify
 * (`bring_to_front_exact_window_unverified` — Safari's launch-time list went stale once it opened
 * the URL in a new window). Try the best-ranked windows, then the app alone; a refusal everywhere
 * is logged, not fatal, since the run can still resolve a window that is already on screen.
 */
export async function frontApp(
  driver: Driver,
  pid: number,
  windows: readonly WindowRecord[],
  sleep: (ms: number) => Promise<void> = defaultSleep,
): Promise<number | "app" | null> {
  const attempts: Array<number | undefined> = [...rankWindows(windows).slice(0, 3).map((w) => w.window_id), undefined];
  // A window on another Space is fronted through a Space switch, and the driver's focus check can
  // run before the animation lands (`bring_to_front_exact_window_unverified` on a call that then
  // succeeds a second later — SONNY-517 live run). Three rounds, a beat apart.
  for (let round = 0; round < 3; round += 1) {
    for (const windowId of attempts) {
      try {
        await driver.bringToFront(pid, windowId);
        return windowId ?? "app";
      } catch (error) {
        if (!(error instanceof DriverRefusal)) throw error;
      }
    }
    await sleep(700);
  }
  return null;
}

/** An app launched in the background may take a moment to show a window; poll rather than guess. */
export async function waitForWindow(
  driver: Driver,
  pid: number,
  initial: readonly WindowRecord[],
  timeoutMs: number,
  sleep: (ms: number) => Promise<void>,
): Promise<WindowState | null> {
  const deadline = performance.now() + timeoutMs;
  let windows = initial;
  for (;;) {
    const resolved = await resolveWindow(driver, pid, windows);
    if (resolved !== null) return resolved;
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
