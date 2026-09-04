import { pathToFileURL } from "node:url";
import pg from "pg";
import { periodStart } from "./entitlement/period.js";

/**
 * `npm run billing-debts` — money this gateway cannot account for, and who has to go and look
 * (SONNY-408).
 *
 * **Why this exists as a command rather than as alerting**, which is `revocations.ts`' reason with a
 * different table under it. Three kinds of row are written precisely so that somebody can go and
 * look, and until this command existed nobody was told any of them: what they bought was evidence
 * that survives, queryable by anyone holding `DATABASE_URL` who already knew to ask. That is
 * strictly better than a log line and it is not a person being told.
 *
 * **The three, and why they are one report rather than three.** Each is a fact about money that
 * moved, or may have moved, at the payment provider while this gateway granted nothing for it — so
 * the operator's question is the same for all three ("is anyone owed something?") and the answer has
 * to be one exit code, or a check that runs it will pass while one of the tables is full.
 *
 *   - `sonny.credit_topup` rows reading `unconfirmed`: the charge was sent and its answer could not
 *     be read. **Money may have moved.**
 *   - `sonny.credit_topup` rows reading `attempted` **and carrying an order id**: the order existed
 *     at the provider and the process died before any answer was recorded. Migration 0019 calls
 *     these resolvable for exactly that reason, and they are the same debt as the line above — an
 *     order whose fate only the provider knows. A row with **no** order id is not here: nothing was
 *     ever created, so there is nothing to ask about and nobody was charged.
 *   - `sonny.billing_event` rows reading `unmatched` or `conflict`: a subscription delivery that
 *     this gateway accepted, verified and then did nothing with. `unmatched` is a paying customer it
 *     could not attribute to an account; `conflict` is a delivery about a different subscription
 *     than the one the account is already live on. Both mean somebody is paying for something they
 *     may not have.
 *
 * **What this command does NOT do: it does not resolve anything.** Deliberately, and the reason is
 * the same for all three. A top-up order can only be resolved by asking the provider what became of
 * it — and `finalizeTopUpOrder` does not only ask, it *charges* a draft that was never charged. That
 * is safe on the account's next attempt inside the same period, which is what `attemptTopUp` already
 * does, and it is not safe from here: see `credit/topup.ts`'s `readOutstandingTopUp` for why a stale
 * period makes it actively wrong. An `unmatched` delivery needs a human to work out which account
 * that customer is, and a `conflict` needs somebody to decide which of two subscriptions is real.
 * None of the three is a decision a gateway can take.
 */
export type TopUpDebtOutcome = "attempted" | "unconfirmed";

export interface UnresolvedTopUp {
  readonly topUpId: string;
  readonly accountId: string;
  readonly provider: string;
  /** Never null: the query selects only rows that carry one, which is what makes the row askable. */
  readonly providerOrderId: string;
  readonly outcome: TopUpDebtOutcome;
  readonly periodStart: Date;
  readonly attemptedAt: Date;
}

export type DeliveryDebtOutcome = "conflict" | "unmatched";

export interface UnaccountedDelivery {
  readonly provider: string;
  readonly eventId: string;
  readonly eventType: string;
  readonly outcome: DeliveryDebtOutcome;
  /** `unmatched` carries none by definition; `conflict` names the account it could not move. */
  readonly accountId: string | null;
  readonly receivedAt: Date;
}

export interface BillingDebts {
  readonly topUps: readonly UnresolvedTopUp[];
  readonly deliveries: readonly UnaccountedDelivery[];
}

/**
 * Every unresolved top-up order, across every account and **every period**.
 *
 * **The period filter that `readOutstandingTopUp` carries is deliberately absent here**, and the
 * difference between the two queries is the whole of this ticket's boundary decision. That one is a
 * resolution path and must not reach a period that has ended; this one is a report and must, or the
 * rows that can never be resolved automatically are the exact rows nobody is ever told about.
 */
