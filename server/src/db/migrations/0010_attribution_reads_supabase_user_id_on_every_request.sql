-- 0010 — `supabase_user_id` gets an index, because SONNY-203 made it a per-request lookup.
--
-- **Nothing was wrong with this column until the gate landed; what changed is how often it is read.**
-- `accountForSupabaseUser` filters on `i.supabase_user_id`, and before SONNY-203 that ran on
-- `POST /v1/auth/refresh` (roughly once an hour per user) and once inside `DELETE /v1/account`. The
-- authenticated-route gate now runs it on **every request to every protected route**, before the
-- handler starts. So the cost of an unindexed predicate moved from "twice a session" to "always",
-- and the migration belongs to the branch that moved it rather than to whoever meets it later.
--
-- **Measured rather than assumed** (PR #104's adversarial review, F4). At 20,000 identities,
-- `EXPLAIN (ANALYZE, BUFFERS)` on the exact query reported `Seq Scan on identity`,
-- `Rows Removed by Filter: 19999`, `Buffers: shared hit=530`, `Execution Time: 2.680 ms`, and 200
-- sequential executions averaged 2.39 ms each. The five existing indexes cover `id`, `account_id`,
-- `lower(email_hint)`, `(provider, subject)` and the revocation-owed partial — none of them covers
-- this column, so every authenticated request read the whole table and evicted shared buffers doing
-- it. At 200,000 identities that is roughly 24 ms and about 5,300 buffer touches before any handler
-- runs.
--
-- **Not unique, deliberately.** `supabase_user_id` carries no uniqueness constraint and never can:
-- the identity design lets several identities name one Supabase user, which is what makes two
-- `auth.users` rows resolve to one account. `accountForSupabaseUser` is built for that — it asks for
-- two rows and refuses on two rather than tiebreaking. A unique index here would reject the writes
-- the model exists to allow.
--
-- **Not partial, either.** The obvious narrowing is `WHERE supabase_user_id IS NOT NULL`, and it
-- would be a smaller index; it is left out because the query's own predicate does not mention
-- nullness, so the planner would have to prove the exclusion from `= $1` — which it does, but the
-- saving is one page on a column that is populated for every row a sign-in creates. A plain index on
-- the column the query names is the one a reader can check against the query without thinking.

CREATE INDEX identity_supabase_user_idx ON sonny.identity (supabase_user_id);

-- @rollback
DROP INDEX IF EXISTS sonny.identity_supabase_user_idx;
