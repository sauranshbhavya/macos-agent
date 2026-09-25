/**
 * Runs V2 tasks: stores what the Mac sends, runs the task's agent one turn at a time, stores and
 * delivers what the agent answers, and ends the task.
 *
 * One turn runs at a time per task. A turn is due when the last message in the transcript came from
 * the Mac; that rule is also what makes recovery work, because after a restart or a reconnect a
 * turn that never stored its answer is simply due again.
 */
import { randomUUID } from "node:crypto";
import {
  BudgetExhausted,
  CreditsExhausted,
  ModelUnavailable,
  type AgentFactory,
  type ModelCallSpec,
  type ModelInvocation,
  type OutboundMessage,
  type TurnContext,
  type TurnResult,
} from "../agent.js";
import { creditsFor, type ModelCallLedger, type TokenRates } from "../credits.js";
import {
  PROTOCOL_VERSION,
  serverMessageSchema,
  type ClientTaskMessage,
  type FinishBody,
  type ServerTaskMessage,
} from "../protocol.js";
import type { EndedStatus, StoredMessage, TaskRecord, TaskStore, TurnEntry } from "./store.js";

export interface TaskBudgets {
  readonly maxTurns: number;
  readonly maxModelCalls: number;
  readonly maxWallTimeMs: number;
}

export const DEFAULT_BUDGETS: TaskBudgets = {
  maxTurns: 80,
  maxModelCalls: 120,
  maxWallTimeMs: 30 * 60_000,
};

/** How many recent screenshots the runner keeps in memory per task. Older ones are dropped. */
const SCREENSHOTS_PER_TASK = 2;

export interface RunnerLog {
  info(data: object, message: string): void;
  error(data: object, message: string): void;
}

export interface RunnerDeps {
  readonly store: TaskStore;
  readonly ledger: ModelCallLedger;
  readonly rates: TokenRates;
  readonly agentFor: AgentFactory;
  /** Sends messages to the task's device if it is connected. Undelivered messages wait in the store. */
  readonly deliver: (task: TaskRecord, messages: readonly ServerTaskMessage[]) => void;
  readonly now: () => Date;
  readonly log: RunnerLog;
  readonly budgets?: TaskBudgets;
}

export type StartOutcome = "created" | "duplicate" | "conflict";
export type ReceiveOutcome = "appended" | "duplicate" | "gap" | "ended" | "unknown";

export interface ResumeEntry {
  readonly task: string;
  readonly lastSeqIn: number;
}

export interface ResumedTask {
  readonly task: string;
  readonly state: "live" | "finished" | "unknown";
  readonly lastSeqIn: number;
}

type TaskStart = Extract<ClientTaskMessage, { type: "task.start" }>;
type TaskReply = Exclude<ClientTaskMessage, TaskStart>;

const FINISH_FOR_ERROR: Record<string, FinishBody> = {
  credits: {
    status: "failed",
    summary: "You're out of credits. Top up to keep going.",
    reason: "credits_exhausted",
  },
  budget: {
    status: "failed",
    summary: "This task took more steps than Sonny allows for one task.",
    reason: "budget_exhausted",
  },
  model: {
    status: "failed",
    summary: "Sonny's assistant is unavailable right now. Try again in a moment.",
    reason: "model_unavailable",
  },
  internal: {
    status: "failed",
    summary: "Something went wrong on Sonny's server, so the task stopped.",
    reason: "internal_error",
  },
};

export function wireMessageOf(taskId: string, message: StoredMessage): ServerTaskMessage {
  return {
    v: PROTOCOL_VERSION,
    type: message.type,
    id: message.msgId,
    task: taskId,
    seq: message.seq,
    ...(message.re === null ? {} : { re: message.re }),
    body: message.body,
  } as ServerTaskMessage;
}

