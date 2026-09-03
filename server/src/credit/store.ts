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
 * **Two columns together say that an iteration cost money, and it took a defect to establish that
 * one was not enough** (PR #182's review, F2).
 *
 * `metering/hook.ts`'s `meteredUpstreamCall` sets `upstreamAttempted` *before* the provider call and
 * writes the duration in a `finally` afterwards, so `upstream_duration_ms` is non-null whenever a
 * call was opened and the handler lived long enough to see it return or throw. **The metering event
 * has a second writer, and it fires in between.** `reply.raw.on("close", …)` writes the row when the
 * caller disconnects while the handler is still awaiting the provider — at which point the `finally`
 * has not run, so the row lands with `upstreamAttempted: true` (hence `outcome: 'client_cancelled'`)
 * and a **null** duration. The vendor has been paid, `entitlement/hook.ts` has charged the spend
 * cap, and a filter on the duration alone excluded the row: the iteration drew nothing, contributed
 * no pixels, and did not even count toward `sessions`, so a session made entirely of cancelled
 * iterations paid no per-session weight either. A user pressing Stop mid-run got it free.
 *
 * That case is ordinary and it is on the paid route specifically — Stop, quitting the app, or losing
 * the network mid-iteration all close the socket while the vision call is in flight — so
 * `outcome = 'client_cancelled'` is read **additively**, never instead of the duration.
 *
 * **The two rejected candidates are still rejected, and each was constructed rather than reasoned
 * about:**
 *
 * - **`provider` alone would be wrong.** It is written from the router's attribution, which a
 *   *failed* call never produces — so a `provider_error` iteration that really did reach a vendor
 *   carries a null provider, and pricing on that column silently gives away every failed call.
 * - **`outcome` alone would be wrong**, more subtly. `outcomeFor`'s last line returns `refused` when
 *   an upstream call *was* attempted and the error carried no provider code, so `refused` does not
 *   mean "spent nothing" in every case the function can produce.
 *
 * **What the draw and the spend cap each ask, stated exactly, because the sentence here used to say
 * they asked the same question and they do not.** The cap asks `upstreamWasAttempted(request)`,
 * which reads a fact set *before* the call. The draw asks the table, which is written at one of two
 * moments. The pair above is what makes the two agree on every path this gateway has — including the
 * one where the handler never finishes — rather than on every path where it does.
 *
 * A session all of whose iterations were refused before any provider call contributes no rows here
 * at all, so it is not counted in `sessions` either and pays no per-session weight. That is the
 * intended reading: nothing was spent on it.
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
        AND (upstream_duration_ms IS NOT NULL OR outcome = 'client_cancelled')
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

/**
 * What this period's granted top-ups added, in credits (SONNY-215).
 *
 * **`outcome = 'granted'` and nothing else.** The table holds one row per *attempt*, so a declined
 * card and a crashed charge path both leave rows behind; only a row the provider actually charged
 * grants anything, and 0019's `credit_topup_granted_is_exactly_the_credited` CHECK is what makes
 * `credits > 0` and `outcome = 'granted'` the same set rather than two conditions that could drift.
 * The filter is written on the outcome because that is the fact being asked about — a later row
 * shape that granted zero credits deliberately would still be a grant, and would still be excluded
 * by a `credits > 0` filter without anybody noticing.
 */
export async function readToppedUpCredits(
  client: pg.Client,
  input: { readonly accountId: string; readonly periodStart: Date },
): Promise<number> {
  const { rows } = await client.query<{ credits: string | number | null }>(
    `SELECT coalesce(sum(credits), 0) AS credits
       FROM sonny.credit_topup
      WHERE account_id = $1 AND period_start = $2 AND outcome = 'granted'`,
    [input.accountId, input.periodStart],
  );
  return count(rows[0]?.credits);
}

/**
 * How many top-up attempts this account has made in this period (SONNY-215).
 *
 * **Every row, whatever its outcome** — which is the same count 0019's `attempt_no` is derived from,
 * and it has to be, or the number the app shows would disagree with the bound the claim enforces. A
 * declined card consumes an attempt; see 0019 for why the bound counts attempts rather than grants.
 */
export async function readTopUpAttempts(
  client: pg.Client,
  input: { readonly accountId: string; readonly periodStart: Date },
): Promise<number> {
  const { rows } = await client.query<{ attempts: string | number }>(
    `SELECT count(*) AS attempts
       FROM sonny.credit_topup
      WHERE account_id = $1 AND period_start = $2`,
    [input.accountId, input.periodStart],
  );
  return count(rows[0]?.attempts);
}

/**
 * When this account opted in to automatic top-ups, or `null` for every way of not having.
 *
 * **One predicate over three states**, which is 0019's decision: no row at all (never asked), a row
 * whose `opted_in_at` is NULL (opted out), and — the only remaining case — a row that names an
 * instant. The first two are the same answer here, so nothing downstream can treat "has a row" as
 * consent.
 */
export async function readAutoTopUpConsent(
  client: pg.Client,
  accountId: string,
): Promise<Date | null> {
  const { rows } = await client.query<{ opted_in_at: Date | null }>(
    `SELECT opted_in_at FROM sonny.auto_topup_consent WHERE account_id = $1`,
    [accountId],
  );
  return rows[0]?.opted_in_at ?? null;
}

/** What the route needs: a plan key, a draw, what top-ups added, and whether any may be charged. */
export interface CreditFacts {
  readonly planKey: string | undefined;
  readonly draw: ScreenControlDraw;
  /** Credits this period's granted top-ups added. `0` for an account that has bought none. */
  readonly toppedUpCredits: number;
  /** How many top-up attempts this period has already carried, granted or not. */
  readonly topUpAttemptsThisPeriod: number;
  /**
   * When this account opted in to automatic top-ups, or `null` (SONNY-215).
   *
   * **Carried as the instant rather than as a boolean**, because it is what a charge records as its
   * own authorisation: `credit_topup.consented_at` is NOT NULL, so a charge copies this value and a
   * `null` here cannot produce a recordable row at all.
   */
  readonly autoTopUpOptedInAt: Date | null;
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
  /**
   * Turn automatic top-ups on or off for one account, and answer what the setting now is
   * (SONNY-215).
   *
   * **Off writes NULL and keeps the row** rather than deleting it, so `updated_at` still answers
   * "when did they turn it off". **On does not refresh an instant that is already set**: a user who
   * presses the control twice has consented once, and the instant a charge cites should be the one
   * they actually agreed at rather than the last time they looked at the setting.
   */
  readonly setAutoTopUp: (
    accountId: string,
    enabled: boolean,
    now: Date,
  ) => Promise<Date | null>;
}

export function postgresCreditStore(withConnection: WithConnection): CreditStore {
  return {
    factsFor: (accountId, now) =>
      withConnection(async (client) => {
        // **One clock read decides every half**, the same call `routes/entitlements.ts` makes: the
        // instant that judges whether a grace window has closed is the instant whose period is
        // counted and whose period's top-ups are summed, so a response cannot report a paid
        // allowance against a free period, or last period's top-up against this period's draw.
        const record = await readEntitlement(client, accountId);
        const since = periodStart(now);
        const draw = await readScreenControlDraw(client, {
          accountId,
          since,
          until: periodEnd(now),
        });
        const toppedUpCredits = await readToppedUpCredits(client, { accountId, periodStart: since });
        const topUpAttemptsThisPeriod = await readTopUpAttempts(client, {
          accountId,
          periodStart: since,
        });
        const autoTopUpOptedInAt = await readAutoTopUpConsent(client, accountId);
        return {
          planKey: creditPlanKeyFor(record, now),
          draw,
          toppedUpCredits,
          topUpAttemptsThisPeriod,
          autoTopUpOptedInAt,
        };
      }),
    setAutoTopUp: (accountId, enabled, now) =>
      withConnection(async (client) => {
        const { rows } = await client.query<{ opted_in_at: Date | null }>(
          `INSERT INTO sonny.auto_topup_consent (account_id, opted_in_at, updated_at)
                VALUES ($1, $2, $3)
           ON CONFLICT (account_id) DO UPDATE
                  SET opted_in_at = CASE
                        WHEN $2::timestamptz IS NULL THEN NULL
                        ELSE COALESCE(sonny.auto_topup_consent.opted_in_at, $2::timestamptz)
                      END,
                      updated_at = $3
             RETURNING opted_in_at`,
          [accountId, enabled ? now : null, now],
        );
        return rows[0]?.opted_in_at ?? null;
      }),
  };
}
