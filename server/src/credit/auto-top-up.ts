/**
 * The automatic top-up in V2 (SONNY-215's consent, V2 plan decision 8's token credits).
 *
 * V1 bought a pack when the Mac's screen gate found no runs left. In V2 the gateway spends the
 * credits, so the gateway is where running out is noticed: when a task's next model call can't be
 * held, this buys one pack for an account that opted in, and the call is tried once more. Every
 * refusal and bound in `attemptTopUp` still applies — consent first, one pack's worth at a time, the
 * period's attempt limit, and an unresolved order resolved before a new one is made.
 *
 * **One purchase at a time per account.** Up to three tasks run at once, and they can run out
 * together. Each waits for the purchase before it and then reads the balance again, so the second
 * finds it no longer needs one instead of buying its own pack.
 */
import { creditBalance, type CreditBalance } from "./balance.js";
import type { CreditCatalogue } from "./catalogue.js";
import type { CreditFacts, CreditStore } from "./store.js";
import { attemptTopUp, TOP_UP_DEADLINE_ELAPSED, withinTopUpDeadline, type TopUpDeps } from "./topup.js";

export interface AutoTopUpLog {
  info(data: object, message: string): void;
  warn(data: object, message: string): void;
}

export interface AutoTopUpDeps {
  readonly store: CreditStore;
  readonly catalogue: CreditCatalogue;
  readonly topUp: Omit<TopUpDeps, "pack">;
  /** How long a purchase may take before the task stops waiting for it. */
  readonly totalDeadlineMs: number;
  readonly now: () => Date;
  readonly log: AutoTopUpLog;
}

/**
 * Buys credits for `accountId` when it opted in and `needed` credits aren't there. True when the
 * call is worth trying again: a pack was granted, or the credits are there after all (another task's
 * purchase landed first).
 */
export type AutoTopUp = (accountId: string, needed: number) => Promise<boolean>;

/** An account's balance, read from its own rows. The credits route reads it the same way. */
export async function accountPosition(
  store: CreditStore,
  catalogue: CreditCatalogue,
  accountId: string,
  at: Date,
): Promise<{ facts: CreditFacts; balance: CreditBalance }> {
  const facts = await store.factsFor(accountId, at);
  const balance = creditBalance({
    catalogue,
    planKey: facts.planKey,
    agentCredits: facts.agentCredits,
    toppedUpCredits: facts.toppedUpCredits,
    now: at,
  });
  return { facts, balance };
}

export function automaticTopUp(deps: AutoTopUpDeps): AutoTopUp {
  const latest = new Map<string, Promise<boolean>>();

  async function once(accountId: string, needed: number): Promise<boolean> {
    try {
      const at = deps.now();
      const { facts, balance } = await accountPosition(deps.store, deps.catalogue, accountId, at);
      const outcome = await withinTopUpDeadline(
        deps.totalDeadlineMs,
        attemptTopUp(
          { ...deps.topUp, pack: deps.catalogue.topUp },
          { accountId, balance, consentedAt: facts.autoTopUpOptedInAt, needed, now: at },
        ),
      );
      if (outcome === TOP_UP_DEADLINE_ELAPSED) {
        deps.log.warn({ accountId, totalDeadlineMs: deps.totalDeadlineMs }, "automatic top-up did not answer inside its deadline");
        return false;
      }
      if (outcome.kind === "refused") {
        if (outcome.refusal === "not_needed") return true;
        // The ordinary answer for most accounts: they didn't opt in.
        deps.log.info({ accountId, refusal: outcome.refusal }, "automatic top-up refused");
        return false;
      }
      deps.log.info({ accountId, credits: outcome.credits }, "automatic top-up granted");
      return true;
    } catch (error) {
      deps.log.warn({ accountId, err: error }, "automatic top-up failed");
      return false;
    }
  }

  return (accountId, needed) => {
    const before = latest.get(accountId) ?? Promise.resolve(false);
    // After the one before it, whatever it answered: this one reads the balance again.
    const next = before.then(() => once(accountId, needed));
    latest.set(accountId, next);
    void next.then(() => {
      if (latest.get(accountId) === next) latest.delete(accountId);
    });
    return next;
  };
}
