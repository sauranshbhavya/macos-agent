import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { callerOf } from "../auth/gate.js";
import { errorBody } from "../errors.js";
import { creditBalance, type CreditBalance } from "../credit/balance.js";
import type { CreditCatalogue } from "../credit/catalogue.js";
import type { CreditFacts, CreditStore } from "../credit/store.js";
import { attemptTopUp, type TopUpDeps, type TopUpRefusal } from "../credit/topup.js";
import { ACCOUNT_DEADLINE_MS, DEADLINE_MS } from "../model/limits.js";
import { sendUpstreamFailure, underTotalDeadline } from "../model/routing.js";

/**
 * `GET /v1/account/credits` — **the one number a user tracks**, served (SONNY-212) — and the two
 * routes that let a user buy more of it when it runs out (SONNY-215).
 *
 * SONNY-17 fixed the user-facing unit: "screen-control runs left this month". This is where the Mac
 * reads it. `ScreenControlAllowanceService` on the client is the reader;
 * rendering it is SONNY-214's and refusing on it is SONNY-213's, and neither of those decisions is
 * taken here — the `GET` reports and never refuses.
 *
 * ## Why this is not on the entitlement claim
 *
 * The obvious alternative was a field on §5.3's signed claim, and it is wrong for a reason the claim
 * itself states: that claim is cached for **24 hours** and honoured for **72 more** past expiry, so a
 * client can legitimately be acting on one that is four days old. An entitlement survives that
 * because it changes on the order of a subscription; a run count changes on the order of a run. A
 * runs-left figure with a four-day grace window would be wrong most of the time it was read, and it
 * would be wrong in the direction that matters — showing runs to somebody who has none.
 *
 * So it is a separate, unsigned, uncached read. **Unsigned is right here and would not be right
 * there**: the claim is signed because the *client* enforces it offline, and nothing offline can be
 * enforced about a number that is stale the moment it is stored.
 *
 * ## Not metered, not charged, and rate limited like everything else
 *
 * §11's `route` enum has no value for it and it opens no provider call, so it costs nothing to
 * serve — the same call `routes/entitlements.ts` makes, and for the sharper version of the same
 * reason: charging a user for asking how much they have left would make the question spend the
 * answer. It is authenticated, so it is absent from `PUBLIC_ROUTES` and rate limited with every
 * other authenticated route. **That is true of the top-up routes below as well, and for the top-up
 * itself it is worth saying out loud: the charge is at the payment provider and against a plan's
 * allowance, and it does not touch §9's spend cap at all** — SONNY-212 declined to weight the cap
 * and SONNY-213 kept the two apart, because the cap is an operator's anti-abuse ceiling and the
 * allowance is a plan's purchase.
 *
 * ## The two top-up routes, and why they are two (SONNY-215)
 *
 * `PUT /v1/account/credits/auto-top-up` records **consent** and charges nothing.
 * `POST /v1/account/credits/top-up` **charges**, and refuses first of all on the absence of that
 * consent. Two paths rather than two methods on one, because a mistyped path must not be able to
 * reach the other one — and the setting is the thing whose whole job is to stand between a user and
 * a charge.
 *
 * **The charge route carries §9's idempotency guarantees like every other `POST`**, and it is the
 * one route where they are about money: `idempotency/hook.ts` claims the key before this handler
 * runs, so a retry of one attempt replays the stored answer rather than buying a second pack. The
 * Mac mints a fresh key per attempt and marks the request not retry-safe, which is
 * `verifyEmailCode`'s pairing and for its reason — a call that spends something the user cannot get
 * back should be made once.
 *
 * ## The read and the setting run under §12's last row's total; the charge does not (SONNY-434)
 *
 * The `GET` and the `PUT` wait on the database and nothing else, and the store leases its own
 * connections, so each handler runs its store calls inside `underTotalDeadline`: one budget for the
 * whole handler, carried to every lease it takes — the `PUT` takes two, its write and the re-read it
 * answers with. A statement cancelled inside it answers `504 provider.timeout`, retryable, which is
 * honest for both: the read costs nothing to repeat, and the setting is idempotent — a retry writes
 * the same value again. **What that `504` does not say on the `PUT`** (PR #235's fresh review, F2):
 * its two leases are two transactions, the write autocommits on the first, and a budget that runs
 * out in the re-read — or in the wait for its connection — answers `504` with the setting already
 * written; the Mac's one automatic retry ordinarily converges on the `200`, and a retry that also
 * times out leaves the toggle showing off while the gateway holds consent, until the next read.
 * One lease in one transaction would roll the write back with the timeout; that touches
 * `CreditStore`'s seam (SONNY-300) and is recorded on SONNY-434 for the founders rather than taken
 * here. The charge below is on §12's own `topUp` row with `withinTotalDeadline`,
 * and its reads before and after the charge deliberately stay on the pool's per-statement bound,
 * because its deadline answers `topup.unconfirmed` and a second bound with a different answer on
 * the same handler would be two promises about one request.
 */
