/**
 * An account's credits this month, spent by tokens (V2 plan decision 8).
 *
 * The allowance is the plan's monthly credits plus what was topped up this period; what is drawn is
 * what the account's model calls spent, settled by tokens at each call's tier (`agent/credits.ts`);
 * what remains is the difference, never below zero. Everything here is pure: `store.ts` reads the
 * facts, `catalogue.ts` holds the numbers, and this is the arithmetic between them.
 */
import { periodStart } from "../entitlement/period.js";
import { planFor, type CreditCatalogue } from "./catalogue.js";

/** Credits are kept to six decimal places, so sums of per-call charges add up exactly. */
export const CREDIT_PRECISION = 6;

function round(credits: number): number {
  const scale = 10 ** CREDIT_PRECISION;
  return Math.round(credits * scale) / scale;
}

export function periodEnd(at: Date): Date {
  const start = periodStart(at);
  return new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1));
}

export interface CreditBalance {
  readonly plan: string;
  readonly periodStart: Date;
  readonly periodEnd: Date;
  readonly credits: {
    readonly allowance: number;
    readonly drawn: number;
    readonly remaining: number;
    readonly toppedUp: number;
  };
}

export function creditBalance(input: {
  readonly catalogue: CreditCatalogue;
  readonly planKey: string | undefined;
  /** What this period's model calls spent. */
  readonly agentCredits: number;
  readonly toppedUpCredits: number;
  readonly now: Date;
}): CreditBalance {
  const plan = planFor(input.catalogue, input.planKey);
  const toppedUp = round(Math.max(0, input.toppedUpCredits));
  const allowance = round(plan.monthlyCredits + toppedUp);
  const drawn = round(Math.max(0, input.agentCredits));
  const remaining = round(Math.max(0, allowance - drawn));
  return {
    plan: plan.key,
    periodStart: periodStart(input.now),
    periodEnd: periodEnd(input.now),
    credits: { allowance, drawn, remaining, toppedUp },
  };
}
