/**
 * Token credits (V2 plan decision 8): every model call inside a task spends credits by the tokens it
 * used, at its tier's rate.
 *
 * Before a call, the gateway holds credits for the call's largest possible size. Afterwards it
 * settles the hold to what the call actually used. A task whose account can't cover the next hold
 * stops before that call, which is always between Mac actions, never during one.
 *
 * Each hold is also a row of `sonny.agent_model_call`, and that row is the call's metering record:
 * tier, provider, model, tokens and credits, keyed by the call's step id.
 */
import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { creditsForDraw, periodEnd } from "../credit/balance.js";
import { planFor, type CreditCatalogue } from "../credit/catalogue.js";
import {
  creditPlanKeyFor,
  readAgentCredits,
  readScreenControlDraw,
  readToppedUpCredits,
} from "../credit/store.js";
import { periodStart } from "../entitlement/period.js";
import { effectiveCap, readEntitlement, reserve, settle as settleReservation } from "../entitlement/store.js";

export const TIERS = ["fast", "standard", "strong"] as const;
export type Tier = (typeof TIERS)[number];

export interface TierRate {
  readonly inputPerThousand: number;
  readonly outputPerThousand: number;
}
export type TokenRates = Readonly<Record<Tier, TierRate>>;

export type ProposingAgent = "planner" | "screen";

const PRECISION = 1_000_000;

export function roundCredits(credits: number): number {
  return Math.round(credits * PRECISION) / PRECISION;
}

export function creditsFor(rate: TierRate, inputTokens: number, outputTokens: number): number {
  return roundCredits(
    (rate.inputPerThousand * inputTokens + rate.outputPerThousand * outputTokens) / 1000,
  );
}

export interface HoldRequest {
  readonly stepId: string;
  readonly accountId: string;
  readonly taskId: string;
  readonly agent: ProposingAgent;
  readonly tier: Tier;
  readonly credits: number;
  readonly now: Date;
}

export type HoldOutcome =
  | { readonly kind: "held" }
  | { readonly kind: "insufficient"; readonly remaining: number }
  | { readonly kind: "over_cap" };

export type CallOutcome = "ok" | "provider_error" | "cancelled";

export interface SettleRequest {
  readonly stepId: string;
  readonly credits: number;
  readonly provider: string | null;
  readonly model: string | null;
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly outcome: CallOutcome;
  readonly now: Date;
}

export interface ModelCallLedger {
  hold(request: HoldRequest): Promise<HoldOutcome>;
  settle(request: SettleRequest): Promise<void>;
  /** Releases holds a process never settled because it died mid-call. Nothing is charged. */
  expireHolds(heldBefore: Date, now: Date): Promise<number>;
}

async function remainingCredits(
  client: pg.Client,
  catalogue: CreditCatalogue,
  accountId: string,
  now: Date,
): Promise<number> {
  const since = periodStart(now);
  const entitlement = await readEntitlement(client, accountId);
  const plan = planFor(catalogue, creditPlanKeyFor(entitlement, now));
  const toppedUp = await readToppedUpCredits(client, { accountId, periodStart: since });
  // Screen-control runs from the V1 path still draw until phase 7 deletes that path.
  const draw = await readScreenControlDraw(client, { accountId, since, until: periodEnd(now) });
  const agent = await readAgentCredits(client, { accountId, periodStart: since });
  return roundCredits(plan.monthlyCredits + toppedUp - creditsForDraw(catalogue.weights, draw) - agent);
}

// One key space per purpose for pg_advisory_xact_lock, so this lock can't collide with another.
const CREDIT_LOCK_NAMESPACE = 8_134_101;

