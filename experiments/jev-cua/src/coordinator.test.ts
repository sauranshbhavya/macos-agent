import { describe, expect, it } from "vitest";
import type OpenAI from "openai";
import { OpenAICoordinator, planSchema, screenSummary, stepsSummary, verdictSchema } from "./coordinator.ts";
import type { InstructionOutcome } from "./executor.ts";
import { element, windowState } from "./testSupport/fakes.ts";

describe("screenSummary", () => {
  it("lists the app, window, offered controls with values, and the visible text", () => {
    const state = windowState([element({ element_index: 3, label: "Search" }), element({ element_index: 9, role: "AXTextField", actions: null, label: "From", value: "ZRH" })], { app_name: "Safari", window_title: "Flights" });
    const summary = screenSummary(state);
    expect(summary).toContain("App: Safari");
    expect(summary).toContain("Window: Flights");
    expect(summary).toContain('[3] button: Search');
    expect(summary).toContain('[9] textfield: From = "ZRH"');
    expect(summary).toContain("From: ZRH");
  });

  it("caps the control list and says how many it left out, and flags a degraded tree", () => {
    const elements = Array.from({ length: 90 }, (_, i) => element({ element_index: i + 1 }));
    const summary = screenSummary(windowState(elements, { degraded_reason: "ax_window_unresolved" }), 80);
    expect(summary).toContain("… and 10 more controls");
    expect(summary).toContain("degraded (ax_window_unresolved)");
  });
});

describe("stepsSummary", () => {
  it("writes one readable line per step plus the outcome", () => {
    const outcome: InstructionOutcome = {
      status: "stalled",
      note: "three actions in a row changed nothing on screen",
      actionsSpent: 2,
      state: windowState([]),
      steps: [
        { step: 1, instruction: "i", operation: "TYPE_TEXT", targetKey: "9", targetLabel: "From", confidence: 0.9, targetConfidence: 0.8, topOperations: [], modelMs: 1, text: { value: "Zurich", latencyMs: 1, model: "m" }, attempts: [{ rung: "ax", effect: "unverifiable", route: null, escalation: null, verdict: "settled: value_matches", driverMs: 1 }], outcome: "settled", windowChanged: true, observeMs: 1, candidates: 2, truncated: 0, note: null },
        { step: 2, instruction: "i", operation: "CLICK", targetKey: "3", targetLabel: "Search", confidence: 0.9, targetConfidence: 0.8, topOperations: [], modelMs: 1, text: null, attempts: [{ rung: "px", effect: "suspected_noop", route: null, escalation: null, verdict: "exhausted", driverMs: 1 }], outcome: "exhausted", windowChanged: false, observeMs: 1, candidates: 2, truncated: 0, note: null },
      ],
    };
    expect(stepsSummary(outcome)).toBe(
      '1. TYPE_TEXT → "From" typed "Zurich" [ax: unverifiable] screen changed\n2. CLICK → "Search" [px: suspected_noop] screen unchanged\nOutcome: stalled — three actions in a row changed nothing on screen',
    );
  });
});

describe("schemas", () => {
  it("require every field, as the strict Responses format does", () => {
    expect(planSchema.safeParse({ understanding: "u", instructions: ["a"], success_criteria: "s" }).success).toBe(true);
    expect(planSchema.safeParse({ understanding: "u", instructions: ["a"] }).success).toBe(false);
    expect(verdictSchema.safeParse({ assessment: "a", verdict: "continue", next_instruction: "n" }).success).toBe(true);
    expect(verdictSchema.safeParse({ assessment: "a", verdict: "maybe", next_instruction: null }).success).toBe(false);
  });
});

describe("OpenAICoordinator", () => {
  function client(output_parsed: unknown): OpenAI {
    return { responses: { parse: async () => ({ output_parsed, model: "gpt-test", usage: { input_tokens: 5, output_tokens: 2 } }) } } as unknown as OpenAI;
  }
  const review = { goal: "g", plan: { understanding: "u", instructions: ["a", "b"], success_criteria: "s" }, instruction: "a", outcome: { status: "done" as const, note: "n" }, stepsSummary: "1. DONE", screen: "App: X", remainingInstructions: ["b"], turnsLeft: 3 };

  it("returns the verdict with the call's timing and usage", async () => {
    const { verdict, call } = await new OpenAICoordinator(client({ assessment: "looks done", verdict: "done", next_instruction: null }), "gpt-test").review(review);
    expect(verdict.verdict).toBe("done");
    expect(call).toMatchObject({ model: "gpt-test", usage: { input_tokens: 5, output_tokens: 2 } });
  });

  it("refuses a continue verdict that carries no next instruction", async () => {
    await expect(new OpenAICoordinator(client({ assessment: "a", verdict: "continue", next_instruction: "  " }), "gpt-test").review(review)).rejects.toThrow(/without a next instruction/);
  });

  it("refuses an empty parse", async () => {
    await expect(new OpenAICoordinator(client(null), "gpt-test").plan("g", "screen")).rejects.toThrow(/no plan/);
  });
});
