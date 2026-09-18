import { choice, type ChoiceQuestion, type EntryType, type TypeSafeClient } from "@typesafe-ai/sdk";
import { z } from "zod";
import {
  CONTROL_OPERATIONS,
  limitTargets,
  offeredCandidates,
  TARGETED_OPERATIONS,
  type ActionSpace,
  type Candidate,
  type Operation,
  type TargetedOperation,
} from "../actionSpace.ts";
import { NEXT_ACTION, TARGET } from "./questions.ts";

/**
 * The action model: Jev picks one operation and, speculatively, one target per operation, in a
 * single TypeSafe request. Nothing here generates text — the operation question's criteria are the
 * operations, the target questions' criteria are the candidates, and the answer is a key.
 */

export interface RecentAction {
  readonly operation: Operation;
  readonly target: string | null;
  readonly text: string | null;
  readonly effect: string | null;
  readonly windowChanged: boolean | null;
}

export interface ActionModelInput {
  readonly instruction: string;
  readonly goal: string;
  readonly window: { readonly app: string | null; readonly title: string | null };
  /**
   * The words on screen — jev-ultrafast's `page.text`. Without it Jev judges from the control
   * table and its own history alone: it pressed Calculator's "4" twice, unable to see the "4"
   * already on the display, and called System Settings DONE with "Wallpaper" as the pane title
   * (SONNY-517, first Jev-as-judge runs). DONE needs evidence, and the evidence is the text.
   */
  readonly visibleText: string;
  readonly space: ActionSpace;
  readonly recentActions: readonly RecentAction[];
}

/** Text past this is cut before the request is fitted; a page's tail rarely decides a step. */
export const MAX_VISIBLE_TEXT_CHARS = 6000;

export interface Decision {
  readonly operation: Operation;
  readonly target: Candidate | null;
  /** How many targets each head offered after fitting the request to Jev's budget. */
  readonly offered: Readonly<Record<TargetedOperation, number>>;
  /** The operation head's confidence — what the executor thresholds. */
  readonly confidence: number;
  readonly operationProbabilities: Readonly<Record<string, number>>;
  readonly targetConfidence: number | null;
  readonly targetProbabilities: Readonly<Record<string, number>>;
  readonly latencyMs: number;
  readonly usage: { readonly input_tokens: number; readonly output_tokens: number } | null;
  readonly model: string;
}

export interface ActionModel {
  choose(input: ActionModelInput): Promise<Decision>;
}

const OPERATION_LABELS: Record<Operation, string> = {
  CLICK: "Click an offered element: a button, link, menu item, checkbox, tab, row, suggestion or calendar day.",
  TYPE_TEXT: "Enter or replace text in an offered editable field on the page or window, not the browser toolbar. A helper model supplies the value from the goal. A combo box that refused typing is a dropdown: CLICK it instead.",
  PRESS_RETURN: "Press Return to submit or confirm the focused field, search or dialog.",
  PRESS_ESCAPE: "Press Escape to close an open menu, sheet, popover or dialog.",
  SCROLL_DOWN: "Scroll the window down because the needed control is plausibly below the visible area.",
  SCROLL_UP: "Scroll the window up because the needed control is plausibly above the visible area.",
  WAIT: "Wait briefly because a submitted action is still loading or the needed control is not yet enabled.",
  DONE: "The current instruction is visibly and fully satisfied.",
  BLOCKED: "No offered operation can make progress on the current instruction.",
};

const choiceAnswerSchema = z.object({
  type: z.literal("choice"),
  choice: z.string(),
  confidence: z.number(),
  probabilities: z.record(z.number()),
});

export interface ValidatedChoice {
  readonly choice: string;
  readonly confidence: number;
  readonly probabilities: Readonly<Record<string, number>>;
}

/**
 * Typed output guarantees the interface, not the arithmetic: the choice must be an offered key,
 * the distribution must cover exactly the offered keys and sum to one, and the choice must be its
 * argmax. Anything else is refused before any action, exactly as jev-ultrafast refuses it.
 */
export function validateChoice(answer: unknown, keys: readonly string[]): ValidatedChoice {
  const parsed = choiceAnswerSchema.safeParse(answer);
  if (!parsed.success) throw new Error("Invalid action-model answer: not a choice; no action executed.");
  const { choice: picked, confidence, probabilities } = parsed.data;
  const offered = new Set(keys);
  const probabilityKeys = Object.keys(probabilities);
  const numbers = [...Object.values(probabilities), confidence];
  const finite = numbers.every((n) => Number.isFinite(n) && n >= 0 && n <= 1);
  const covers = probabilityKeys.length === offered.size && probabilityKeys.every((k) => offered.has(k));
  const sum = Object.values(probabilities).reduce((a, b) => a + b, 0);
  const max = Math.max(...Object.values(probabilities));
  const chosen = probabilities[picked];
  if (!offered.has(picked) || !covers || !finite || Math.abs(sum - 1) >= 0.02 || chosen === undefined || chosen < max - 1e-6) {
    throw new Error("Invalid action-model answer: distribution does not match the offered options; no action executed.");
  }
  return { choice: picked, confidence, probabilities };
}

function targetQuestionKey(operation: TargetedOperation): string {
  return `${operation.toLowerCase()}_target`;
}

