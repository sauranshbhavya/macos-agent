-- 0006 — a provider-side revocation is OWED until something records that it happened
-- (SONNY-127, PR #87 third round, F1).
--
-- **Closing an account and revoking its provider-side sessions were one step that could half-happen,
-- and the half that failed had nowhere to be written down.** `DELETE /v1/account` commits the close
-- and then walks the account's identities calling `signOutAllForUser` on each. That loop lived
-- entirely in memory: it aborted on the first error that was not `ProviderRejected`, so every
-- identity ordered after the failing one was never even attempted, and nothing anywhere recorded
-- that they had not been.
--
-- Reproduced end to end against a real database with a provider that fails once transiently: the
-- account closed and **committed**, the request answered 500, the third identity's revocation was
-- never called, and the retry answered 401 — because a closed account can no longer be attributed
-- to its caller, which is correct and which is also what removes every retry path. The user deletes
-- their account, is told it failed, and a live provider-side session survives indefinitely with no
-- mechanism anywhere that will ever try again.
--
-- **The durable record is the fix, not the retry.** A loop that catches and continues stops one
-- failure hiding the others, and it still leaves the failures nowhere. With a column, "what is still
-- owed" becomes a query any process can run — the deletion route drains it on the way in, and
-- `npm run revocations` reports it from outside, needing no caller who can still authenticate.
-- (This line named `npm run revoke-pending`, a command that has never existed — PR #87 fifth round, F8.)

ALTER TABLE sonny.identity
  ADD COLUMN provider_session_revoked_at timestamptz;

COMMENT ON COLUMN sonny.identity.provider_session_revoked_at IS
  'When this identity''s provider-side sessions were successfully revoked. NULL on a closed account '
  'means the revocation is still OWED and something must retry it; NULL on a live account means '
  'nothing has asked for one, which is the ordinary state. Written only after the provider call '
  'returns successfully — never optimistically, because the whole point is that it records what '
  'actually happened rather than what was attempted.';

-- Finding the work. Partial, because the only rows this is ever asked about are the closed ones with
-- nothing recorded — on any real database that is a handful of rows against every identity ever
-- created, and a full index would be almost entirely dead weight.
CREATE INDEX identity_revocation_owed
  ON sonny.identity (account_id)
  WHERE account_closed AND provider_session_revoked_at IS NULL;

-- **Rows that predate this column are NOT marked done.** Leaving them NULL says "we do not know",
-- which is true, and the drain will attempt them once and then know. Back-filling `now()` would
-- assert a revocation nobody can evidence, and would do it to exactly the rows most likely to be
-- the stranded ones this migration exists for.

-- @rollback
DROP INDEX IF EXISTS sonny.identity_revocation_owed;
ALTER TABLE sonny.identity DROP COLUMN provider_session_revoked_at;
