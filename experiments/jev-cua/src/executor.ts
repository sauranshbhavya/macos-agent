import { buildActionSpace, type Candidate, type Operation } from "./actionSpace.ts";
import type { ActionModel, Decision, RecentAction } from "./actionModel/jev.ts";
import type { TextHelper } from "./actionModel/textHelper.ts";
import type { ActionTarget, Driver } from "./driver/driver.ts";
import { DriverRefusal, type ActionResult, type Element, type WindowRecord, type WindowState } from "./driver/types.ts";
import { deliveryFor, fingerprint, nextRung, targetFor, RUNGS, type Rung } from "./ladder.ts";

/**
 * Runs one coordinator instruction against one window: observe, let Jev choose, act up the
 * ladder, observe again, until Jev says DONE or BLOCKED, the loop stalls, confidence drops below
 * the floor, or the action budget runs out. Every step is recorded with its timings so the report
 * can say where the time went and which rung each action needed.
 */

export interface AttemptRecord {
  readonly rung: Rung;
  readonly effect: ActionResult["effect"] | "refused";
  readonly route: string | null;
  readonly escalation: string | null;
  readonly verdict: string;
  readonly driverMs: number;
}

export interface StepRecord {
  readonly step: number;
  readonly instruction: string;
  readonly operation: Operation;
  readonly targetKey: string | null;
  readonly targetLabel: string | null;
  readonly confidence: number;
  readonly targetConfidence: number | null;
  readonly topOperations: ReadonlyArray<readonly [string, number]>;
  readonly modelMs: number;
  readonly text: { readonly value: string | null; readonly latencyMs: number; readonly model: string } | null;
  readonly attempts: readonly AttemptRecord[];
  readonly outcome: "settled" | "exhausted" | "skipped" | "control";
  readonly windowChanged: boolean | null;
  readonly observeMs: number;
  readonly candidates: number;
  readonly truncated: number;
  /** Targets per head after the request was fitted to Jev's budget. */
  readonly offered: Readonly<Record<"CLICK" | "TYPE_TEXT", number>>;
  readonly note: string | null;
}

export type InstructionStatus = "done" | "blocked" | "stalled" | "low_confidence" | "budget" | "refused";

export interface InstructionOutcome {
  readonly status: InstructionStatus;
  readonly steps: readonly StepRecord[];
  readonly state: WindowState;
  readonly note: string;
  /** Driver actions this instruction spent, so the run's budget carries across instructions. */
  readonly actionsSpent: number;
}

export interface ExecutorSettings {
  readonly maxActions: number;
  readonly minOperationConfidence: number;
  /** How long WAIT waits, and how long an action gets to settle before the next observation. */
  readonly waitMs: number;
  readonly settleMs: number;
}

export interface ExecutorDeps {
  readonly driver: Driver;
  readonly actionModel: ActionModel;
  readonly textHelper: TextHelper;
  readonly settings: ExecutorSettings;
  readonly sleep?: (ms: number) => Promise<void>;
  /** Called with every snapshot the loop bases a decision on — the CLI writes them beside the report. */
  readonly onObserve?: (state: WindowState, step: number) => void;
}

export interface InstructionContext {
  readonly pid: number;
  readonly windowId: number;
  readonly goal: string;
  readonly instruction: string;
  /** Actions already spent on this run by earlier instructions; the budget is per run. */
  readonly actionsUsed: number;
  readonly history: readonly RecentAction[];
}

const defaultSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export class Executor {
  #driver: Driver;
  #actionModel: ActionModel;
  #textHelper: TextHelper;
  #settings: ExecutorSettings;
  #sleep: (ms: number) => Promise<void>;
  #onObserve: (state: WindowState, step: number) => void;
  #observed = 0;

  constructor(deps: ExecutorDeps) {
    this.#driver = deps.driver;
    this.#actionModel = deps.actionModel;
    this.#textHelper = deps.textHelper;
    this.#settings = deps.settings;
    this.#sleep = deps.sleep ?? defaultSleep;
    this.#onObserve = deps.onObserve ?? (() => undefined);
  }

  async runInstruction(context: InstructionContext): Promise<InstructionOutcome> {
    const steps: StepRecord[] = [];
    const history: RecentAction[] = [...context.history];
    let windowId = context.windowId;
    let actionsUsed = context.actionsUsed;
    let state = await this.#observe(context.pid, windowId);

    for (;;) {
      windowId = state.window_id;
      this.#observed += 1;
      this.#onObserve(state, this.#observed);
      const space = buildActionSpace(state.elements);
      const window = { app: state.app_name ?? null, title: state.window_title ?? null };
      const modelStarted = performance.now();
      const decision = await this.#actionModel.choose({
        instruction: context.instruction,
        goal: context.goal,
        window,
        space,
        recentActions: history,
      });
      const modelMs = Math.round(performance.now() - modelStarted);
      const base = stepBase(steps.length + 1, context.instruction, decision, modelMs, space.candidates.length, space.truncated.CLICK + space.truncated.TYPE_TEXT);

      if (decision.confidence < this.#settings.minOperationConfidence && decision.operation !== "DONE") {
        steps.push({ ...base, outcome: "control", note: `operation confidence ${decision.confidence.toFixed(2)} below floor` });
        return { status: "low_confidence", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: `Jev was unsure (${decision.confidence.toFixed(2)}) between ${topOperations(decision).map(([op]) => op).join(" / ")}` };
      }
      if (decision.operation === "DONE") {
        steps.push({ ...base, outcome: "control", note: null });
        return { status: "done", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: "Jev judged the instruction satisfied" };
      }
      if (decision.operation === "BLOCKED") {
        steps.push({ ...base, outcome: "control", note: null });
        return { status: "blocked", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: "Jev found no operation that makes progress" };
      }
      if (actionsUsed >= this.#settings.maxActions) {
        steps.push({ ...base, outcome: "control", note: "action budget exhausted" });
        return { status: "budget", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: `the run's ${this.#settings.maxActions}-action budget is spent` };
      }

      const before = fingerprint(state);
      let text: StepRecord["text"] = null;
      let attempts: AttemptRecord[] = [];
      let outcome: StepRecord["outcome"] = "settled";
      let note: string | null = null;

      try {
        if (decision.operation === "WAIT") {
          await this.#sleep(this.#settings.waitMs);
          outcome = "control";
        } else if (decision.operation === "TYPE_TEXT") {
          const field = decision.target;
          if (field === null) throw new Error("TYPE_TEXT without a target");
          const helper = await this.#textHelper.fieldText({
            instruction: context.instruction,
            goal: context.goal,
            field,
            window,
            visibleText: visibleText(state),
            recentActions: history,
          });
          text = { value: helper.text, latencyMs: helper.latencyMs, model: helper.model };
          if (helper.text === null) {
            outcome = "skipped";
            note = "the text helper found nothing in the goal to type";
          } else {
            const value = helper.text;
            ({ attempts, outcome } = await this.#climb(
              state,
              field.element,
              (target, delivery) => this.#typeInto(target, field, value, delivery),
              value,
            ));
          }
        } else if (decision.operation === "CLICK") {
          const target = decision.target;
          if (target === null) throw new Error("CLICK without a target");
          ({ attempts, outcome } = await this.#climb(state, target.element, (t, delivery) => this.#driver.click(t, delivery)));
        } else if (decision.operation === "PRESS_RETURN" || decision.operation === "PRESS_ESCAPE") {
          const key = decision.operation === "PRESS_RETURN" ? "return" : "escape";
          ({ attempts, outcome } = await this.#climb(state, null, (t, delivery) => this.#driver.pressKey(t, key, delivery)));
        } else {
          const direction = decision.operation === "SCROLL_DOWN" ? "down" : "up";
          const target: ActionTarget = { kind: "focused", pid: state.pid, windowId: state.window_id };
          const started = performance.now();
          const result = await this.#driver.scroll(target, direction, 3, "background");
          attempts = [attempt("ax", result, "scrolled", started)];
          outcome = "control";
        }
      } catch (error) {
        if (error instanceof DriverRefusal) {
          steps.push({ ...base, text, attempts, outcome: "exhausted", windowChanged: null, observeMs: 0, note: error.message });
          return { status: "refused", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: error.message };
        }
        throw error;
      }

      actionsUsed += 1;
      if (decision.operation !== "WAIT") await this.#sleep(this.#settings.settleMs);
      const observeStarted = performance.now();
      state = await this.#observe(context.pid, windowId);
      const observeMs = Math.round(performance.now() - observeStarted);
      const windowChanged = fingerprint(state) !== before;

      steps.push({ ...base, text, attempts, outcome, windowChanged, observeMs, note });
      history.push({
        operation: decision.operation,
        target: decision.target?.label ?? null,
        text: text?.value ?? null,
        effect: attempts.at(-1)?.effect ?? null,
        windowChanged,
      });

      // Three consecutive actions that moved nothing is a stall, not a plan (jev-ultrafast's rule).
      const recent = history.slice(-3);
      if (recent.length === 3 && recent.every((h) => h.windowChanged === false && h.operation !== "WAIT")) {
        return { status: "stalled", steps, state, actionsSpent: actionsUsed - context.actionsUsed, note: "three actions in a row changed nothing on screen" };
      }
    }
  }

  /** Climb the ladder for one action: try a rung, read the driver's signals, settle or climb. */
  async #climb(
    state: WindowState,
    element: Element | null,
    act: (target: ActionTarget, delivery: "background" | "foreground") => Promise<ActionResult>,
    expectedValue: string | null = null,
  ): Promise<{ attempts: AttemptRecord[]; outcome: "settled" | "exhausted" }> {
    const attempts: AttemptRecord[] = [];
    const before = fingerprint(state);
    let window: WindowRecord | null = null;
    let rung: Rung = "ax";
    for (;;) {
      if (rung === "px" && window === null) {
        window = (await this.#driver.listWindows(state.pid)).find((w) => w.window_id === state.window_id) ?? null;
      }
      const target = targetFor(rung, element, state, window);
      if (target === null) {
        // No geometry for the px rung (or no element for a key press): skip it, do not aim at a guess.
        const next: Rung | undefined = RUNGS[RUNGS.indexOf(rung) + 1];
        if (next === undefined) return { attempts, outcome: "exhausted" };
        rung = next;
        continue;
      }
      const started = performance.now();
      let result: ActionResult;
      try {
        result = await act(target, deliveryFor(rung));
      } catch (error) {
        // A rung the driver refuses is a rung that failed, not a run that failed: the px rung is
        // refused with px_capture_unavailable whenever screen capture is not consented, and the
        // ladder still has foreground above it (SONNY-517, first live run).
        if (!(error instanceof DriverRefusal)) throw error;
        attempts.push({ rung, effect: "refused", route: null, escalation: null, verdict: `refused: ${error.message.replace(/^\w+ refused: /, "")}`.slice(0, 200), driverMs: Math.round(performance.now() - started) });
        const next: Rung | undefined = RUNGS[RUNGS.indexOf(rung) + 1];
        if (next === undefined) return { attempts, outcome: "exhausted" };
        rung = next;
        continue;
      }
      const fresh = await this.#observe(state.pid, state.window_id);
      const verdict = nextRung(rung, result, {
        windowChanged: fingerprint(fresh) !== before,
        valueMatches: element !== null && expectedValue !== null && valueReflects(fresh, element, expectedValue),
      });
      attempts.push(attempt(rung, result, describe(verdict), started));
      if (verdict.kind === "settled") return { attempts, outcome: "settled" };
      if (verdict.kind === "exhausted") return { attempts, outcome: "exhausted" };
      rung = verdict.to;
    }
  }

  /**
   * Typing replaces: a field that already holds text gets select-all first so the value is set
   * rather than appended to (jev-ultrafast does the same through the browser). A failed select-all
   * is not fatal — the type still runs and the value check after it says whether it landed.
   */
  async #typeInto(target: ActionTarget, field: Candidate, value: string, delivery: "background" | "foreground"): Promise<ActionResult> {
    if (field.value && target.kind === "element") {
      await this.#driver.hotkey(target, ["cmd", "a"], delivery).catch(() => undefined);
    }
    return this.#driver.typeText(target, value, delivery);
  }

  /**
   * Observe the window; if it is gone or its tree no longer resolves, fall back to whichever of the
   * app's windows does. A window a button closed can outlive its close as a hidden, degraded window
   * — TextEdit's Open panel did, after "New Document", while the new Untitled document sat on
   * screen unobserved for eleven turns (SONNY-517, first live run).
   */
  async #observe(pid: number, windowId: number): Promise<WindowState> {
    let degraded: WindowState | null = null;
    try {
      const state = await this.#driver.windowState(pid, windowId, { screenshot: false });
      if (state.snapshot_id && !state.degraded_reason) return state;
      degraded = state;
    } catch (error) {
      if (!(error instanceof DriverRefusal) || error.code !== "window_id_not_found") throw error;
    }
    // An open menu or a page mid-navigation can leave every window unresolved for a moment; a
    // closed window stays that way. Three tries a half-second apart tell the two apart.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const resolved = await resolveWindow(this.#driver, pid, await this.#driver.listWindows(pid));
      if (resolved !== null) return resolved;
      await this.#sleep(500);
    }
    if (degraded !== null) return degraded;
    throw new DriverRefusal("get_window_state", { code: "window_id_not_found", message: `no window of pid ${pid} resolves` });
  }
}

