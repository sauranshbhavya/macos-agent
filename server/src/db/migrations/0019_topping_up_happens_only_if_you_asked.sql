-- 0019 — topping up happens only if you asked (SONNY-215).
--
-- Spec §16.4 names auto top-up as the mechanism that serves its mid-task-lapse principle: a user
-- running low tops up rather than hitting a wall. SONNY-17 fixed its shape on 2026-08-16 —
-- **opt-in, and off by default** — and this file is where "off by default" stops being a value
-- somebody has to set correctly and becomes a property of the schema.
--
-- ## The consent is a row, and its absence is the default
--
-- `auto_topup_consent` holds one row per account that has ever *touched* the setting. An account
-- with no row has not opted in, and an account whose row carries a NULL `opted_in_at` has opted
-- back out. So the predicate the charge path runs is `opted_in_at IS NOT NULL` against a row that
-- may not exist, and **both ways of not having said yes answer the same way**. There is no boolean
-- with a default to get wrong, no backfill, and no migration that could turn the feature on for
-- anybody.
--
-- **It is its own table rather than a column on `sonny.entitlement`, and the reason is lifecycle
-- rather than tidiness.** That row is written by the payment provider's webhooks — `writeFor` in
-- `server/src/billing/store.ts` rewrites plan, capabilities, revocation and the grace window on
-- every delivery — and it is the row an operator `grant` overwrites. A consent to be charged money
-- is a different fact with a different owner: it is the *user's*, it survives cancelling and
-- resubscribing, and nothing the provider says should move it. Keeping it out of the reach of every
-- writer that has a reason to touch an entitlement is the whole of the argument.
--
-- **`opted_in_at` is an instant and not a boolean**, because the question a disputed charge asks is
-- *when did they agree to this*, and a boolean cannot answer it. `credit_topup.consented_at` then
-- copies the value that was in force at the moment of each charge, so every charge carries its own
-- proof rather than pointing at a setting that may have moved since.
--
-- ## `credit_topup` is the grant, the attempt, and the bound — one row per attempt
--
-- `balance.ts` derives the credit balance from `sonny.metering_event` and keeps no ledger, on the
-- reasoning in its own header: the audit row *is* the charge, so a second writer of the same fact
-- cannot drift from it. **This table is not that second writer.** The *draw* stays derived from
-- metering, untouched. What is recorded here is a **grant** — money that moved at the payment
-- provider and the credits it bought — which is a fact no metering row could ever carry. PR #182's
-- cycle 3 said so in as many words when it withdrew the stronger version of the no-snapshot
-- finding: "a top-up is a payment-provider charge with its own amount and record, so what would be
-- missing at SONNY-215 is the justification for the trigger, not the charge." Hence
-- `runs_left_at_trigger` and `credits_remaining_at_trigger`: the justification, recorded beside the
-- charge, because the catalogue that priced it lives in an environment variable and is not
-- reconstructable from any row (SONNY-394).
--
-- **A row is written before the provider is called, not after**, and that ordering is what makes
-- `max_per_period` a bound rather than a hope. `attempt_no` plus the unique index below is the
-- whole mechanism: the insert computes `max(attempt_no) + 1` and refuses when the period already
-- holds the configured number, so two concurrent attempts computing the same number collide on the
-- index and exactly one of them proceeds. Under READ COMMITTED a plain `count(*) < n` check would
-- let both through. A row that stays `attempted` is a process that died between the claim and the
-- answer; it consumes its slot deliberately, so a charge path that crashes cannot loop.
--
-- **The bound counts attempts and not grants.** A declined card costs the user nothing and costs
-- the founders their standing with the provider, so three declines is a reason to stop trying
-- rather than a reason to keep going for free. The cost of that choice is stated rather than
-- hidden: a user who fixes their card after exhausting the bound gets no further automatic charge
-- until the next period, and meets the ordinary wall in the meantime.
--
-- **`account_id` is a scope and not a foreign key**, for the reason 0011, 0012, 0013 and 0018 each
-- give: an account's deletion is a state rather than a `DELETE`, and a cascade would remove the
-- record of money that moved, which is the last thing that should go.
--
-- ## `entitlement.billing_customer_id` — the one thing an off-session charge needs and this
-- gateway did not have
--
-- The account id travels to the provider at checkout as an *external* id, and 0018 records the
-- subscription id that comes back. Charging an existing customer off-session needs the provider's
-- **own** customer id, which every subscription delivery already carries and which nothing was
-- keeping. It sits beside `billing_provider` and `billing_subscription_id` for their reason: an id
-- is only unique within the provider that issued it.

