-- 0014 — every provider-side user an identity has ever named is remembered, and a superseded one is
-- owed a revocation from the moment it is superseded (SONNY-196, SONNY-230).
--
-- **The two tickets are one defect seen from two sides, which is why this is one migration.**
--
-- SONNY-230: `resolve()`'s rule 1 refreshes an existing identity with
-- `supabase_user_id = COALESCE($5, supabase_user_id)`. That OVERWRITES. Reproduced by PR #87's
-- reviewer: resolve twice for one subject with two different provider-side user ids, close the
-- account, drain — only the newer id is revoked, and the older one appears in no owed query,
-- because the column that named it is gone. The superseded provider-side user may still hold live
-- sessions at Supabase; they were unrevocable through any path this gateway has, and unrecorded, so
-- `npm run revocations` was correct to report nothing and still wrong about the world.
--
-- SONNY-196: `sonny.identity` never reconciled against Supabase removing an identity we hold a row
-- for. **The reconciliation is the supersession**, and that is the insight this migration is built
-- on. When Supabase prunes an unconfirmed identity, the next sign-in for that same
-- `(provider, subject)` presents a DIFFERENT `supabase_user_id` — which is Supabase telling us, in
-- the one exchange we already make, that the id we held no longer serves that subject. No round
-- trip, no service-role key, no call in front of a user waiting to sign in. What was missing was
-- not a question to ask the provider; it was somewhere to write the answer down.
--
-- **Why a trigger rather than two statements in `resolve()`.** A supersession recorded only when one
-- function remembers to record it goes unrecorded the first time anything else writes that column —
-- a backfill, a support script, a future link path. The column change is the event; the trigger
-- makes observing it structural, the way 0004 made `account_closed` follow the account rather than
-- trusting every closer to set it.
--
-- **What it catches is any statement that NAMES the column, which is not the same as any writer**
-- (PR #164 review, F5, correcting the wider claim this paragraph used to make). `AFTER … UPDATE OF
-- supabase_user_id` keys on the SET list of the original statement rather than on what the row ends
-- up holding. The reviewer measured six write shapes: a bulk `UPDATE` over many rows, an
-- `UPDATE … FROM`, an `INSERT … ON CONFLICT … DO UPDATE`, and a write of the same value all fire;
-- **a `BEFORE` trigger rewriting `NEW.supabase_user_id` on an UPDATE that does not name the column
-- does not, and neither does anything under `SET session_replication_role = replica`.** Both leave
-- exactly SONNY-230's state behind. Neither is reachable from application code — no `BEFORE` trigger
-- on this table writes that column (`derive_identity_closed` writes `NEW.account_closed` only) and
-- nothing in `server/` sets `session_replication_role` — but `replica` is what a logical-replication
-- apply worker and `pg_restore --disable-triggers` set, so it is an operational concern for the
-- first real remote deploy rather than a hypothetical one. `ALTER TABLE … ENABLE ALWAYS TRIGGER`
-- would close that half and is deliberately not done here: it would also make the trigger fire on
-- replicated changes at a subscriber, which is a replication-topology decision this migration has
-- no standing to take. The other half is inherent to `UPDATE OF` and only needs saying.
--
-- **Revocation bookkeeping moves off `sonny.identity` and onto this table, wholly.** It has to: the
-- thing a revocation is owed *for* is a provider-side user, not an identity — which the drain
-- already conceded by stamping "every identity naming this provider-side user" rather than the row
-- it claimed. Keeping the old columns beside the new ones would leave two answers to "is this
-- revoked?", and this repository's changelog is largely a record of what two sources of truth cost.

CREATE TABLE sonny.identity_provider_user (
  -- A surrogate key so the drain can claim a row by `WHERE id = (SELECT id … FOR UPDATE SKIP
  -- LOCKED)`, which is the shape `drainOwedRevocations` already uses and whose atomicity PR #87's
  -- fifth round established. `(identity_id, supabase_user_id)` is the real key and is unique below.
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  identity_id                 uuid NOT NULL REFERENCES sonny.identity(id) ON DELETE CASCADE,

  -- One of the `auth.users` rows this identity has named. NOT NULL: a row exists here because an id
  -- was observed, and "no provider-side user" is the absence of a row rather than a NULL in one.
  supabase_user_id            uuid NOT NULL,

  first_seen_at               timestamptz NOT NULL DEFAULT now(),
  last_seen_at                timestamptz NOT NULL DEFAULT now(),

  -- NULL while this is the identity's current provider-side user. Set the moment the identity's
  -- `supabase_user_id` moves to a different value — which is the only evidence this gateway ever
  -- gets that the provider re-keyed this subject.
  superseded_at               timestamptz,

  -- Moved here from `sonny.identity` (0006, 0008), and **its meaning is narrower than the column
  -- name suggests** (PR #164 review, F1). It does NOT mean "this id has been revoked at least
  -- once". It means **"the revocation owed for this id's CURRENT EPISODE has been performed"** — an
  -- episode beginning when the identity observes the id and ending when a provider call returns.
  -- Written only after that call returns, never optimistically; **cleared by the trigger below the
  -- moment the identity observes the id again**, because that starts a new episode and any sessions
  -- minted in it are owed a fresh revocation.
  --
  -- The two readings are one letter apart in English and opposite in effect. `OWED_PREDICATE`
  -- (`server/src/auth/revocation.ts`) reads this column as "has no outstanding revocation", so under
  -- the log reading a single stamp would make an id permanently un-owed — through a come-back, a
  -- reopen, and every close afterwards. That is the defect F1 reproduced end to end.
  provider_session_revoked_at timestamptz,
  revocation_claimed_at       timestamptz,

  UNIQUE (identity_id, supabase_user_id)
);

COMMENT ON TABLE sonny.identity_provider_user IS
  'Every provider-side (Supabase) user id an identity has ever named, and the revocation state of '
  'each. The identity''s own supabase_user_id is the CURRENT one and is what attribution reads; '
  'this table is the history, and a row with superseded_at set is owed a revocation whether or not '
  'the account is closed. provider_session_revoked_at means "the revocation owed for this id''s '
  'CURRENT episode has been performed", not "this id has been revoked at least once" — observing '
  'the id again starts a new episode and clears it. Maintained by the '
  'identity_records_its_provider_side_user trigger — never written by application code '
  '(SONNY-196, SONNY-230, PR #164 review F1).';

COMMENT ON COLUMN sonny.identity_provider_user.superseded_at IS
  'When the identity stopped naming this provider-side user. This is the whole of SONNY-196''s '
  'reconciliation: a new id for the same (provider, subject) is the provider reporting that the old '
  'one no longer serves that subject, which is exactly what its unconfirmed-identity pruning '
  'produces. NULL means current.';

-- The drain's working set. Partial on the only column of the predicate that lives on this table;
-- `account_closed` and the account id are the parent's and are reached by the join.
CREATE INDEX identity_provider_user_owed
  ON sonny.identity_provider_user (identity_id)
  WHERE provider_session_revoked_at IS NULL;

-- One `signOutAllForUser` revokes every session of one provider-side user, so the drain stamps
-- every row naming it. That fan-out is keyed here.
CREATE INDEX identity_provider_user_supabase_user_idx
  ON sonny.identity_provider_user (supabase_user_id);

-- Backfill. `linked_at` is the only timestamp the existing rows carry, and it is when we wrote the
-- identity rather than when the provider minted the user — close enough to be useful and not
-- pretended to be more: nothing reads these two columns for correctness, only for a support answer.
--
-- **`WHERE supabase_user_id IS NOT NULL` drops one representable state and it is unreachable**
-- (PR #164 review, F8, and it is the only difference the reviewer's full apply-then-rollback data
-- comparison found across seven seeded states). An identity with a NULL id that nonetheless carries
-- a revocation stamp has nowhere to go here, and the `DROP COLUMN`s below then destroy the stamp.
-- Pre-0014 the drain only ever stamped a row whose `supabase_user_id` was non-NULL, and
-- `resolve()`'s `COALESCE` cannot clear one, so no such row can exist. Written down rather than
-- guarded, because a guard against an unreachable state reads as evidence that it is reachable.
INSERT INTO sonny.identity_provider_user
  (identity_id, supabase_user_id, first_seen_at, last_seen_at,
   provider_session_revoked_at, revocation_claimed_at)
SELECT id, supabase_user_id, linked_at, linked_at,
       provider_session_revoked_at, revocation_claimed_at
  FROM sonny.identity
 WHERE supabase_user_id IS NOT NULL;

-- The trigger. Fires on INSERT, and on any UPDATE whose SET list names `supabase_user_id` — which
-- rule 1's refresh always does, so a sign-in that does not change the id still bumps `last_seen_at`
-- and one that does change it supersedes the old id in the same statement.
--
-- **`IS DISTINCT FROM`, not `<>`, and the case it buys is NEW being NULL rather than OLD.** The
-- `OLD.supabase_user_id IS NOT NULL` line above already settles the old side, so the two spellings
-- agree on every update that sets a real id — which is every update `resolve()` makes, since its
-- `COALESCE` cannot write a NULL. They differ on a writer that *clears* the column: `'x' <> NULL` is
-- NULL rather than true, so `<>` would leave the cleared id sitting there un-superseded, still
-- current in the history, still attributing nothing and owed nothing. `IS DISTINCT FROM` supersedes
-- it, which is the same answer as for any other id the identity stopped naming.
--
-- **This comment claimed the opposite and was caught by a mutant.** It said `<>` would skip "the
-- first id an identity acquires after having been created without one" — a case that goes through
-- the INSERT branch below and never reaches this line at all. A battery replacing `IS DISTINCT
-- FROM` with `<>` SURVIVED against the test written from that reading, which is what a wrong
-- explanation of a correct line costs: the test it produces guards nothing.
--
-- **An id observed again begins a new episode, and the `ON CONFLICT` arm is what says so.** If the
-- provider hands the same user id back for this subject, that id is once more what the subject
-- signs in as: it is no longer superseded, and — the half that took a review round to get right —
-- **any revocation recorded against it is spent**, because the sessions it revoked are not the
-- sessions the subject is minting now.
--
-- **This arm cleared `superseded_at` alone and left the revocation stamp, and the comment defending
-- that was wrong** (PR #164 review, F1). It argued "a revocation that happened is a fact about the
-- past and is not unwound by the id returning". The premise is true and the conclusion does not
-- follow, because this column is not a log of a past event — `OWED_PREDICATE` reads it three lines
-- of TypeScript away as "does this id still owe one". So from the first successful revocation the
-- id was **permanently** not-owed, and a later close revoked nothing. Reproduced end to end through
-- the real `resolve()` and `drainOwedRevocations()`, ending in an account that hard-deleted cleanly
-- with live sessions never revoked.
--
-- **Clearing here closes a second route that predates this branch** (SONNY-358, authorised by the
-- founder to be fixed here rather than split): close → drain → an operator reopens the account
-- (`UPDATE sonny.account SET deleted_at = NULL`, which 0005's `mark_identities_closed` un-flags the
-- identities for) → the user signs in again as the same id → they close again → nothing is owed.
-- That route needs no supersession at all, and the reviewer measured it against `main` at `def8c3a`
-- (`owed = 1` after the first close, `owed = 0` after the reopen and the second). It is the same
-- root cause reached without this table, and it is closed here because rule 1's refresh names
-- `supabase_user_id` on **every** sign-in, so the reopened user's next sign-in lands in this arm.
--
-- **`revocation_claimed_at` is cleared with it**, which also settles the review's F8 note that a
-- stale lease survived a come-back: a row superseded → claimed by a drain that then died →
-- un-superseded → superseded again was invisible to the claim query for up to
-- `sonny.revocation_lease_seconds()`. A lease belongs to an episode too.
--
-- **Why clearing rather than a timestamp comparison, and the reason is stronger than a tie**
-- (PR #164 cycle 2, C-F4, which replaced the argument this comment used to make). The other shape
-- on offer was `provider_session_revoked_at IS NULL OR provider_session_revoked_at < last_seen_at`.
-- It closes the same two routes and it cannot be trusted, for two measured reasons rather than a
-- hypothetical tie-break:
--
-- 1. **The two clocks are not merely different resolutions, they carry a systematic offset.**
--    `last_seen_at` is SQL `now()`; `provider_session_revoked_at` is bound from a JavaScript
--    `Date`. Measured against a local container, twelve samples of `now() - jsDate`: **103, 99, 99,
--    103, 99, 99, 99, 99, 99, 99, 98, 98 ms** — about 100 ms before any cross-host skew, and in the
--    direction that makes a stamp look older than it is. A `<` / `<=` choice does not address a
--    hundred-millisecond bias; it only decides an exact equality that would essentially never
--    arrive.
-- 2. **The stamp is not the time the provider call returned — it is the time the drain STARTED.**
--    `drainOwedRevocations` captures `const now = options.now ?? new Date()` **once**, before a loop
--    that runs up to 100 provider calls. So the value written can be minutes behind the write, and a
--    comparison against a `last_seen_at` that SQL wrote *during* that loop would read a
--    genuinely-completed revocation as still owed. That is a property of this code rather than of
--    anyone's clock, and it kills the comparison on its own.
--
-- Clearing needs no comparison and no clock at all: whichever of the two writes commits last is
-- right on its own terms. A drain stamping after a sign-in really did revoke that sign-in's
-- sessions; a sign-in clearing after a drain really does owe a new one. **And the interleaving was
-- traced rather than assumed** — a sign-in landing *inside* `signOutAllForUser` leaves the row
-- **un-stamped** rather than wrongly stamped, because the mark-done re-checks `OWED_PREDICATE` per
-- row, so the conservative direction is the one that happens and a later close owes the id afresh.
CREATE OR REPLACE FUNCTION sonny.record_provider_side_user() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.supabase_user_id IS NOT NULL
     AND OLD.supabase_user_id IS DISTINCT FROM NEW.supabase_user_id THEN
    UPDATE sonny.identity_provider_user
       SET superseded_at = now()
     WHERE identity_id = OLD.id
       AND supabase_user_id = OLD.supabase_user_id
       AND superseded_at IS NULL;
  END IF;

  IF NEW.supabase_user_id IS NOT NULL THEN
    INSERT INTO sonny.identity_provider_user (identity_id, supabase_user_id)
         VALUES (NEW.id, NEW.supabase_user_id)
    ON CONFLICT (identity_id, supabase_user_id) DO UPDATE
       SET last_seen_at = now(),
           superseded_at = NULL,
           provider_session_revoked_at = NULL,
           revocation_claimed_at = NULL;
  END IF;

  RETURN NULL;
END $$;

CREATE TRIGGER identity_records_its_provider_side_user
  AFTER INSERT OR UPDATE OF supabase_user_id ON sonny.identity
  FOR EACH ROW EXECUTE FUNCTION sonny.record_provider_side_user();

-- The delete guard counts what the drain counts — 0009's rule, applied to the set the drain now
-- reads. It gains one member: an account that was never closed but carries a superseded id owes a
-- revocation, and hard-deleting it would destroy the only record that it does.
CREATE OR REPLACE FUNCTION sonny.refuse_delete_while_revocation_owed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE owed integer;
BEGIN
  SELECT count(*) INTO owed
    FROM sonny.identity_provider_user pu
    JOIN sonny.identity i ON i.id = pu.identity_id
   WHERE i.account_id = OLD.id
     AND pu.provider_session_revoked_at IS NULL
     AND (i.account_closed OR pu.superseded_at IS NOT NULL);
  IF owed > 0 THEN
    RAISE EXCEPTION
      'account % still owes % provider-side revocation(s); deleting it would destroy the only '
      'record that they are owed. Drain them first (npm run revocations reports what is '
      'outstanding), then delete.', OLD.id, owed
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN OLD;
END $$;

-- The old columns go, so there is exactly one answer to "is this provider-side user revoked?".
DROP INDEX IF EXISTS sonny.identity_revocation_owed;
ALTER TABLE sonny.identity DROP COLUMN provider_session_revoked_at;
ALTER TABLE sonny.identity DROP COLUMN revocation_claimed_at;

-- @rollback

DROP TRIGGER IF EXISTS identity_records_its_provider_side_user ON sonny.identity;
DROP FUNCTION IF EXISTS sonny.record_provider_side_user();

ALTER TABLE sonny.identity ADD COLUMN provider_session_revoked_at timestamptz;
ALTER TABLE sonny.identity ADD COLUMN revocation_claimed_at timestamptz;

-- Restore what 0006 and 0008 held: the state of the identity's CURRENT provider-side user. A
-- superseded one has no column to go back into — that is the defect this migration exists for, and
-- the rollback loses it rather than pretending otherwise. Rolling forward again re-derives nothing:
-- the history is gone with the table.
UPDATE sonny.identity i
   SET provider_session_revoked_at = pu.provider_session_revoked_at,
       revocation_claimed_at = pu.revocation_claimed_at
  FROM sonny.identity_provider_user pu
 WHERE pu.identity_id = i.id
   AND pu.supabase_user_id = i.supabase_user_id
   AND pu.superseded_at IS NULL;

CREATE INDEX identity_revocation_owed
  ON sonny.identity (account_id)
  WHERE account_closed AND provider_session_revoked_at IS NULL;

CREATE OR REPLACE FUNCTION sonny.refuse_delete_while_revocation_owed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE owed integer;
BEGIN
  SELECT count(*) INTO owed FROM sonny.identity
   WHERE account_id = OLD.id
     AND account_closed
     AND provider_session_revoked_at IS NULL
     AND supabase_user_id IS NOT NULL;
  IF owed > 0 THEN
    RAISE EXCEPTION
      'account % still owes % provider-side revocation(s); deleting it would destroy the only '
      'record that they are owed. Drain them first (npm run revocations reports what is '
      'outstanding), then delete.', OLD.id, owed
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN OLD;
END $$;

DROP TABLE IF EXISTS sonny.identity_provider_user;
