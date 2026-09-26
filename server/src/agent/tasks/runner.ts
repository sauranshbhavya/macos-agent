/**
 * Runs V2 tasks: stores what the Mac sends, runs the task's agent one turn at a time, stores and
 * delivers what the agent answers, and ends the task.
 *
 * One turn runs at a time per task. A turn is due when the last message in the transcript came from
 * the Mac; that rule is also what makes recovery work, because after a restart or a reconnect a
 * turn that never stored its answer is simply due again.
 */
import { randomUUID } from "node:crypto";
import type { AutoTopUp } from "../../credit/auto-top-up.js";
import {
  AgentTurnFailed,
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
  type Manifest,
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
/**
 * How long a screenshot stays in memory. A turn reads the one it was triggered by within seconds,
 * so this only bounds memory for tasks the runner never hears from again (a Mac that went away,
 * a task the sweep abandoned), which nothing else would ever clear.
 */
export const SCREENSHOT_TTL_MS = 10 * 60_000;
/** And how many tasks may hold screenshots at once, oldest dropped first. */
const MAX_TASKS_WITH_SCREENSHOTS = 1000;
/**
 * The longest one model call may take. It is shorter than the spend-cap reservation's five-minute
 * life (`entitlement/period.ts`), so a reservation is always settled by its own call rather than
 * reclaimed by the operator's sweep first.
 */
export const MODEL_CALL_DEADLINE_MS = 180_000;

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
  /** Overrides `MODEL_CALL_DEADLINE_MS`, for tests. */
  readonly modelCallDeadlineMs?: number;
  /** What a device declared in its hello, while it is connected. */
  readonly manifestFor?: (accountId: string, deviceId: string) => Manifest | undefined;
  /**
   * Buys credits for an account that opted in to automatic top-up, when a model call can't be
   * held. Absent where this deployment sells none.
   */
  readonly topUp?: AutoTopUp;
}

