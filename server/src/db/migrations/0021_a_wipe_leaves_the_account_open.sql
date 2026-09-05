-- 0021 — the account's content can be deleted without the account (SONNY-404). Contract §4.6.3.
--
-- **What this is for.** Settings › Data › "Delete Sonny local data" is a promise about the account
-- (founder decision 2026-09-04, restated 2026-09-05 after a coordinator's error had briefly reversed
-- it). So the press deletes everything the gateway retains for the account — live content and every
-- training-snapshot copy of it — and leaves the account itself open. Closing an account is
-- `DELETE /v1/account`, a different promise with no control in the app today.
--
-- **All this migration moves is the record, for 0020's reason.** `sonny.content_deletion` is where
-- "was this deleted, and what did it reach" stops being a belief, and its `reason` CHECK admits no
-- value for this act. Filing it under `account` would be the closest wrong answer available: that
-- value means the account was closed and its content went with it, and a reader a year from now
-- cannot tell the two apart from the row — `sonny.account.deleted_at` answers it only until the user
-- closes the account for real, at which point every earlier content wipe reads as a close.
--
-- **The rollback deletes the rows this reason wrote**, for the reason 0020's does: a CHECK cannot be
-- narrowed while rows violate it. What is lost is the record of those wipes; the content itself is
-- unaffected either way, being already gone.

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'task_screenshots', 'account', 'account_content',
                    'expiry', 'snapshot_expiry'));

-- @rollback

DELETE FROM sonny.content_deletion WHERE reason = 'account_content';

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'task_screenshots', 'account', 'expiry', 'snapshot_expiry'));
