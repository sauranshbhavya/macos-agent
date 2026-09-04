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
/**
 * The outcome vocabularies, and **which side of them is the default** (PR #201's F4).
 *
 * **Both queries below exclude the states known not to be debt and report everything else**, which
 * is the opposite of how this file first shipped. The first version listed the debt states in a
 * closed `IN (…)`, and nothing tied that list to the `CHECK` constraints that actually define the
 * vocabulary — migration 0018 for deliveries, 0019 for top-ups. So a later migration adding an
 * outcome put it silently on the *not-debt* side: measured by the reviewer, an eighth
 * `billing_event` outcome as the only row in the table produced `no unresolved billing debt` and
 * exit **0**. That is the clean-zero family `CLAUDE.md` records, arriving on a money report — the
 * reassuring sentence printed over a row nobody had classified.
 *
 * Inverting it makes the failure direction the safe one: an outcome this file has never heard of is
 * reported, labelled `UNKNOWN` so nobody mistakes it for a classified debt, and the exit code is
 * non-zero. The cost is that a genuinely harmless future outcome shows up until somebody adds it to
 * the non-debt list, which is a person being asked a question rather than a report keeping quiet.
 */
export const TOPUP_DEBT_OUTCOMES: readonly string[] = ["attempted", "unconfirmed"];

/**
 * The top-up outcomes that are **not** debt, and why each one is not.
 *
 * - `granted` — the provider charged the customer and this gateway credited the pack. Settled.
 * - `declined` — the provider answered and did not charge. No money moved.
 * - `provider_error` — the order could not be created at all, so there is nothing at the provider to
 *   ask about. 0019 calls it the one outcome that never carries an order id.
 */
export const TOPUP_NON_DEBT_OUTCOMES: readonly string[] = ["granted", "declined", "provider_error"];

export interface UnresolvedTopUp {
  readonly topUpId: string;
  readonly accountId: string;
  readonly provider: string;
  /**
   * **Nullable now, and only ever null on an outcome this file does not know** (F4). A known
   * resolvable row is selected only when it carries an order id, because that id is what makes the
   * row askable at the provider; an unknown outcome is reported whether or not it carries one,
   * since this file cannot know what invariants a future outcome keeps.
   */
  readonly providerOrderId: string | null;
  /** The raw column. Not a union: an outcome added by a later migration must survive being read. */
  readonly outcome: string;
  readonly periodStart: Date;
  readonly attemptedAt: Date;
}

export const DELIVERY_DEBT_OUTCOMES: readonly string[] = ["conflict", "unmatched"];

/**
 * The delivery outcomes that are **not** debt, and why each one is not.
 *
 * - `applied` — the entitlement moved. That is the delivery working.
 * - `ignored` — a type this gateway does not act on. Never ours.
 * - `stale` — an older delivery than the state it met. A newer one already won.
 * - `unmapped` — a product `BILLING_PLANS` does not name. Fail-closed by design and a configuration
 *   mistake with a different fix and a different person.
 * - `unreadable` — the signature passed and the payload did not parse. A bug report, not a debt.
 *
 * **`unmapped` is the one worth arguing about and it is excluded deliberately** (PR #201's F4, as a
 * question rather than a finding): it is a customer who paid for a product nobody configured, which
 * is the same user-facing fact as `unmatched`. It stays out because it is fail-closed and visible by
 * configuration rather than unknown, and because the fix is a `BILLING_PLANS` entry. Recorded here
 * so the next reader meets the argument rather than re-deriving it.
 */
export const DELIVERY_NON_DEBT_OUTCOMES: readonly string[] = [
  "applied",
  "ignored",
  "stale",
  "unmapped",
  "unreadable",
];

