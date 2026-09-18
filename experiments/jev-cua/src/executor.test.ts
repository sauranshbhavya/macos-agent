import { describe, expect, it } from "vitest";
import { DriverRefusal } from "./driver/types.ts";
import { Executor, frontmost, valueReflects, visibleText, type ExecutorSettings } from "./executor.ts";
import { actionResult, element, FakeActionModel, FakeDriver, FakeTextHelper, instantSleep, windowRecord, windowState } from "./testSupport/fakes.ts";

const settings: ExecutorSettings = { maxActions: 10, minOperationConfidence: 0.35, waitMs: 0, settleMs: 0 };
const button = element({ element_index: 3, label: "Search" });
const field = element({ element_index: 9, role: "AXTextField", actions: null, label: "From", value: "old" });

function executor(driver: FakeDriver, script: ConstructorParameters<typeof FakeActionModel>[0], texts: Array<string | null> = [], overrides: Partial<ExecutorSettings> = {}) {
  const actionModel = new FakeActionModel(script);
  const textHelper = new FakeTextHelper(texts);
  const run = new Executor({ driver, actionModel, textHelper, settings: { ...settings, ...overrides }, sleep: instantSleep });
  return { run, actionModel, textHelper };
}

const context = { pid: 42, windowId: 7, goal: "g", instruction: "i", actionsUsed: 0, history: [] };

