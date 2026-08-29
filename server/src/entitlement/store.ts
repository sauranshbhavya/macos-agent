import type pg from "pg";
import { ACCOUNT_REQUESTS, bucketKey, consume } from "../auth/ratelimit.js";
import type { WithConnection } from "../db/connection.js";
import { periodStart, reservationExpiry } from "./period.js";

/**
 * The per-account spend cap, as the one statement `docs/sonny-row-12-host-decision.md` §9 named
 * (SONNY-135).
 *
 * **This implements the mechanism the host decision named and does not put a second one beside it.**
 * The coordinator's amendment of 2026-08-28 is explicit about that, and §9.1 gives the reason a
 * second one would be wrong: the counter lives in Postgres, not in process memory and not in a cache,
 * because two gateway processes behind one address have no consistency story anywhere else. A cache
 * in front of this that answered the cap question would be the same defect wearing a performance
 * justification.
 *
 * ## The mechanism, in one statement
 *
 * ```sql
 * UPDATE sonny.usage_period
 *    SET reserved = reserved + $amount
 *  WHERE account_id = $account AND period_start = $period
 *    AND spent + reserved + $amount <= cap_units
 * RETURNING reserved;
 * ```
 *
 * No rows returned means the cap is reached, and the request is refused **before any provider is
 * called**.
 *
 * **Why one statement is sufficient, which is the part worth not re-deriving.** Under READ COMMITTED
 * — Postgres's default, and Supabase's — an `UPDATE` that meets a row a concurrent transaction has
 * just updated does not use the snapshot it began with. It waits for that transaction, then
 * **re-evaluates its own `WHERE` against the new row version**. So the second racer tests the cap
 * against a row that already carries the first one's reservation, finds it does not fit, and is
 * skipped. No advisory lock, no `SELECT … FOR UPDATE`, no retry loop, and no read-then-write window
 * to slip through. Measured by SONNY-125 against Postgres 17: two racers against a cap fitting one
 * gave `A=100, B=REFUSED`; fifty concurrent reservations against a cap fitting ten gave exactly ten
 * wins and forty refusals; and the naive read-then-write control reached `reserved = 200` against a
 * cap of 100 — an over-spend reproduced rather than argued.
 *
 * ## Why there are two statements here and the mechanism is still one
 *
 * A period's row has to exist before it can be updated, so `reserve` issues an idempotent
 * `INSERT … ON CONFLICT DO NOTHING` first. **That insert decides nothing about the cap** — it opens
 * the counter and nothing else — and the refusal is still decided entirely by the conditional
 * `UPDATE` below it.
 *
 * **The tempting one-statement form is wrong, and it is worth naming because it looks right.**
 * Writing the insert as a CTE above the update —
 * `WITH ensure AS (INSERT … ON CONFLICT DO NOTHING) UPDATE sonny.usage_period …` — does not work:
 * every part of a statement with a data-modifying CTE sees the *same* snapshot, taken before the
 * statement ran, so the `UPDATE` cannot see the row the `INSERT` beside it just created. A first
 * request in a period would be refused with an empty cap it had itself just opened.
 *
 * **The insert-then-update pair is safe under a race for a reason worth stating.** Two requests
 * opening the same period at once: one insert wins, the other blocks on the speculative-insertion
 * lock until the winner's transaction ends, then takes its `DO NOTHING` branch. Its `UPDATE` runs as
 * a new statement and therefore takes a new snapshot, in which the winner's row is committed and
 * visible. Nothing here depends on which of the two arrives first.
 *
 * ## Reserve, then settle
 *
 * The amount is held before the provider call and charged after it, because what a call costs is
 * only known once it has happened. `settle` moves the hold into `spent`; `release` gives it back for
 * a request that never reached a provider. A request the host kills between the two leaks its hold
 * until `sweep` reclaims it — §9.5's first residual, and the reason `usage_reservation` carries an
 * `expires_at` at all.
 */

/** What one metered call costs against the cap. */
export interface SpendAmount {
  readonly units: number;
}

