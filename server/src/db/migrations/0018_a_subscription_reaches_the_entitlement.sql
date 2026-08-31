-- 0018 — what the payment provider says about a subscription, and where it lands (SONNY-211).
--
-- Spec §16.4 for the grace period, and this row's own rule: **the payment provider is the source of
-- truth for "is this user paid."** Nothing in this gateway decides that; what it does is record what
-- the provider said, when it said it, and derive the entitlement from that.
--
-- **This file holds no plan, no price and no tier, exactly as 0013 does not.** `plan` stays the
-- opaque key 0013 declared it; which provider plan key maps to which capability list is deployment
-- configuration (`BILLING_PLAN_CAPABILITIES`), and the numbers behind it are SONNY-212's. What is
-- added here is the *state* a subscription puts an account into, and the audit of the deliveries
-- that put it there.
--
-- ## The three columns on `entitlement`, and why grace is two of them
--
-- `grace_until` is the instant a payment failure's grace window closes. Spec §16.4 requires grace
-- handling; §16.4's own reason is that a user must never be cut off mid-task by a billing event, so
-- a failed payment does **not** take capabilities away at the moment it arrives. It sets a deadline,
-- and the capabilities go when that deadline passes.
--
-- `past_due_since` is when the failure was first seen. It is not derivable from `grace_until` once
-- the window length is configurable, and it is what an operator answering "since when?" reads. A
-- successful renewal clears both.
--
-- **Grace is evaluated at read time and never by a job**, which is `server/src/entitlement/store.ts`'s
-- `claimFactsFor`. A job that revokes on a timer is a job that has not run yet: the window would
-- close whenever the sweeper next fired rather than when it expired, and every reader — the signed
-- claim and the per-request capability check — would disagree with the row in front of them for as
-- long as that took. One derivation, two consumers, no drift.
--
-- ## Why the provider's own identifiers live on the entitlement row
--
-- `billing_subscription_id` is how a later delivery finds the account when the payload carries no
-- external customer id of its own. The first delivery for a subscription arrives with the account
-- named (checkout puts the account id on the customer as an external id); every later one can then
-- be resolved by subscription id alone. `billing_provider` sits beside it because an id is only
-- unique within the provider that issued it, and this repository deliberately does not assume there
-- will only ever be one provider — the seam is the whole point (founder decision, 2026-08-30: Polar
-- is final, and the seam stays because a merchant-of-record swap is a business decision that can
-- recur).
--
-- `billing_event_at` is the `occurred_at` of the delivery this row's state came from, and it is what
-- makes out-of-order deliveries safe. Webhooks are not ordered: a `cancelled` retried after an
-- `activated` that was sent later would otherwise revoke a live subscription. A delivery whose
-- `occurred_at` is not newer than this column is recorded and does not move the state.
--
-- ## `billing_event` is the replay bound and the audit at once
--
-- A signature-valid delivery replayed is still signature-valid, so the signature cannot be the only
-- thing standing between a replayed `activated` and a resurrected entitlement. The provider's own
-- event id is unique per delivery, so a primary key on it makes the second copy a no-op. It doubles
-- as the record of every delivery this gateway accepted or refused, which is the only place a
-- founder can answer "did the provider tell us, and what did we do with it" — the alternative is a
-- log line, and a log line is not queryable a month later.
--
-- **`account_id` is a scope and not a foreign key**, for the reason 0011, 0012 and 0013 each give:
-- an account's deletion is a state rather than a `DELETE`, and a cascade would remove the record of
-- what the provider said about an account exactly when someone needs it most. It is nullable here
-- besides, because a delivery that named no account this gateway knows is a delivery worth keeping.

ALTER TABLE sonny.entitlement
  -- When a payment failure's grace window closes. NULL means no failure is outstanding. Past this
  -- instant the entitlement mints a claim with no capabilities, exactly as a revoked one does.
  ADD COLUMN grace_until            timestamptz,
  -- When the outstanding payment failure was first seen. Cleared together with `grace_until`.
  ADD COLUMN past_due_since         timestamptz,
  -- Which provider's subscription this row's state came from, and its id there.
  ADD COLUMN billing_provider       text,
  ADD COLUMN billing_subscription_id text,
  -- The `occurred_at` of the delivery this state came from. Older deliveries do not move the state.
  ADD COLUMN billing_event_at       timestamptz,

  -- A grace window that has no failure behind it, or a failure with no window, is a half-written
  -- state rather than a meaning. Both or neither.
  ADD CONSTRAINT entitlement_grace_is_whole
    CHECK ((grace_until IS NULL) = (past_due_since IS NULL)),
  -- A subscription id without the provider that issued it names nothing.
  ADD CONSTRAINT entitlement_billing_identity_is_whole
    CHECK (billing_subscription_id IS NULL OR billing_provider IS NOT NULL);

