import { describe, expect, it } from "vitest";
import type OpenAI from "openai";
import { buildActionSpace } from "../actionSpace.ts";
import { element } from "../testSupport/fakes.ts";
import { helperContext, OpenAITextHelper, validateFieldText } from "./textHelper.ts";

describe("validateFieldText", () => {
  it("accepts a string or an explicit null", () => {
    expect(validateFieldText({ text: "Zurich" })).toBe("Zurich");
    expect(validateFieldText({ text: null })).toBeNull();
  });

  it.each([
    ["an extra key", { text: "a", note: "b" }],
    ["a missing key", {}],
    ["a blank string", { text: "   " }],
    ["a value over 2000 characters", { text: "x".repeat(2001) }],
    ["a number", { text: 5 }],
    ["a bare string", "Zurich"],
  ])("refuses %s so nothing is typed", (_name, output) => {
    expect(() => validateFieldText(output)).toThrow(/nothing typed/);
  });
});

describe("helperContext", () => {
  const field = buildActionSpace([element({ element_index: 9, role: "AXTextField", actions: null, label: "From", value: "old" })]).candidates[0]!;

  it("carries the instruction, goal, field, window text and the last six actions only", () => {
    const recentActions = Array.from({ length: 8 }, (_, i) => ({ operation: "CLICK" as const, target: `t${i}`, text: null, effect: "confirmed", windowChanged: true }));
    const context = helperContext({ instruction: "i", goal: "g", field, window: { app: "A", title: "T" }, visibleText: "x".repeat(7000), recentActions });
    expect(context).toMatchObject({ instruction: "i", goal: "g", field: { label: "From", role: "textfield", current_value: "old" } });
    expect((context["window"] as { text: string }).text).toHaveLength(6000);
    expect((context["recent_actions"] as unknown[]).length).toBe(6);
    expect((context["recent_actions"] as Array<{ target: string }>)[0]?.target).toBe("t2");
  });
});

describe("OpenAITextHelper", () => {
  const field = buildActionSpace([element({ element_index: 9, role: "AXTextField", actions: null, label: "From" })]).candidates[0]!;
  const input = { instruction: "i", goal: "g", field, window: { app: null, title: null }, visibleText: "", recentActions: [] };

  function client(output_parsed: unknown): OpenAI {
    return { responses: { parse: async () => ({ output_parsed, model: "gpt-text", usage: { input_tokens: 3, output_tokens: 1 } }) } } as unknown as OpenAI;
  }

  it("returns the validated text with timing and usage", async () => {
    const result = await new OpenAITextHelper(client({ text: "Zurich" }), "gpt-text").fieldText(input);
    expect(result).toMatchObject({ text: "Zurich", model: "gpt-text", usage: { input_tokens: 3, output_tokens: 1 } });
  });

  it("refuses an invalid parse rather than typing it", async () => {
    await expect(new OpenAITextHelper(client({ text: "" }), "gpt-text").fieldText(input)).rejects.toThrow(/nothing typed/);
  });
});