/**
 * Which of an app's windows to drive. `list_windows` returns the per-display menu-bar shims
 * (1920x30, off screen, high z_index) beside the real window, and a shim's tree comes back empty
 * with `degraded_reason: ax_window_unresolved` — measured on Calculator (SONNY-517 probe at
 * 41a1529d). So candidates are tried in preference order and the first whose tree resolves wins;
 * a z_index alone would have picked a shim every time.
 */
export async function resolveWindow(driver: Driver, pid: number, windows: readonly WindowRecord[]): Promise<WindowState | null> {
  for (const window of rankWindows(windows).slice(0, 6)) {
    try {
      const state = await driver.windowState(pid, window.window_id, { screenshot: false });
      if (!state.degraded_reason && state.snapshot_id) return state;
    } catch (error) {
      if (!(error instanceof DriverRefusal)) throw error;
    }
  }
  return null;
}

/** On-screen first, then anything taller than a menu bar, then the larger window, then z-order. */
export function rankWindows(windows: readonly WindowRecord[]): WindowRecord[] {
  const score = (w: WindowRecord): number => {
    const b = w.bounds;
    const area = b ? b.width * b.height : 0;
    return (w.is_on_screen === true ? 1e12 : 0) + (b && b.height > 40 ? 1e9 : 0) + area + (w.z_index ?? 0) / 1e3;
  };
  return [...windows].sort((a, b) => score(b) - score(a));
}

