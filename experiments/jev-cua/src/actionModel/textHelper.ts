import type OpenAI from "openai";
import { zodTextFormat } from "openai/helpers/zod";
import { z } from "zod";
import type { Candidate } from "../actionSpace.ts";
import type { RecentAction } from "./jev.ts";
import { TEXT_VALUE } from "./questions.ts";

/**
 * The one place free text is generated: a small model writes the value for a field Jev chose to
 * type into. Its output is a strict JSON object with one key, validated before a character is
 * typed; `null` means the goal does not say what to type, and nothing is typed.
 */

export interface TextHelperInput {
  readonly instruction: string;
  readonly goal: string;
  readonly field: Candidate;
  readonly window: { readonly app: string | null; readonly title: string | null };
  readonly visibleText: string;
  readonly recentActions: readonly RecentAction[];
}

export interface TextHelperResult {
  readonly text: string | null;
  readonly latencyMs: number;
  readonly model: string;
  readonly usage: { readonly input_tokens: number; readonly output_tokens: number } | null;
}

export interface TextHelper {
  fieldText(input: TextHelperInput): Promise<TextHelperResult>;
}

export const fieldTextSchema = z.object({ text: z.string().nullable() });

/** Pins the helper's JSON contract: exactly one key, a non-empty string of sane length, or null. */
export function validateFieldText(output: unknown): string | null {
  const parsed = fieldTextSchema.strict().safeParse(output);
  if (!parsed.success) throw new Error("Text helper returned no valid field value; nothing typed.");
  const { text } = parsed.data;
  if (text === null) return null;
  if (text.trim().length === 0 || text.length > 2000) {
    throw new Error("Text helper returned no valid field value; nothing typed.");
  }
  return text;
}

export function helperContext(input: TextHelperInput): Record<string, unknown> {
  return {
    instruction: input.instruction,
    goal: input.goal,
    field: { label: input.field.label, role: input.field.role, current_value: input.field.value },
    window: { app: input.window.app, title: input.window.title, text: input.visibleText.slice(0, 6000) },
    recent_actions: input.recentActions.slice(-6).map((a) => ({ operation: a.operation, target: a.target, text: a.text })),
  };
}

export class OpenAITextHelper implements TextHelper {
  #client: OpenAI;
  #model: string;

  constructor(client: OpenAI, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async fieldText(input: TextHelperInput): Promise<TextHelperResult> {
    const started = performance.now();
    const response = await this.#client.responses.parse({
      model: this.#model,
      reasoning: { effort: "low" },
      input: [
        { role: "system", content: TEXT_VALUE },
        { role: "user", content: JSON.stringify(helperContext(input)) },
      ],
      text: { format: zodTextFormat(fieldTextSchema, "field_text") },
    });
    const text = validateFieldText(response.output_parsed);
    return {
      text,
      latencyMs: Math.round(performance.now() - started),
      model: response.model,
      usage: response.usage
        ? { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens }
        : null,
    };
  }
}
