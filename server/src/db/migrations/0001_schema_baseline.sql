-- 0001 — the baseline this row builds on.
--
-- Deliberately small. SONNY-126 is the foundation ticket and owns no domain tables: accounts are
-- SONNY-127's, entitlements and the spend cap are SONNY-135's, retention is SONNY-134's. What this
-- migration establishes is the one thing every later migration needs to exist first — a schema to
-- migrate, and a demonstration that the forward and rollback halves of this runner actually work
-- against a real Postgres.
--
-- `sonny` rather than `public`: Supabase's `public` schema already carries objects its own tooling
-- manages, and mixing this row's tables into it makes "what does the gateway own" unanswerable
-- later. Under the 2026-08-21 decision Postgres stays on Supabase, so this matters.

CREATE SCHEMA IF NOT EXISTS sonny;

COMMENT ON SCHEMA sonny IS
  'Tables owned by the Sonny gateway. Created by server/src/db/migrations, never by hand.';

-- @rollback
DROP SCHEMA IF EXISTS sonny CASCADE;
