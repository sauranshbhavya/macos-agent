import { describe, expect, it } from "vitest";
import { runTask, totals, waitForWindow, type Task } from "./agent.ts";
import type { Coordinator, CoordinatorCall, Plan, ReviewInput, Verdict } from "./coordinator.ts";
import type { Executor, InstructionContext, InstructionOutcome } from "./executor.ts";
import { DriverRefusal } from "./driver/types.ts";
import { element, FakeDriver, instantSleep, windowRecord, windowState } from "./testSupport/fakes.ts";

const task: Task = { id: "t", goal: "do the thing", app: { bundleId: "com.example.app" }, humanCheck: "it is done" };
const call: CoordinatorCall = { latencyMs: 10, model: "gpt-test", usage: { input_tokens: 1, output_tokens: 1 } };

class FakeCoordinator implements Coordinator {
  readonly reviews: ReviewInput[] = [];
  readonly planned: Plan;
  #verdicts: Verdict[];
  constructor(planned: Plan, verdicts: Verdict[]) {
    this.planned = planned;
    this.#verdicts = verdicts;
  }
  async plan(): Promise<{ plan: Plan; call: CoordinatorCall }> {
    return { plan: this.planned, call };
  }
  async review(input: ReviewInput): Promise<{ verdict: Verdict; call: CoordinatorCall }> {
    this.reviews.push(input);
    const verdict = this.#verdicts.shift();
    if (verdict === undefined) throw new Error("FakeCoordinator out of verdicts");
    return { verdict, call };
  }
}

function outcome(status: InstructionOutcome["status"], actionsSpent = 1): InstructionOutcome {
  return {
    status,
    note: status,
    actionsSpent,
    state: windowState([element({ element_index: 1 })]),
    steps: [{ step: 1, instruction: "i", withheld: [], operation: "CLICK", targetKey: "1", targetLabel: "Element 1", confidence: 0.9, targetConfidence: 0.8, topOperations: [], modelMs: 20, text: null, attempts: [{ rung: "ax", effect: "confirmed", route: null, escalation: null, verdict: "settled: confirmed", driverMs: 30, }], outcome: "settled", windowChanged: true, observeMs: 40, candidates: 1, truncated: 0, offered: { CLICK: 1, TYPE_TEXT: 0 }, note: null }],
  };
}

class FakeExecutor {
  readonly contexts: InstructionContext[] = [];
  #outcomes: InstructionOutcome[];
  constructor(outcomes: InstructionOutcome[]) {
    this.#outcomes = outcomes;
  }
  async runInstruction(context: InstructionContext): Promise<InstructionOutcome> {
    this.contexts.push(context);
    const next = this.#outcomes.shift();
    if (next === undefined) throw new Error("FakeExecutor out of outcomes");
    return next;
  }
}

const plan: Plan = { understanding: "u", instructions: ["open it", "press it"], success_criteria: "pressed" };
const settings = { judge: "coordinator" as const, maxCoordinatorTurns: 5, windowWaitMs: 100, frontAtLaunch: false };