COMMENT ON COLUMN sonny.entitlement.grace_until IS
  'When a payment failures grace window closes (spec 16.4). Evaluated at read time by '
  'claimFactsFor, never by a job: a job that revokes on a timer revokes when it next runs.';

-- How a later delivery finds the account it belongs to when its payload names no external customer.
-- Partial, because the overwhelming majority of entitlement rows carry no subscription at all.
CREATE UNIQUE INDEX entitlement_billing_subscription_idx
  ON sonny.entitlement (billing_provider, billing_subscription_id)
  WHERE billing_subscription_id IS NOT NULL;

CREATE TABLE sonny.billing_event (
  -- The provider that sent it, and its own id for this delivery. Together the replay bound: a
  -- second copy of one delivery conflicts here and changes nothing.
  provider      text        NOT NULL,
  event_id      text        NOT NULL,

  -- The provider's own type string, verbatim and unmapped -- `subscription.active`, and so on. Kept
  -- raw so a delivery this gateway did not understand can still be read back and understood later.
  event_type    text        NOT NULL,

  -- What this gateway did with it. Six values, and the five that are not `applied` all exist so a
  -- delivery that changed nothing is still queryable afterwards — the alternative is a log line,
  -- and nobody greps a month of logs to answer "why is this customer not paid".
  --   applied   — the entitlement moved.
  --   ignored   — a type this gateway does not act on (an order receipt, a benefit grant).
  --   stale     — an older delivery than the state it met. Webhooks are not ordered.
  --   unmatched — no account this gateway knows. A paying customer it cannot attribute.
  --   unmapped  — a product `BILLING_PLANS` does not name. Fail-closed: no capabilities granted.
  --   unreadable— the signature passed and the payload did not parse, or named a status this
  --               gateway has no mapping for. Either the provider changed a shape or something
  --               holding the endpoint secret is sending nonsense; both are worth seeing.
  outcome       text        NOT NULL,

  -- The account it reached, when it reached one. A scope, not a foreign key.
  account_id    uuid,

  -- The provider's own instant for the event, and ours for the delivery. Both, because a provider
  -- clock and a gateway clock disagree and the difference is the first thing anyone investigating a
  -- late webhook wants to see.
  occurred_at   timestamptz,
  received_at   timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (provider, event_id),

  CONSTRAINT billing_event_outcome_known
    CHECK (outcome IN ('applied', 'ignored', 'stale', 'unmatched', 'unmapped', 'unreadable'))
);

COMMENT ON TABLE sonny.billing_event IS
  'Every subscription webhook delivery this gateway accepted, by the providers own event id. The '
  'primary key is the replay bound: a valid signature is still valid on a replay, so the id is what '
  'makes the second copy a no-op. Also the only queryable record of what the provider said.';

-- The operator question this table exists to answer: what happened to this account's subscription,
-- most recent first.
CREATE INDEX billing_event_account_idx
  ON sonny.billing_event (account_id, received_at DESC)
  WHERE account_id IS NOT NULL;

-- @rollback

-- The state goes and the entitlement rows stay. What is lost is the grace window and the link to the
-- provider's subscription, which means an account inside grace reverts to full capabilities until the
-- next delivery -- the safe direction for a rollback of a billing change is not to strip a paying
-- user, and the provider is the source of truth either way: the next event restores the state.
DROP INDEX IF EXISTS sonny.billing_event_account_idx;
DROP TABLE IF EXISTS sonny.billing_event;
DROP INDEX IF EXISTS sonny.entitlement_billing_subscription_idx;
ALTER TABLE sonny.entitlement
  DROP CONSTRAINT IF EXISTS entitlement_billing_identity_is_whole,
  DROP CONSTRAINT IF EXISTS entitlement_grace_is_whole,
  DROP COLUMN IF EXISTS billing_event_at,
  DROP COLUMN IF EXISTS billing_subscription_id,
  DROP COLUMN IF EXISTS billing_provider,
  DROP COLUMN IF EXISTS past_due_since,
  DROP COLUMN IF EXISTS grace_until;
