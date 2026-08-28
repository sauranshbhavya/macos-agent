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
-- host kills between reserve and settle leaks cap until something reclaims it. `expires_at` and
-- `sweep_expired_reservations()` are that reclamation.
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
  'settle does not leak cap forever: sonny.sweep_expired_reservations() reclaims expired holds.';

-- The sweep's only query: unsettled holds past their expiry. Partial, because a settled hold is
-- never read again and they are the overwhelming majority.
CREATE INDEX usage_reservation_expiry_idx
  ON sonny.usage_reservation (expires_at)
  WHERE NOT settled;

-- The support/operator query: what is this account holding right now.
CREATE INDEX usage_reservation_account_idx
  ON sonny.usage_reservation (account_id, period_start)
  WHERE NOT settled;

-- Reclaim every expired hold, and return how many HOLDS were reclaimed.
--
-- **The aggregation in `per_period` is the whole of this function's correctness, and it is here
-- because the obvious version loses money silently** (SONNY-125, PR #82 cycle 1, F2). `UPDATE …
-- FROM` is a join: when several source rows match one target row Postgres applies exactly one of
-- them and discards the rest. A version that subtracted straight from the expired reservations
-- therefore reclaimed a single hold per (account, period) while marking every one of them settled —
-- so the remainder became permanently unusable cap with no row left to reclaim it from. Reproduced
-- before it was fixed: three orphaned 300-unit holds against a 1000 cap left 600 lost for good, and
-- the function reported success. Summing per (account, period) first gives the one-source-row-per-
-- target-row shape the statement requires.
--
-- **The return value counts holds, not periods, and that is the second half of the same defect.**
-- The broken version counted `usage_period` rows and called them holds, so it answered 1 for that
-- three-hold case — a plausible number that agreed with the bug instead of exposing it.
CREATE FUNCTION sonny.sweep_expired_reservations(p_now timestamptz)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  reclaimed bigint;
BEGIN
  WITH dead AS (
    UPDATE sonny.usage_reservation
       SET settled = true
     WHERE NOT settled AND expires_at < p_now
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
  SELECT coalesce(sum(holds), 0) INTO reclaimed FROM released;
  RETURN reclaimed;
END;
$$;

COMMENT ON FUNCTION sonny.sweep_expired_reservations(timestamptz) IS
  'Reclaims expired reservations and returns the number of HOLDS reclaimed, not periods. The '
  'per-period aggregation is load-bearing: UPDATE ... FROM applies one source row per target row, '
  'so subtracting straight from the expired rows strands every hold but one. SONNY-125, PR #82 F2.';

-- @rollback
DROP FUNCTION IF EXISTS sonny.sweep_expired_reservations(timestamptz);
DROP INDEX IF EXISTS sonny.usage_reservation_account_idx;
DROP INDEX IF EXISTS sonny.usage_reservation_expiry_idx;
DROP TABLE IF EXISTS sonny.usage_reservation;
DROP TABLE IF EXISTS sonny.usage_period;
DROP TABLE IF EXISTS sonny.entitlement;
