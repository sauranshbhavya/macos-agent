/**
 * The screen agent: the planner's subagent for work inside one app's window (V2 plan decision 7).
 *
 * It sees only the objective the planner gave it, fresh observations and its own steps. It never
 * asks the user directly: when it needs a person, it returns to the planner, which decides whether
 * to ask. Its state is the part of the transcript after the planner started it.
 */
import { randomUUID } from "node:crypto";
import { z } from "zod/v4";
import type { AgentNote, OutboundMessage, TurnContext } from "../agent.js";
import { estimateRequestTokens } from "../model/adapter.js";
import { chooseTier, type ModelRouter } from "../model/router.js";
import {
  effectSchema,
  EFFECTS,
  type Action,
  type ActionResult,
  type Effect,
  type ObservationBody,
} from "../protocol.js";
import type { StoredMessage } from "../tasks/store.js";
import {
  SCREEN_DECISION_SCHEMA,
  SCREEN_DECISION_SCHEMA_NAME,
  SCREEN_TOOLS,
  screenPrompt,
} from "./prompt.js";

export interface ScreenTaskSpec {
  readonly app: string;
  readonly objective: string;
  readonly doneWhen: string | null;
  /** What the person asked for. The planner wrote the objective, having read untrusted content,
   * so the person's request is what the objective is checked against. */
  readonly request: string;
}

export type ScreenResultStatus = "done" | "failed" | "needs_clarification" | "outcome_unknown";

export interface ScreenResult {
  readonly status: ScreenResultStatus;
  readonly summary: string;
}

export type ScreenStep =
  | { readonly kind: "messages"; readonly notes: AgentNote[]; readonly messages: OutboundMessage[] }
  | { readonly kind: "returned"; readonly notes: AgentNote[]; readonly result: ScreenResult };

/** A screen session gives up after this many steps; the planner hears why. */
export const MAX_SCREEN_STEPS = 30;
const MAX_OUTPUT_TOKENS = 1200;
const DEFAULT_SCROLL = 3;

const decisionSchema = z.object({
  kind: z.enum(["act", "observe", "done", "failed", "need_help"]),
  tool: z.enum(SCREEN_TOOLS).nullable(),
  ref: z.string().nullable(),
  text: z.string().nullable(),
  keys: z.array(z.string()).nullable(),
  menu_path: z.array(z.string()).nullable(),
  direction: z.enum(["up", "down", "left", "right"]).nullable(),
  x: z.number().nullable(),
  y: z.number().nullable(),
  effect: effectSchema,
  expect: z.string().nullable(),
  want_screenshot: z.boolean(),
  message: z.string().nullable(),
  unsure: z.boolean(),
});
type Decision = z.infer<typeof decisionSchema>;

/** What each step note records: enough to describe the step in later prompts. */
interface StepNote {
  readonly kind: Decision["kind"] | "open_app" | "look";
  readonly actionId?: string;
  readonly description: string;
  readonly screenshot?: boolean;
  /** The model said it was unsure of this step, so the next one goes to a stronger tier. */
  readonly unsure?: boolean;
}

export const SCREEN_STEP_NOTE = "screen.step";

function observationOf(message: StoredMessage): ObservationBody {
  return message.body as ObservationBody;
}

function fingerprint(observation: ObservationBody): string {
  return JSON.stringify(observation.ax?.nodes.map((node) => [node.role, node.label, node.value, node.selected, node.focused]) ?? null);
}

function stepNotes(session: readonly StoredMessage[]): StepNote[] {
  return session.filter((m) => m.direction === "note" && m.type === SCREEN_STEP_NOTE).map((m) => m.body as StepNote);
}

/** The history the model sees: each earlier step and how it ended. */
function historyOf(session: readonly StoredMessage[]): string[] {
  const results = new Map<string, ActionResult>();
  for (const message of session) {
    if (message.direction === "in" && message.type === "outcome") {
      for (const result of (message.body as { results: ActionResult[] }).results) results.set(result.action_id, result);
    }
  }
  return stepNotes(session)
    .filter((note) => note.kind !== "look")
    .map((note) => {
      const result = note.actionId ? results.get(note.actionId) : undefined;
      if (!result) return note.description;
      const detail = result.error?.message ?? result.evidence;
      return `${note.description} → ${result.status}${detail ? ` (${detail})` : ""}`;
    });
}

export class ScreenAgent {
  constructor(private readonly router: ModelRouter) {}