CREATE TABLE sonny.auto_topup_consent (
  account_id   uuid        PRIMARY KEY,

  -- When this account said yes. NULL means it has said no, or has said yes and then no. An absent
  -- row means it has never been asked. All three are "not opted in" and the charge path reads them
  -- with one predicate.
  opted_in_at  timestamptz,

  -- When the setting last moved, in either direction. Kept when a user opts out so that "they
  -- turned it off on the 3rd" is answerable, which deleting the row would lose.
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE sonny.auto_topup_consent IS
  'Whether an account has asked for automatic top-ups (SONNY-215). Absent row or NULL opted_in_at '
  'means no; both are read by one predicate, so off-by-default is a property of the schema rather '
  'than of a value somebody sets. Deliberately not a column on sonny.entitlement, which the '
  'payment providers webhooks rewrite.';

CREATE TABLE sonny.credit_topup (
  topup_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid        NOT NULL,

  -- Which provider was asked, and its own id for the order once there is one. The order id is
  -- written as soon as the draft exists, before anything is charged, so an attempt whose answer is
  -- lost still names the object an operator has to look at.
  provider     text        NOT NULL,
  provider_order_id text,

  -- The period this top-up adds to. A top-up is spent against the period it was bought in and does
  -- not carry over -- see server/src/credit/balance.ts for why carrying over is a ledger and this
  -- design does not have one.
  period_start timestamptz NOT NULL,

  -- Which attempt of this period this is. 1-based, and the unique index below is what makes the
  -- per-period bound exact under concurrency rather than approximately right.
  attempt_no   int         NOT NULL,

  --   attempted      -- the slot was claimed and no answer was ever recorded. A crash, and it keeps
  --                     its slot on purpose so a failing charge path cannot loop.
  --   granted        -- the provider charged the customer. `credits` is what it bought.
  --   declined       -- the provider answered and did not charge: card declined, no payment method
  --                     on file, or an authentication challenge an off-session charge cannot answer.
  --   provider_error -- the provider could not be reached, timed out, or refused this gateway.
  --   unconfirmed    -- the charge was attempted and its answer could not be read. **Money may have
  --                     moved.** Nothing is granted for one of these, and resolving it is manual:
  --                     the order id names what to look at.
  outcome      text        NOT NULL,

  -- What this top-up bought. Zero for every outcome but `granted`, which the CHECK below enforces
  -- in both directions so a granted row cannot grant nothing and a failed one cannot grant credit.
  credits      double precision NOT NULL DEFAULT 0,

  -- The value `auto_topup_consent.opted_in_at` held when this charge was authorised. NOT NULL, so a
  -- charge with no consent behind it cannot be recorded at all -- which is the schema half of this
  -- ticket's one hard requirement.
  consented_at timestamptz NOT NULL,

  -- The justification for the trigger, recorded because the catalogue that priced it is an
  -- environment variable and is not reconstructable from any row (SONNY-394).
  runs_left_at_trigger         int              NOT NULL,
  credits_remaining_at_trigger double precision NOT NULL,

  attempted_at timestamptz NOT NULL DEFAULT now(),
  settled_at   timestamptz,

  CONSTRAINT credit_topup_outcome_known
    CHECK (outcome IN ('attempted', 'granted', 'declined', 'provider_error', 'unconfirmed')),
  -- Both directions. A granted row that granted nothing and a declined row that granted something
  -- are the two ways this table could lie about money.
  CONSTRAINT credit_topup_granted_is_exactly_the_credited
    CHECK ((outcome = 'granted') = (credits > 0)),
  CONSTRAINT credit_topup_credits_not_negative CHECK (credits >= 0),
  CONSTRAINT credit_topup_attempt_no_positive CHECK (attempt_no >= 1)
);

COMMENT ON TABLE sonny.credit_topup IS
  'One row per automatic top-up attempt (SONNY-215). Written before the provider is called, so '
  'attempt_no and its unique index bound how many charges a period can carry. consented_at is NOT '
  'NULL: a charge with no consent behind it cannot be recorded.';

-- The bound. Two concurrent attempts compute the same `attempt_no` and one of them loses here,
-- which is what a `count(*) < n` guard alone cannot do under READ COMMITTED.
CREATE UNIQUE INDEX credit_topup_attempt_idx
  ON sonny.credit_topup (account_id, period_start, attempt_no);

-- A provider order is charged once. The draft's id is recorded before the charge, so a replayed
-- settle cannot mint a second grant for one order.
CREATE UNIQUE INDEX credit_topup_provider_order_idx
  ON sonny.credit_topup (provider, provider_order_id)
  WHERE provider_order_id IS NOT NULL;

-- The operator question this table exists to answer: what did this account get charged for, most
-- recent first.
CREATE INDEX credit_topup_account_idx
  ON sonny.credit_topup (account_id, attempted_at DESC);

ALTER TABLE sonny.entitlement
  -- The provider's own id for this account's customer, as every subscription delivery carries it.
  -- An off-session charge is addressed to this and not to the external id checkout travels on.
  ADD COLUMN billing_customer_id text;

COMMENT ON COLUMN sonny.entitlement.billing_customer_id IS
  'The payment providers own customer id, read off subscription deliveries (SONNY-215). What an '
  'off-session top-up charge is addressed to; the external id checkout carries is not accepted '
  'there.';

-- @rollback

-- Both tables go and the entitlement rows stay. What is lost is every consent and every record of a
-- top-up that was charged -- which is why a rollback of this migration is a thing to think about
-- rather than a thing to do: the money moved at the provider either way, and the provider's own
-- orders are the surviving record of it. The safe direction for a rollback of a billing change is
-- the one that cannot charge anybody: with the consent table gone, the charge path finds no consent
-- and refuses every top-up, which is exactly the state this repository ships in.
DROP INDEX IF EXISTS sonny.credit_topup_account_idx;
DROP INDEX IF EXISTS sonny.credit_topup_provider_order_idx;
DROP INDEX IF EXISTS sonny.credit_topup_attempt_idx;
DROP TABLE IF EXISTS sonny.credit_topup;
DROP TABLE IF EXISTS sonny.auto_topup_consent;
ALTER TABLE sonny.entitlement
  DROP COLUMN IF EXISTS billing_customer_id;
