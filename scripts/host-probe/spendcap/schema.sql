-- SONNY-125 requirement 3: the per-user spend cap, and what two racing requests do.
-- Throwaway probe schema. Not server/ and not a migration.

CREATE TABLE IF NOT EXISTS usage_period (
  user_id      uuid        NOT NULL,
  period_start date        NOT NULL,
  cap_credits  bigint      NOT NULL,
  spent        bigint      NOT NULL DEFAULT 0,   -- settled, from completed calls
  reserved     bigint      NOT NULL DEFAULT 0,   -- held by calls in flight
  PRIMARY KEY (user_id, period_start),
  CONSTRAINT never_over_cap CHECK (spent + reserved <= cap_credits)
);

-- A reservation is a row, not just a number, so a request the platform kills mid-flight can
-- be swept by its expiry instead of leaking cap forever. Requirement 2 is measuring exactly
-- the event that produces those orphans, so this is a real failure mode, not a theoretical one.
CREATE TABLE IF NOT EXISTS reservation (
  id           uuid PRIMARY KEY,
  user_id      uuid        NOT NULL,
  period_start date        NOT NULL,
  amount       bigint      NOT NULL,
  expires_at   timestamptz NOT NULL,
  settled      boolean     NOT NULL DEFAULT false
);

-- Reserve. ONE statement, and that is the whole mechanism.
--
-- Under READ COMMITTED (Postgres's default, and Supabase's) an UPDATE that meets a row a
-- concurrent transaction has just updated does not use the snapshot it started with: it waits
-- for that transaction, then re-evaluates its own WHERE against the NEW row version. So the
-- second of two racing requests tests `spent + reserved + amount <= cap` against a row that
-- already carries the first one's reservation. If it no longer fits, the row is skipped and
-- the statement returns no rows -- which is the refusal. No advisory lock, no SELECT ... FOR
-- UPDATE, no retry loop, and no read-then-write window for two requests to slip through.
CREATE OR REPLACE FUNCTION reserve(p_user uuid, p_period date, p_amount bigint, p_id uuid)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE new_reserved bigint;
BEGIN
  UPDATE usage_period
     SET reserved = reserved + p_amount
   WHERE user_id = p_user AND period_start = p_period
     AND spent + reserved + p_amount <= cap_credits
  RETURNING reserved INTO new_reserved;

  IF NOT FOUND THEN
    RETURN NULL;                      -- caller answers 402 before any provider is called
  END IF;

  INSERT INTO reservation (id, user_id, period_start, amount, expires_at)
  VALUES (p_id, p_user, p_period, p_amount, now() + interval '150 seconds');
  RETURN new_reserved;
END $$;

-- Settle: release the hold, charge what the call actually cost. Same transaction as the
-- metering event in the real gateway, so a charge cannot exist without its audit row.
CREATE OR REPLACE FUNCTION settle(p_id uuid, p_actual bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r reservation%ROWTYPE;
BEGIN
  UPDATE reservation SET settled = true WHERE id = p_id AND NOT settled RETURNING * INTO r;
  IF NOT FOUND THEN RETURN; END IF;   -- idempotent: a retried settle charges once
  UPDATE usage_period
     SET reserved = reserved - r.amount,
         spent    = spent + LEAST(p_actual, r.amount)
   WHERE user_id = r.user_id AND period_start = r.period_start;
END $$;

-- Sweep: reclaim holds whose request died before settling -- the platform-timeout case.
CREATE OR REPLACE FUNCTION sweep() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  WITH dead AS (
    UPDATE reservation SET settled = true
     WHERE NOT settled AND expires_at < now() RETURNING *
  ), released AS (
    UPDATE usage_period u SET reserved = u.reserved - d.amount
      FROM dead d WHERE u.user_id = d.user_id AND u.period_start = d.period_start
    RETURNING 1
  ) SELECT count(*) INTO n FROM released;
  RETURN n;
END $$;
