-- 0008 — an owed revocation cannot be deleted out from under itself, and a drain claims it for
-- longer than one SELECT (SONNY-127, PR #87 fifth round, F2 and F3).
--
-- Both findings are the same mistake in two places: **0006 recorded a debt and then relied on
-- something other than the debt to keep it safe.**

-- ── F2: the cascade ──────────────────────────────────────────────────────────────────────────
--
-- `sonny.identity.account_id` is `REFERENCES sonny.account(id) ON DELETE CASCADE` (0002:51), which
-- was right when an identity was only ever a fact about an account. Since 0006 the identity row also
-- carries a debt to a *third party* — a provider-side session that is still live and that only
-- `supabase_user_id` can name — and that debt does not stop being owed because the account row went
-- away.
--
-- Reproduced: a closed account with two owed identities reports `owedRevocationCount = 2`; one
-- `DELETE FROM sonny.account WHERE deleted_at IS NOT NULL` later it reports **0**, with no rows left,
-- and `npm run revocations` prints "no provider-side revocation is owed" and exits 0. The sessions
-- are still live and nothing has ever asked the provider about them. **A report that cannot see the
-- work is worse than no report**, because it is the one an operator would act on.
--
-- **A hard delete of the account row is not hypothetical**: it is the statement
-- `feature/row-12-retention` exists to write. Left alone, that ticket inherits this on its first day
-- and nothing anywhere would say so — 0006, `revocation.ts`, the README's "Owed revocations" section
-- and the changelog all describe the residual as durable without naming what it depends on.
--
-- **Refuse the delete rather than move the debt.** The alternative — a table outside the cascade —
-- was rejected: it duplicates state that `provider_session_revoked_at` already holds, and it would
-- let an account be forgotten while a session it owns is still live, which is the outcome being
-- prevented rather than a smaller version of it. Refusing states the real ordering: **pay the debt,
-- then delete the row.** Retention gets a loud error naming the command that clears it, on the first
-- run rather than in production.
CREATE OR REPLACE FUNCTION sonny.refuse_delete_while_revocation_owed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE owed integer;
BEGIN
  SELECT count(*) INTO owed FROM sonny.identity
   WHERE account_id = OLD.id
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

CREATE TRIGGER account_delete_refuses_owed_revocation
  BEFORE DELETE ON sonny.account
  FOR EACH ROW EXECUTE FUNCTION sonny.refuse_delete_while_revocation_owed();

COMMENT ON FUNCTION sonny.refuse_delete_while_revocation_owed() IS
  'Refuses DELETE on an account whose identities still owe a provider-side revocation. NOTE: row '
  'triggers do not fire for TRUNCATE, so TRUNCATE bypasses this — deliberate, because TRUNCATE is a '
  'whole-table operator action rather than anything an application path performs, and the test '
  'suite resets itself with it.';

-- ── F3: the claim that was not a claim ───────────────────────────────────────────────────────
--
-- `drainOwedRevocations` claimed a row with `BEGIN; SELECT … FOR UPDATE SKIP LOCKED; COMMIT` and
-- **then** called the provider. The commit releases the row lock, so the lock covered one SELECT
-- rather than the work it was claiming, and the unguarded window is the entire provider call — which
-- that function's own comment describes as "a network call of unbounded duration".
--
-- Reproduced with a provider taking 300ms: two drains started 100ms apart against one owed row
-- called `signOutAllForUser` **twice for the same user**. Two started simultaneously against three
-- rows did divide correctly — so the mechanism worked only in the instant-collision case, which is
-- the one an ad-hoc test tries first.
--
-- **A lease, not a longer lock.** Holding the transaction open across a network call is the other
-- obvious fix and it is worse: it pins a connection and a row lock for however long the provider
-- takes, which is the thing the original comment was right to avoid. A timestamp claimed in one
-- atomic `UPDATE … RETURNING` costs no held lock, divides the work between any number of drains, and
-- **self-heals**: a drain that crashes mid-call leaves a lease that simply expires, where a held
-- lock would have been released by the crash into a state nobody recorded.
ALTER TABLE sonny.identity
  ADD COLUMN revocation_claimed_at timestamptz;

COMMENT ON COLUMN sonny.identity.revocation_claimed_at IS
  'When a drain last claimed this row to call the provider about it. A lease, not a lock: another '
  'drain skips a row claimed within sonny.revocation_lease_seconds() and re-claims it after, so a '
  'crashed drain''s work resumes without anything having to notice it crashed.';

-- The lease window, in the schema rather than in TypeScript so that a claim query and a human
-- reading the table agree about it. Long enough for a provider call that is going badly, short
-- enough that a crashed drain's row is retried within minutes.
CREATE OR REPLACE FUNCTION sonny.revocation_lease_seconds() RETURNS integer
LANGUAGE sql IMMUTABLE AS $$ SELECT 300 $$;

-- @rollback
DROP TRIGGER IF EXISTS account_delete_refuses_owed_revocation ON sonny.account;
DROP FUNCTION IF EXISTS sonny.refuse_delete_while_revocation_owed();
DROP FUNCTION IF EXISTS sonny.revocation_lease_seconds();
ALTER TABLE sonny.identity DROP COLUMN revocation_claimed_at;