describe("Executor.runInstruction", () => {
  it("settles a confirmed click on the accessibility rung in one attempt and records it", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("done");
    expect(outcome.actionsSpent).toBe(1);
    const click = outcome.steps[0];
    expect(click).toMatchObject({ operation: "CLICK", targetKey: "3", targetLabel: "Search", outcome: "settled", windowChanged: false });
    expect(click?.attempts).toEqual([expect.objectContaining({ rung: "ax", effect: "confirmed", verdict: "settled: confirmed" })]);
    expect(driver.calls.filter((c) => c.tool === "click")).toEqual([
      expect.objectContaining({ delivery: "background", target: expect.objectContaining({ kind: "element", elementIndex: 3, snapshotId: "s00000001" }) }),
    ]);
  });

  it("climbs from ax to px when the driver could not verify and nothing on screen moved", async () => {
    const driver = new FakeDriver([windowState([button])], [windowRecord({ bounds: { x: 0, y: 0, width: 800, height: 600 } })]);
    driver.results["click"] = [actionResult("unverifiable"), actionResult("confirmed")];
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    const attempts = outcome.steps[0]?.attempts ?? [];
    expect(attempts.map((a) => [a.rung, a.effect])).toEqual([["ax", "unverifiable"], ["px", "confirmed"]]);
    expect(attempts[0]?.verdict).toContain("climb to px");
    const clicks = driver.calls.filter((c) => c.tool === "click");
    expect(clicks[1]?.target).toEqual({ kind: "pixel", pid: 42, windowId: 7, x: 140, y: 112 });
    expect(driver.calls.some((c) => c.tool === "list_windows")).toBe(true);
  });

  it("follows a foreground recommendation straight past px", async () => {
    const driver = new FakeDriver([windowState([button])]);
    driver.results["click"] = [actionResult("unverifiable", { recommended: "foreground", reason: "focus-polling app" }), actionResult("confirmed")];
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.steps[0]?.attempts.map((a) => a.rung)).toEqual(["ax", "foreground"]);
    expect(driver.calls.filter((c) => c.tool === "click")[1]?.delivery).toBe("foreground");
  });

  it("reports an exhausted ladder as a step outcome and keeps going rather than throwing", async () => {
    const driver = new FakeDriver([windowState([button])]);
    driver.results["click"] = [actionResult("suspected_noop"), actionResult("suspected_noop"), actionResult("suspected_noop")];
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "BLOCKED" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("blocked");
    expect(outcome.steps[0]?.outcome).toBe("exhausted");
    expect(outcome.steps[0]?.attempts.map((a) => a.rung)).toEqual(["ax", "px", "foreground"]);
  });

  it("types through the helper, selects existing text first, and settles when the fresh value holds the text", async () => {
    const after = windowState([button, { ...field, value: "Zurich" }]);
    const driver = new FakeDriver([windowState([button, field]), after]);
    driver.results["type_text"] = [actionResult("unverifiable")];
    const { run, textHelper } = executor(driver, [{ operation: "TYPE_TEXT", targetKey: "9" }, { operation: "DONE" }], ["Zurich"]);
    const outcome = await run.runInstruction(context);
    expect(outcome.steps[0]).toMatchObject({ operation: "TYPE_TEXT", outcome: "settled", text: { value: "Zurich", model: "fake-text" } });
    expect(outcome.steps[0]?.attempts[0]?.verdict).toBe("settled: value_matches");
    const tools = driver.calls.map((c) => c.tool);
    expect(tools.indexOf("hotkey")).toBeLessThan(tools.indexOf("type_text"));
    expect(driver.calls.find((c) => c.tool === "hotkey")?.extra["keys"]).toEqual(["cmd", "a"]);
    expect(driver.calls.find((c) => c.tool === "type_text")?.extra["text"]).toBe("Zurich");
    expect(textHelper.inputs[0]?.field.label).toBe("From");
  });

  it("does not select-all into an empty field", async () => {
    const empty = { ...field, value: "" };
    const driver = new FakeDriver([windowState([empty])]);
    const { run } = executor(driver, [{ operation: "TYPE_TEXT", targetKey: "9" }, { operation: "DONE" }], ["Zurich"]);
    await run.runInstruction(context);
    expect(driver.calls.some((c) => c.tool === "hotkey")).toBe(false);
  });

  it("types nothing when the helper says the goal does not say what to type", async () => {
    const driver = new FakeDriver([windowState([field])]);
    const { run } = executor(driver, [{ operation: "TYPE_TEXT", targetKey: "9" }, { operation: "DONE" }], [null]);
    const outcome = await run.runInstruction(context);
    expect(outcome.steps[0]).toMatchObject({ outcome: "skipped", note: expect.stringContaining("nothing in the goal") });
    expect(driver.calls.some((c) => c.tool === "type_text" || c.tool === "hotkey")).toBe(false);
  });

  it("hands a low-confidence operation back to the coordinator without acting", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3", confidence: 0.2 }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("low_confidence");
    expect(outcome.actionsSpent).toBe(0);
    expect(driver.calls.some((c) => c.tool === "click")).toBe(false);
  });

  it("accepts DONE at any confidence", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [{ operation: "DONE", confidence: 0.1 }]);
    expect((await run.runInstruction(context)).status).toBe("done");
  });

  it("calls a stall after three actions that changed nothing", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [
      { operation: "CLICK", targetKey: "3" },
      { operation: "CLICK", targetKey: "3" },
      { operation: "CLICK", targetKey: "3" },
      { operation: "DONE" },
    ]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("stalled");
    expect(outcome.steps).toHaveLength(3);
  });

  it("does not count WAIT towards a stall", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [
      { operation: "CLICK", targetKey: "3" },
      { operation: "WAIT" },
      { operation: "CLICK", targetKey: "3" },
      { operation: "DONE" },
    ]);
    expect((await run.runInstruction(context)).status).toBe("done");
  });

  it("stops at the run's action budget, counting actions spent by earlier instructions", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "CLICK", targetKey: "3" }], [], { maxActions: 5 });
    const outcome = await run.runInstruction({ ...context, actionsUsed: 4 });
    expect(outcome.status).toBe("budget");
    expect(outcome.actionsSpent).toBe(1);
  });

  it("presses Return at the focused element and skips the px rung for a key", async () => {
    const driver = new FakeDriver([windowState([button])]);
    driver.results["press_key"] = [actionResult("unverifiable"), actionResult("confirmed")];
    const { run } = executor(driver, [{ operation: "PRESS_RETURN" }, { operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.steps[0]?.attempts.map((a) => a.rung)).toEqual(["ax", "foreground"]);
    const presses = driver.calls.filter((c) => c.tool === "press_key");
    expect(presses[0]).toMatchObject({ target: { kind: "focused" }, delivery: "background", extra: { key: "return" } });
    expect(presses[1]?.delivery).toBe("foreground");
  });

  it("scrolls the focused region without a ladder", async () => {
    const driver = new FakeDriver([windowState([button])]);
    const { run } = executor(driver, [{ operation: "SCROLL_DOWN" }, { operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    expect(driver.calls.find((c) => c.tool === "scroll")).toMatchObject({ extra: { direction: "down", amount: 3 } });
    expect(outcome.steps[0]?.outcome).toBe("control");
  });

  it("falls back to the app's frontmost window when the one it was given is gone", async () => {
    const driver = new FakeDriver([windowState([button], { window_id: 8 })], [windowRecord({ window_id: 8, z_index: 5 }), windowRecord({ window_id: 2, z_index: 1 })]);
    driver.windowStateError = new DriverRefusal("get_window_state", { code: "window_id_not_found" });
    const { run } = executor(driver, [{ operation: "DONE" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("done");
    expect(driver.calls.filter((c) => c.tool === "get_window_state").map((c) => c.extra["windowId"])).toEqual([7, 8]);
  });

  it("surfaces any other driver refusal as a refused outcome", async () => {
    const driver = new FakeDriver([windowState([button])]);
    driver.click = async () => {
      throw new DriverRefusal("click", { code: "stale_element_token", message: "re-snapshot" });
    };
    const { run } = executor(driver, [{ operation: "CLICK", targetKey: "3" }]);
    const outcome = await run.runInstruction(context);
    expect(outcome.status).toBe("refused");
    expect(outcome.note).toContain("stale_element_token");
  });

  it("feeds the recent-action history, including effects and screen changes, back to the action model", async () => {
    const changed = windowState([button, element({ element_index: 4, label: "Results" })]);
    const driver = new FakeDriver([windowState([button]), changed]);
    const { run, actionModel } = executor(driver, [{ operation: "CLICK", targetKey: "3" }, { operation: "DONE" }]);
    await run.runInstruction({ ...context, history: [{ operation: "WAIT", target: null, text: null, effect: null, windowChanged: false }] });
    expect(actionModel.inputs[1]?.recentActions).toEqual([
      { operation: "WAIT", target: null, text: null, effect: null, windowChanged: false },
      { operation: "CLICK", target: "Search", text: null, effect: "confirmed", windowChanged: true },
    ]);
  });
});

describe("frontmost", () => {
  it("prefers on-screen windows and the highest z_index, tolerating null z_index", () => {
    expect(frontmost([windowRecord({ window_id: 1, z_index: null }), windowRecord({ window_id: 2, z_index: 3 }), windowRecord({ window_id: 3, z_index: 9, is_on_screen: false })])?.window_id).toBe(2);
    expect(frontmost([windowRecord({ window_id: 3, z_index: 9, is_on_screen: false })])?.window_id).toBe(3);
    expect(frontmost([])).toBeNull();
  });
});

describe("valueReflects and visibleText", () => {
  it("matches the same element by index and role", () => {
    const fresh = windowState([{ ...field, value: "Zurich (ZRH)" }]);
    expect(valueReflects(fresh, field, "Zurich")).toBe(true);
    expect(valueReflects(fresh, { ...field, role: "AXTextArea" }, "Zurich")).toBe(false);
    expect(valueReflects(fresh, field, "London")).toBe(false);
  });

  it("prefers the markdown tree, stripped of index tags and markup, and falls back to labels", () => {
    expect(visibleText(windowState([], { tree_markdown: "- **Search** [element_index 3]\n  - From: ZRH" }))).toBe("Search \n From: ZRH");
    expect(visibleText(windowState([button, field]))).toBe("Search\nFrom: old");
  });
});
