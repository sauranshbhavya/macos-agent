-- 0016 — the discharge of a revocation obligation carries the identity of the obligation it
-- discharges, so a drain can only stamp what it actually claimed (SONNY-365).
--
-- **The decision, stated before the SQL, because the SQL is a column and three increments and the
-- decision is the whole ticket.**
--
-- 0015 made the OBLIGATION correct: the two events that create one — the account closing and the id
-- being superseded — each clear `provider_session_revoked_at`, so a fresh obligation always starts
-- unstamped. Its header says so and then says what it does not cover, which is this file:
--
--   `drainOwedRevocations`' mark-done re-checks whether a row is owed *now*. It never checks whether
--   the provider call it just made covers the obligation that exists *now*.
--
-- Those are different questions whenever an obligation is created between a drain's provider call
-- and its mark-done. The drain calls `signOutAllForUser`, and while that call is in flight the
-- account is reopened, the user refreshes, the account is closed again. A fresh obligation now
-- exists and 0015 correctly cleared the stamp for it. The drain returns and stamps the row anyway —
-- because from the row's point of view it is owed and unstamped, which is exactly what mark-done
-- looks for. The obligation created after the provider call is discharged by a call that predates
-- it, and the sessions minted during the reopen are never revoked on an account owed nothing.
--
-- PR #167's reviewer reproduced that against a real database in three configurations and confirmed
-- it is **not a regression**: 0014 behaves identically, and 0015 strictly narrows the window.
--
-- **What the mechanism was missing is an episode identity, and it could not be borrowed from a
-- column that was already there.** Three candidates were considered and two do not work:
--
--   * **`revocation_claimed_at` as the token.** Both obligation-creating triggers already NULL it,
--     so for the CLAIMED row a surviving claim really is proof that no new obligation arrived. It
--     fails on the fan-out. Mark-done deliberately stamps **every** row naming the provider-side
--     user, because one `signOutAllForUser` ends every session of that user and stamping one row
--     would leave the others owed for ever — and those sibling rows were never claimed, so their
--     `revocation_claimed_at` is NULL both before and after a fresh obligation arrives. The claim
--     is per-row and the discharge is per-user, and that asymmetry is where the identity is lost.
--   * **Claiming the whole fan-out set, so the claim and the discharge share a unit.** Structurally
--     the nicest answer and it is rejected for a concrete reason: the claim's inner `SELECT … FOR
--     UPDATE SKIP LOCKED` takes one row, and an outer `UPDATE` fanning out to the siblings would
--     wait on rows another drain holds. Two drains that pick two different rows of one user
--     deadlock — A holds row1 and waits for row2, B holds row2 and waits for row1 — and Postgres
--     resolves that by aborting one of them with a 40P01. Trading a silent wrong stamp for a hard
--     error under concurrency is not a trade this file is willing to make.
--   * **A monotonic counter per row.** What is shipped.
--
-- `revocation_episode` counts the obligations this row has had. It is incremented by every event
-- that creates a fresh one, and it is never decremented and never reset. The drain reads it for
-- every row it is about to discharge, at the instant it claims — one statement, one snapshot, so
-- there is no window between choosing the set and recording its episodes — and mark-done stamps a
-- row only if that row is still in the episode the drain saw. A mismatch means an obligation
-- arrived that this provider call cannot have covered, and the obligation stands.
--
-- **A counter rather than a timestamp, deliberately.** A timestamp comparison here would be between
-- a value the trigger writes from the database's clock and a value the drain captured from Node's,
-- and two obligations inside one clock tick would be indistinguishable — which is the same defect
-- one table over, and is SONNY-353. A counter is monotonic by construction and needs no clock.
--
-- **What this costs.** One `bigint` per row, and every close now writes its identity's current rows
-- rather than only the ones carrying a stamp or a claim — see the guard note below. A drain whose
-- stamp is refused reports the call in `RevocationOutcome.stale` and the row stays owed, so the
-- next pass through the loop claims it again and calls the provider again. That second call is the
-- point: the new obligation gets its own revocation instead of inheriting a discharge from an older
-- one. It is bounded by the drain's `limit`.
--
-- **What this does NOT do**, so nobody reads it as more than it is. It does not make the stamp mean
-- the sessions are gone — `ProviderRejected` is still recorded as done and any 4xx but 429 is
-- `ProviderRejected`, so the record can still be wrong about the provider having complied, exactly
-- as 0015's column comment says. Narrowing that is SONNY-313's and is unchosen by decision of
-- 2026-08-29. What this fixes is narrower and is a different claim: that a discharge belongs to the
-- obligation it was performed for.

ALTER TABLE sonny.identity_provider_user
  ADD COLUMN revocation_episode bigint NOT NULL DEFAULT 1;

COMMENT ON COLUMN sonny.identity_provider_user.revocation_episode IS
  'Which obligation to revoke this row is currently carrying — a counter, incremented by every '
  'event that creates a fresh obligation (the account closing, the id being superseded, the '
  'identity observing the id again) and never decremented or reset. It is the episode identity '
  'provider_session_revoked_at''s meaning has always referred to and nothing recorded: a drain '
  'reads it when it claims and stamps only rows still carrying that value, so a provider call '
  'cannot discharge an obligation created after it was made (SONNY-365). Maintained by the '
  'identity_records_its_provider_side_user and identity_close_owes_a_revocation triggers — never '
  'written by application code.';

-- **The close trigger bumps the episode, and its third `AND` is gone.** 0015's guard —
-- `AND (provider_session_revoked_at IS NOT NULL OR revocation_claimed_at IS NOT NULL)` — existed
-- only to keep an ordinary first close from writing rows it did not change, and 0015's own header
-- says the trigger is correct without it. It is not merely unnecessary now; it is **wrong**, and in
-- the direction this migration exists to close.
--
-- A row that is owed but carries neither a stamp nor a claim is exactly the sibling case above: a
-- drain claimed some *other* row naming the same provider-side user and snapshotted this one as
-- part of its fan-out. Under the guard, this row's identity could be reopened, its user could
-- refresh and mint sessions, and it could be closed again — all without the trigger firing, because
-- there was no stamp and no claim to clear. The episode would not move, and the drain's mark-done
-- would discharge that fresh obligation. Removing the guard costs one write per current row per
-- close and closes the case.
CREATE OR REPLACE FUNCTION sonny.close_owes_its_own_revocation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sonny.identity_provider_user
     SET provider_session_revoked_at = NULL,
         revocation_claimed_at = NULL,
         revocation_episode = revocation_episode + 1
   WHERE identity_id = NEW.id
     AND superseded_at IS NULL;
  RETURN NULL;
END $$;

-- The other two events that start an episode, in 0014's trigger as 0015 left it. Both already NULL
-- the stamp; both now move the counter with it, because a cleared stamp and an unchanged episode
-- are the two halves of one fact and a reader of either alone gets the wrong answer.
--
-- **The observation arm bumps unconditionally, including when nothing else about the row changes.**
-- 0014's reading is that observing an id starts a new episode — that is what its clear of the stamp
-- means — so a drain in flight when the id is observed must not stamp on the way out. Most
-- observations land on rows that are not owed at all, where the bump is inert: mark-done's
-- `OWED_PREDICATE` excludes them either way.
--
-- Everything else in this function is 0015's, byte for byte, restated because `CREATE OR REPLACE
-- FUNCTION` has no partial form. The `AS pu` alias is new and is not cosmetic: the `DO UPDATE SET`
-- has to read the existing row's own counter, and an unqualified `revocation_episode` on the right
-- of that assignment is ambiguous.
CREATE OR REPLACE FUNCTION sonny.record_provider_side_user() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.supabase_user_id IS NOT NULL
     AND OLD.supabase_user_id IS DISTINCT FROM NEW.supabase_user_id THEN
    UPDATE sonny.identity_provider_user
       SET superseded_at = now(),
           provider_session_revoked_at = NULL,
           revocation_claimed_at = NULL,
           revocation_episode = revocation_episode + 1
     WHERE identity_id = OLD.id
       AND supabase_user_id = OLD.supabase_user_id
       AND superseded_at IS NULL;
  END IF;

  IF NEW.supabase_user_id IS NOT NULL THEN
    INSERT INTO sonny.identity_provider_user AS pu (identity_id, supabase_user_id)
         VALUES (NEW.id, NEW.supabase_user_id)
    ON CONFLICT (identity_id, supabase_user_id) DO UPDATE
       SET last_seen_at = now(),
           superseded_at = NULL,
           provider_session_revoked_at = NULL,
           revocation_claimed_at = NULL,
           revocation_episode = pu.revocation_episode + 1;
  END IF;

  RETURN NULL;
END $$;

-- 0015's sentence about this column is unchanged and is restated only because the paragraph it sits
-- in gains one clause: the stamp is now read together with `revocation_episode`, which says WHICH
-- obligation the stamp discharged.
COMMENT ON COLUMN sonny.identity_provider_user.provider_session_revoked_at IS
  'Whether a revocation is outstanding for this provider-side user id — NULL means one is owed as '
  'soon as an owed condition holds. It records only that the provider was already asked about this '
  'id and that nothing has happened since which would make that answer stale. It does NOT mean the '
  'provider ended the sessions: ProviderRejected is recorded as done and any 4xx but 429 is '
  'ProviderRejected, so the record can be wrong, and nothing may rest on it being right. Cleared by '
  'the two events that create a fresh obligation — the account closing '
  '(identity_close_owes_a_revocation) and the id being superseded — and by the identity observing '
  'the id again (SONNY-358, PR #164 review F1). WHICH obligation a stamp discharged is '
  'revocation_episode, which the same three events increment: a drain stamps only rows still in the '
  'episode it claimed, so a stamp can never discharge an obligation created after the provider call '
  'that produced it (SONNY-365).';

-- @rollback

-- The column goes, and the two functions return to 0015's text. Nothing is corrupted and nothing is
-- repaired: rows keep whatever `provider_session_revoked_at` they carry, read afterwards by a
-- mark-done that asks less of them. What comes back with the rollback is SONNY-365's window — a
-- drain's stamp discharging an obligation created after its provider call — which is where 0014 and
-- 0015 both stand.
ALTER TABLE sonny.identity_provider_user DROP COLUMN revocation_episode;

CREATE OR REPLACE FUNCTION sonny.close_owes_its_own_revocation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sonny.identity_provider_user
     SET provider_session_revoked_at = NULL,
         revocation_claimed_at = NULL
   WHERE identity_id = NEW.id
     AND superseded_at IS NULL
     AND (provider_session_revoked_at IS NOT NULL OR revocation_claimed_at IS NOT NULL);
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION sonny.record_provider_side_user() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.supabase_user_id IS NOT NULL
     AND OLD.supabase_user_id IS DISTINCT FROM NEW.supabase_user_id THEN
    UPDATE sonny.identity_provider_user
       SET superseded_at = now(),
           provider_session_revoked_at = NULL,
           revocation_claimed_at = NULL
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

COMMENT ON COLUMN sonny.identity_provider_user.provider_session_revoked_at IS
  'Whether a revocation is outstanding for this provider-side user id — NULL means one is owed as '
  'soon as an owed condition holds. It records only that the provider was already asked about this '
  'id and that nothing has happened since which would make that answer stale. It does NOT mean the '
  'provider ended the sessions: ProviderRejected is recorded as done and any 4xx but 429 is '
  'ProviderRejected, so the record can be wrong, and nothing may rest on it being right. Cleared by '
  'the two events that create a fresh obligation — the account closing '
  '(identity_close_owes_a_revocation) and the id being superseded — and by the identity observing '
  'the id again (SONNY-358, PR #164 review F1).';
