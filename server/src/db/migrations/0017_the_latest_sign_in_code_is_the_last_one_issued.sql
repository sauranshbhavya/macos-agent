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
-- **So the queries order on `issue_seq DESC, issued_at DESC`, and the second key is required rather
-- than defensive** (PR #171 cycle 2, F1). The sentinel puts every post-migration row above every
-- pre-migration row, which is correct — all of them are newer. What it also does, on the sequence
-- alone, is collapse the ENTIRE pre-migration population into one tie.
--
-- **An earlier draft of this paragraph claimed that tie was "exactly the state this migration
-- inherits — what `ORDER BY issued_at DESC` already gave them". That was false, and false in the
-- direction that hides a regression.** The old ordering was undefined only for rows sharing an exact
-- `issued_at`; it was correct for every other pair, which is the ordinary case. Ordering on the
-- sequence alone is undefined for **every** inherited row. Measured: three rows at 12:00, 12:05 and
-- 12:09 return the newest on 20 of 20 runs before this migration, and the **oldest** after it. So
-- the migration whose whole subject is what "latest" means would have made `latestIssuance` worse
-- for exactly the population it exists to fix — on the query that reads `source_hash` and feeds the
-- disclosure gate.
--
-- With `issued_at DESC` behind it the inherited rows are ordered exactly as they were, the residual
-- is once again only the exact-tie case, and post-migration rows are untouched: their `issue_seq` is
-- distinct, so it decides before the second key is consulted — the clock-rewind case included.
--
-- **What that costs, stated so it is not discovered later.** Two things, both small and both real.
-- First, the exact-tie case among inherited rows is still undefined, and that genuinely is the state
-- this migration inherits. It closes on its own: a row is only reachable for anything but "nothing is
-- live here" while it is inside `CODE_LIFETIME_SECONDS` or `FAILURE_DISCLOSURE_SECONDS`, so it is
-- bounded by the codes issued in the twenty minutes before the migration ran, and every code issued
-- after it is ordered exactly.
--
-- **Second, a ROLLBACK-THEN-REAPPLY collapses order that had been recorded** (PR #171 cycle 2, F5).
-- The rollback drops the column, so re-applying gives every row then in the table the sentinel —
-- including rows that had carried real sequence numbers. Rows that were 4, 5, 6 come back 0, 0, 0.
-- With the second key they fall back to `issued_at`, so nothing is wrong for the ordinary case; what
-- is lost is the tie-breaking for rows sharing an instant, which had been recorded exactly and is
-- now gone. This is a property of the round trip rather than of either direction alone, and the
-- staging rule in `server/README.md` walks that path deliberately — so it belongs here rather than
-- being found by whoever rolls back.
--
-- **Two separate things decide a migration's read stall, and an earlier draft of this paragraph
-- collapsed them into one** (PR #171 cycle 2, F3):
--
--   * **The lock MODE decides WHETHER readers stall at all.** `ACCESS EXCLUSIVE` conflicts with
--     `ACCESS SHARE`, so it stalls them; `SHARE`, which `CREATE INDEX` takes, does not. Measured
--     by the reviewer on a `CREATE INDEX` alone in a transaction: **read 3 ms, write 284 ms.**
--   * **The transaction decides HOW LONG.** A lock is held to COMMIT, so once any statement has
--     taken a read-conflicting mode, the stall runs to the end of the migration rather than to the
--     end of that statement.
--
-- The draft said "every statement after it inherits a read stall whatever its own lock mode says",
-- which reads as *there is nothing to gain from a gentler lock mode*. That is exactly backwards: a
-- gentler mode is what buys readers their freedom, and it is the only thing that can. The reason
-- this migration stalls readers anyway is that it contains statements that take `ACCESS EXCLUSIVE` —
-- and the fix that mattered was making the transaction SHORT, because it could not make the mode
-- gentler.
--
-- **And do not use `ALTER TABLE` as the marker for "this migration stalls readers".** That proxy
-- fails in both directions and the reviewer measured the interesting one: a migration containing a
-- `DROP INDEX` and no `ALTER TABLE` at all blocked reads for **1005 ms of its 1007 ms**, because
-- `DROP INDEX` takes `ACCESS EXCLUSIVE` too. This file contains one.
--
-- Measured on this repository's own container (`postgres:17.11`), one reader running
-- `latestIssuance`'s exact query and one writer inserting, both polled as fast as they will go
-- across the migration. `index` is what `CREATE INDEX` had to build and `external` is whether it
-- exceeded `maintenance_work_mem` (64 MB here), which is the sort-regime boundary:
--
--     rows       version   index    external   migration   worst read   worst write
--     200,000    backfill  11 MB         no      1985 ms      1982 ms       1984 ms
--     200,000    this      11 MB         no       186 ms       184 ms        185 ms
--     400,000    backfill  23 MB         no      4194 ms      4191 ms       4193 ms
--     400,000    this      23 MB         no       475 ms       470 ms        469 ms
--   1,000,000    this      56 MB         no      1309 ms      1299 ms       1303 ms
--   2,000,000    this     113 MB        YES      2289 ms      2274 ms       2275 ms
--
-- (Every row re-measured at `a767c6e` after this branch rebased onto `85a78f9`. Nothing is carried:
-- `server/` moved twice under this branch, and the earlier readings — 2427/2424 and 213/212 at
-- 200,000 — were taken at heads a rebase has since orphaned. The `backfill` rows are the rejected
-- design, run here from its own commit's copy of this file so the comparison is against the same
-- tree as the row above it rather than against a memory of one.)
--
-- The backfill grew worse than linearly. What is left is the index build, and **it is still
-- unbounded**. An earlier draft put ten million rows "near eight seconds" by extrapolating from the
-- 200,000 and 400,000 points alone, and that number was wrong twice over (F2): those points sit
-- where scheduling noise is a large fraction of the signal, and — the part that makes it not an
-- extrapolation at all — **every one of them is an in-memory sort, while ten million rows is not.**
-- The boundary is crossed between 1,000,000 and 2,000,000 rows here, and the rows at which it is
-- crossed depend on `maintenance_work_mem`, which no document had said. The reviewer measured ten
-- million directly: **11.1 s.** The measured point past the boundary above is this file's own; the
-- ten-million figure is theirs and is cited rather than derived.
--
-- Closing it needs `CREATE INDEX CONCURRENTLY`, which cannot run inside a transaction, and this
-- runner gives every migration one — so it needs a runner that can take a migration outside its
-- transaction, which is **SONNY-370**'s and not this file's. The numbers are here so that decision
-- has them before a deploy rather than after.

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
    ON sonny.sign_in_code_issue (mailbox_key, issue_seq DESC, issued_at DESC);
DROP INDEX sonny.sign_in_code_issue_email_idx;

-- @rollback

-- The column and its sequence go, and the old index comes back. Nothing is lost that was not
-- already absent: `issued_at` is still on every row, and the queries that read it are back to
-- having no defined answer when two share an instant, which is where 0002 through 0016 stand.
CREATE INDEX sign_in_code_issue_email_idx
    ON sonny.sign_in_code_issue (mailbox_key, issued_at DESC);
DROP INDEX sonny.sign_in_code_issue_mailbox_seq_idx;
ALTER TABLE sonny.sign_in_code_issue DROP COLUMN issue_seq;