export function postgresModelCallLedger(input: {
  readonly withConnection: WithConnection;
  readonly catalogue: CreditCatalogue;
  readonly defaultCapUnits: number;
}): ModelCallLedger {
  const { withConnection, catalogue } = input;
  return {
    hold: (request) =>
      withConnection(async (client): Promise<HoldOutcome> => {
        // A closed account spends nothing more, whatever its balance says.
        const account = await client.query<{ deleted_at: Date | null }>(
          "SELECT deleted_at FROM sonny.account WHERE id = $1",
          [request.accountId],
        );
        if (account.rows[0] === undefined || account.rows[0].deleted_at !== null) {
          return { kind: "insufficient", remaining: 0 };
        }
        const entitlement = await readEntitlement(client, request.accountId);
        const reservation = await reserve(client, {
          accountId: request.accountId,
          capUnits: effectiveCap(entitlement.capUnits, input.defaultCapUnits),
          amount: { units: 1 },
          now: request.now,
        });
        if (reservation.kind === "over_cap") return { kind: "over_cap" };

        await client.query("BEGIN");
        let remaining: number;
        try {
          // Two calls for one account must not both pass the balance check on the same credits.
          await client.query("SELECT pg_advisory_xact_lock($1, hashtext($2))", [
            CREDIT_LOCK_NAMESPACE,
            request.accountId,
          ]);
          remaining = await remainingCredits(client, catalogue, request.accountId, request.now);
          if (remaining >= request.credits) {
            await client.query(
              `INSERT INTO sonny.agent_model_call
                 (step_id, account_id, task_id, agent, tier, period_start, status, credits_held,
                  spend_reservation_id, created_at)
               VALUES ($1, $2, $3, $4, $5, $6, 'held', $7, $8, $9)`,
              [
                request.stepId,
                request.accountId,
                request.taskId,
                request.agent,
                request.tier,
                periodStart(request.now),
                request.credits,
                reservation.reservationId,
                request.now,
              ],
            );
          }
          await client.query("COMMIT");
        } catch (error) {
          await client.query("ROLLBACK");
          await settleReservation(client, reservation.reservationId, false);
          throw error;
        }
        if (remaining < request.credits) {
          await settleReservation(client, reservation.reservationId, false);
          return { kind: "insufficient", remaining: Math.max(0, remaining) };
        }
        return { kind: "held" };
      }),

    settle: (request) =>
      withConnection(async (client) => {
        const { rows } = await client.query<{ spend_reservation_id: string | null }>(
          `UPDATE sonny.agent_model_call
              SET status = 'settled', credits_charged = $2, provider = $3, model = $4,
                  input_tokens = $5, output_tokens = $6, outcome = $7, settled_at = $8
            WHERE step_id = $1 AND status = 'held'
          RETURNING spend_reservation_id`,
          [
            request.stepId,
            request.credits,
            request.provider,
            request.model,
            request.inputTokens,
            request.outputTokens,
            request.outcome,
            request.now,
          ],
        );
        const reservationId = rows[0]?.spend_reservation_id;
        if (reservationId) await settleReservation(client, reservationId, request.outcome !== "provider_error");
      }),

    expireHolds: (heldBefore, now) =>
      withConnection(async (client) => {
        const { rows } = await client.query<{ spend_reservation_id: string | null }>(
          `UPDATE sonny.agent_model_call
              SET status = 'released', credits_charged = 0, outcome = 'expired', settled_at = $2
            WHERE status = 'held' AND created_at < $1
          RETURNING spend_reservation_id`,
          [heldBefore, now],
        );
        for (const row of rows) {
          if (row.spend_reservation_id) await settleReservation(client, row.spend_reservation_id, false);
        }
        return rows.length;
      }),
  };
}

/** A ledger with a fixed balance, for tests and for a gateway run without a database. */
export function memoryModelCallLedger(balance: number): ModelCallLedger & {
  readonly calls: Map<string, { hold: HoldRequest; settle?: SettleRequest; released?: boolean }>;
  readonly remaining: () => number;
  setBalance(credits: number): void;
} {
  let total = balance;
  const calls = new Map<string, { hold: HoldRequest; settle?: SettleRequest; released?: boolean }>();
  const spent = (): number =>
    [...calls.values()].reduce((sum, call) => {
      if (call.released) return sum;
      return sum + (call.settle ? call.settle.credits : call.hold.credits);
    }, 0);
  return {
    calls,
    remaining: () => roundCredits(total - spent()),
    setBalance(credits) {
      total = credits;
    },
    hold(request) {
      const remaining = roundCredits(total - spent());
      if (remaining < request.credits) {
        return Promise.resolve({ kind: "insufficient", remaining: Math.max(0, remaining) });
      }
      calls.set(request.stepId, { hold: request });
      return Promise.resolve({ kind: "held" });
    },
    settle(request) {
      const call = calls.get(request.stepId);
      if (call !== undefined && call.settle === undefined && !call.released) call.settle = request;
      return Promise.resolve();
    },
    expireHolds(heldBefore) {
      let released = 0;
      for (const call of calls.values()) {
        if (call.settle === undefined && !call.released && call.hold.now < heldBefore) {
          call.released = true;
          released += 1;
        }
      }
      return Promise.resolve(released);
    },
  };
}