/** An observation as the transcript keeps it: the screenshot's pixels are not written down. */
function storedBodyOf(message: TaskReply): unknown {
  if (message.type !== "observation" || message.body.screenshot === undefined) return message.body;
  const { data: _data, ...rest } = message.body.screenshot;
  return { ...message.body, screenshot: { ...rest, data: "" } };
}

function endedStatusOf(finish: FinishBody): EndedStatus {
  return finish.status;
}

function lastExchanged(transcript: readonly StoredMessage[]): StoredMessage | undefined {
  for (let index = transcript.length - 1; index >= 0; index -= 1) {
    const message = transcript[index]!;
    if (message.direction !== "note") return message;
  }
  return undefined;
}

export class TaskRunner {
  private readonly chains = new Map<string, Promise<void>>();
  private readonly running = new Map<string, AbortController>();
  private readonly screenshots = new Map<string, Map<string, string>>();
  private readonly budgets: TaskBudgets;
  private stopped = false;

  constructor(private readonly deps: RunnerDeps) {
    this.budgets = deps.budgets ?? DEFAULT_BUDGETS;
  }

  async start(accountId: string, deviceId: string, message: TaskStart): Promise<StartOutcome> {
    const body = message.body;
    const outcome = await this.deps.store.createTask(
      {
        id: message.task,
        accountId,
        deviceId,
        isPrivate: body.private,
        unattended: body.unattended,
        goal: body.goal,
        origin: body.origin,
        mode: body.mode,
        priorTask: body.prior_task ?? null,
        start: { msgId: message.id, body },
      },
      this.deps.now(),
    );
    if (outcome === "created") this.schedule(message.task);
    return outcome;
  }

  async receive(accountId: string, message: TaskReply): Promise<ReceiveOutcome> {
    const task = await this.deps.store.task(message.task);
    if (task === undefined || task.accountId !== accountId) return "unknown";
    if (message.type === "observation" && message.body.screenshot !== undefined) {
      this.keepScreenshot(message.task, message.id, message.body.screenshot.data);
    }
    const outcome = await this.deps.store.appendInbound(
      message.task,
      { seq: message.seq, re: message.re ?? null, msgId: message.id, type: message.type, body: storedBodyOf(message) },
      this.deps.now(),
    );
    if (outcome !== "appended") return outcome;
    if (message.type === "task.cancel") {
      await this.cancel(task, message.seq);
    } else {
      this.schedule(message.task);
    }
    return outcome;
  }

  /** The gateway's view of each task a reconnecting Mac lists, and a replay to run after welcome. */
  async resume(
    accountId: string,
    entries: readonly ResumeEntry[],
  ): Promise<{ tasks: ResumedTask[]; replay: () => Promise<void> }> {
    const known: { task: TaskRecord; lastSeqIn: number }[] = [];
    const tasks: ResumedTask[] = [];
    for (const entry of entries) {
      const task = await this.deps.store.task(entry.task);
      if (task === undefined || task.accountId !== accountId) {
        tasks.push({ task: entry.task, state: "unknown", lastSeqIn: 0 });
        continue;
      }
      known.push({ task, lastSeqIn: entry.lastSeqIn });
      tasks.push({
        task: task.id,
        state: task.status === "live" ? "live" : "finished",
        lastSeqIn: task.lastSeqIn,
      });
    }
    const replay = async (): Promise<void> => {
      for (const { task, lastSeqIn } of known) {
        const missed = await this.deps.store.outboundAfter(task.id, lastSeqIn);
        if (missed.length > 0) {
          this.deps.deliver(task, missed.map((message) => wireMessageOf(task.id, message)));
        }
        if (task.status === "live") this.schedule(task.id);
      }
    };
    return { tasks, replay };
  }

  /** Stops every running turn without ending its task, for a shutdown; resume runs it again. */
  async stop(): Promise<void> {
    this.stopped = true;
    for (const controller of this.running.values()) controller.abort(new Error("shutting down"));
    await Promise.allSettled([...this.chains.values()]);
  }

  /** Resolves when every scheduled turn has settled. For tests. */
  async idle(): Promise<void> {
    while (this.chains.size > 0) await Promise.allSettled([...this.chains.values()]);
  }

