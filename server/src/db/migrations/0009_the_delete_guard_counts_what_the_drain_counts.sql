-- 0009 — the delete guard counts the same rows the drain does (SONNY-127, PR #87 sixth round).
--
-- **0008's trigger asked a different question than every other reader of this column, and the
-- difference was the whole of `account_closed`.** It counted identities with
-- `provider_session_revoked_at IS NULL AND supabase_user_id IS NOT NULL` and stopped there;
-- `owedRevocationCount` and `drainOwedRevocations` both also require `account_closed`. So the two
-- disagreed about every live account — because **never-revoked is the ordinary state of a live
-- account**, which has never been closed and therefore has never owed a revocation at all.
--
-- Reproduced: `owedRevocationCount` reports 1 (the closed account), and a `DELETE` of the *live*
-- account is refused with `23503 … still owes 1 provider-side revocation(s)`.
--
-- **The remedy the message names cannot clear it**, which is what turns a wrong refusal into a trap.
-- It says "Drain them first (npm run revocations reports what is outstanding)" — and that command
-- only ever sees closed accounts, so an operator meeting this runs the named fix, is told there is
-- nothing to do, and has nowhere to go. The only way through is to close the account, drain it, then
-- delete, which is a sequence nobody would derive from the message.
--
-- **No user-facing breakage, and that was checked rather than assumed:** `DELETE /v1/account`
-- soft-deletes (`UPDATE … SET deleted_at`) and never issues a hard delete, so a user whose provider
-- is unreachable is not blocked from deleting their account — the route answers 204, the debt is
-- recorded, and a later drain pays it. The trap is operational, and it lands on
-- `feature/row-12-retention`, which is the ticket 0008's own header says it was written for.

CREATE OR REPLACE FUNCTION sonny.refuse_delete_while_revocation_owed() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE owed integer;
BEGIN
  -- `account_closed` is the clause 0008 was missing. It is what makes this count the same set as
  -- `owedRevocationCount` and `drainOwedRevocations`, so the refusal and the remedy agree about
  -- which rows exist — and a guard whose message names a command that disagrees with it is worse
  -- than no guard, because it costs the reader the time to find that out.
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

-- @rollback
-- Back to 0008's body verbatim, missing clause included. A rollback restores the previous state
-- rather than a better version of it.
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
