/**
 * Task retention (V2 plan decisions 10 and 11). An ordinary task is deleted 30 days after it ends;
 * a private one is deleted when it ends, which the store does as part of ending it. The sweep also
 * fails tasks nobody has touched for a day, releases credit holds a process died holding, and clears
 * the replies kept for idempotent retries once their day is up.
 */
import type { ModelCallLedger } from "../credits.js";
import type { SweepOutcome, TaskStore } from "./store.js";

export const TASK_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
export const TASK_ABANDON_AFTER_MS = 24 * 60 * 60 * 1000;
/** Longer than any model call's total deadline, so a hold is only released once its call is over. */
export const HOLD_EXPIRY_MS = 15 * 60 * 1000;

export interface RetentionDeps {
  readonly store: TaskStore;
  readonly ledger: ModelCallLedger;
  /** Clears stored idempotent replies past their day and says how many. */
  readonly pruneReplies: () => Promise<number>;
  readonly now: () => Date;
}

export async function sweepTasksOnce(
  deps: RetentionDeps,
): Promise<SweepOutcome & { releasedHolds: number; prunedReplies: number }> {
  const now = deps.now();
  const swept = await deps.store.sweep(now, {
    retentionMs: TASK_RETENTION_MS,
    abandonAfterMs: TASK_ABANDON_AFTER_MS,
  });
  const releasedHolds = await deps.ledger.expireHolds(new Date(now.getTime() - HOLD_EXPIRY_MS), now);
  const prunedReplies = await deps.pruneReplies();
  return { ...swept, releasedHolds, prunedReplies };
}

export function startTaskRetentionSweeper(
  deps: RetentionDeps & {
    readonly intervalMs: number;
    readonly log: { info(data: object, message: string): void; error(data: object, message: string): void };
  },
): () => void {
  let running = false;
  const tick = async (): Promise<void> => {
    if (running) return;
    running = true;
    try {
      const result = await sweepTasksOnce(deps);
      if (result.deleted + result.abandoned + result.releasedHolds + result.prunedReplies > 0) {
        deps.log.info(result, "task retention sweep");
      }
    } catch (error) {
      deps.log.error({ err: error }, "task retention sweep failed");
    } finally {
      running = false;
    }
  };
  const timer = setInterval(() => void tick(), deps.intervalMs);
  timer.unref();
  void tick();
  return () => clearInterval(timer);
}