/** Build the request body — exported so a test can pin what Jev is asked without a network. */
export function buildRequest(input: ActionModelInput): {
  state: EntryType;
  questions: Record<string, ChoiceQuestion>;
  operations: Operation[];
} {
  const { space } = input;
  const operations: Operation[] = [
    ...TARGETED_OPERATIONS.filter((op) => Object.keys(space.targets[op]).length > 0),
    ...CONTROL_OPERATIONS,
  ];
  const operationCriteria = Object.fromEntries(operations.map((op) => [op, OPERATION_LABELS[op]]));
  const questions: Record<string, ChoiceQuestion> = {
    operation: choice({ instruction: input.instruction, goal: input.goal, rules: NEXT_ACTION }, operationCriteria),
  };
  for (const operation of TARGETED_OPERATIONS) {
    const candidates = Object.values(space.targets[operation]);
    if (candidates.length === 0) continue;
    questions[targetQuestionKey(operation)] = choice(
      { instruction: input.instruction, goal: input.goal, operation, rules: [NEXT_ACTION, TARGET] },
      Object.fromEntries(
        candidates.map((c) => [
          c.key,
          { element: `[${c.key}] ${c.role}: ${c.label}`, current_value: c.value ?? "" },
        ]),
      ),
    );
  }
  const state: EntryType = {
    instruction: input.instruction,
    goal: input.goal,
    window: { app: input.window.app, title: input.window.title, visible_text: input.visibleText.slice(0, MAX_VISIBLE_TEXT_CHARS) },
    // Only what Jev can pick: a candidate past every cap cannot be chosen, so listing it is tokens
    // for nothing — 1,122 of them on Wikipedia's main page blew the request past Jev's budget.
    elements: offeredCandidates(space).map((c) => ({
      index: c.key,
      role: c.role,
      label: c.label,
      value: c.value,
      operations: [...c.operations],
    })),
    recent_actions: input.recentActions.slice(-10).map((a) => ({
      operation: a.operation,
      target: a.target,
      text: a.text,
      effect: a.effect,
      window_changed: a.windowChanged,
    })),
  };
  return { state, questions, operations };
}

/**
 * Jev 1.13 takes 64k tokens per request and 32k for the state plus its longest question
 * (docs.typesafe.ai/models). Characters over four is a coarse token estimate, so the budget sits
 * well under the limit; a request over it halves the per-operation target cap until it fits.
 */
export const REQUEST_BUDGET_CHARS = 90_000;
const MIN_TARGETS = 16;

export function fitToBudget(input: ActionModelInput, budgetChars: number = REQUEST_BUDGET_CHARS): { input: ActionModelInput; request: ReturnType<typeof buildRequest> } {
  let space = input.space;
  let maxTargets = Math.max(...TARGETED_OPERATIONS.map((op) => Object.keys(space.targets[op]).length), MIN_TARGETS);
  for (;;) {
    const request = buildRequest({ ...input, space });
    const stateChars = JSON.stringify(request.state).length;
    const longestQuestion = Math.max(...Object.values(request.questions).map((q) => JSON.stringify(q).length));
    if (stateChars + longestQuestion <= budgetChars || maxTargets <= MIN_TARGETS) return { input: { ...input, space }, request };
    maxTargets = Math.max(MIN_TARGETS, Math.floor(maxTargets / 2));
    space = limitTargets(space, maxTargets);
  }
}

export class JevActionModel implements ActionModel {
  #client: TypeSafeClient;
  #model: string | undefined;

  constructor(client: TypeSafeClient, model?: string) {
    this.#client = client;
    this.#model = model;
  }

  async choose(original: ActionModelInput): Promise<Decision> {
    const { input, request } = fitToBudget(original);
    const { state, questions, operations } = request;
    const started = performance.now();
    const result = await this.#client.systemOne({
      state,
      questions,
      ...(this.#model === undefined ? {} : { model: this.#model }),
    });
    const latencyMs = Math.round(performance.now() - started);
    const answers = result.answers as Record<string, unknown>;
    const operationAnswer = validateChoice(answers["operation"], operations);
    const operation = operationAnswer.choice as Operation;
    let target: Candidate | null = null;
    let targetAnswer: ValidatedChoice | null = null;
    if ((TARGETED_OPERATIONS as readonly string[]).includes(operation)) {
      const targeted = operation as TargetedOperation;
      // Only the head the chosen operation names is read; the unused heads cannot cause an action.
      const group = input.space.targets[targeted];
      targetAnswer = validateChoice(answers[targetQuestionKey(targeted)], Object.keys(group));
      target = group[targetAnswer.choice] ?? null;
      if (target === null) throw new Error("Action model chose a target that is not offered; no action executed.");
    }
    return {
      operation,
      target,
      offered: { CLICK: Object.keys(input.space.targets.CLICK).length, TYPE_TEXT: Object.keys(input.space.targets.TYPE_TEXT).length },
      confidence: operationAnswer.confidence,
      operationProbabilities: operationAnswer.probabilities,
      targetConfidence: targetAnswer?.confidence ?? null,
      targetProbabilities: targetAnswer?.probabilities ?? {},
      latencyMs,
      usage: result.usage ?? null,
      model: result.model,
    };
  }
}
