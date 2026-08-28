-- 0013 — what an account is allowed to do, and what it has spent doing it (SONNY-135).
-- Contract §5.3 for the claim, §7.2 cases 2/2a/3/3a for the refusals, and
-- `docs/sonny-row-12-host-decision.md` §9 for the cap mechanism, which this file implements and
-- does not re-derive.
--
-- **This file holds no plan, no price, no tier and no allowance, and the distinction it turns on is
-- column-versus-value.** SONNY-212 sets the numbers; row 18 (SONNY-23) decides which capability
-- keys are gated. What is here is the shape those answers land in: `plan` is an opaque key,
-- `capabilities` is an opaque list of strings, and `cap_units` is a number with **no default in
-- this repository at all** — an account with no explicit cap falls back to the deployment's
-- `SPEND_CAP_UNITS`, which `config.ts` refuses to invent and startup refuses to run without.
-- Nothing in `server/src/entitlement/` can answer "what does this cost in money".
--
-- **`account_id` is a scope and not a foreign key**, for 0011's and 0012's reason: deletion of an
-- account is a *state* (`deleted_at`, 0002) rather than a `DELETE`, and a cascade would remove the
-- record of what an account was allowed and what it spent, which is the last thing that should go.
--
-- ## The three tables, and why the cap needs all three
--
-- `entitlement` is what the account is allowed — the row a signed claim is minted from. One row per
-- account, absent until something provisions it, and its absence is a real answer: no plan, no
-- capabilities, the deployment's cap.
--
-- `usage_period` is the counter the cap is enforced against — one row per account per period,
-- carrying the cap it was opened with, what has been settled (`spent`) and what is held
-- (`reserved`). §9.1: "not in function memory and not in a cache", because two gateway processes
-- behind one address have no consistency story anywhere else.
--
-- `usage_reservation` is one row per hold, and it exists for the residual §9.5 names: a request the
-- host kills between reserve and settle leaks cap until something reclaims it. `expires_at` and the
-- sweep in `server/src/entitlement/store.ts` are that reclamation.
--
-- **The sweep is application SQL and not a function in this file, and that is a deliberate move
-- rather than the obvious placement.** It began here as a `plpgsql` function and a mutation battery
-- showed what that costs: a migration is applied once and recorded in a ledger, so a database that
-- already holds 0013 never re-reads this file — a mutant that broke the sweep's aggregation was
-- therefore never executed, and the battery reported it killed on the strength of an unrelated
-- timeout. A function nothing can test is a function nothing is holding. It also makes fixing the
-- sweep a schema migration rather than a deploy, which is the wrong shape for a bug fix in a query.
--
-- ## The CHECK is a backstop and deliberately not the interface
--
-- §9.4 measured both: with the constraint and a naive read-then-write, an over-spend becomes
-- `ERROR: new row for relation … violates check constraint`, which is a 500 rather than the 429 the
-- contract wants. The single-statement reserve in `entitlement/store.ts` is what produces a clean
-- refusal; this constraint is what makes an over-spend structurally impossible even if that
-- statement is later rewritten badly. Keep both, and never let the constraint be the interface.

CREATE TABLE sonny.entitlement (
  account_id    uuid        PRIMARY KEY,

  -- An opaque plan key, provisioned from outside this repository. **Not a tier name chosen here.**
  -- `'none'` is what an account with no plan carries, and it is the absence of a plan rather than a
  -- plan called none; SONNY-212 owns the real keys.
  plan          text        NOT NULL DEFAULT 'none',

  -- §5.3: "a list of opaque capability keys. Which capabilities are gated is row 18's". Empty is
  -- the honest default and the fail-closed one: a gated capability is refused for an account whose
  -- list does not name it, and an unprovisioned account names nothing.
  capabilities  text[]      NOT NULL DEFAULT '{}',

  -- This account's own cap for a period, or NULL to take the deployment's `SPEND_CAP_UNITS`.
  -- **No default here on purpose**: a number in this column would be an allowance, and allowances
  -- are SONNY-212's.
  cap_units     bigint,

  -- Set when a subscription is cancelled or a plan is withdrawn. A revoked entitlement still mints
  -- a claim — with no capabilities — because a client that gets a fresh, signed, empty claim stops
  -- allowing gated features at its next refresh, while a client that gets an error keeps the claim
  -- it already has until that one expires.
  revoked_at    timestamptz,

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT entitlement_cap_units_not_negative CHECK (cap_units IS NULL OR cap_units >= 0)
);

