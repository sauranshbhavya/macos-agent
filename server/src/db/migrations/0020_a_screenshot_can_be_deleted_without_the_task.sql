-- 0020 — a screenshot can be deleted without the task it belonged to (SONNY-404). Contract §4.6.2.
--
-- **What this is for.** "Delete what Sonny did on screen" is a per-task control in the Mac app's
-- task detail: it removes that task's vision-session record and leaves the task, its command text
-- and its result standing. Until this migration the only server-side delete was the whole task's
-- (§4.6), so the button either reached nothing or would have had to delete more than it says. The
-- founder decision of 2026-09-05 is the narrower route, on the ground that screenshots are the most
-- sensitive content this gateway holds and that snapshot copies of them never expire today.
--
-- **No new table and no new column on the content store.** The screenshot columns already exist on
-- `sonny.retained_content` and on `sonny.training_snapshot_member`; clearing one is an UPDATE to
-- NULL rather than a DELETE of the row, because the row's request text and served response are not
-- what the button names. So all this migration moves is the *record* of the deletion.
--
-- ## Why the record needs both changes
--
-- `sonny.content_deletion` is the table 0013 added so that "was this deleted, and what did it
-- reach" is a query rather than a belief, and its own header says every removal path writes to it in
-- the same transaction as the removal. A screenshot clear is a removal path, so it writes here too —
-- and it cannot do that honestly with the columns as they stand:
--
-- - `reason` carries a CHECK admitting four values, none of which is this one. Filing a screenshot
--   clear under `'task'` would make the record say the whole task was deleted, which is the one
--   thing this route exists not to do.
-- - `content_rows` and `snapshot_rows` count rows *removed*. This path removes none: it clears two
--   columns on rows that stay. Reusing those counters would change what they mean for every reader
--   of this table, including readers that predate this route.
--
-- Hence one widened CHECK and two counters of its own. The counters are separate for the same
-- reason `stored_responses` is separate: a record saying "5" without saying five of what is the kind
-- of record that gets misread a year later by somebody who was not here.
--
-- **The rollback deletes the records this reason wrote, and that is a real loss rather than a
-- formality.** A CHECK cannot be narrowed while rows violate it, so the rows have to go first.
-- Rolling this back means the screenshots route is gone; what is lost with it is the record of the
-- clears it performed. The content itself is unaffected either way -- a cleared screenshot is
-- already NULL and no rollback puts it back.

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'task_screenshots', 'account', 'expiry', 'snapshot_expiry'));

-- Live rows whose `screenshot` was set to NULL. Not "rows deleted": the row survives, because the
-- request text and the served response beside the screenshot are not what the user asked to remove.
ALTER TABLE sonny.content_deletion
  ADD COLUMN screenshots_cleared integer NOT NULL DEFAULT 0;

-- The same clear reaching training-snapshot members. This is the half the whole lineage exists for:
-- a member holds a copy rather than a pointer, and `expireSnapshots` skips a NULL `expires_at`,
-- which is every snapshot the builder makes -- so a screenshot left in a snapshot is left there
-- indefinitely.
ALTER TABLE sonny.content_deletion
  ADD COLUMN snapshot_screenshots_cleared integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN sonny.content_deletion.screenshots_cleared IS
  'Live retained_content rows whose screenshot was set to NULL by DELETE /v1/tasks/{task_id}/'
  'screenshots. Counted apart from content_rows because no row was removed.';

COMMENT ON COLUMN sonny.content_deletion.snapshot_screenshots_cleared IS
  'Training snapshot member copies whose screenshot was set to NULL by the same route. Counted '
  'apart from snapshot_rows for the same reason.';

-- @rollback

DELETE FROM sonny.content_deletion WHERE reason = 'task_screenshots';

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'account', 'expiry', 'snapshot_expiry'));

ALTER TABLE sonny.content_deletion
  DROP COLUMN IF EXISTS snapshot_screenshots_cleared;

ALTER TABLE sonny.content_deletion
  DROP COLUMN IF EXISTS screenshots_cleared;
