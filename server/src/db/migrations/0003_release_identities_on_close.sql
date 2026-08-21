-- 0003 — a closed account cannot hold identities (SONNY-127, PR #87 F3).
--
-- **The bug this closes was a permanent denial of service on an address, and the first fix missed
-- it.** `resolve()`'s rule 1 excludes identities whose account is deleted; the unique constraint on
-- `(provider, subject)` does not. So a closed account's identity still occupies the address while
-- being invisible to sign-in: the insert conflicts, the resolver rolls back, and the address is
-- unusable by anyone, including its owner. The first fix released identities inside the DELETE
-- handler, which works only for accounts closed by that one code path — and after the retry was
-- bounded, every other path (a retention sweep, an operator's UPDATE, the race between `resolve`
-- and a concurrent close) turned the livelock into a permanent `IdentityConflict`, which is worse
-- because it no longer even spins where someone might notice.
--
-- **A trigger rather than handler code, because the invariant belongs to the data.** "An identity
-- may not reference a closed account" is true regardless of which statement closed it, and a rule
-- enforced in one handler is a rule that holds until the second writer appears. This is the
-- structural answer the review asked for: after it, the exclusion and the constraint agree by
-- construction.
--
-- **Superseded by 0004, and this header contained a false claim.** It said a partial unique index
-- scoped to live accounts "is not expressible". That is true only of the form joining to
-- `sonny.account`, which Postgres rejects with "cannot use subquery in index predicate" — and false
-- of the form 0004 uses, where the state is denormalised onto `sonny.identity` and the predicate is
-- a plain column. Both forms were tried against a real database before 0004 was written. The
-- DELETE below also broke two other things: the close handler's own read of `supabase_user_id`
-- (it revoked nobody) and the audit trail. See 0004.

CREATE OR REPLACE FUNCTION sonny.release_identities_on_close() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Only on the transition into closed. Firing on every update of a closed account would be
  -- harmless but pointless, and firing on re-open would be wrong; there is no re-open.
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    DELETE FROM sonny.identity WHERE account_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER account_close_releases_identities
  AFTER UPDATE OF deleted_at ON sonny.account
  FOR EACH ROW EXECUTE FUNCTION sonny.release_identities_on_close();

-- Any rows already in the stuck state when this migration runs. Idempotent, and a no-op on a fresh
-- database; present because a deployment that already closed an account before this landed would
-- otherwise keep that address permanently unusable with nothing to say so.
DELETE FROM sonny.identity i
  USING sonny.account a
 WHERE i.account_id = a.id AND a.deleted_at IS NOT NULL;

-- @rollback
DROP TRIGGER IF EXISTS account_close_releases_identities ON sonny.account;
DROP FUNCTION IF EXISTS sonny.release_identities_on_close();