export interface CreditRouteDeps {
  readonly store: CreditStore;
  readonly catalogue: CreditCatalogue;
  /**
   * Everything the charge needs, or `undefined` on a deployment that takes no payments (SONNY-215).
   *
   * **`undefined` unmounts nothing.** The two routes are registered either way, and the charge
   * refuses with `topup.not_permitted`, for the reason `app.ts` gives about the model routes: a
   * `404` tells a client there is no such route, which is a different and less true statement than
   * "this deployment does not sell top-ups". The setting route still works, because consent is the
   * user's and is worth keeping whether or not a pack exists to spend it on today.
   */
  readonly topUp?: Omit<TopUpDeps, "pack"> | undefined;
  /** Tests only. Nothing a deployment sets, the same seam and reason as the entitlement route's. */
  readonly now?: (() => Date) | undefined;
  /**
   * §12's total deadline for the charge, in milliseconds — **tests only**, defaulting to
   * `DEADLINE_MS.topUp.total` (SONNY-430).
   *
   * The seam exists because the property worth testing is what the route *does* when the deadline
   * elapses, and a test that waited the real thirty seconds to find out would be a thirty-second
   * test.
   *
   * **What holds the default is `runs on §12's own total when nothing overrides it`, which drives
   * this route with no override at all and advances its own timer** — not the constant assertion
   * this comment used to point at. That one asserted `DEADLINE_MS.topUp.total === 30_000`, a fact
   * about the table that says nothing about the route reading it, so pointing the `??` below at the
   * `auth` row's fifteen seconds passed the whole suite (PR #220's F2) — deploying the charge on a
   * bound shorter than its own upstream budget.
   */
  readonly topUpTotalDeadlineMs?: number | undefined;
}

export const CREDITS_PATH = "/v1/account/credits";
export const AUTO_TOP_UP_PATH = "/v1/account/credits/auto-top-up";
export const TOP_UP_PATH = "/v1/account/credits/top-up";

/**
 * The setting's body. **`enabled` is required and has no default**, on `config.ts`'s standing rule
 * about values with no safe reading: a `PUT` that omitted it would be a request to set a
 * money-spending switch to whatever this code happened to think was sensible.
 */
const autoTopUpBody = z.object({ enabled: z.boolean() });

/**
 * One body, three routes.
 *
 * **The `GET`, the setting and the charge all answer the same shape**, so a client decodes one type
 * and every answer is the account's whole current position rather than a fragment it has to merge
 * into what it already had. It is also what lets the gate skip a re-read after a successful charge:
 * the response *is* the new balance.
 */