export interface UnaccountedDelivery {
  readonly provider: string;
  readonly eventId: string;
  readonly eventType: string;
  /** The raw column, for `UnresolvedTopUp.outcome`'s reason. */
  readonly outcome: string;
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
 *
 * **Two clauses, and the second is the inversion** (F4). The first takes the two known resolvable
 * states when they name an order — the order id is what makes the row askable, and without one
 * nothing was ever created at the provider. The second takes any outcome not in the known five at
 * all, order id or not, because this file cannot know which invariants a future outcome keeps.
 */
export async function readUnresolvedTopUps(client: pg.Client): Promise<readonly UnresolvedTopUp[]> {
  const { rows } = await client.query<{
    topup_id: string;
    account_id: string;
    provider: string;
    provider_order_id: string | null;
    outcome: string;
    period_start: Date;
    attempted_at: Date;
  }>(
    `SELECT topup_id, account_id, provider, provider_order_id, outcome, period_start, attempted_at
       FROM sonny.credit_topup
      WHERE (outcome = ANY($1) AND provider_order_id IS NOT NULL)
         OR NOT (outcome = ANY($2))
      ORDER BY attempted_at, topup_id`,
    [TOPUP_DEBT_OUTCOMES, [...TOPUP_DEBT_OUTCOMES, ...TOPUP_NON_DEBT_OUTCOMES]],
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
 * Every subscription delivery this gateway accepted and could not act on — **and every one whose
 * outcome this file does not recognise** (F4).
 *
 * The five states that are not debt are named in `DELIVERY_NON_DEBT_OUTCOMES` above, each with the
 * reason it is not; everything else is reported. So `conflict` and `unmatched` arrive as they always
 * did, and an outcome a later migration adds arrives too, labelled `UNKNOWN`, rather than falling
 * silently on the harmless side of a closed list.
 */
export async function readUnaccountedDeliveries(
  client: pg.Client,
): Promise<readonly UnaccountedDelivery[]> {
  const { rows } = await client.query<{
    provider: string;
    event_id: string;
    event_type: string;
    outcome: string;
    account_id: string | null;
    received_at: Date;
  }>(
    `SELECT provider, event_id, event_type, outcome, account_id, received_at
       FROM sonny.billing_event
      WHERE NOT (outcome = ANY($1))
      ORDER BY received_at, event_id`,
    [DELIVERY_NON_DEBT_OUTCOMES],
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
 * Has the period rolled over past this row?
 *
 * **This models ONE of the filters `readOutstandingTopUp` applies, and is named for exactly that**
 * (PR #201's F3). It used to be documented as answering "is this row past the reach of the
 * self-healing path", which is a claim about *all* of that query's scoping, and it is not: the query
 * filters on account, provider, period and outcome, and `attemptTopUp` refuses on withdrawn consent
 * before it ever reads it. `reachOfSelfHeal` below is the classification the report uses; this stays
 * a separate predicate because the period boundary is the one this branch's decision is about and
 * because it cannot be wrong in the dangerous direction — `<` against `periodStart(now)`, and the
 * self-heal only ever asks for the current period, so a row this answers `true` for is genuinely
 * unreachable.
 */
export function strandedByPeriodRollover(topUp: UnresolvedTopUp, now: Date): boolean {
  return topUp.periodStart.getTime() < periodStart(now).getTime();
}

/**
 * How far out of the self-healing path's reach a row is — the label the report prints.
 *
 * **The whole value this report adds over `SELECT *` is this split**, so it has to be honest about
 * which rows it can actually say something about. Four answers, checked in this order:
 *
 * - `unknown-outcome` — the outcome is not one of the five 0019 declares, so nothing here knows what
 *   the row means. Checked first: a state this file has never heard of cannot be reasoned about with
 *   rules written for the states it has (F4).
 * - `stranded-period` — the period rolled over. The self-heal looks only inside the account's
 *   current period, so no future attempt finds it. This branch's boundary decision.
 * - `stranded-provider` — the row names a provider this deployment no longer runs, so the self-heal's
 *   `provider = $3` can never match it either (F3). Checkable only when the caller knows what this
 *   deployment's provider is; `main` reads it from `BILLING_PROVIDER`, the same variable
 *   `billingDepsFrom` turns into `deps.provider.name`.
 * - `resolvable` — none of the above. **Still not a promise**, and the report's own paragraph says
 *   what has to hold: `attemptTopUp` refuses before it reads the order at all if the account has
 *   withdrawn consent (`opted_in_at` set to NULL by `setAutoTopUp(false)`), has no customer at the
 *   provider, or the deployment offers no pack. Consent is the reachable one — turning auto-top-up
 *   off is the likeliest reaction to a surprise charge, and it is exactly the account whose
 *   `unconfirmed` row is outstanding. Those three are named rather than modelled: two of them are
 *   configuration this command does not read, and the consent join is recorded on SONNY-408 rather
 *   than built here.
 */
export type TopUpReach = "unknown-outcome" | "stranded-period" | "stranded-provider" | "resolvable";

export function reachOfSelfHeal(
  topUp: UnresolvedTopUp,
  now: Date,
  deploymentProvider: string | undefined,
): TopUpReach {
  if (!TOPUP_DEBT_OUTCOMES.includes(topUp.outcome)) return "unknown-outcome";
  if (strandedByPeriodRollover(topUp, now)) return "stranded-period";
  if (deploymentProvider !== undefined && topUp.provider !== deploymentProvider) {
    return "stranded-provider";
  }
  return "resolvable";
}

/** What each reach prints in the row's first column. */
const REACH_LABEL: Readonly<Record<TopUpReach, string>> = {
  "unknown-outcome": "UNKNOWN",
  "stranded-period": "STRANDED (period)",
  "stranded-provider": "STRANDED (provider)",
  resolvable: "resolvable",
};

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
export function reportBillingDebts(
  debts: BillingDebts,
  now: Date,
  deploymentProvider?: string,
): BillingDebtReport {
  if (debts.topUps.length === 0 && debts.deliveries.length === 0) {
    return { text: "no unresolved billing debt\n", exitCode: 0 };
  }
  const lines: string[] = [];
  const reach = new Map<UnresolvedTopUp, TopUpReach>(
    debts.topUps.map((topUp) => [topUp, reachOfSelfHeal(topUp, now, deploymentProvider)]),
  );
  const withReach = (want: TopUpReach): readonly UnresolvedTopUp[] =>
    debts.topUps.filter((topUp) => reach.get(topUp) === want);
  const strandedPeriod = withReach("stranded-period");
  const strandedProvider = withReach("stranded-provider");
  const unknownOutcome = withReach("unknown-outcome");
  const resolvable = withReach("resolvable");

  if (debts.topUps.length > 0) {
    lines.push(`${debts.topUps.length} top-up order(s) this gateway granted nothing for:`);
    for (const topUp of debts.topUps) {
      const order = topUp.providerOrderId === null ? "no order id" : `order ${topUp.providerOrderId}`;
      lines.push(
        `  ${REACH_LABEL[reach.get(topUp)!]}  account ${topUp.accountId}  ${topUp.provider} ${order}` +
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
      `${resolvable.length} of those ${were(resolvable.length)} in the account's CURRENT period, at this\n` +
        "deployment's own provider, and the next automatic top-up that account attempts would ask the\n" +
        "provider about the order it already has rather than buying a second pack. **That is a\n" +
        "possibility and not a promise**, and three things this report does not check have to hold\n" +
        "for it: the account must still be opted in to automatic top-ups, it must still have a\n" +
        "customer at the provider, and this deployment must still offer a pack. Consent is the one to\n" +
        "look at first — `attemptTopUp` refuses on a withdrawn consent before it reads the order at\n" +
        "all, and turning auto-top-up off is the likeliest reaction to a surprise charge.",
    );
  }
  if (deploymentProvider === undefined && resolvable.length > 0) {
    lines.push("");
    lines.push(
      "BILLING_PROVIDER was not set when this ran, so the provider half of that could not be\n" +
        "checked: a row above marked resolvable may name a provider this deployment no longer runs,\n" +
        "which the self-healing path would never match either. Re-run with BILLING_PROVIDER set to\n" +
        "see those separated out.",
    );
  }
  if (strandedProvider.length > 0) {
    lines.push("");
    lines.push(
      `${strandedProvider.length} of those ${were(strandedProvider.length)} STRANDED at another PROVIDER (PR #201's F3):\n` +
        `the order was bought at a provider this deployment no longer runs — BILLING_PROVIDER is now\n` +
        `${JSON.stringify(deploymentProvider)} — and the self-healing path scopes its lookup by provider as well as by\n` +
        "period, so no future attempt will match it whatever the period. Same remedy as the period\n" +
        "case below: settle it at the provider it was bought at.",
    );
  }
  if (unknownOutcome.length > 0) {
    lines.push("");
    lines.push(
      `${unknownOutcome.length} of those ${were(unknownOutcome.length)} carrying an outcome this command has never heard\n` +
        "of, so nothing above is known about them (PR #201's F4). A migration has added an outcome to\n" +
        "sonny.credit_topup that src/billing-debts.ts does not classify. They are reported rather than\n" +
        "hidden, and the exit code is non-zero, because the alternative is a report that answers 'no\n" +
        "unresolved billing debt' over a row nobody has looked at. Classify it in\n" +
        "TOPUP_DEBT_OUTCOMES or TOPUP_NON_DEBT_OUTCOMES and this line stops.",
    );
  }
  if (strandedPeriod.length > 0) {
    lines.push("");
    lines.push(
      `${strandedPeriod.length} of those ${were(strandedPeriod.length)} STRANDED by a period rollover and cannot resolve ` +
        `${strandedPeriod.length === 1 ? "itself" : "themselves"} at all (SONNY-408).\n` +
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
      const mark = DELIVERY_DEBT_OUTCOMES.includes(delivery.outcome)
        ? delivery.outcome
        : `UNKNOWN ${delivery.outcome}`;
      lines.push(
        `  ${mark}  ${delivery.provider} event ${delivery.eventId}` +
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
    const unknownDeliveries = debts.deliveries.filter(
      (delivery) => !DELIVERY_DEBT_OUTCOMES.includes(delivery.outcome),
    );
    if (unknownDeliveries.length > 0) {
      lines.push("");
      lines.push(
        `${unknownDeliveries.length} of those ${were(unknownDeliveries.length)} marked UNKNOWN: a migration has added an\n` +
          "outcome to sonny.billing_event that src/billing-debts.ts does not classify (PR #201's F4).\n" +
          "Reported rather than hidden, for the reason the top-up half gives. Classify it in\n" +
          "DELIVERY_DEBT_OUTCOMES or DELIVERY_NON_DEBT_OUTCOMES and this line stops.",
      );
    }
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
    // **`BILLING_PROVIDER`, the same variable `billingDepsFrom` turns into `deps.provider.name`**
    // (F3). Optional here rather than required: this command must run on a deployment that does no
    // billing at all, and when it is absent the report says which half of the classification it
    // could not make rather than quietly making it wrong.
    const report = reportBillingDebts(
      await readBillingDebts(client),
      new Date(),
      process.env["BILLING_PROVIDER"],
    );
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