/**
 * **One metered call is one unit, and that is a consequence of what this repository is allowed to
 * decide rather than a pricing choice.**
 *
 * A cost-weighted cap needs a credit weight — how many units a thousand tokens or a megapixel of
 * screenshot is worth — and credit weights are SONNY-212's, explicitly on this ticket's never-touch
 * list. What is left that this gateway can measure honestly, today, is the call itself. So the cap
 * counts calls, and `SPEND_CAP_UNITS` is a per-period ceiling on metered calls.
 *
 * **What that bounds and what it does not, said plainly, because a loose bound described as a tight
 * one is worse than no bound.** It bounds the founder's exposure to a leaked token: that token can
 * make at most `cap_units` metered calls in a period, each of them bounded in turn by §6.1's body
 * limits and §12's deadlines. It does **not** bound the money, because a call's cost varies by
 * route, by model and by payload size — a `/v1/search` and a twelve-iteration screen-control session
 * are the same number of units here and are nowhere near the same number of dollars.
 *
 * **This function is the seam that closes that gap.** When SONNY-212 sets credit weights, this is
 * where they land: the reservation becomes a weighted estimate, the settle becomes a weighted actual
 * read off the metering event, and **§9.5's second residual returns with them** — a settle that
 * charges more than was held has to either exceed the cap, be refused, or be clamped, and that is a
 * pricing question. Today it cannot arise, because the estimate and the actual are the same number
 * by construction, and `settle` asserts that by taking no amount at all.
 */
export function unitsForMeteredCall(): SpendAmount {
  return { units: 1 };
}

/** What an account is allowed, as `sonny.entitlement` holds it. */
export interface EntitlementRecord {
  readonly accountId: string;
  readonly plan: string;
  readonly capabilities: readonly string[];
  readonly capUnits: number | null;
  readonly revokedAt: Date | null;
}

/**
 * What an account with no row in `sonny.entitlement` is allowed: **nothing, and the deployment's
 * cap.**
 *
 * **Both halves are fail-closed and they fail closed differently, which is the point.** No plan and
 * no capabilities means every *gated* capability is refused — §16.3's rule, and the direction this
 * ticket's own description calls the one most likely to be inverted by accident. A `capUnits` of
 * `null` means "take the deployment's `SPEND_CAP_UNITS`", which is a number an operator was forced
 * to choose at startup: unprovisioned accounts are capped, never uncapped.
 *
 * **`'none'` is not a tier name.** It is the absence of a plan record. SONNY-212 owns the real keys.
 */
export function unprovisioned(accountId: string): EntitlementRecord {
  return { accountId, plan: "none", capabilities: [], capUnits: null, revokedAt: null };
}

/**
 * What a claim should say about this account right now.
 *
 * **A revoked entitlement keeps its plan key and loses every capability**, rather than disappearing.
 * A client that refreshes and receives a fresh, signed, capability-less claim stops allowing gated
 * features immediately; a client that receives an *error* keeps the claim it already has until that
 * one expires, which is the slower of the two and the wrong one for a cancellation.
 */
export function claimFactsFor(record: EntitlementRecord): {
  plan: string;
  capabilities: readonly string[];
} {
  if (record.revokedAt !== null) return { plan: record.plan, capabilities: [] };
  return { plan: record.plan, capabilities: record.capabilities };
}

export async function readEntitlement(
  client: pg.Client,
  accountId: string,
): Promise<EntitlementRecord> {
  const result = await client.query<{
    plan: string;
    capabilities: string[];
    cap_units: string | null;
    revoked_at: Date | null;
  }>(
    `SELECT plan, capabilities, cap_units, revoked_at
       FROM sonny.entitlement WHERE account_id = $1`,
    [accountId],
  );
  const row = result.rows[0];
  if (row === undefined) return unprovisioned(accountId);
  return {
    accountId,
    plan: row.plan,
    capabilities: row.capabilities,
    // `pg` returns `bigint` as a string, because a Postgres bigint does not fit a JS number. These
    // values are call counts in the thousands, so `Number` is exact here — but the conversion is
    // done once, at the boundary, rather than left for arithmetic elsewhere to trip over.
    capUnits: row.cap_units === null ? null : Number(row.cap_units),
    revokedAt: row.revoked_at,
  };
}

/** A hold taken against a period, or the reason none was. */
export type ReserveOutcome =
  | { readonly kind: "reserved"; readonly reservationId: string; readonly units: number }
  /** The cap is reached. The request is refused before any provider is called. */
  | { readonly kind: "over_cap"; readonly capUnits: number };

