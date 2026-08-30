-- 0017 — "the latest code at this mailbox" is decided by insertion order, not by a timestamp two
-- rows can share (SONNY-353).
--
-- **The decision, stated before the SQL.**
--
-- Two queries in `server/src/auth/codes.ts` pick a single row per mailbox with
-- `ORDER BY issued_at DESC LIMIT 1`: `consumeLatest`, which decides **which code a verify redeems**,
-- and `latestIssuance`, which decides **which of the three distinct failures a caller is told**.
-- `issued_at` is not unique and carries no tie-break, so when two rows share it the ordering is
-- undefined — Postgres may return either, and which one it returns is not stable across plans,
-- versions or row order on disk. Found 2026-08-29 by SONNY-341's lane: a frozen-clock test harness
-- makes every code in a test share one `issued_at`, which turns an unlikely case into every case.
--
-- **What "latest" means, decided: the last code issued at this mailbox.** Not "the one with the
-- largest timestamp" — that is a proxy which fails exactly when two codes are close enough together
-- for the question to matter. `issueCode` takes `pg_advisory_xact_lock(hashtext('sonny.code:' ||
-- mailbox_key))` across its invalidate-and-insert, so per mailbox the issues are serialised and
-- insertion order IS issuance order. A sequence records that order directly.
--
-- **The two alternatives the ticket named, and why neither is shipped:**
--
--   * **Tie-break on the primary key.** `id` is `uuid DEFAULT gen_random_uuid()`, which has no
--     relationship to insertion order at all. `ORDER BY issued_at DESC, id DESC` is deterministic
--     and answers the wrong question: for two codes in one instant it picks a random one, stably.
--     Under the frozen-clock harness — where every `issued_at` is equal, so `id` decides everything
--     — a test issuing two codes and expecting the second to win would pass about half the time.
--     Defined is not the same as correct, and the ticket asks for a defined answer *to this
--     question*.
--   * **A constraint making the case impossible** — a partial unique index over unconsumed rows per
--     mailbox. It cannot be built here and would break issuance if it were: `invalidateLive` marks
--     only *live* rows (`expires_at > now`) consumed, so an issuance that simply expired keeps
--     `consumed_at NULL` for ever, and the next code at that mailbox would violate the index. It
--     also reaches only `consumeLatest`; `latestIssuance` reads consumed and expired rows too, by
--     design, so its ambiguity would survive.
--
-- **Consistent with `issued_at`, and what happens when it is not.** A test that rewinds its clock
-- can produce a row whose `issue_seq` is higher and whose `issued_at` is earlier. The sequence wins,
-- and that is the right answer: the last code issued is the one the user is holding, and
-- `issueCode` has already invalidated the live ones before it in the same transaction.
--
-- **The backfill is an approximation and only for rows written before this migration.** Their real
-- issuance order is not recorded anywhere — that is the defect — so `ORDER BY issued_at, id` is the
-- best available reconstruction, and for historical rows sharing an instant it falls back to the
-- same arbitrary-but-stable uuid order rejected above. Every row written after this migration
-- carries real insertion order. Rows this old are long past `FAILURE_DISCLOSURE_SECONDS` and past
-- `CODE_LIFETIME_SECONDS`, so neither query can reach them for anything but "nothing is live here".

ALTER TABLE sonny.sign_in_code_issue ADD COLUMN issue_seq bigint;

UPDATE sonny.sign_in_code_issue s
   SET issue_seq = ordered.n
  FROM (SELECT id, row_number() OVER (ORDER BY issued_at, id) AS n
          FROM sonny.sign_in_code_issue) ordered
 WHERE s.id = ordered.id;

ALTER TABLE sonny.sign_in_code_issue ALTER COLUMN issue_seq SET NOT NULL;
ALTER TABLE sonny.sign_in_code_issue
  ALTER COLUMN issue_seq ADD GENERATED ALWAYS AS IDENTITY;

-- The identity's sequence is created starting at 1, which would collide with every backfilled row.
-- The third argument is `is_called`: false on an empty table so the first insert gets 1, true
-- otherwise so the next insert gets max+1. `GREATEST` ignores NULL in Postgres, which is what makes
-- the empty case land on 1 rather than on nothing.
SELECT setval(pg_get_serial_sequence('sonny.sign_in_code_issue', 'issue_seq'),
              GREATEST((SELECT max(issue_seq) FROM sonny.sign_in_code_issue), 1),
              (SELECT count(*) FROM sonny.sign_in_code_issue) > 0);

COMMENT ON COLUMN sonny.sign_in_code_issue.issue_seq IS
  'Issuance order, and the only thing that decides which code at a mailbox is the latest one '
  '(SONNY-353). issued_at is not unique and two codes sharing an instant have no defined newest, '
  'which makes both "which code does a verify redeem" and "which of the three failures is '
  'disclosed" depend on the query plan. GENERATED ALWAYS: application code may not write it. '
  'Per mailbox this is exactly issuance order, because issueCode holds an advisory lock on the '
  'mailbox across its invalidate-and-insert.';

-- The lookup index moves with the ordering. `(mailbox_key, issued_at DESC)` no longer serves either
-- query's ORDER BY, and its leading column is all `invalidateLive` ever needed, so the new index is
-- a strict replacement rather than an addition.
CREATE INDEX sign_in_code_issue_mailbox_seq_idx
    ON sonny.sign_in_code_issue (mailbox_key, issue_seq DESC);
DROP INDEX sonny.sign_in_code_issue_email_idx;

-- @rollback

-- The column and its sequence go, and the old index comes back. Nothing is lost that was not
-- already absent: `issued_at` is still on every row, and the queries that read it are back to
-- having no defined answer when two share an instant, which is where 0002 through 0016 stand.
CREATE INDEX sign_in_code_issue_email_idx
    ON sonny.sign_in_code_issue (mailbox_key, issued_at DESC);
DROP INDEX sonny.sign_in_code_issue_mailbox_seq_idx;
ALTER TABLE sonny.sign_in_code_issue DROP COLUMN issue_seq;