describe("runTask", () => {
  it("launches, plans, runs instructions in order and stops when the coordinator says done", async () => {
    const driver = new FakeDriver([windowState([element({ element_index: 1 })])]);
    const coordinator = new FakeCoordinator(plan, [
      { assessment: "opened", verdict: "continue", next_instruction: "press it" },
      { assessment: "pressed", verdict: "done", next_instruction: null },
    ]);
    const executor = new FakeExecutor([outcome("done"), outcome("done", 2)]);
    const report = await runTask(task, { driver, coordinator, executor: executor as unknown as Executor, settings, sleep: instantSleep });
    expect(report.status).toBe("done");
    expect(report.reason).toBe("pressed");
    expect(executor.contexts.map((c) => c.instruction)).toEqual(["open it", "press it"]);
    expect(executor.contexts.map((c) => c.actionsUsed)).toEqual([0, 1]);
    expect(coordinator.reviews[0]?.remainingInstructions).toEqual(["press it"]);
    expect(coordinator.reviews[1]?.remainingInstructions).toEqual([]);
    expect(report.totals).toMatchObject({ actions: 3, coordinatorCalls: 3, coordinatorMs: 30, jevCalls: 2, jevMs: 40, driverMs: 60, observeMs: 80, rungs: { ax: 2, px: 0, foreground: 0 } });
    expect(report.finalScreen).toContain("[1] button: Element 1");
  });

  it("fronts the app once at launch when asked, naming its best-ranked window", async () => {
    const driver = new FakeDriver([windowState([element({ element_index: 1 })])]);
    const coordinator = new FakeCoordinator(plan, [{ assessment: "ok", verdict: "done", next_instruction: null }]);
    await runTask(task, { driver, coordinator, executor: new FakeExecutor([outcome("done")]) as unknown as Executor, settings: { ...settings, frontAtLaunch: true }, sleep: instantSleep });
    const tools = driver.calls.map((c) => c.tool);
    expect(tools.indexOf("bring_to_front")).toBeGreaterThan(tools.indexOf("launch_app"));
    expect(driver.calls.filter((c) => c.tool === "bring_to_front")).toEqual([expect.objectContaining({ extra: { pid: 42, windowId: 7 } })]);
  });

  it("falls back through the ranked windows and then the app alone when fronting is refused, and carries on", async () => {
    const driver = new FakeDriver([windowState([element({ element_index: 1 })])], [windowRecord({ window_id: 7 }), windowRecord({ window_id: 8, z_index: 0 })]);
    const refused: Array<number | undefined> = [];
    driver.bringToFront = async (_pid, windowId) => {
      refused.push(windowId);
      if (windowId !== undefined) throw new DriverRefusal("bring_to_front", { code: "bring_to_front_exact_window_unverified" });
    };
    const lines: string[] = [];
    const report = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, [{ assessment: "ok", verdict: "done", next_instruction: null }]), executor: new FakeExecutor([outcome("done")]) as unknown as Executor, settings: { ...settings, frontAtLaunch: true }, sleep: instantSleep, log: (l) => lines.push(l) });
    expect(refused).toEqual([7, 8, undefined]);
    refused.length = 0;
    let calls = 0;
    driver.bringToFront = async () => {
      calls += 1;
      if (calls < 5) throw new DriverRefusal("bring_to_front", { code: "bring_to_front_exact_window_unverified" });
    };
    const late = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, [{ assessment: "ok", verdict: "done", next_instruction: null }]), executor: new FakeExecutor([outcome("done")]) as unknown as Executor, settings: { ...settings, frontAtLaunch: true }, sleep: instantSleep, log: (l) => lines.push(l) });
    expect(late.status).toBe("done");
    expect(calls).toBe(5);
    expect(report.status).toBe("done");
    driver.bringToFront = async () => {
      throw new DriverRefusal("bring_to_front", { code: "ambiguous_window_target" });
    };
    const still = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, [{ assessment: "ok", verdict: "done", next_instruction: null }]), executor: new FakeExecutor([outcome("done")]) as unknown as Executor, settings: { ...settings, frontAtLaunch: true }, sleep: instantSleep, log: (l) => lines.push(l) });
    expect(still.status).toBe("done");
    expect(lines.some((l) => l.includes("could not bring"))).toBe(true);
  });

  it("lets the coordinator replace the planned instruction with a better one", async () => {
    const driver = new FakeDriver([windowState([])]);
    const coordinator = new FakeCoordinator(plan, [
      { assessment: "a dialog is in the way", verdict: "continue", next_instruction: "close the dialog" },
      { assessment: "ok", verdict: "done", next_instruction: null },
    ]);
    const executor = new FakeExecutor([outcome("stalled"), outcome("done")]);
    await runTask(task, { driver, coordinator, executor: executor as unknown as Executor, settings, sleep: instantSleep });
    expect(executor.contexts.map((c) => c.instruction)).toEqual(["open it", "close the dialog"]);
    // The unused planned instruction stays queued for the coordinator to see.
    expect(coordinator.reviews[1]?.remainingInstructions).toEqual(["press it"]);
  });

  it("carries the executor's history across instructions", async () => {
    const driver = new FakeDriver([windowState([])]);
    const coordinator = new FakeCoordinator(plan, [{ assessment: "a", verdict: "continue", next_instruction: "press it" }, { assessment: "b", verdict: "done", next_instruction: null }]);
    const executor = new FakeExecutor([outcome("done"), outcome("done")]);
    await runTask(task, { driver, coordinator, executor: executor as unknown as Executor, settings, sleep: instantSleep });
    expect(executor.contexts[1]?.history).toEqual([{ operation: "CLICK", target: "Element 1", text: null, effect: "confirmed", windowChanged: true }]);
  });

  it("reports failed, turn budget and action budget as their own statuses", async () => {
    const driver = new FakeDriver([windowState([])]);
    const failed = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, [{ assessment: "needs a login", verdict: "failed", next_instruction: null }]), executor: new FakeExecutor([outcome("blocked")]) as unknown as Executor, settings, sleep: instantSleep });
    expect(failed).toMatchObject({ status: "failed", reason: "needs a login" });

    const forever = Array.from({ length: 5 }, (): Verdict => ({ assessment: "more", verdict: "continue", next_instruction: "again" }));
    const turns = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, forever), executor: new FakeExecutor(Array.from({ length: 5 }, () => outcome("done"))) as unknown as Executor, settings, sleep: instantSleep });
    expect(turns.status).toBe("turn_budget");
    expect(turns.instructions).toHaveLength(5);

    const budget = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, []), executor: new FakeExecutor([outcome("budget", 0)]) as unknown as Executor, settings, sleep: instantSleep });
    expect(budget.status).toBe("action_budget");
    expect(budget.instructions[0]?.review).toBeNull();
  });

  it("fails after three BLOCKED answers in a row with nothing acted on, whatever the coordinator says", async () => {
    const driver = new FakeDriver([windowState([])]);
    const keepGoing = Array.from({ length: 5 }, (): Verdict => ({ assessment: "try again", verdict: "continue", next_instruction: "again" }));
    const executor = new FakeExecutor(Array.from({ length: 5 }, () => outcome("blocked", 0)));
    const report = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, keepGoing), executor: executor as unknown as Executor, settings, sleep: instantSleep });
    expect(report.status).toBe("failed");
    expect(report.reason).toContain("three instructions in a row");
    expect(report.instructions).toHaveLength(3);
    expect(report.instructions[2]?.review).toBeNull();
  });

  it("resets the blocked count when an instruction acts", async () => {
    const driver = new FakeDriver([windowState([])]);
    const verdicts = Array.from({ length: 5 }, (): Verdict => ({ assessment: "on", verdict: "continue", next_instruction: "again" }));
    const executor = new FakeExecutor([outcome("blocked", 0), outcome("blocked", 0), outcome("done", 1), outcome("blocked", 0), outcome("blocked", 0)]);
    const report = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, verdicts), executor: executor as unknown as Executor, settings, sleep: instantSleep });
    expect(report.status).toBe("turn_budget");
  });

  it("reports an error rather than throwing when the app shows no window or a call fails", async () => {
    const driver = new FakeDriver([windowState([])], []);
    const report = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, []), executor: new FakeExecutor([]) as unknown as Executor, settings: { ...settings, windowWaitMs: 0 }, sleep: instantSleep });
    expect(report.status).toBe("error");
    expect(report.reason).toContain("none of its windows resolved");

    const throwing = new FakeDriver([windowState([])]);
    throwing.launchApp = async () => {
      throw new Error("daemon not running");
    };
    const crashed = await runTask(task, { driver: throwing, coordinator: new FakeCoordinator(plan, []), executor: new FakeExecutor([]) as unknown as Executor, settings, sleep: instantSleep });
    expect(crashed).toMatchObject({ status: "error", reason: "daemon not running" });
  });
});