/**
 * Take a hold, or refuse.
 *
 * `capUnits` is the effective cap — the account's own if it has one, the deployment's otherwise —
 * resolved by the caller so that this function has one number to enforce and no policy of its own.
 *
 * **The cap is copied onto the period row the first time that period is opened and is never
 * re-read.** A cap that changed mid-period would otherwise retroactively re-decide every refusal
 * already issued: a user told at 400 calls that they were out would, after an operator raised the
 * cap, have been silently not-out at the time they were told. Copying makes the period's answer
 * stable for its whole life. Changing an account's cap therefore takes effect at the next period,
 * which is the behaviour a period boundary is for.
 */
export async function reserve(
  client: pg.Client,
  input: {
    accountId: string;
    capUnits: number;
    amount: SpendAmount;
    now: Date;
  },
): Promise<ReserveOutcome> {
  const period = periodStart(input.now);
  await client.query("BEGIN");
  try {
    // Opens the counter and decides nothing. See this module's header for why this cannot be folded
    // into the statement below as a CTE.
    await client.query(
      `INSERT INTO sonny.usage_period (account_id, period_start, cap_units)
            VALUES ($1, $2, $3)
       ON CONFLICT (account_id, period_start) DO NOTHING`,
      [input.accountId, period, input.capUnits],
    );

    // **The mechanism.** No rows means the cap is reached.
    const held = await client.query<{ reserved: string; cap_units: string }>(
      `UPDATE sonny.usage_period
          SET reserved = reserved + $3
        WHERE account_id = $1 AND period_start = $2
          AND spent + reserved + $3 <= cap_units
      RETURNING reserved, cap_units`,
      [input.accountId, period, input.amount.units],
    );
    if (held.rows.length === 0) {
      // Read the cap the period was actually opened with, so the refusal reports the number that
      // decided it rather than the one the caller passed in — they differ whenever an operator
      // changed the cap mid-period, which is exactly when a support question gets asked.
      const existing = await client.query<{ cap_units: string }>(
        "SELECT cap_units FROM sonny.usage_period WHERE account_id = $1 AND period_start = $2",
        [input.accountId, period],
      );
      await client.query("ROLLBACK");
      return {
        kind: "over_cap",
        capUnits: Number(existing.rows[0]?.cap_units ?? input.capUnits),
      };
    }

    const reservation = await client.query<{ reservation_id: string }>(
      `INSERT INTO sonny.usage_reservation (account_id, period_start, amount, expires_at)
            VALUES ($1, $2, $3, $4)
       RETURNING reservation_id`,
      [input.accountId, period, input.amount.units, reservationExpiry(input.now)],
    );
    await client.query("COMMIT");
    return {
      kind: "reserved",
      reservationId: reservation.rows[0]!.reservation_id,
      units: input.amount.units,
    };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/** What a settle turned out to be. `already_settled` is the retried-settle case, and is not an error. */
export type SettleOutcome = "charged" | "released" | "already_settled";

/**
 * Close a hold: charge it, or give it back.
 *
 * **`charge` is a boolean and not an amount, and that is this ticket's answer to §9.5's second
 * residual.** The probe SONNY-125 built settled with `LEAST(actual, reserved)`, which silently
 * absorbs the difference when a call costs more than was held — reserve 100, spend 900, and 800
 * units of real provider spend never reach the cap. That hole cannot open here, because there is no
 * separate actual to be larger: one metered call is one unit, so the amount charged is the amount
 * held or nothing at all. `unitsForMeteredCall` carries what changes when SONNY-212 makes the two
 * different numbers again.
 *
 * **A retried settle charges once.** The `AND NOT settled` guard is what makes that true, and it
 * matters because the settle runs on a response path that can be reached twice.
 *
 * **Releasing and charging both preserve `spent + reserved <= cap_units`**, so neither can trip the
 * backstop constraint: a charge moves a unit from `reserved` to `spent` and leaves the sum alone,
 * and a release lowers `reserved`.
 */
export async function settle(
  client: pg.Client,
  reservationId: string,
  charge: boolean,
): Promise<SettleOutcome> {
  await client.query("BEGIN");
  try {
    const closed = await client.query<{
      account_id: string;
      period_start: Date;
      amount: string;
    }>(
      `UPDATE sonny.usage_reservation
          SET settled = true
        WHERE reservation_id = $1 AND NOT settled
      RETURNING account_id, period_start, amount`,
      [reservationId],
    );
    const row = closed.rows[0];
    if (row === undefined) {
      await client.query("ROLLBACK");
      return "already_settled";
    }
    const amount = Number(row.amount);
    await client.query(
      `UPDATE sonny.usage_period
          SET reserved = reserved - $3,
              spent = spent + $4
        WHERE account_id = $1 AND period_start = $2`,
      [row.account_id, row.period_start, amount, charge ? amount : 0],
    );
    await client.query("COMMIT");
    return charge ? "charged" : "released";
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
}

/**
 * Reclaim every hold whose request never came back, and answer how many **holds** were reclaimed.
 *
 * **The aggregation in `per_period` is the whole of this function's correctness, and it is here
 * because the obvious version loses money silently** (SONNY-125, PR #82 cycle 1, F2). `UPDATE … FROM`
 * is a join: when several source rows match one target row Postgres applies exactly one of them and
 * discards the rest. A version that subtracted straight from the expired reservations therefore
 * reclaimed a single hold per (account, period) while marking every one of them settled — so the
 * remainder became permanently unusable cap with no row left to reclaim it from. Reproduced before it
 * was fixed: three orphaned 300-unit holds against a 1000 cap left 600 lost for good, and the
 * function reported success. Summing per (account, period) first gives the one-source-row-per-target-
 * row shape the statement requires.
 *
 * **The return value counts holds, not periods, and that is the second half of the same defect.** The
 * broken version counted `usage_period` rows and called them holds, so it answered `1` for that
 * three-hold case — a plausible number that agreed with the bug instead of exposing it.
 *
 * **It is application SQL rather than a database function, and a mutation battery is what moved it.**
 * As a `plpgsql` function in migration `0013` it was unreachable by any test run against a database
 * that already held the migration — the runner's ledger skips an applied file — so a mutant restoring
 * the defect above ran against the *correct* function still in the database, and was recorded killed
 * on the strength of an unrelated timeout. Here the mutant reaches the code, and
 * `reclaims EVERY expired hold across several accounts, not one per period` is what catches it.
 *
 * One statement, so it is one transaction of its own with no `BEGIN` needed: every row it touches is
 * touched inside it.
 */
export async function sweepExpiredReservations(client: pg.Client, now: Date): Promise<number> {
  const result = await client.query<{ reclaimed: string }>(
    `WITH dead AS (
       UPDATE sonny.usage_reservation
          SET settled = true
        WHERE NOT settled AND expires_at < $1
       RETURNING account_id, period_start, amount
     ), per_period AS (
       SELECT account_id, period_start, sum(amount) AS total, count(*) AS holds
         FROM dead
        GROUP BY account_id, period_start
     ), released AS (
       UPDATE sonny.usage_period u
          SET reserved = u.reserved - p.total
         FROM per_period p
        WHERE u.account_id = p.account_id AND u.period_start = p.period_start
       RETURNING p.holds
     )
     SELECT coalesce(sum(holds), 0) AS reclaimed FROM released`,
    [now],
  );
  return Number(result.rows[0]?.reclaimed ?? 0);
}

/** What one account has spent and is holding in the period `now` falls in. Operator-facing. */
export interface PeriodUsage {
  readonly periodStart: Date;
  readonly capUnits: number;
  readonly spent: number;
  readonly reserved: number;
}

export async function readPeriodUsage(
  client: pg.Client,
  accountId: string,
  now: Date,
): Promise<PeriodUsage | undefined> {
  const period = periodStart(now);
  const result = await client.query<{
    cap_units: string;
    spent: string;
    reserved: string;
  }>(
    `SELECT cap_units, spent, reserved FROM sonny.usage_period
      WHERE account_id = $1 AND period_start = $2`,
    [accountId, period],
  );
  const row = result.rows[0];
  if (row === undefined) return undefined;
  return {
    periodStart: period,
    capUnits: Number(row.cap_units),
    spent: Number(row.spent),
    reserved: Number(row.reserved),
  };
}

/**
 * Everything one request's admission needs, decided on **one** connection.
 *
 * **One lease, and the reason is the pool rather than tidiness.** `db/pool.ts` sizes the pool at ten
 * on the stated property that "the gateway checks a connection out once at a time per request and
 * never nests" — a property its own docstring says a future route calling `withConnection` inside
 * another would break. This check asks the database three things (the rate-limit counter, the
 * entitlement row, the reservation), and three leases per request would treble this hook's share of
 * a pool that already serves the gate's attribution, the idempotency claim, its completion and the
 * metering insert. So the three statements run in sequence on one connection, and the settle takes a
 * second lease later, on the response path, when this one is long returned.
 *
 * **The order of the checks is policy and lives here**, in one place, rather than in the hook: the
 * rate limit first because it is the cheapest refusal and the one that bounds how fast everything
 * below it can be driven, then the capability gate, then the cap. `entitlement.db.test.ts` drives
 * this function against a real Postgres; `entitlement.test.ts` drives the hook above it against a
 * fake, so what each refusal *says* to a client is covered without a database and what the cap
 * *does* under concurrency is covered with one.
 */
export interface AdmitInput {
  readonly accountId: string;
  /** The capability this route requires, or `undefined` for a route that gates on nothing. */
  readonly requiredCapability: string | undefined;
  /** Whether this route spends against the cap. Metered routes do; nothing else does. */
  readonly metered: boolean;
  readonly defaultCapUnits: number;
  readonly rateLimitSalt: string;
  readonly now: Date;
}

export type AdmitOutcome =
  | { readonly kind: "rate_limited"; readonly retryAfterSeconds: number }
  | { readonly kind: "not_entitled"; readonly capability: string }
  | { readonly kind: "over_cap"; readonly capUnits: number }
  /** Admitted. `reservationId` is present exactly when a hold was taken and must be settled. */
  | { readonly kind: "admitted"; readonly reservationId: string | undefined };

export async function admitRequest(client: pg.Client, input: AdmitInput): Promise<AdmitOutcome> {
  const verdict = await consume(
    client,
    bucketKey("acct", input.accountId, input.rateLimitSalt),
    ACCOUNT_REQUESTS,
    input.now,
  );
  if (!verdict.allowed) {
    return { kind: "rate_limited", retryAfterSeconds: verdict.retryAfterSeconds };
  }

  // A route that gates on nothing and spends nothing needs no entitlement row read at all. Every
  // authenticated route is rate limited; only some of them are worth a second query.
  if (input.requiredCapability === undefined && !input.metered) {
    return { kind: "admitted", reservationId: undefined };
  }

  const entitlement = await readEntitlement(client, input.accountId);
  if (input.requiredCapability !== undefined) {
    const { capabilities } = claimFactsFor(entitlement);
    if (!capabilities.includes(input.requiredCapability)) {
      return { kind: "not_entitled", capability: input.requiredCapability };
    }
  }
  if (!input.metered) return { kind: "admitted", reservationId: undefined };

  const outcome = await reserve(client, {
    accountId: input.accountId,
    capUnits: effectiveCap(entitlement.capUnits, input.defaultCapUnits),
    amount: unitsForMeteredCall(),
    now: input.now,
  });
  if (outcome.kind === "over_cap") return { kind: "over_cap", capUnits: outcome.capUnits };
  return { kind: "admitted", reservationId: outcome.reservationId };
}

/**
 * The effective cap for an account: its own if it names one, the deployment's otherwise.
 *
 * **An account row with `cap_units = 0` is not the same as one with `NULL`**, and the difference is
 * why this reads `!== null` rather than testing for falsiness: `0` is an operator saying "this
 * account may spend nothing", which is a real answer and must not silently become the deployment
 * default.
 */
export function effectiveCap(accountCap: number | null, deploymentCap: number): number {
  return accountCap !== null ? accountCap : deploymentCap;
}

/**
 * The store as the request path uses it: admit a request, and close the hold it took.
 *
 * A seam of the same shape and for the same reason as `MeteringStore` and `KeyStore` — the flagged
 * `npm test` runs with no database, so without it every behaviour this ticket is about would be
 * verified only under `npm run test:db` and the run this repository gates on would be silent about
 * the check that decides whether a user may do anything at all. What it does **not** stand in for is
 * the cap itself: `entitlement.db.test.ts` proves the SQL and the race against a real Postgres,
 * because a race against a fake proves nothing and a fake that appears to enforce a cap is how a
 * suite comes to believe it has tested one.
 */
export interface EntitlementStore {
  readonly entitlementFor: (accountId: string) => Promise<EntitlementRecord>;
  readonly admit: (input: AdmitInput) => Promise<AdmitOutcome>;
  readonly settle: (reservationId: string, charge: boolean) => Promise<SettleOutcome>;
}

export function postgresEntitlementStore(withConnection: WithConnection): EntitlementStore {
  return {
    entitlementFor: (accountId) => withConnection((client) => readEntitlement(client, accountId)),
    admit: (input) => withConnection((client) => admitRequest(client, input)),
    settle: (reservationId, charge) =>
      withConnection((client) => settle(client, reservationId, charge)),
  };
}