  private keepScreenshot(taskId: string, msgId: string, data: string): void {
    const kept = this.screenshots.get(taskId) ?? new Map<string, string>();
    kept.set(msgId, data);
    while (kept.size > SCREENSHOTS_PER_TASK) kept.delete(kept.keys().next().value!);
    this.screenshots.set(taskId, kept);
  }

  private schedule(taskId: string): void {
    if (this.stopped) return;
    const previous = this.chains.get(taskId) ?? Promise.resolve();
    const next = previous
      .then(() => this.runTurnIfDue(taskId))
      .catch((error: unknown) => {
        this.deps.log.error({ err: error, task: taskId }, "a task turn failed outside the agent");
      })
      .finally(() => {
        if (this.chains.get(taskId) === next) this.chains.delete(taskId);
      });
    this.chains.set(taskId, next);
  }

  private async cancel(task: TaskRecord, cancelSeq: number): Promise<void> {
    this.running.get(task.id)?.abort(new Error("cancelled"));
    await this.endWith(task, cancelSeq, [], {
      status: "cancelled",
      summary: "Stopped.",
      reason: "cancelled",
    });
  }

  private async runTurnIfDue(taskId: string): Promise<void> {
    const { store, now } = this.deps;
    const task = await store.task(taskId);
    if (task === undefined || task.status !== "live") {
      this.screenshots.delete(taskId);
      return;
    }
    const transcript = await store.transcript(taskId);
    const trigger = lastExchanged(transcript);
    if (trigger === undefined || trigger.direction !== "in") return;

    if (task.turns >= this.budgets.maxTurns) {
      return this.endWith(task, trigger.seq, [], FINISH_FOR_ERROR.budget!);
    }
    if (now().getTime() - task.createdAt.getTime() > this.budgets.maxWallTimeMs) {
      return this.endWith(task, trigger.seq, [], FINISH_FOR_ERROR.budget!);
    }

    const controller = new AbortController();
    this.running.set(taskId, controller);
    let result: TurnResult;
    try {
      result = await this.deps.agentFor(task).turn(this.contextFor(task, transcript, controller.signal));
    } catch (error) {
      if (controller.signal.aborted) return;
      return this.endWith(task, trigger.seq, [], this.finishFor(error, task));
    } finally {
      this.running.delete(taskId);
    }
    if (controller.signal.aborted) return;

    const problem = this.checkTurn(task, result);
    if (problem !== undefined) {
      this.deps.log.error({ task: taskId, problem }, "an agent turn broke the protocol");
      return this.endWith(task, trigger.seq, result.notes ?? [], FINISH_FOR_ERROR.internal!);
    }

    const last = result.messages[result.messages.length - 1]!;
    const end = last.type === "finish" ? endedStatusOf(last.body) : undefined;
    const entries: TurnEntry[] = [
      ...(result.notes ?? []).map((note) => ({
        direction: "note" as const,
        re: null,
        msgId: randomUUID(),
        type: note.type,
        body: note.body,
      })),
      ...result.messages.map((message) => ({
        direction: "out" as const,
        re: trigger.seq,
        msgId: randomUUID(),
        type: message.type,
        body: message.body,
      })),
    ];
    const stored = await store.appendTurn(taskId, entries, now(), end);
    if (stored === undefined) return;
    this.deps.deliver(task, stored.map((message) => wireMessageOf(taskId, message)));
    if (end !== undefined) this.screenshots.delete(taskId);
  }

