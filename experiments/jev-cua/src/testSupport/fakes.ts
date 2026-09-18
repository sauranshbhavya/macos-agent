import type { ActionModel, ActionModelInput, Decision } from "../actionModel/jev.ts";
import type { TextHelper, TextHelperInput, TextHelperResult } from "../actionModel/textHelper.ts";
import type { Candidate, Operation } from "../actionSpace.ts";
import type { ActionTarget, DeliveryMode, Driver, ScrollDirection } from "../driver/driver.ts";
import type { ActionResult, Element, LaunchResult, WindowRecord, WindowState } from "../driver/types.ts";

/** Test doubles. Each records what it was asked so a test can assert the loop's behaviour, not just its result. */

export function element(overrides: Partial<Element> & { element_index: number }): Element {
  return {
    role: "AXButton",
    label: `Element ${overrides.element_index}`,
    actions: ["AXPress"],
    frame: { x: 100, y: 100, w: 80, h: 24 },
    ...overrides,
  };
}

export function windowState(elements: Element[], overrides: Partial<WindowState> = {}): WindowState {
  return {
    snapshot_id: "s00000001",
    pid: 42,
    window_id: 7,
    elements,
    app_name: "FakeApp",
    window_title: "Untitled",
    ...overrides,
  };
}

export function windowRecord(overrides: Partial<WindowRecord> = {}): WindowRecord {
  return { window_id: 7, pid: 42, app_name: "FakeApp", title: "Untitled", bounds: { x: 0, y: 0, width: 800, height: 600 }, z_index: 1, is_on_screen: true, ...overrides };
}

export function actionResult(effect: ActionResult["effect"], escalation: { recommended: "px" | "page" | "foreground" | null; reason: string | null } = { recommended: null, reason: null }): ActionResult {
  return { effect, route: "accessibility", escalation };
}

export interface DriverCall {
  readonly tool: string;
  readonly target: ActionTarget | null;
  readonly delivery: DeliveryMode | null;
  readonly extra: Record<string, unknown>;
}

/**
 * States are served in order, the last one repeating; action results are served per tool in order,
 * defaulting to `confirmed`. A test that wants the window to "change" hands two different states.
 */
export class FakeDriver implements Driver {
  readonly calls: DriverCall[] = [];
  states: WindowState[];
  windows: WindowRecord[];
  results: Partial<Record<string, ActionResult[]>> = {};
  windowStateError: Error | null = null;

  constructor(states: WindowState[], windows: WindowRecord[] = [windowRecord()]) {
    this.states = states;
    this.windows = windows;
  }

  #next(tool: string): ActionResult {
    const queue = this.results[tool];
    const head = queue?.shift();
    return head ?? actionResult("confirmed");
  }

  async launchApp(bundleId: string): Promise<LaunchResult> {
    this.calls.push({ tool: "launch_app", target: null, delivery: null, extra: { bundleId } });
    return { pid: 42, bundle_id: bundleId, windows: this.windows };
  }

  async listWindows(): Promise<WindowRecord[]> {
    this.calls.push({ tool: "list_windows", target: null, delivery: null, extra: {} });
    return this.windows;
  }

  async windowState(pid: number, windowId: number): Promise<WindowState> {
    this.calls.push({ tool: "get_window_state", target: null, delivery: null, extra: { pid, windowId } });
    if (this.windowStateError) {
      const error = this.windowStateError;
      this.windowStateError = null;
      throw error;
    }
    const state = this.states.length > 1 ? this.states.shift() : this.states[0];
    if (state === undefined) throw new Error("FakeDriver has no state to serve");
    return state;
  }

  async click(target: ActionTarget, delivery: DeliveryMode): Promise<ActionResult> {
    this.calls.push({ tool: "click", target, delivery, extra: {} });
    return this.#next("click");
  }

  async typeText(target: ActionTarget, text: string, delivery: DeliveryMode): Promise<ActionResult> {
    this.calls.push({ tool: "type_text", target, delivery, extra: { text } });
    return this.#next("type_text");
  }

  async pressKey(target: ActionTarget, key: string, delivery: DeliveryMode): Promise<ActionResult> {
    this.calls.push({ tool: "press_key", target, delivery, extra: { key } });
    return this.#next("press_key");
  }

  async hotkey(target: ActionTarget, keys: readonly string[], delivery: DeliveryMode): Promise<ActionResult> {
    this.calls.push({ tool: "hotkey", target, delivery, extra: { keys } });
    return this.#next("hotkey");
  }

  async scroll(target: ActionTarget, direction: ScrollDirection, amount: number, delivery: DeliveryMode): Promise<ActionResult> {
    this.calls.push({ tool: "scroll", target, delivery, extra: { direction, amount } });
    return this.#next("scroll");
  }

  async close(): Promise<void> {
    this.calls.push({ tool: "close", target: null, delivery: null, extra: {} });
  }
}

export function decision(operation: Operation, target: Candidate | null = null, confidence = 0.9): Decision {
  return {
    operation,
    target,
    confidence,
    operationProbabilities: { [operation]: confidence, BLOCKED: 1 - confidence },
    targetConfidence: target ? 0.8 : null,
    targetProbabilities: target ? { [target.key]: 1 } : {},
    latencyMs: 5,
    usage: { input_tokens: 10, output_tokens: 1 },
    model: "fake-jev",
  };
}

/** Answers a scripted sequence of decisions; `pick` resolves a target key against the offered space. */
export class FakeActionModel implements ActionModel {
  readonly inputs: ActionModelInput[] = [];
  #script: Array<{ operation: Operation; targetKey?: string; confidence?: number }>;

  constructor(script: Array<{ operation: Operation; targetKey?: string; confidence?: number }>) {
    this.#script = script;
  }

  async choose(input: ActionModelInput): Promise<Decision> {
    this.inputs.push(input);
    const next = this.#script.shift();
    if (next === undefined) throw new Error("FakeActionModel script exhausted");
    let target: Candidate | null = null;
    if (next.targetKey !== undefined) {
      const op = next.operation === "TYPE_TEXT" ? "TYPE_TEXT" : "CLICK";
      target = input.space.targets[op][next.targetKey] ?? null;
      if (target === null) throw new Error(`FakeActionModel: target ${next.targetKey} not offered for ${op}`);
    }
    return decision(next.operation, target, next.confidence ?? 0.9);
  }
}

export class FakeTextHelper implements TextHelper {
  readonly inputs: TextHelperInput[] = [];
  #values: Array<string | null>;

  constructor(values: Array<string | null>) {
    this.#values = values;
  }

  async fieldText(input: TextHelperInput): Promise<TextHelperResult> {
    this.inputs.push(input);
    const value = this.#values.shift();
    if (value === undefined) throw new Error("FakeTextHelper script exhausted");
    return { text: value, latencyMs: 3, model: "fake-text", usage: null };
  }
}

export const instantSleep = async (): Promise<void> => undefined;