function creditsBody(
  balance: CreditBalance,
  facts: CreditFacts,
  catalogue: CreditCatalogue,
  topUpConfigured: boolean,
): Record<string, unknown> {
  // §2.1 makes the client tolerant of unknown response fields, so this body can grow additively.
  return {
    plan: balance.plan,
    period_start: balance.periodStart.toISOString(),
    period_end: balance.periodEnd.toISOString(),
    /** The user-facing unit. Everything below it is the derivation that produced it. */
    screen_control_runs_left: balance.runsLeft,
    screen_control_runs_included: balance.runsIncluded,
    /**
     * **Diagnostic, and deliberately not a second thing to show a user.** The ticket's own
     * verification asks the founders to "sanity-check the numbers once measured costs exist", and
     * a runs figure with no visible derivation cannot be sanity-checked at all — the question is
     * always whether the weights or the divisor is what moved it. The rounding in `balance.ts`
     * exists so these five numbers and the run count agree with each other exactly.
     *
     * **`remaining` is read by the Mac and the other four are not** (SONNY-213's F1): the gate's
     * step boundary asks whether the account has actually run out, which `screen_control_runs_left`
     * cannot answer for a session whose own iterations are already subtracted from it.
     */
    credits: {
      allowance: balance.credits.allowance,
      drawn: balance.credits.drawn,
      remaining: balance.credits.remaining,
      per_run: balance.credits.perRun,
      topped_up: balance.credits.toppedUp,
    },
    /**
     * The auto-top-up setting, and whether there is anything to spend it on (SONNY-215).
     *
     * **`offered` and `opted_in` are separate because they are different facts with different
     * owners**: the first is the deployment's — is a pack configured and can this gateway charge —
     * and the second is the user's. The app renders no control when nothing is offered, on the
     * founder direction of 2026-08-31 that a control which only fails when pressed is a broken
     * control.
     */
    auto_top_up: {
      offered: topUpConfigured,
      opted_in: facts.autoTopUpOptedInAt !== null,
      /** How many attempts this period has left. `0` once the bound is spent. */
      attempts_left: attemptsLeft(catalogue, facts),
      /**
       * **What one pack costs, so the switch that authorises the charge can say it** (SONNY-215's
       * F6, founder decision option B). `null` when this deployment sells none, because a price for
       * a thing that cannot be bought is a number with nothing behind it.
       *
       * The *configured* price, which is the only one available before a purchase has happened. The
       * record below is the provider's own figure, and the two can disagree if a deployment lets
       * them — `credit/catalogue.ts` carries what bounds that.
       */
      price:
        topUpConfigured && catalogue.topUp !== undefined
          ? { amount: catalogue.topUp.price.amount, currency: catalogue.topUp.price.currency }
          : null,
    },
    /**
     * **What this account was last charged for a top-up, and when** (SONNY-215's F6). `null` for an
     * account that has never been charged, which is every account by default.
     *
     * Outside `auto_top_up` because it is not the setting: it is a record of something that
     * happened, and it stays true after the setting is turned off. Outside `credits` for the mirror
     * of that reason — every figure in there is a credit in this period's pool, and this is money in
     * a currency, at an instant that may be months old.
     */
    last_top_up:
      facts.lastTopUp === undefined
        ? null
        : {
            amount: facts.lastTopUp.amount,
            currency: facts.lastTopUp.currency,
            at: facts.lastTopUp.at.toISOString(),
          },
  };
}

/**
 * How many top-up attempts this period may still make.
 *
 * `0` when nothing is offered, which is the honest answer for a deployment that sells no pack and is
 * also what stops a client reading a positive number off a gateway that would refuse.
 */
function attemptsLeft(catalogue: CreditCatalogue, facts: CreditFacts): number {
  const pack = catalogue.topUp;
  if (pack === undefined) return 0;
  return Math.max(0, pack.maxPerPeriod - facts.topUpAttemptsThisPeriod);
}

/** §7.2's mapping for every way a top-up does not happen. */
function refuse(
  request: FastifyRequest,
  reply: FastifyReply,
  refusal: TopUpRefusal,
): FastifyReply {
  switch (refusal) {
    case "not_offered":
    case "not_opted_in":
    case "not_needed":
    case "limit_reached":
    case "no_customer":
      // **One code for five refusals, and the distinction is logged rather than sent.** They share
      // everything a client does about them — do not retry, and let the gate refuse exactly as it
      // would have — and the app's own copy for the wall is SONNY-213's one sentence. What separates
      // them is what an operator needs to know, which is what the log line beside this carries.
      return reply
        .status(409)
        .send(
          errorBody("topup.not_permitted", "No top-up was made for this account.", request.id, {
            retryable: false,
          }),
        );
    case "declined":
      // **Its own status and its own code**, even though this client does nothing different with it
      // yet: the difference between "your card" and "your settings" is the one a later surface
      // cannot recover if the two are collapsed here.
      return reply
        .status(402)
        .send(
          errorBody("topup.declined", "The payment provider did not complete the charge.", request.id, {
            retryable: false,
          }),
        );
    case "unavailable":
      return reply
        .status(502)
        .send(
          errorBody("provider.unavailable", "The payment provider could not be reached.", request.id, {
            retryable: true,
          }),
        );
    case "timed_out":
      return reply
        .status(504)
        .send(
          errorBody("provider.timeout", "The payment provider took too long.", request.id, {
            retryable: true,
          }),
        );
    case "rejected":
      return reply
        .status(502)
        .send(
          errorBody("provider.rejected", "The payment provider refused this request.", request.id, {
            retryable: false,
          }),
        );
    case "unconfirmed":
      // **Not retryable, and that is the whole reason this is not `provider.unavailable`.** The
      // charge may have gone through. A client told to retry would buy a second pack to recover from
      // a first one it cannot see.
      return reply
        .status(502)
        .send(
          errorBody("topup.unconfirmed", "The payment provider's answer could not be read.", request.id, {
            retryable: false,
          }),
        );
  }
}