export async function readUnresolvedTopUps(client: pg.Client): Promise<readonly UnresolvedTopUp[]> {
  const { rows } = await client.query<{
    topup_id: string;
    account_id: string;
    provider: string;
    provider_order_id: string;
    outcome: TopUpDebtOutcome;
    period_start: Date;
    attempted_at: Date;
  }>(
    `SELECT topup_id, account_id, provider, provider_order_id, outcome, period_start, attempted_at
       FROM sonny.credit_topup
      WHERE provider_order_id IS NOT NULL
        AND outcome IN ('attempted', 'unconfirmed')
      ORDER BY attempted_at, topup_id`,
  );
  return rows.map((row) => ({
    topUpId: row.topup_id,
    accountId: row.account_id,
    provider: row.provider,
    providerOrderId: row.provider_order_id,
    outcome: row.outcome,
    periodStart: row.period_start,
    attemptedAt: row.attempted_at,
  }));
}

/**
 * Every subscription delivery this gateway accepted and could not act on.
 *
 * `stale`, `ignored` and `unmapped` are deliberately not here. A stale delivery lost to a newer one
 * and an ignored type was never ours to act on, so neither is owed anything; `unmapped` is a product
 * `BILLING_PLANS` does not name, which is a configuration mistake with a different fix and a
 * different person — and it is fail-closed by design rather than an unknown. `unreadable` is left
 * out on the same terms: it is a shape this gateway could not parse, which is a bug report, not a
 * debt. What is here is only what means somebody may have paid for something they do not have.
 */
export async function readUnaccountedDeliveries(
  client: pg.Client,
): Promise<readonly UnaccountedDelivery[]> {
  const { rows } = await client.query<{
    provider: string;
    event_id: string;
    event_type: string;
    outcome: DeliveryDebtOutcome;
    account_id: string | null;
    received_at: Date;
  }>(
    `SELECT provider, event_id, event_type, outcome, account_id, received_at
       FROM sonny.billing_event
      WHERE outcome IN ('conflict', 'unmatched')
      ORDER BY received_at, event_id`,
  );
  return rows.map((row) => ({
    provider: row.provider,
    eventId: row.event_id,
    eventType: row.event_type,
    outcome: row.outcome,
    accountId: row.account_id,
    receivedAt: row.received_at,
  }));
}

export async function readBillingDebts(client: pg.Client): Promise<BillingDebts> {
  return {
    topUps: await readUnresolvedTopUps(client),
    deliveries: await readUnaccountedDeliveries(client),
  };
}

/**
 * Is this row past the reach of the self-healing path in `credit/topup.ts`?
 *
 * **`attemptTopUp` resolves an outstanding order before it claims a new slot, and it looks only
 * inside the account's current period.** So a row whose `period_start` is an earlier period will
 * never be resolved by the account coming back — the next attempt looks in the new period and finds
 * nothing. That is the case SONNY-408 owns, and it is the reason this report separates the two
 * rather than printing one list: a row in the current period may yet heal itself and one in a past
 * period definitively will not.
 */
export function strandedByPeriodRollover(topUp: UnresolvedTopUp, now: Date): boolean {
  return topUp.periodStart.getTime() < periodStart(now).getTime();
}

/** Operator output is read by people; "1 of those are" is a sentence nobody wrote on purpose. */
function were(n: number): string {
  return n === 1 ? "is" : "are";
}

/** An instant, to the minute, in UTC. Enough to find a row; not a timestamp anybody parses. */
function at(instant: Date): string {
  return instant.toISOString().replace(/:\d\d\.\d+Z$/, "Z");
}

export interface BillingDebtReport {
  readonly text: string;
  /** 1 while anything is outstanding, so a check that runs this command fails while debt exists. */
  readonly exitCode: number;
}

/**
 * The report, and the exit code beside it.
 *
 * **Separated from `main` so the exit code is a value a test can assert**, rather than a branch that
 * only a spawned process could reach. The one thing this command promises — that it exits non-zero
 * while there is unresolved debt — is the thing most worth pinning, and a `process.exitCode` set
 * inside `main` is unreachable from the suite.
 */
