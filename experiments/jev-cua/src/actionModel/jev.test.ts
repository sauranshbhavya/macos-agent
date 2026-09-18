import { describe, expect, it } from "vitest";
import type { TypeSafeClient } from "@typesafe-ai/sdk";
import { buildActionSpace } from "../actionSpace.ts";
import { element } from "../testSupport/fakes.ts";
import { buildRequest, fitToBudget, JevActionModel, validateChoice } from "./jev.ts";

const good = { type: "choice", choice: "b", confidence: 0.7, probabilities: { a: 0.2, b: 0.7, c: 0.1 } };

describe("validateChoice", () => {
  it("accepts a well-formed distribution whose choice is its argmax", () => {
    expect(validateChoice(good, ["a", "b", "c"]).choice).toBe("b");
  });

  it.each([
    ["a choice that was not offered", { ...good, choice: "z" }],
    ["a distribution missing an offered key", { ...good, probabilities: { a: 0.3, b: 0.7 } }],
    ["a distribution with an extra key", { ...good, probabilities: { ...good.probabilities, d: 0 } }],
    ["a distribution that does not sum to one", { ...good, probabilities: { a: 0.5, b: 0.7, c: 0.1 } }],
    ["a choice that is not the argmax", { ...good, choice: "a" }],
    ["a NaN probability", { ...good, probabilities: { a: Number.NaN, b: 0.7, c: 0.3 } }],
    ["a confidence outside [0, 1]", { ...good, confidence: 1.5 }],
    ["something that is not a choice at all", { type: "noul", noul: 0.5 }],
    ["nothing", undefined],
  ])("refuses %s so no action can follow it", (_name, answer) => {
    expect(() => validateChoice(answer, ["a", "b", "c"])).toThrow(/no action executed/);
  });
});

describe("buildRequest", () => {
  const space = buildActionSpace([
    element({ element_index: 3, label: "Search" }),
    element({ element_index: 9, role: "AXTextField", actions: null, label: "From", value: "ZRH" }),
  ]);
  const input = { instruction: "Search flights", goal: "Find a flight", window: { app: "Safari", title: "Flights" }, space, recentActions: [] };

  it("offers a targeted operation only when it has targets, plus every control operation", () => {
    const { questions, operations } = buildRequest(input);
    expect(operations).toEqual(["CLICK", "TYPE_TEXT", "PRESS_RETURN", "PRESS_ESCAPE", "SCROLL_DOWN", "SCROLL_UP", "WAIT", "DONE", "BLOCKED"]);
    expect(Object.keys(questions)).toEqual(["operation", "click_target", "type_text_target"]);
    const clickOnly = buildRequest({ ...input, space: buildActionSpace([element({ element_index: 3 })]) });
    expect(clickOnly.operations).not.toContain("TYPE_TEXT");
    expect(Object.keys(clickOnly.questions)).toEqual(["operation", "click_target"]);
  });

  it("names each target question's premise operation, since questions cannot see each other", () => {
    const { questions } = buildRequest(input);
    const typeTarget = questions["type_text_target"];
    expect(typeTarget?.instructions).toMatchObject({ operation: "TYPE_TEXT", instruction: "Search flights" });
    expect(Object.keys(typeTarget?.criteria ?? {})).toEqual(["9"]);
    expect(typeTarget?.criteria["9"]).toEqual({ element: "[9] textfield: From", current_value: "ZRH" });
  });

  it("puts the indexed element table and the recent actions in state", () => {
    const { state } = buildRequest({ ...input, recentActions: [{ operation: "CLICK", target: "Search", text: null, effect: "confirmed", windowChanged: true }] });
    expect(state).toMatchObject({
      instruction: "Search flights",
      elements: [{ index: "3", role: "button", label: "Search", operations: ["CLICK"] }, { index: "9", value: "ZRH" }],
      recent_actions: [{ operation: "CLICK", target: "Search", window_changed: true }],
    });
  });
});

describe("JevActionModel.choose", () => {
  const space = buildActionSpace([element({ element_index: 3, label: "Search" }), element({ element_index: 9, role: "AXTextField", actions: null, label: "From" })]);
  const input = { instruction: "i", goal: "g", window: { app: null, title: null }, space, recentActions: [] };

  function client(answers: Record<string, unknown>): TypeSafeClient {
    return { systemOne: async () => ({ model: "jev-test", answers, usage: { input_tokens: 1, output_tokens: 1 } }) } as unknown as TypeSafeClient;
  }

  const operation = (choice: string) => ({
    type: "choice",
    choice,
    confidence: 0.8,
    probabilities: Object.fromEntries(["CLICK", "TYPE_TEXT", "PRESS_RETURN", "PRESS_ESCAPE", "SCROLL_DOWN", "SCROLL_UP", "WAIT", "DONE", "BLOCKED"].map((op) => [op, op === choice ? 0.8 : 0.025])),
  });

  it("reads only the target head the chosen operation names; a broken unused head cannot stop it", async () => {
    const model = new JevActionModel(client({
      operation: operation("CLICK"),
      click_target: { type: "choice", choice: "3", confidence: 1, probabilities: { "3": 1 } },
      type_text_target: { type: "choice", choice: "nonsense", confidence: 1, probabilities: {} },
    }));
    const decision = await model.choose(input);
    expect(decision.operation).toBe("CLICK");
    expect(decision.target?.key).toBe("3");
    expect(decision.targetConfidence).toBe(1);
  });

  it("refuses when the chosen operation's own head is invalid", async () => {
    const model = new JevActionModel(client({
      operation: operation("TYPE_TEXT"),
      click_target: { type: "choice", choice: "3", confidence: 1, probabilities: { "3": 1 } },
      type_text_target: { type: "choice", choice: "3", confidence: 1, probabilities: { "3": 1 } },
    }));
    await expect(model.choose(input)).rejects.toThrow(/no action executed/);
  });

  it("returns a control operation with no target", async () => {
    const model = new JevActionModel(client({ operation: operation("DONE") }));
    const decision = await model.choose(input);
    expect(decision).toMatchObject({ operation: "DONE", target: null, targetConfidence: null, model: "jev-test" });
  });
});

describe("fitToBudget", () => {
  const big = buildActionSpace(Array.from({ length: 200 }, (_, i) => element({ element_index: i + 1, label: `Link number ${i + 1} with a longer label` })));
  const input = { instruction: "i", goal: "g", window: { app: null, title: null }, space: big, recentActions: [] };

  it("leaves a request under budget untouched", () => {
    const { input: fitted } = fitToBudget(input, 1_000_000);
    expect(Object.keys(fitted.space.targets.CLICK)).toHaveLength(200);
  });

  it("halves the target cap until the state plus the longest question fits", () => {
    const { input: fitted, request } = fitToBudget(input, 12_000);
    const offered = Object.keys(fitted.space.targets.CLICK).length;
    expect(offered).toBeLessThan(200);
    expect(offered).toBeGreaterThanOrEqual(16);
    const longest = Math.max(...Object.values(request.questions).map((q) => JSON.stringify(q).length));
    expect(JSON.stringify(request.state).length + longest).toBeLessThanOrEqual(12_000);
    expect((request.state as { elements: unknown[] }).elements).toHaveLength(offered);
  });

  it("stops at the floor rather than looping when even the floor does not fit", () => {
    const { input: fitted } = fitToBudget(input, 10);
    expect(Object.keys(fitted.space.targets.CLICK)).toHaveLength(16);
  });
});
