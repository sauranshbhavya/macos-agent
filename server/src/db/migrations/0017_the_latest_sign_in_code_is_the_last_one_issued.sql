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
-- **There is NO backfill, and that is a lock decision rather than a shortcut** (PR #171 review, F1).
--
-- The first version of this file added the column nullable, ran `UPDATE … SET issue_seq =
-- row_number() OVER (ORDER BY issued_at, id)` over the whole table, then `SET NOT NULL`. Every
-- migration runs inside one transaction, so the `ALTER TABLE`'s `ACCESS EXCLUSIVE` was held across
-- that full-table `UPDATE` — and `sonny.sign_in_code_issue` is read by `latestIssuance` on the
-- **sign-in path**. Measured at 200,000 rows on this repository's own container: the migration took
-- **2160 ms** and a concurrent read of exactly that query blocked for **2157 ms** (the reviewer
-- measured 2851 ms on their machine). Nothing prunes this table, so that number grows without
-- bound. `CREATE INDEX CONCURRENTLY` and a batched backfill are the standard escapes and neither is
-- available: both need to run outside a transaction, and this runner gives every migration one.
--
-- **What the backfill was buying did not justify that, which is what makes removing it the fix
-- rather than a trade.** The real issuance order of a pre-existing row is recorded nowhere — that is
-- the defect this migration is about — so `ORDER BY issued_at, id` was never a reconstruction of it.
-- For rows sharing an instant it falls back to `id`, `gen_random_uuid()`, the arbitrary order this
-- file rejects two paragraphs above. So the backfill bought a *stable* arbitrary order in place of
-- an *unstable* one, for rows written before the column existed, at the cost of a read stall on the
-- sign-in path that grows with the table.
--
-- **So every pre-existing row gets 0, and 0 is a sentinel that means "written before this column
-- existed; its issuance order is not recorded and never was".** `ADD COLUMN … NOT NULL DEFAULT 0`
-- is metadata-only from PostgreSQL 11 — a non-volatile default is stored in `pg_attribute` rather
-- than written to every row — so the `ACCESS EXCLUSIVE` is held for the catalog update alone. The
-- default is then dropped and the identity attached, both catalog-only, and the identity's sequence
-- starts at 1, so **no row written after this migration can ever read 0**.
--
-- **What that costs, stated so it is not discovered later.** `ORDER BY issue_seq DESC` puts every
-- post-migration row above every pre-migration row, which is correct — all of them are newer. Among
-- pre-migration rows it is a tie, so their relative order is undefined. That is **exactly the state
-- this migration inherits** rather than a new defect: it is what `ORDER BY issued_at DESC` already
-- gave them. The window in which it can change an answer is narrow and closes on its own — a row is
-- only reachable for anything but "nothing is live here" while it is inside `CODE_LIFETIME_SECONDS`
-- or `FAILURE_DISCLOSURE_SECONDS`, so it is bounded by the codes issued in the twenty minutes before
-- the migration ran, and every code issued after it is ordered exactly.
--
-- **The residual cost is the index build, and it is the same KIND of cost — smaller, not different.**
-- The first draft of this paragraph said `CREATE INDEX` takes `SHARE`, so it blocks writes and not
-- reads. That is true of the statement and false of the migration, and measuring both probes rather
-- than one is what caught it: **the `ALTER TABLE` above already took `ACCESS EXCLUSIVE`, and a lock
-- is held to COMMIT, so every statement after it inherits a read stall whatever its own lock mode
-- says.** In every run below the worst read block and the worst write block are within 3 ms of each
-- other and both track the migration's total time. **The unit that matters is how long the
-- transaction runs, not which lock each statement takes** — which is why removing the backfill is
-- the whole fix and changing a lock mode would have been no fix at all.
--
-- Measured on this repository's own container (`postgres:17`), one reader running `latestIssuance`'s
-- exact query and one writer inserting, both polled as fast as they will go across the migration:
--
--     rows     version   migration   worst read block   worst write block
--     200,000  backfill     2427 ms            2424 ms             2423 ms
--     200,000  this          154 ms             153 ms              152 ms
--     400,000  backfill     6186 ms            6181 ms             6184 ms
--     400,000  this          309 ms             305 ms              304 ms
--
-- The backfill grows worse than linearly (2.5x the time for 2x the rows); what is left grows
-- linearly, because it is the index build, and it is about 16x smaller at 200,000 and 20x at
-- 400,000. **It is still unbounded, and that is stated rather than left for the deploy to find**: at
-- ten million rows the same slope puts it near eight seconds. Closing it needs `CREATE INDEX
-- CONCURRENTLY`, which cannot run inside a transaction, and this runner gives every migration one —
-- so it needs a runner that can take a migration outside its transaction, which is **SONNY-370**'s
-- and not this file's. The number is here so that decision has one before a deploy rather than
-- after.

ALTER TABLE sonny.sign_in_code_issue
  ADD COLUMN issue_seq bigint NOT NULL DEFAULT 0;

-- The default has to go before the identity can be attached — `ADD GENERATED` refuses a column that
-- already has one — and both statements are catalog-only. Existing rows keep the 0 the default
-- already gave them; `DROP DEFAULT` does not revisit a row.
ALTER TABLE sonny.sign_in_code_issue ALTER COLUMN issue_seq DROP DEFAULT;

ALTER TABLE sonny.sign_in_code_issue
  ALTER COLUMN issue_seq ADD GENERATED ALWAYS AS IDENTITY;

COMMENT ON COLUMN sonny.sign_in_code_issue.issue_seq IS
  'Issuance order, and the only thing that decides which code at a mailbox is the latest one '
  '(SONNY-353). issued_at is not unique and two codes sharing an instant have no defined newest, '
  'which makes both "which code does a verify redeem" and "which of the three failures is '
  'disclosed" depend on the query plan. GENERATED ALWAYS: application code may not write it, and '
  'the sequence starts at 1. 0 is therefore a sentinel no new row can carry, and it means "written '
  'before this column existed" — those rows sort below every later one, correctly, and tie with '
  'each other, which is the ordering they already had. Per mailbox this is exactly issuance order, '
  'because issueCode holds an advisory lock on the mailbox across its invalidate-and-insert.';

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