describe("runTask with Jev as the judge", () => {
  const jev = { ...settings, judge: "jev" as const };

  it("hands the whole goal to the executor once and never calls the coordinator", async () => {
    const driver = new FakeDriver([windowState([element({ element_index: 1 })])]);
    const coordinator = new FakeCoordinator(plan, []);
    const executor = new FakeExecutor([outcome("done", 4)]);
    const report = await runTask(task, { driver, coordinator, executor: executor as unknown as Executor, settings: jev, sleep: instantSleep });
    expect(report.status).toBe("done");
    expect(report.plan).toBeNull();
    expect(executor.contexts).toEqual([expect.objectContaining({ instruction: "do the thing", goal: "do the thing", actionsUsed: 0 })]);
    expect(coordinator.reviews).toHaveLength(0);
    expect(report.totals).toMatchObject({ actions: 4, coordinatorCalls: 0, coordinatorMs: 0, jevCalls: 1 });
  });

  it.each([
    ["blocked", "failed"],
    ["stalled", "failed"],
    ["low_confidence", "failed"],
    ["budget", "action_budget"],
    ["refused", "error"],
  ] as const)("maps an executor outcome of %s to a run status of %s", async (status, expected) => {
    const driver = new FakeDriver([windowState([])]);
    const report = await runTask(task, { driver, coordinator: new FakeCoordinator(plan, []), executor: new FakeExecutor([outcome(status)]) as unknown as Executor, settings: jev, sleep: instantSleep });
    expect(report.status).toBe(expected);
  });
});

describe("waitForWindow", () => {
  it("polls list_windows until a window resolves and gives up at the deadline", async () => {
    const driver = new FakeDriver([windowState([])], []);
    let polls = 0;
    driver.listWindows = async () => {
      polls += 1;
      return polls >= 2 ? [windowRecord()] : [];
    };
    expect((await waitForWindow(driver, 42, [], 5_000, instantSleep))?.window_id).toBe(7);
    expect(polls).toBe(2);
    driver.listWindows = async () => [];
    expect(await waitForWindow(driver, 42, [], 0, instantSleep)).toBeNull();
  });
});

describe("totals", () => {
  it("counts an exhausted step under exhausted and not under any rung, and counts truncated snapshots", () => {
    const exhausted: InstructionOutcome = { ...outcome("blocked"), steps: [{ ...outcome("blocked").steps[0]!, outcome: "exhausted", truncated: 3 }] };
    const t = totals([{ turn: 1, instruction: "i", outcome: exhausted, review: null }], null);
    expect(t).toMatchObject({ exhausted: 1, rungs: { ax: 0, px: 0, foreground: 0 }, truncatedSnapshots: 1, coordinatorCalls: 0 });
  });
});