/**
 * What the charge's total deadline resolves to when it elapses — a value, deliberately, not a throw
 * (SONNY-430).
 *
 * A thrown timeout would reach `sendUpstreamFailure`'s `504 provider.timeout`, and that answer is
 * marked retryable. On this route it must not be: at the instant the deadline elapses a charge may
 * be in flight at the provider, and "the provider did not answer in time, try again" is how PR
 * #196's F1 bought a second pack. The route answers `topup.unconfirmed` instead, which is the code
 * this state already has and which §7.2 marks not retryable.
 */
const TOP_UP_DEADLINE_ELAPSED = Symbol("the top-up route's total deadline elapsed");

/**
 * Race `work` against §12's total deadline for this route.
 *
 * **The losing work is not cancelled, and that is the property rather than an oversight.**
 * `attemptTopUp` writes the provider's order id onto the attempt row *before* anything can charge,
 * so a charge still in flight when this returns is one whose row already names the object it is
 * charging: the work runs on, settles that row, and the account's next attempt resolves it either
 * way. Cancelling it here would be the one way to abandon a charge the provider has accepted —
 * killing the settle after the money moved — which is exactly the shape PR #196's F1 exists to close.
 * So this bounds the *answer*, never the work.
 *
 * **The no-op `catch` is defensive, not load-bearing, and the reason first given for it was wrong**
 * (PR #220's F5). That reason was that a rejection arriving after the timer decided the race would be
 * unhandled and end the process. `Promise.race` subscribes to every promise it is handed, so a late
 * rejection is already handled; the reviewer measured it on node v22.23.1 with this line removed —
 * the process stayed alive and an `unhandledRejection` listener saw nothing, against a control in the
 * same harness where a genuinely unhandled rejection was observed and set a non-zero exit. It is kept
 * because it makes the handling explicit at the one place a reader asks the question, and because it
 * would still hold if the race were ever replaced by something that does not subscribe. What it is
 * not is the thing standing between this route and a crash.
 */
async function withinTotalDeadline<T>(
  totalMs: number,
  work: Promise<T>,
): Promise<T | typeof TOP_UP_DEADLINE_ELAPSED> {
  // Defensive, not load-bearing — see this function's doc comment and PR #220's F5.
  work.catch(() => {});
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<typeof TOP_UP_DEADLINE_ELAPSED>((resolve) => {
        timer = setTimeout(() => resolve(TOP_UP_DEADLINE_ELAPSED), totalMs);
      }),
    ]);
  } finally {
    // Or the timer holds the event loop open for the rest of the deadline on every fast charge.
    if (timer !== undefined) clearTimeout(timer);
  }
}