export function reportBillingDebts(debts: BillingDebts, now: Date): BillingDebtReport {
  if (debts.topUps.length === 0 && debts.deliveries.length === 0) {
    return { text: "no unresolved billing debt\n", exitCode: 0 };
  }
  const lines: string[] = [];
  const stranded = debts.topUps.filter((topUp) => strandedByPeriodRollover(topUp, now));
  const resolvable = debts.topUps.filter((topUp) => !strandedByPeriodRollover(topUp, now));

  if (debts.topUps.length > 0) {
    lines.push(`${debts.topUps.length} top-up order(s) this gateway granted nothing for:`);
    for (const topUp of debts.topUps) {
      const mark = strandedByPeriodRollover(topUp, now) ? "STRANDED" : "resolvable";
      lines.push(
        `  ${mark}  account ${topUp.accountId}  ${topUp.provider} order ${topUp.providerOrderId}` +
          `  ${topUp.outcome}  period ${at(topUp.periodStart)}  attempted ${at(topUp.attemptedAt)}`,
      );
    }
    lines.push("");
    lines.push(
      "Each of these names an order at the provider whose fate only the provider knows: the charge\n" +
        "was sent and its answer was not read, or the process died between the two. Nothing was\n" +
        "granted for any of them. Look the order up at the provider; if it was paid, either refund\n" +
        "it there or grant the pack by hand.",
    );
  }
  if (resolvable.length > 0) {
    lines.push("");
    lines.push(
      `${resolvable.length} of those ${were(resolvable.length)} in the account's CURRENT period and may still resolve\n` +
        "themselves: the next automatic top-up that account attempts asks the provider about the\n" +
        "order it already has rather than buying a second pack. They are listed because 'may' is not\n" +
        "'will' — an account that never comes back never resolves one.",
    );
  }
  if (stranded.length > 0) {
    lines.push("");
    lines.push(
      `${stranded.length} of those ${were(stranded.length)} STRANDED and cannot resolve ` +
        `${stranded.length === 1 ? "itself" : "themselves"} at all (SONNY-408).\n` +
        "The order was left outstanding when the period rolled over, and the self-healing path looks\n" +
        "only inside the account's current period, so no future attempt will ever find it. Widening\n" +
        "that lookback is deliberately not the fix: resolving an order means finalizing it, which\n" +
        "CHARGES a draft that was never charged, and the credits would land on a period that has\n" +
        "ended and that the balance no longer reads — a charge taken for nothing. So these are a\n" +
        "person's to settle at the provider, and this line is the record that they exist.",
    );
  }
  if (debts.deliveries.length > 0) {
    lines.push("");
    lines.push(`${debts.deliveries.length} subscription delivery(s) that changed nothing:`);
    for (const delivery of debts.deliveries) {
      const scope = delivery.accountId === null ? "no account" : `account ${delivery.accountId}`;
      lines.push(
        `  ${delivery.outcome}  ${delivery.provider} event ${delivery.eventId}` +
          `  ${delivery.eventType}  ${scope}  received ${at(delivery.receivedAt)}`,
      );
    }
    lines.push("");
    lines.push(
      "An `unmatched` delivery is a paying customer this gateway could not attribute to an account —\n" +
        "most often the account id did not survive the round trip through the checkout link. A\n" +
        "`conflict` is a delivery about a different subscription than the one that account is already\n" +
        "live on, which is refused rather than merged because merging is the direction that can cost\n" +
        "a customer their access. Both need somebody to decide who is paying for what.",
    );
  }
  return { text: `${lines.join("\n")}\n`, exitCode: 1 };
}

async function main(): Promise<void> {
  const url = process.env["DATABASE_URL"];
  if (!url) {
    process.stderr.write("DATABASE_URL is not set\n");
    process.exit(78);
  }
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    const report = reportBillingDebts(await readBillingDebts(client), new Date());
    process.stdout.write(report.text);
    process.exitCode = report.exitCode;
  } finally {
    await client.end();
  }
}

// Only as a CLI, never on import — the same guard and the same reason as `db/migrate.ts`, where a
// template-string comparison made the whole command a silent no-op under any path with a space.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