  /**
   * One step of a screen session. `session` is every transcript entry after the planner started
   * this session, including notes written earlier in the same turn.
   */
  async step(context: TurnContext, spec: ScreenTaskSpec, session: readonly StoredMessage[]): Promise<ScreenStep> {
    const notes = stepNotes(session);
    if (notes.length >= MAX_SCREEN_STEPS) {
      return returned({ status: "failed", summary: `Stopped after ${MAX_SCREEN_STEPS} steps without finishing.` });
    }
    const exchanged = session.filter((m) => m.direction !== "note");
    const last = exchanged.at(-1);

    if (last === undefined || last.direction === "out") {
      return look(spec.app, false);
    }
    if (last.type === "outcome") {
      const results = (last.body as { results: ActionResult[] }).results;
      // An unknown end reaches here only once the person has checked and chosen to continue (the
      // Mac pauses first); either way the window shows what happened, so look again.
      const declined = results.find((r) => r.status === "declined");
      if (declined) return returned({ status: "failed", summary: "You chose not to go ahead with that step." });
      const screenshot = notes.at(-1)?.screenshot ?? false;
      return look(spec.app, screenshot);
    }
    if (last.type !== "observation") {
      return returned({ status: "failed", summary: "The screen session lost its place." });
    }

    const observation = observationOf(last);
    const appForActions = observation.app?.bundle_id ?? spec.app;
    if (observation.error) {
      switch (observation.error.code) {
        case "permission_denied":
          return returned({
            status: "failed",
            summary: "Sonny needs Accessibility and Screen Recording permission to work in apps.",
          });
        case "app_not_running":
        case "no_window": {
          if (notes.some((note) => note.kind === "open_app")) {
            return returned({ status: "failed", summary: `${spec.app} did not open a window Sonny could use.` });
          }
          const action: Action = {
            action_id: randomUUID(),
            effect: "navigate",
            expect: `${spec.app} is open with a window`,
            operation: { name: "open_app", version: 1, args: { app: spec.app } },
          };
          return propose([{ kind: "open_app", actionId: action.action_id, description: `open ${spec.app}` }], action);
        }
        case "unreadable":
          if (!notes.some((note) => note.screenshot)) return look(spec.app, true);
          return returned({ status: "failed", summary: "Sonny could not read this app's window." });
        case "foreground_unavailable":
          return returned({ status: "failed", summary: `Sonny could not bring ${spec.app} to the front.` });
      }
    }

    const history = historyOf(session);
    const lastLooks = session.filter((m) => m.direction === "in" && m.type === "observation").slice(-3).map((m) => fingerprint(observationOf(m)));
    const stepsWithoutProgress = lastLooks.length >= 3 && new Set(lastLooks).size === 1 ? 2 : 0;
    const screenshot = observation.screenshot ? context.screenshot(last.msgId) : undefined;

    const ambiguityFlagged = [...notes].reverse().find((note) => note.kind === "act")?.unsure === true;
    let feedback: string | null = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const decision = await this.decide(context, spec, observation, screenshot, history, feedback, {
        invalidOutputRetries: attempt,
        stepsWithoutProgress,
        ambiguityFlagged,
      });
      if (decision === null) {
        feedback = "it was not valid JSON for the schema.";
        continue;
      }
      const outcome = this.interpret(decision, spec, observation, appForActions, screenshot !== undefined);
      if (typeof outcome === "string") {
        feedback = outcome;
        continue;
      }
      return outcome;
    }
    return returned({ status: "failed", summary: "Sonny couldn't work out a usable next step in this app." });
  }

  private async decide(
    context: TurnContext,
    spec: ScreenTaskSpec,
    observation: ObservationBody,
    screenshot: string | undefined,
    history: string[],
    feedback: string | null,
    signals: { invalidOutputRetries: number; stepsWithoutProgress: number; ambiguityFlagged: boolean },
  ): Promise<Decision | null> {
    const prompt = screenPrompt({ request: spec.request, objective: spec.objective, doneWhen: spec.doneWhen, observation, history, feedback });
    const images =
      screenshot !== undefined && observation.screenshot
        ? [{ mediaType: observation.screenshot.media_type, base64: screenshot }]
        : [];
    const { tier, reasons } = chooseTier({ purpose: "screen_step", ...signals });
    const request = { ...prompt, images };
    const text = await context.modelCall(
      {
        agent: "screen",
        tier,
        maxInputTokens: estimateRequestTokens(request) + 200,
        maxOutputTokens: MAX_OUTPUT_TOKENS,
        escalatedBecause: reasons,
      },
      (signal) =>
        this.router.run(tier, {
          ...request,
          schemaName: SCREEN_DECISION_SCHEMA_NAME,
          schema: SCREEN_DECISION_SCHEMA,
          maxOutputTokens: MAX_OUTPUT_TOKENS,
          signal,
        }),
    );
    try {
      const parsed = decisionSchema.safeParse(JSON.parse(text));
      return parsed.success ? parsed.data : null;
    } catch {
      return null;
    }
  }

  /** Turns a decision into the next step, or says why it can't be used. */
  private interpret(
    decision: Decision,
    spec: ScreenTaskSpec,
    observation: ObservationBody,
    app: string,
    hasScreenshot: boolean,
  ): ScreenStep | string {
    switch (decision.kind) {
      case "done":
        return returned({ status: "done", summary: decision.message ?? "Done." });
      case "failed":
        return returned({ status: "failed", summary: decision.message ?? "There was no way forward." });
      case "need_help":
        return returned({ status: "needs_clarification", summary: decision.message ?? "Sonny needs you to decide something." });
      case "observe":
        return look(spec.app, decision.want_screenshot);
      case "act":
        break;
    }

    const generation = observation.generation;
    const nodes = observation.ax?.nodes ?? [];
    const element = (): { ref: string; generation: number } | string => {
      const node = nodes.find((n) => n.ref === decision.ref);
      if (!node) return `ref ${decision.ref ?? "(none)"} is not in the current tree.`;
      return { ref: node.ref, generation };
    };
    const effect: Effect = (EFFECTS as readonly string[]).includes(decision.effect) ? decision.effect : "unknown";
    const label = nodes.find((n) => n.ref === decision.ref)?.label;
    const base = { action_id: randomUUID(), effect, ...(decision.expect ? { expect: decision.expect.slice(0, 500) } : {}) };

    let action: Action;
    let description: string;
    switch (decision.tool) {
      case null:
        return "an act needs a tool.";
      case "open_app":
        action = { ...base, operation: { name: "open_app", version: 1, args: { app: spec.app } } };
        description = `open ${spec.app}`;
        break;
      case "press": {
        const ref = element();
        if (typeof ref === "string") return ref;
        action = { ...base, screen: { tool: "press", app, element: ref } };
        description = `press ${ref.ref}${label ? ` "${label}"` : ""}`;
        break;
      }
      case "set_value": {
        const ref = element();
        if (typeof ref === "string") return ref;
        if (decision.text === null) return "set_value needs text.";
        action = { ...base, screen: { tool: "set_value", app, element: ref, value: decision.text } };
        description = `set ${ref.ref}${label ? ` "${label}"` : ""} to "${decision.text.slice(0, 80)}"`;
        break;
      }
      case "type_text": {
        if (!decision.text) return "type_text needs text.";
        const ref = decision.ref === null ? undefined : element();
        if (typeof ref === "string") return ref;
        action = { ...base, screen: { tool: "type_text", app, text: decision.text, ...(ref ? { element: ref } : {}) } };
        description = `type "${decision.text.slice(0, 80)}"`;
        break;
      }
      case "key": {
        const keys = (decision.keys ?? []).map((key) => key.trim().toLowerCase());
        if (keys.length === 0 || keys.length > 5 || keys.some((key) => !/^[a-z0-9]{1,16}$/.test(key))) {
          return "key needs one chord of 1 to 5 lowercase key names, like [\"cmd\",\"n\"].";
        }
        action = { ...base, screen: { tool: "key", app, keys } };
        description = `press keys ${keys.join("+")}`;
        break;
      }
      case "scroll": {
        if (decision.direction === null) return "scroll needs a direction.";
        const ref = decision.ref === null ? undefined : element();
        if (typeof ref === "string") return ref;
        action = {
          ...base,
          screen: { tool: "scroll", app, direction: decision.direction, amount: DEFAULT_SCROLL, ...(ref ? { element: ref } : {}) },
        };
        description = `scroll ${decision.direction}`;
        break;
      }
      case "menu": {
        const path = (decision.menu_path ?? []).map((title) => title.trim()).filter((title) => title.length > 0);
        if (path.length === 0 || path.length > 6) return "menu needs a path of 1 to 6 titles.";
        action = { ...base, screen: { tool: "menu", app, path } };
        description = `choose ${path.join(" › ")}`;
        break;
      }
      case "click_point": {
        const shot = observation.screenshot;
        if (!hasScreenshot || !shot) return "click_point needs a screenshot; observe with want_screenshot first.";
        const { x, y } = decision;
        if (x === null || y === null || x < 0 || y < 0 || x >= shot.width || y >= shot.height) {
          return `click_point needs x and y inside the ${shot.width}x${shot.height} screenshot.`;
        }
        action = { ...base, screen: { tool: "click_point", app, x, y, generation } };
        description = `click at ${Math.round(x)},${Math.round(y)}`;
        break;
      }
    }
    return propose([{ kind: "act", actionId: action.action_id, description, unsure: decision.unsure }], action);
  }
}

function returned(result: ScreenResult): ScreenStep {
  return { kind: "returned", notes: [], result };
}

function look(app: string, screenshot: boolean): ScreenStep {
  return {
    kind: "messages",
    notes: [{ type: SCREEN_STEP_NOTE, body: { kind: "look", description: "look", screenshot } satisfies StepNote }],
    messages: [{ type: "observe", body: { app, ax: true, screenshot } }],
  };
}

function propose(steps: StepNote[], action: Action): ScreenStep {
  return {
    kind: "messages",
    notes: steps.map((body) => ({ type: SCREEN_STEP_NOTE, body })),
    messages: [{ type: "propose", body: { agent: "screen", actions: [action], final: false } }],
  };
}
