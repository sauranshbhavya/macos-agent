-- 0005 — `account_closed` follows the account, whichever statement moved either one
-- (SONNY-127, PR #87 second-round F1, with F10 and F12).
--
-- **0004 denormalised a fact and then maintained it on only two of the three ways it can change.**
-- `sonny.identity.account_closed` mirrors `sonny.account.deleted_at`, and 0004 kept it true when an
-- account closed (`account_close_marks_identities`) and when an identity was inserted
-- (`identity_insert_derives_closed`, BEFORE INSERT only). It left the third: **an identity moving to
-- a different account.** `linkExplicitly` does exactly that — `UPDATE sonny.identity SET account_id`
-- — and no trigger fired, so the row kept whichever flag its *old* account had given it.
--
-- Reproduced against a real database before this was written, closing an account, moving its
-- identity onto a live one, and signing in again:
--
--   * the moved identity sat on a LIVE account carrying `account_closed = true`;
--   * rule 1 excludes `account_closed` identities, so the next sign-in with that same
--     `(provider, subject)` **created a second account** — the one-person-two-accounts failure this
--     whole ticket exists to prevent, arrived at from the one path that is supposed to prevent it;
--   * and 0004's own rollback then failed, because it removes rows by joining to
--     `sonny.account.deleted_at` and this row's account is not deleted — leaving a duplicate
--     `(provider, subject)` for the unconditional constraint the rollback re-adds:
--     `could not create unique index "identity_provider_subject_unique"`.
--
-- The fix is not "also fire on update": it is to make the trigger's *coverage* match the column's
-- definition. A denormalised column has to be maintained on **every** statement that can falsify
-- it, and the three statements are insert, account-close, and account-move.

-- **Derive on insert AND on a move.** Recomputed from the account the row is landing on, so the
-- flag is a function of the current `account_id` rather than of the one it was inserted with.
--
-- **`IF NOT FOUND` matters, and it is a second defect** (PR #87 F12). `SELECT … INTO` assigns NULL
-- when nothing matches, so an insert naming an account that does not exist set `account_closed` to
-- NULL and failed the NOT NULL constraint — `23502 not_null_violation`, reported against a column
-- the caller never wrote. The real error is `23503 foreign_key_violation`, and it is the one that
-- tells the caller what is actually wrong. Leaving the flag alone lets the foreign key raise it.
CREATE OR REPLACE FUNCTION sonny.derive_identity_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  SELECT (a.deleted_at IS NOT NULL) INTO NEW.account_closed
    FROM sonny.account a WHERE a.id = NEW.account_id;
  IF NOT FOUND THEN
    -- No such account. Say nothing about the flag and let the foreign key speak.
    NEW.account_closed := false;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS identity_insert_derives_closed ON sonny.identity;
CREATE TRIGGER identity_derives_closed
  BEFORE INSERT OR UPDATE OF account_id ON sonny.identity
  FOR EACH ROW EXECUTE FUNCTION sonny.derive_identity_closed();

-- **The close trigger becomes two-way** (PR #87 F10). 0004's marked on close and never unmarked,
-- so `UPDATE sonny.account SET deleted_at = NULL` — an operator undoing a mistaken closure, which is
-- the only way an account is ever reopened — left every identity on it flagged closed. Rule 1
-- excludes those, so the reopened account's owner would sign in and get a **new** account: the same
-- failure as above, reached from the other direction.
--
-- A reopen that would produce two live identities on one `(provider, subject)` now fails on the
-- partial unique index instead of succeeding quietly. That is the right direction: the address was
-- re-used while the account was closed, and refusing the reopen is a fact somebody has to see.
CREATE OR REPLACE FUNCTION sonny.mark_identities_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    UPDATE sonny.identity SET account_closed = true
      WHERE account_id = NEW.id AND NOT account_closed;
  ELSE
    UPDATE sonny.identity SET account_closed = false
      WHERE account_id = NEW.id AND account_closed;
  END IF;
  RETURN NEW;
END $$;

-- Any row already carrying a flag its account disagrees with. Reachable on a database where an
-- identity was moved before this migration, which is the state the reproduction above produced.
-- Idempotent, and a no-op on a fresh database.
UPDATE sonny.identity i
   SET account_closed = (a.deleted_at IS NOT NULL)
  FROM sonny.account a
 WHERE a.id = i.account_id
   AND i.account_closed <> (a.deleted_at IS NOT NULL);

-- @rollback
-- Restores 0004's two functions and its insert-only trigger verbatim. The repair pass above is not
-- undone: putting a row back into a state the schema calls invalid is not a rollback, and 0004's
-- own rollback removes exactly these rows anyway.
DROP TRIGGER IF EXISTS identity_derives_closed ON sonny.identity;
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
CREATE OR REPLACE FUNCTION sonny.mark_identities_closed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL THEN
    UPDATE sonny.identity SET account_closed = true
      WHERE account_id = NEW.id AND NOT account_closed;
  END IF;
  RETURN NEW;
END $$;