function attempt(rung: Rung, result: ActionResult, verdict: string, started: number): AttemptRecord {
  return {
    rung,
    effect: result.effect,
    route: result.route ?? null,
    escalation: result.escalation.recommended ?? null,
    verdict,
    driverMs: Math.round(performance.now() - started),
  };
}

function describe(verdict: ReturnType<typeof nextRung>): string {
  switch (verdict.kind) {
    case "settled":
      return `settled: ${verdict.reason}`;
    case "climb":
      return `climb to ${verdict.to}: ${verdict.reason}`;
    case "exhausted":
      return `exhausted: ${verdict.reason}`;
  }
}

function topOperations(decision: Decision): Array<[string, number]> {
  return Object.entries(decision.operationProbabilities)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([k, v]) => [k, Math.round(v * 100) / 100]);
}

function stepBase(step: number, instruction: string, decision: Decision, modelMs: number, candidates: number, truncated: number) {
  return {
    step,
    instruction,
    operation: decision.operation,
    targetKey: decision.target?.key ?? null,
    targetLabel: decision.target?.label ?? null,
    confidence: decision.confidence,
    targetConfidence: decision.targetConfidence,
    topOperations: topOperations(decision),
    modelMs,
    text: null,
    attempts: [] as AttemptRecord[],
    windowChanged: null,
    observeMs: 0,
    candidates,
    truncated,
    offered: decision.offered,
  };
}

/** After a type: does the same element in the fresh snapshot now hold what was typed? */
export function valueReflects(fresh: WindowState, element: Element, typed: string): boolean {
  const same = fresh.elements.find((e) => e.element_index === element.element_index && e.role === element.role);
  return typeof same?.value === "string" && same.value.includes(typed);
}

/** The words on screen, for the text helper: the markdown tree when the driver sends it, else the labels. */
export function visibleText(state: WindowState): string {
  if (state.tree_markdown) {
    return state.tree_markdown
      .replace(/\[element_index \d+\]/g, "")
      .replace(/[#*`>-]+/g, " ")
      .replace(/[ \t]+/g, " ")
      .trim();
  }
  return state.elements
    .map((e) => [e.label, typeof e.value === "string" ? e.value : null].filter(Boolean).join(": "))
    .filter((line) => line.length > 0)
    .join("\n");
}
