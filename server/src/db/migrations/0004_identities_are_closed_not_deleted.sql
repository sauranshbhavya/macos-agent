-- 0004 — a closed account's identities are MARKED closed, never deleted (SONNY-127, PR #87 R1/R3/R19).
--
-- **One choice in 0003 caused three separate defects, which is why this replaces the design rather
-- than patching each symptom.** That migration DELETEd identity rows when an account closed. The
-- trigger is `AFTER UPDATE`, so it fires at statement end — before any statement the same handler
-- runs next. Consequences, all verified against a real database:
--
--   R1  The delete handler reads `supabase_user_id` *after* closing the account, to revoke every
--       provider-side session. It read an empty table and revoked **nobody**. Reproduced: 0 rows.
--   R3  A sweep cannot see rows inserted after it fires, so a `resolve()` racing a close still
--       inserted an identity onto an account that was closing — stranded, and permanent.
--   R19 It destroyed `link_method`, which is the audit trail answering "why are these two joined?",
--       and the `supabase_user_id`s that `provider.deleteUser` and SONNY-196 both need. That is the
--       same reasoning that keeps the *account* row on close, applied backwards one table over.
--
-- **Marking rather than deleting fixes all three at once**, and buys the guarantee 0003's own header
-- claimed and could not deliver. That header said a partial unique index "is not expressible" —
-- true only of the form that joins to `sonny.account`, which Postgres rejects with "cannot use
-- subquery in index predicate". With the state denormalised onto this table the predicate is a
-- plain column reference, which Postgres accepts. Both forms were tried before this was written.

ALTER TABLE sonny.identity
  ADD COLUMN account_closed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN sonny.identity.account_closed IS
  'Denormalised from sonny.account.deleted_at, maintained by triggers. Exists so the live-identity '
  'uniqueness rule can be a partial unique index — a predicate joining to another table is not a '
  'legal index predicate. Never written by application code.';

UPDATE sonny.identity i SET account_closed = true
  FROM sonny.account a WHERE a.id = i.account_id AND a.deleted_at IS NOT NULL;

-- **The constraint now says what the resolver means.** The old one was unconditional, so a closed
-- account's identity kept occupying its address while being invisible to sign-in — the exact
-- disagreement between the exclusion and the constraint that produced a permanent denial of service
-- on that address. Now they are the same statement.
ALTER TABLE sonny.identity DROP CONSTRAINT identity_provider_subject_unique;
CREATE UNIQUE INDEX identity_live_provider_subject
  ON sonny.identity (provider, subject) WHERE NOT account_closed;

-- Closing marks. Fires on any update leaving `deleted_at` set, not only the transition into it:
-- 0003 guarded on `OLD.deleted_at IS NULL`, so a second `UPDATE ... SET deleted_at` — an operator
-- correcting a timestamp, a retry — skipped the trigger entirely and left identities live on a
-- closed account. Marking is idempotent, so there is nothing to gain by guarding it.
CREATE OR REPLACE FUNCTION sonny.mark_identities_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    UPDATE sonny.identity SET account_closed = true
      WHERE account_id = NEW.id AND NOT account_closed;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS account_close_releases_identities ON sonny.account;
DROP FUNCTION IF EXISTS sonny.release_identities_on_close();

CREATE TRIGGER account_close_marks_identities
  AFTER UPDATE OF deleted_at ON sonny.account
  FOR EACH ROW EXECUTE FUNCTION sonny.mark_identities_closed();

-- The out-of-band hole 0003 had no answer for: an identity inserted onto an account that is
-- *already* closed. The close trigger has long since fired, so nothing would ever mark it, and it
-- would occupy the live uniqueness slot forever. Deriving the flag at insert time closes it without
-- the caller having to know the rule.
CREATE OR REPLACE FUNCTION sonny.derive_identity_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  SELECT (a.deleted_at IS NOT NULL) INTO NEW.account_closed
    FROM sonny.account a WHERE a.id = NEW.account_id;
  RETURN NEW;
END $$;

CREATE TRIGGER identity_insert_derives_closed
  BEFORE INSERT ON sonny.identity
  FOR EACH ROW EXECUTE FUNCTION sonny.derive_identity_closed();

-- **Lock order, recorded because it is about to matter to someone else.** The close trigger updates
-- `sonny.account` and then `sonny.identity`, in that order, inside one transaction. Any code taking
-- them in the opposite order — updating an identity and then the account row — can deadlock against
-- a concurrent close. The reviewer reproduced exactly that shape, and it is the shape SONNY-128's
-- training-consent write path will have if written naively.
--
--   **The rule: take `sonny.account` before `sonny.identity`, always.**
--
-- Stated here rather than in a comment on one function because it binds every future writer of
-- these two tables, and the trigger is what makes it non-negotiable.

-- @rollback
DROP TRIGGER IF EXISTS identity_insert_derives_closed ON sonny.identity;
DROP FUNCTION IF EXISTS sonny.derive_identity_closed();
DROP TRIGGER IF EXISTS account_close_marks_identities ON sonny.account;
DROP FUNCTION IF EXISTS sonny.mark_identities_closed();
DROP INDEX IF EXISTS sonny.identity_live_provider_subject;
-- Restores 0003's state faithfully: rows a closed account still holds would violate the
-- unconditional constraint this re-adds, so they are removed first, which is what 0003 would have
-- done to them anyway.
DELETE FROM sonny.identity i USING sonny.account a
  WHERE i.account_id = a.id AND a.deleted_at IS NOT NULL;
ALTER TABLE sonny.identity DROP COLUMN account_closed;
ALTER TABLE sonny.identity ADD CONSTRAINT identity_provider_subject_unique UNIQUE (provider, subject);
CREATE OR REPLACE FUNCTION sonny.release_identities_on_close() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    DELETE FROM sonny.identity WHERE account_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER account_close_releases_identities
  AFTER UPDATE OF deleted_at ON sonny.account
  FOR EACH ROW EXECUTE FUNCTION sonny.release_identities_on_close();