  /** A turn must end in a message that waits for the Mac or in finish, with finish only last. */
  private checkTurn(task: TaskRecord, result: TurnResult): string | undefined {
    if (result.messages.length === 0) return "the turn sent nothing";
    const waits = new Set(["observe", "propose", "ask", "finish"]);
    const last = result.messages[result.messages.length - 1]!;
    if (!waits.has(last.type)) return `the turn ended with ${last.type}, which waits for nothing`;
    for (const [index, message] of result.messages.entries()) {
      if (index < result.messages.length - 1 && waits.has(message.type)) {
        return `${message.type} came before the end of the turn`;
      }
      const parsed = serverMessageSchema.safeParse({
        v: PROTOCOL_VERSION,
        type: message.type,
        id: randomUUID(),
        task: task.id,
        seq: 1,
        body: message.body,
      });
      if (!parsed.success) return `${message.type} does not match the contract: ${parsed.error.message}`;
    }
    return undefined;
  }

  private finishFor(error: unknown, task: TaskRecord): FinishBody {
    if (error instanceof CreditsExhausted) return FINISH_FOR_ERROR.credits!;
    if (error instanceof BudgetExhausted) return FINISH_FOR_ERROR.budget!;
    if (error instanceof ModelUnavailable) return FINISH_FOR_ERROR.model!;
    this.deps.log.error({ err: error, task: task.id }, "an agent turn threw");
    return FINISH_FOR_ERROR.internal!;
  }

  private async endWith(
    task: TaskRecord,
    re: number,
    notes: TurnResult["notes"] & object,
    finish: FinishBody,
  ): Promise<void> {
    const entries: TurnEntry[] = [
      ...notes.map((note) => ({ direction: "note" as const, re: null, msgId: randomUUID(), type: note.type, body: note.body })),
      { direction: "out", re, msgId: randomUUID(), type: "finish", body: finish },
    ];
    const stored = await this.deps.store.appendTurn(task.id, entries, this.deps.now(), endedStatusOf(finish));
    this.screenshots.delete(task.id);
    if (stored !== undefined) this.deps.deliver(task, stored.map((message) => wireMessageOf(task.id, message)));
  }

  private contextFor(task: TaskRecord, transcript: StoredMessage[], signal: AbortSignal): TurnContext {
    const { store, ledger, rates, now, log } = this.deps;
    const budgets = this.budgets;
    const kept = this.screenshots.get(task.id);
    return {
      task,
      transcript,
      signal,
      screenshot: (msgId) => kept?.get(msgId),
      async modelCall<T>(
        spec: ModelCallSpec,
        invoke: (signal: AbortSignal) => Promise<ModelInvocation<T>>,
      ): Promise<T> {
        signal.throwIfAborted();
        const count = await store.countModelCall(task.id);
        if (count > budgets.maxModelCalls) throw new BudgetExhausted("model_calls");
        const rate = rates[spec.tier];
        const stepId = randomUUID();
        const hold = await ledger.hold({
          stepId,
          accountId: task.accountId,
          taskId: task.id,
          agent: spec.agent,
          tier: spec.tier,
          credits: creditsFor(rate, spec.maxInputTokens, spec.maxOutputTokens),
          now: now(),
        });
        if (hold.kind !== "held") throw new CreditsExhausted();
        let invocation: ModelInvocation<T>;
        try {
          invocation = await invoke(signal);
        } catch (error) {
          await ledger
            .settle({
              stepId,
              credits: 0,
              provider: null,
              model: null,
              inputTokens: null,
              outputTokens: null,
              outcome: signal.aborted ? "cancelled" : "provider_error",
              now: now(),
            })
            .catch((settleError: unknown) =>
              log.error({ err: settleError, stepId }, "a failed model call's hold could not be released"),
            );
          throw error;
        }
        await ledger
          .settle({
            stepId,
            credits: creditsFor(rate, invocation.usage.inputTokens, invocation.usage.outputTokens),
            provider: invocation.provider,
            model: invocation.model,
            inputTokens: invocation.usage.inputTokens,
            outputTokens: invocation.usage.outputTokens,
            outcome: "ok",
            now: now(),
          })
          .catch((settleError: unknown) =>
            log.error({ err: settleError, stepId }, "a model call could not be settled; its hold stands"),
          );
        return invocation.value;
      },
    };
  }
}

export type { OutboundMessage };
