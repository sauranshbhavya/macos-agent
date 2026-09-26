/**
 * What an agent is to the task runner.
 *
 * An agent takes turns. A turn reads the task's transcript and returns the next messages for the
 * Mac, ending in one that waits for the Mac (observe, propose, ask) or in finish. A turn has no side
 * effects beyond model calls and server tools, so the runner may run it again after a crash: the
 * transcript alone is the agent's state.
 */
import type { FinishBody, Manifest, ObserveBody, ProposeBody } from "./protocol.js";
import type { ProposingAgent, Tier } from "./credits.js";
import type { StoredMessage, TaskRecord } from "./tasks/store.js";

export type OutboundMessage =
  | { readonly type: "observe"; readonly body: ObserveBody }
  | { readonly type: "propose"; readonly body: ProposeBody }
  | { readonly type: "ask"; readonly body: { question: string; choices?: string[] } }
  | { readonly type: "progress"; readonly body: { message: string } }
  | { readonly type: "finish"; readonly body: FinishBody };

/** A record an agent keeps in the transcript for its own later turns. The Mac never sees it. */
export interface AgentNote {
  readonly type: string;
  readonly body: unknown;
}

export interface TurnResult {
  readonly notes?: readonly AgentNote[];
  readonly messages: readonly OutboundMessage[];
}

export interface ModelUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
}

/** What one model invocation returns: its value, and what it cost. */
export interface ModelInvocation<T> {
  readonly value: T;
  readonly usage: ModelUsage;
  readonly provider: string;
  readonly model: string;
}

export interface ModelCallSpec {
  readonly agent: ProposingAgent;
  readonly tier: Tier;
  /** The most tokens this call can use, which is what the credit hold covers. */
  readonly maxInputTokens: number;
  readonly maxOutputTokens: number;
  /** Why the router went above the purpose's own tier, if it did. The runner logs it. */
  readonly escalatedBecause?: readonly string[];
}

export interface TurnContext {
  readonly task: TaskRecord;
  readonly transcript: readonly StoredMessage[];
  readonly signal: AbortSignal;
  /** The screenshot of an observation received during this process's life, by message id. */
  screenshot(msgId: string): string | undefined;
  /** What the task's Mac declared it can do, when it is connected to say. */
  manifest(): Manifest | undefined;
  /** A short account of the task this one follows up, when there is one the account can see. */
  priorTask(): Promise<string | undefined>;
  /** Runs one model call under the task's budget and the account's credits. */
  modelCall<T>(spec: ModelCallSpec, invoke: (signal: AbortSignal) => Promise<ModelInvocation<T>>): Promise<T>;
}

export interface Agent {
  turn(context: TurnContext): Promise<TurnResult>;
}

export type AgentFactory = (task: TaskRecord) => Agent;

/** Thrown by `modelCall` when the account can't cover the call. The task ends credits_exhausted. */
export class CreditsExhausted extends Error {
  constructor() {
    super("the account has no credits for the next model call");
    this.name = "CreditsExhausted";
  }
}

/** Thrown when a task has used its model-call, turn or time budget. */
export class BudgetExhausted extends Error {
  constructor(readonly budget: "model_calls" | "turns" | "wall_time") {
    super(`the task used its ${budget} budget`);
    this.name = "BudgetExhausted";
  }
}

/**
 * Thrown by an agent whose turn failed after it had already made progress: `notes` are what the
 * earlier part of the turn decided, which the runner keeps in the transcript as it ends the task.
 */
export class AgentTurnFailed extends Error {
  constructor(
    override readonly cause: unknown,
    readonly notes: readonly AgentNote[],
  ) {
    super(cause instanceof Error ? cause.message : String(cause));
    this.name = "AgentTurnFailed";
  }
}

/** Thrown by a model adapter when every provider for the tier is unavailable. */
export class ModelUnavailable extends Error {
  constructor(message = "no model provider is available") {
    super(message);
    this.name = "ModelUnavailable";
  }
}

/** The agent a gateway runs before a real one is configured: every task ends at once, honestly. */
export const unavailableAgent: AgentFactory = () => ({
  turn: () =>
    Promise.resolve({
      messages: [
        {
          type: "finish",
          body: {
            status: "failed",
            summary: "Sonny's assistant isn't available on this server yet.",
            reason: "unsupported",
          },
        },
      ],
    }),
});