/** How much of a prior task a follow-up sees. */
const PRIOR_TASK_LINES = 12;

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
  private readonly running = new Map<string, { controller: AbortController; accountId: string }>();
  private readonly screenshots = new Map<string, Map<string, { data: string; keptAt: number }>>();
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
    for (const { controller } of this.running.values()) controller.abort(new Error("shutting down"));
    await Promise.allSettled([...this.chains.values()]);
  }

  /** Resolves when every scheduled turn has settled. For tests. */
  async idle(): Promise<void> {
    while (this.chains.size > 0) await Promise.allSettled([...this.chains.values()]);
  }

  /**
   * Stops every running turn of a closed account and ends its tasks, so nothing more is spent for
   * an account that no longer exists.
   */
  async stopAccount(accountId: string): Promise<void> {
    const ending: Promise<void>[] = [];
    for (const [taskId, turn] of this.running) {
      if (turn.accountId !== accountId) continue;
      turn.controller.abort(new Error("account closed"));
      ending.push(
        this.deps.store.end(taskId, "failed", this.deps.now()).then(() => {
          this.screenshots.delete(taskId);
        }),
      );
    }
    await Promise.all(ending);
  }

  private keepScreenshot(taskId: string, msgId: string, data: string): void {
    const now = this.deps.now().getTime();
    this.pruneScreenshots(now);
    const kept = this.screenshots.get(taskId) ?? new Map<string, { data: string; keptAt: number }>();
    kept.set(msgId, { data, keptAt: now });
    while (kept.size > SCREENSHOTS_PER_TASK) kept.delete(kept.keys().next().value!);
    this.screenshots.delete(taskId);
    this.screenshots.set(taskId, kept);
    while (this.screenshots.size > MAX_TASKS_WITH_SCREENSHOTS) {
      this.screenshots.delete(this.screenshots.keys().next().value!);
    }
  }

  private pruneScreenshots(now: number): void {
    for (const [taskId, kept] of this.screenshots) {
      for (const [msgId, entry] of kept) {
        if (now - entry.keptAt >= SCREENSHOT_TTL_MS) kept.delete(msgId);
      }
      if (kept.size === 0) this.screenshots.delete(taskId);
    }
  }

  /** How many tasks hold screenshots in memory. For tests. */
  get tasksWithScreenshots(): number {
    return this.screenshots.size;
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
    this.running.get(task.id)?.controller.abort(new Error("cancelled"));
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
    this.running.set(taskId, { controller, accountId: task.accountId });
    let result: TurnResult;
    try {
      result = await this.deps.agentFor(task).turn(this.contextFor(task, transcript, controller.signal));
    } catch (error) {
      if (controller.signal.aborted) return;
      if (error instanceof AgentTurnFailed) {
        return this.endWith(task, trigger.seq, error.notes, this.finishFor(error.cause, task));
      }
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

  /**
   * The follow-up's view of the task it continues: its goal, what was done and how it ended. Only a
   * task of the same account that still exists counts; a private one is gone by design.
   */
  private async priorTaskSummary(task: TaskRecord): Promise<string | undefined> {
    if (task.priorTask === null) return undefined;
    const prior = await this.deps.store.task(task.priorTask);
    if (prior === undefined || prior.accountId !== task.accountId) return undefined;
    const lines = [`Earlier request: ${prior.goal}`];
    for (const message of await this.deps.store.transcript(prior.id)) {
      if (message.direction === "note" && message.type === "planner.decision") {
        const decision = message.body as { kind: string; actions?: { operation?: { name: string; args: unknown } }[] };
        for (const action of decision.actions ?? []) {
          if (action.operation) lines.push(`Ran ${action.operation.name} ${JSON.stringify(action.operation.args).slice(0, 200)}`);
        }
      } else if (message.direction === "note" && message.type === "screen.start") {
        lines.push(`Worked in ${(message.body as { app: string }).app}: ${(message.body as { objective: string }).objective}`);
      } else if (message.direction === "out" && message.type === "finish") {
        const finish = message.body as FinishBody;
        lines.push(`It ended ${finish.status}: ${finish.summary}`);
      }
    }
    return lines.slice(0, PRIOR_TASK_LINES).join("\n");
  }

  private contextFor(task: TaskRecord, transcript: StoredMessage[], signal: AbortSignal): TurnContext {
    const { store, ledger, rates, now, log, topUp } = this.deps;
    const budgets = this.budgets;
    const deadlineMs = this.deps.modelCallDeadlineMs ?? MODEL_CALL_DEADLINE_MS;
    const kept = this.screenshots.get(task.id);
    return {
      task,
      transcript,
      signal,
      screenshot: (msgId) => kept?.get(msgId)?.data,
      manifest: () => this.deps.manifestFor?.(task.accountId, task.deviceId),
      priorTask: () => this.priorTaskSummary(task),
      async modelCall<T>(
        spec: ModelCallSpec,
        invoke: (signal: AbortSignal) => Promise<ModelInvocation<T>>,
      ): Promise<T> {
        signal.throwIfAborted();
        const count = await store.countModelCall(task.id);
        if (count > budgets.maxModelCalls) throw new BudgetExhausted("model_calls");
        const rate = rates[spec.tier];
        const stepId = randomUUID();
        const held = creditsFor(rate, spec.maxInputTokens, spec.maxOutputTokens);
        const request = {
          stepId,
          accountId: task.accountId,
          taskId: task.id,
          agent: spec.agent,
          tier: spec.tier,
          credits: held,
        };
        let hold = await ledger.hold({ ...request, now: now() });
        // Out of credits, and the account asked to be topped up: buy once, then try once more. A
        // task stopped meanwhile stops waiting at once; the purchase itself runs on and settles.
        if (hold.kind === "insufficient" && topUp !== undefined && (await untilAborted(topUp(task.accountId, held), signal))) {
          hold = await ledger.hold({ ...request, now: now() });
        }
        if (hold.kind !== "held") throw new CreditsExhausted();
        let invocation: ModelInvocation<T>;
        const call = new AbortController();
        const onTurnAbort = (): void => call.abort(signal.reason);
        signal.addEventListener("abort", onTurnAbort, { once: true });
        let deadline: NodeJS.Timeout | undefined;
        try {
          invocation = await Promise.race([
            invoke(call.signal),
            new Promise<never>((_resolve, reject) => {
              deadline = setTimeout(() => {
                const late = new ModelUnavailable("the model call took longer than its deadline");
                call.abort(late);
                reject(late);
              }, deadlineMs);
            }),
          ]);
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
        } finally {
          clearTimeout(deadline);
          signal.removeEventListener("abort", onTurnAbort);
        }
        await ledger
          .settle({
            stepId,
            // Never more than was held: the hold is the most a call can cost, and an input larger
            // than its estimate is the gateway's misjudgement, not the account's.
            credits: Math.min(held, creditsFor(rate, invocation.usage.inputTokens, invocation.usage.outputTokens)),
            provider: invocation.provider,
            model: invocation.model,
            inputTokens: invocation.usage.inputTokens,
            outputTokens: invocation.usage.outputTokens,
            outcome: "ok",
            now: now(),
          })
          .catch((settleError: unknown) =>
            log.error(
              { err: settleError, stepId },
              "a model call could not be settled; the retention sweep releases its hold uncharged",
            ),
          );
        return invocation.value;
      },
    };
  }
}

/** `work`'s answer, or the signal's reason as soon as it aborts. `work` itself is not stopped. */
function untilAborted<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  signal.throwIfAborted();
  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
    work.then(resolve, reject).finally(() => signal.removeEventListener("abort", onAbort));
  });
}

export type { OutboundMessage };