COMMENT ON TABLE sonny.entitlement IS
  'What an account is allowed. Contract section 5.3. Holds an opaque plan key and an opaque '
  'capability list, provisioned from outside this repository - no tier, no price, no allowance. '
  'Read by GET /v1/account/entitlements, which signs a claim from it.';

CREATE TABLE sonny.usage_period (
  account_id    uuid        NOT NULL,
  -- The period this row counts, as an instant rather than a label. `entitlement/period.ts` computes
  -- it (a UTC calendar month today) so the boundary is testable against an injected clock rather
  -- than against `now()` inside a statement nobody can move.
  period_start  timestamptz NOT NULL,
  -- The cap this period was opened with, copied from the entitlement at that moment. **Copied
  -- rather than joined**: a cap that changed mid-period would otherwise retroactively re-decide
  -- every refusal already issued, and a user who was told they were out would silently not have
  -- been.
  cap_units     bigint      NOT NULL,
  spent         bigint      NOT NULL DEFAULT 0,
  reserved      bigint      NOT NULL DEFAULT 0,

  PRIMARY KEY (account_id, period_start),
  CONSTRAINT usage_period_never_over_cap CHECK (spent + reserved <= cap_units),
  CONSTRAINT usage_period_never_negative CHECK (spent >= 0 AND reserved >= 0)
);

COMMENT ON TABLE sonny.usage_period IS
  'The per-account, per-period spend counter the cap is enforced against. Contract section 7.2 case '
  '3a; mechanism in docs/sonny-row-12-host-decision.md section 9. One statement reserves, one '
  'settles. The CHECK is a backstop, never the interface.';

CREATE TABLE sonny.usage_reservation (
  reservation_id uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     uuid        NOT NULL,
  period_start   timestamptz NOT NULL,
  amount         bigint      NOT NULL,
  settled        boolean     NOT NULL DEFAULT false,
  -- When an unsettled hold becomes reclaimable. §9.5's first residual: a request killed between
  -- reserve and settle leaks cap until swept, and the window is derived from the gateway's own
  -- longest request deadline rather than from a platform's cliff (the 150 s Supabase Edge limit
  -- that motivated the original number stopped binding with the 2026-08-21 move to a VM).
  expires_at     timestamptz NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT usage_reservation_amount_positive CHECK (amount > 0)
);

COMMENT ON TABLE sonny.usage_reservation IS
  'One row per hold taken before a provider call. Exists so a request killed between reserve and '
  'settle does not leak cap forever: the sweep in server/src/entitlement/store.ts reclaims '
  'expired holds.';

-- The sweep's only query: unsettled holds past their expiry. Partial, because a settled hold is
-- never read again and they are the overwhelming majority.
CREATE INDEX usage_reservation_expiry_idx
  ON sonny.usage_reservation (expires_at)
  WHERE NOT settled;

-- The support/operator query: what is this account holding right now.
CREATE INDEX usage_reservation_account_idx
  ON sonny.usage_reservation (account_id, period_start)
  WHERE NOT settled;

-- @rollback
DROP INDEX IF EXISTS sonny.usage_reservation_account_idx;
DROP INDEX IF EXISTS sonny.usage_reservation_expiry_idx;
DROP TABLE IF EXISTS sonny.usage_reservation;
DROP TABLE IF EXISTS sonny.usage_period;
DROP TABLE IF EXISTS sonny.entitlement;
