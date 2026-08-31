import type pg from "pg";
import type { WithConnection } from "../db/connection.js";
import { readEntitlement, type EntitlementRecord } from "../entitlement/store.js";
import { periodStart } from "../entitlement/period.js";
import { NO_DRAW, periodEnd, type ScreenControlDraw } from "./balance.js";

/**
 * Reading the credit pool: what this account drew on screen control this period, and which plan it
 * is drawing against (SONNY-212).
 *
 * **The draw is read out of `sonny.metering_event` and out of nothing else.** `balance.ts`'s header
 * carries the argument for deriving rather than ledgering; this file is the one query that argument
 * produces.
 */

/**
 * Only `screen.analyze` is read, and that is the acceptance criterion "only screen control draws
 * down" held **by construction rather than by configuration**.
 *
 * The distinction matters for what a later ticket may safely change. The *numbers* are a
 * deployment's — tiers, allowances, weights, all of `CREDIT_PLANS`. *Which line is paid* is not: the
 * founders decided on 2026-08-16 that screen control is the only one, and on 2026-08-31 they
 * re-affirmed it against the one case that had been written down as contradicting it — a standing
 * watcher's repeated checks, which SONNY-236 had recorded as "a recurring charge against the user's
 * allowance". That decision went the other way: **watchers are free and capped instead**, so that
 * "screen-control runs left" stays the single number a user tracks rather than becoming a pool two
 * different things spend out of. So this constant is not a knob, and a route added to it would be a
 * second currency arriving by configuration.
 */
const PAID_ROUTE = "screen.analyze";

interface DrawRow {
  sessions: string | number;
  iterations: string | number;
  pixels: string | number | null;
}

/** `bigint` comes back from `pg` as a string. `metering/query.ts` carries the same converter. */
function count(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0;
  return typeof value === "number" ? value : Number(value);
}

/**
 * What one account's screen control consumed between two instants.
 *
 * **`upstream_duration_ms IS NOT NULL` is what separates an iteration that cost money from one that
 * did not**, and the column choice is a measurement rather than a preference:
 *
 * - `metering/hook.ts`'s `meteredUpstreamCall` sets `upstreamAttempted` *before* the provider call
 *   and writes the duration in a `finally`, so the column is non-null exactly when a call was opened
 *   and returned or threw. That is the same "was a provider reached" question `entitlement/hook.ts`
 *   asks before it charges a hold, so a credit draw and a cap charge agree about which requests were
 *   free.
 * - **`provider` would be wrong**, and it is the obvious candidate: it is written from the router's
 *   attribution, which a *failed* call never produces — so a `provider_error` iteration that really
 *   did reach a vendor carries a null provider, and pricing on that column would silently give away
 *   every failed call.
 * - **`outcome` would also be wrong**, more subtly. `outcomeFor`'s last line returns `refused` when
 *   an upstream call *was* attempted and the error carried no provider code, so `refused` does not
 *   mean "spent nothing" in every case the function can produce.
 *
 * A session all of whose iterations were refused contributes no rows here at all, so it is not
 * counted in `sessions` either and pays no per-session weight. That is the intended reading: nothing
 * was spent on it.
 */
export async function readScreenControlDraw(
  client: pg.Client,
  input: { readonly accountId: string; readonly since: Date; readonly until: Date },
): Promise<ScreenControlDraw> {
  const { rows } = await client.query<DrawRow>(
    `SELECT count(DISTINCT session_id)                                  AS sessions,
            count(*)                                                    AS iterations,
            coalesce(sum(image_pixel_width::bigint * image_pixel_height), 0) AS pixels
       FROM sonny.metering_event
      WHERE account_id = $1
        AND route = $2
        AND session_id IS NOT NULL
        AND upstream_duration_ms IS NOT NULL
        AND occurred_at >= $3
        AND occurred_at < $4`,
    [input.accountId, PAID_ROUTE, input.since, input.until],
  );
  const row = rows[0];
  if (row === undefined) return NO_DRAW;
  return {
    sessions: count(row.sessions),
    iterations: count(row.iterations),
    pixels: count(row.pixels),
  };
}

/**
 * The plan key this account's credits are drawn against, or `undefined` for "the catalogue's
 * default".
 *
 * **A revoked entitlement, and one past its payment-failure grace, fall to the default plan** — they
 * keep their plan *key* for the claim, and they do not keep its allowance. `claimFactsFor` makes the
 * first half of that call deliberately: a cancelled subscription keeps `plan` so a client can say
 * which plan ended, and loses every capability. The allowance is the other half of the same
 * decision, and it goes the same way for the reason `catalogue.ts` gives about unknown plan keys —
 * of the two ways to be wrong, reporting a smaller allowance than a user is owed is visible and
 * complainable, and reporting a larger one is a bill nobody sees until it arrives.
 *
 * **This repeats `claimFactsFor`'s two conditions rather than calling it, and the repetition is
 * pinned rather than tolerated.** That function answers with a capability list, and "no capabilities"
 * cannot be read back as "not live": an unprovisioned account and a live plan that gates nothing both
 * carry an empty list, and today *every* plan does, because no capability is gated anywhere in this
 * repository (row 18, SONNY-23). `theCreditPlanIsLiveExactlyWhenTheClaimKeepsItsCapabilities` drives
 * both functions over the same records and fails if either side's rule moves.
 */
export function creditPlanKeyFor(record: EntitlementRecord, now: Date): string | undefined {
  if (record.revokedAt !== null) return undefined;
  if (record.graceUntil !== null && now.getTime() >= record.graceUntil.getTime()) return undefined;
  return record.plan;
}

/** What the route needs: a plan key and a draw, for one account, at one instant. */
export interface CreditFacts {
  readonly planKey: string | undefined;
  readonly draw: ScreenControlDraw;
}

/**
 * The store as the request path uses it.
 *
 * A seam of the same shape and for the same reason as `MeteringStore`, `EntitlementStore` and
 * `BillingStore` — the sixth time, and the reason has not changed: the flagged `npm test` runs with
 * no database, so without it every behaviour this ticket is about would be verified only under
 * `npm run test:db`. What it does **not** stand in for is the draw itself: `credit.db.test.ts` proves
 * the SQL against a real Postgres, because a fake that appears to exclude the unpaid routes is how a
 * suite comes to believe it has tested an exclusion.
 */
export interface CreditStore {
  readonly factsFor: (accountId: string, now: Date) => Promise<CreditFacts>;
}

export function postgresCreditStore(withConnection: WithConnection): CreditStore {
  return {
    factsFor: (accountId, now) =>
      withConnection(async (client) => {
        // **One clock read decides both halves**, the same call `routes/entitlements.ts` makes: the
        // instant that judges whether a grace window has closed is the instant whose period is
        // counted, so a response cannot report a paid allowance against a free period or the reverse.
        const record = await readEntitlement(client, accountId);
        const draw = await readScreenControlDraw(client, {
          accountId,
          since: periodStart(now),
          until: periodEnd(now),
        });
        return { planKey: creditPlanKeyFor(record, now), draw };
      }),
  };
}