export function registerCreditRoutes(app: FastifyInstance, deps: CreditRouteDeps): void {
  const now = deps.now ?? (() => new Date());
  const pack = deps.catalogue.topUp;
  const topUpConfigured = pack !== undefined && deps.topUp !== undefined;
  const topUpTotalDeadlineMs = deps.topUpTotalDeadlineMs ?? DEADLINE_MS.topUp.total;

  /** The account's whole position, read once. Every route below answers with it. */
  async function position(accountId: string, at: Date) {
    const facts = await deps.store.factsFor(accountId, at);
    const balance = creditBalance({
      catalogue: deps.catalogue,
      planKey: facts.planKey,
      draw: facts.draw,
      toppedUpCredits: facts.toppedUpCredits,
      now: at,
    });
    return { facts, balance };
  }

  app.get(CREDITS_PATH, async (request, reply) => {
    const caller = callerOf(request);
    // One clock read for the whole response, so the period whose draw is counted is the period
    // reported, and the grace window is judged at the same instant both.
    const at = now();
    let read;
    try {
      read = await underTotalDeadline(ACCOUNT_DEADLINE_MS, () => position(caller.accountId, at));
    } catch (error) {
      return sendUpstreamFailure(request, reply, error);
    }
    const { facts, balance } = read;
    return reply.send(creditsBody(balance, facts, deps.catalogue, topUpConfigured));
  });

  app.put(AUTO_TOP_UP_PATH, async (request, reply) => {
    const caller = callerOf(request);
    const parsed = autoTopUpBody.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .status(400)
        .send(
          errorBody("request.invalid", "This request body is not a setting.", request.id, {
            retryable: false,
          }),
        );
    }
    const at = now();
    let read;
    try {
      read = await underTotalDeadline(ACCOUNT_DEADLINE_MS, async () => {
        await deps.store.setAutoTopUp(caller.accountId, parsed.data.enabled, at);
        // **Answered with the whole position rather than with an acknowledgement**, so the app's
        // toggle and the number above it can never be one request apart: the surface that shows
        // the setting shows the allowance beside it, and two reads is two chances for them to
        // disagree. Inside the same budget as the write, so the two leases share §12's total.
        return position(caller.accountId, at);
      });
    } catch (error) {
      return sendUpstreamFailure(request, reply, error);
    }
    const { facts, balance } = read;
    request.log.info(
      { accountId: caller.accountId, optedIn: facts.autoTopUpOptedInAt !== null },
      "auto top-up setting",
    );
    return reply.send(creditsBody(balance, facts, deps.catalogue, topUpConfigured));
  });

  app.post(TOP_UP_PATH, async (request, reply) => {
    const caller = callerOf(request);
    const at = now();
    const { facts, balance } = await position(caller.accountId, at);
    const outcome =
      deps.topUp === undefined
        ? ({ kind: "refused", refusal: "not_offered" } as const)
        : await withinTotalDeadline(
            topUpTotalDeadlineMs,
            attemptTopUp(
              { ...deps.topUp, pack },
              {
                accountId: caller.accountId,
                balance,
                consentedAt: facts.autoTopUpOptedInAt,
                now: at,
              },
            ),
          );
    if (outcome === TOP_UP_DEADLINE_ELAPSED) {
      // **Logged at `warn`, unlike the ordinary refusals below.** Every other refusal is a decision
      // this gateway made and can explain; this one means the gateway stopped waiting for an answer
      // about money, and the attempt row is left for the account's next try to resolve. That is an
      // operator's business, and SONNY-408 is the surface that will read those rows.
      request.log.warn(
        { accountId: caller.accountId, totalDeadlineMs: topUpTotalDeadlineMs },
        "top-up did not answer inside its total deadline",
      );
      return refuse(request, reply, "unconfirmed");
    }
    if (outcome.kind === "refused") {
      // The reason is logged and never sent, exactly as the webhook's refusal reason and the
      // portal's are: five of the ten collapse into one code above, and this is where the difference
      // between "they never asked" and "their card was declined" survives.
      request.log.info(
        { accountId: caller.accountId, refusal: outcome.refusal },
        "top-up refused",
      );
      return refuse(request, reply, outcome.refusal);
    }
    request.log.info(
      { accountId: caller.accountId, credits: outcome.credits },
      "top-up granted",
    );
    // Re-read rather than adding the granted credits to the balance in hand. The row is written by
    // the charge path, so reading it back is what proves the grant actually landed — and computing
    // the new figure here would be a second derivation of a number `balance.ts` owns.
    const after = await position(caller.accountId, at);
    return reply.send(creditsBody(after.balance, after.facts, deps.catalogue, topUpConfigured));
  });
}
