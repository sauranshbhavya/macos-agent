-- 0015 — an obligation to revoke a provider-side user is created by the CLOSE and by the
-- SUPERSESSION, and each one clears the record of the last revocation (SONNY-358).
--
-- **The decision this migration is, stated before the SQL, because the SQL is four lines and the
-- decision is the whole ticket.**
--
-- `provider_session_revoked_at` is read by `OWED_PREDICATE` as "this id has no outstanding
-- revocation". 0014 gave it a matching meaning — "the revocation owed for this id's current episode
-- has been performed" — and made it true by clearing the stamp whenever the identity **observes**
-- the id again. That closes every route on which the user comes back through a door that runs
-- `resolve()`. It rests, unavoidably, on a premise nobody had written down: **that a user whose
-- sessions were revoked can only come back by signing in.**
--
-- That premise is false three times over, and all three were measured against this tree before this
-- file was written (`server/test/supersession.db.test.ts` and `server/test/auth.db.test.ts` hold
-- each one now):
--
--   A. **They come back by refreshing.** `POST /v1/auth/refresh` mints a full session and never
--      calls `resolve()`, so nothing names `supabase_user_id` and 0014's trigger never fires. This
--      is the route SONNY-358 was filed for.
--   B. **They do not come back at all.** Close, drain, an operator reopens the account, the account
--      is closed again with no sign-in and no refresh in between. Nothing observed the id, so
--      nothing cleared the stamp, and the second close owes 0. No route change could have closed
--      this one: there is no request to hang the fix on.
--   C. **They come back as somebody else.** Close, drain, reopen, and the next sign-in presents a
--      DIFFERENT provider-side user id. The stamped id is superseded rather than observed, so it
--      keeps its stamp — and a superseded id with a stamp is owed nothing, for ever.
--
-- **So the fix is not "fire the trigger from refresh".** That closes A and leaves B and C open,
-- and it leaves the design resting on the premise that the user comes back through a door this
-- gateway can see. The question the ticket asks is what a recorded revocation is allowed to imply,
-- and the answer is:
--
--   **A recorded revocation implies only that the provider was already asked about this id, and
--   that nothing has happened since which would make that answer stale. It does NOT imply that the
--   provider ended the sessions, and nothing may rest on it doing so.**
--
-- It cannot imply more than that, because `ProviderRejected` is recorded as done and the classifier
-- behind it treats any 4xx but 429 as `ProviderRejected` (`server/src/auth/provider.ts`,
-- `server/src/auth/revocation.ts`). A 401 or a 403 out of whichever mechanism SONNY-313 chooses
-- lands there with every session still alive, and the stamp says the work was done. Under the old
-- reading a lie like that is permanent; under this one it costs one redundant provider call the
-- next time the id is owed.
--
-- **What follows from it, mechanically:** the stamp must be cleared by the events that CREATE an
-- obligation, not only by the events that evidence the user's return. `OWED_PREDICATE` names
-- exactly two obligations — `i.account_closed` and `pu.superseded_at IS NOT NULL` — so there are
-- exactly two transitions to catch, and this migration catches both. Doors A, B and C are then all
-- the same door: whichever way the user did or did not return, the **close** that follows owes its
-- own revocation.
--
-- **That sentence is about the OBLIGATION and says nothing about the DISCHARGE, which is a fourth
-- shape and is not closed here** (PR #167 review, F3; SONNY-365). `drainOwedRevocations`' mark-done
-- re-checks whether a row is owed *now*; it never checks whether the provider call it just made
-- covers the obligation that exists *now*. So a drain still inside `signOutAllForUser` when the
-- account is reopened, refreshed and re-closed stamps the row on its way out and discharges an
-- obligation created after its own call — reproduced against a real database, ending `owed = 0`
-- with the sessions minted during the reopen never revoked. It is **not a regression**: 0014
-- behaves identically and this migration strictly narrows the window rather than opening it, and
-- the lease clear below is what makes recovery possible at all, since a second drain inside the
-- window does call the provider again. What is missing is an episode identity on the mark-done —
-- a claim token, or the claimed `revocation_claimed_at` carried into its predicate — and that is
-- SONNY-365's, sequenced with this ticket before SONNY-313.
--
-- **The whole enumeration rests on one invariant, and it is stated here because nothing else states
-- it** (PR #167 review). **An identity's CURRENT provider-side user id can never be a superseded
-- row.** It holds by construction of 0014's trigger — the `ON CONFLICT` arm clears `superseded_at`
-- for the id being named — and the reviewer measured 0 violations over 32 rows across 6 databases.
-- Everything above depends on it: `accountForSupabaseUser` reads `sonny.identity.supabase_user_id`,
-- so "a refresh succeeds" means "some live identity currently names this id", which under the
-- invariant means that identity's row is current, not superseded, and therefore covered by the
-- close's clear rather than skipped by its `superseded_at IS NULL` scoping. Break the invariant and
-- the scoping silently starts skipping rows a refresh can still reach. An unstated invariant a
-- mechanism rests on is what gets broken by someone who never knew it was load-bearing.
--
-- **And `POST /v1/auth/refresh` is deliberately left alone.** It creates no obligation to revoke —
-- the account it serves is live, by construction, or `accountForSupabaseUser` would have refused it
-- — so there is nothing for it to record. The route's own comment says so, pointing here.
--
-- **What this costs, stated rather than discovered later.** An account closed, drained, reopened and
-- closed again asks the provider about the same id a second time. If the first revocation really
-- happened, that call is redundant and the provider answers "no such session", which
-- `drainOwedRevocations` already treats as done. One wasted idempotent call per close cycle is the
-- price of never missing a real one, and this is a privacy guarantee: the two directions are not
-- symmetric.
--
-- **What it does not do**, so nobody reads it as more than it is. It does not make the stamp
-- trustworthy — only SONNY-313's choice of mechanism, and a classifier narrowed to fit it, can do
-- that. What it bounds is narrower than "how long a wrong stamp survives", and the difference is
-- worth spelling out because the shorter phrasing reads as reassurance in the one shape where it
-- delivers nothing (PR #167 review, F5). **A wrong stamp is corrected only where a NEW obligation
-- arrives**: a reopen and re-close, or the id being superseded. For the ordinary case — a user
-- closes their account and never comes back — no transition ever fires again, `owedRevocationCount`
-- reads 0 and the hard delete goes through, exactly as before. So where the classifier lies, this
-- migration reaches the reopen and supersession cases and leaves the never-return case untouched;
-- that case is closed only by narrowing the classifier, which is SONNY-313's.
-- And it says nothing about access tokens already minted, which are SONNY-237's, or about a
-- provider-side refresh family that `deps.provider.refresh()` keeps rotating for an id this gateway
-- then refuses to attribute — the same ticket's neighbourhood, and not this one's.
--
-- **0014's observation clear is kept and is no longer load-bearing.** With both obligations catching
-- their own transition, every route enumerated above is closed by this migration alone; the
-- `ON CONFLICT` arm's clear now runs strictly earlier than a clear that would happen anyway. It is
-- kept because it is true on its own terms — observing an id does start a new episode — and because
-- deleting a just-merged fix that nothing is wrong with is a change with no defect behind it. Two
-- writers of one column are a hazard when they can disagree; these cannot, because both only ever
-- write NULL and neither reads the other.

-- **`AFTER UPDATE` with a value-based `WHEN`, never `AFTER UPDATE OF account_closed`.** This is
-- 0014's F5 gotcha, one table over and in the direction that would have silently lost a case:
-- `UPDATE OF` keys on the SET list of the original statement, and `account_closed` has two writers
-- that do not agree about naming it. `sonny.mark_identities_closed` (0005) names the column, so an
-- `UPDATE OF` trigger would fire for an account being closed; `sonny.derive_identity_closed` (0005)
-- is a `BEFORE INSERT OR UPDATE OF account_id` trigger that assigns `NEW.account_closed` on a
-- statement that never mentions it, so an identity **moved onto a closed account** would not fire
-- one. 0005's own header calls that move the third of the three statements that can falsify this
-- flag, and it is the statement 0004 forgot. Comparing OLD to NEW asks what actually happened to the
-- row rather than what the statement said it would do, and catches all three.
--
-- **`superseded_at IS NULL` is the whole of the scoping, and it is not caution.** A close creates an
-- obligation for the id the identity is CURRENTLY naming: those are the sessions that must stop. An
-- id the identity has already stopped naming had its obligation created once, by the supersession,
-- and a later close tells us nothing new about it — no session for a superseded id can have been
-- minted through this gateway since, because `accountForSupabaseUser` reads
-- `sonny.identity.supabase_user_id` and so refuses one. Without this clause a closed account would
-- re-owe every id in its history on every close, which drains but reports a debt an operator cannot
-- act on.
--
-- The third `AND` is only there to keep the ordinary first close from writing rows it does not
-- change; the trigger is correct without it.
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

CREATE TRIGGER identity_close_owes_a_revocation
  AFTER UPDATE ON sonny.identity
  FOR EACH ROW
  WHEN (NEW.account_closed AND NOT OLD.account_closed)
  EXECUTE FUNCTION sonny.close_owes_its_own_revocation();

-- The second obligation, in 0014's own trigger: an id that is superseded is owed a revocation from
-- that moment, and any revocation recorded against it belongs to the episode that just ended.
--
-- **The state this is reachable from is door C above, measured rather than imagined**: close →
-- drain (the current id is stamped) → reopen → sign in presenting a different id. At the moment of
-- supersession the row is current and stamped, and 0014 left the stamp — so the id the user signed
-- in as last month, whose sessions may still be live, was owed nothing by anybody, for ever.
--
-- Everything else in this function is 0014's, byte for byte. It is restated in full rather than
-- patched because `CREATE OR REPLACE FUNCTION` has no partial form, and the rollback below restores
-- 0014's text the same way.
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

-- 0014's table comment carries the same "current episode has been performed" reading and is
-- restated for the same reason. Only the sentence about this column changes; the rest is 0014's.
COMMENT ON TABLE sonny.identity_provider_user IS
  'Every provider-side (Supabase) user id an identity has ever named, and the revocation state of '
  'each. The identity''s own supabase_user_id is the CURRENT one and is what attribution reads; '
  'this table is the history, and a row with superseded_at set is owed a revocation whether or not '
  'the account is closed. provider_session_revoked_at means "no revocation is outstanding for this '
  'id" — it records that the provider was asked, never that it complied, and it is cleared by the '
  'account closing, by the id being superseded, and by the identity observing the id again. '
  'Maintained by the identity_records_its_provider_side_user and identity_close_owes_a_revocation '
  'triggers — never written by application code (SONNY-196, SONNY-230, SONNY-358).';

-- @rollback

DROP TRIGGER IF EXISTS identity_close_owes_a_revocation ON sonny.identity;
DROP FUNCTION IF EXISTS sonny.close_owes_its_own_revocation();

-- 0014's `record_provider_side_user`, restored verbatim. The rollback loses doors A, B and C with
-- it: a stamp written before the rollback stays where it is, and under 0014's reading it makes that
-- id un-owed until the identity observes it again. Nothing is corrupted and nothing is repaired —
-- the rows are the same rows, read by a predicate that asks less of them.
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

COMMENT ON COLUMN sonny.identity_provider_user.provider_session_revoked_at IS NULL;

COMMENT ON TABLE sonny.identity_provider_user IS
  'Every provider-side (Supabase) user id an identity has ever named, and the revocation state of '
  'each. The identity''s own supabase_user_id is the CURRENT one and is what attribution reads; '
  'this table is the history, and a row with superseded_at set is owed a revocation whether or not '
  'the account is closed. provider_session_revoked_at means "the revocation owed for this id''s '
  'CURRENT episode has been performed", not "this id has been revoked at least once" — observing '
  'the id again starts a new episode and clears it. Maintained by the '
  'identity_records_its_provider_side_user trigger — never written by application code '
  '(SONNY-196, SONNY-230, PR #164 review F1).';
