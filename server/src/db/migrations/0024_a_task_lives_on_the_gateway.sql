-- @locks SHARE ROW EXCLUSIVE sonny.account
-- @scans sonny.account

-- 0024 — V2 tasks live on the gateway (docs/sonny-v2-implementation-plan.md, section 5).
--
-- A Mac holds one WebSocket session to the gateway. Each task it starts is a row of agent_task, and
-- every message of that task, in either direction, is a row of agent_message: that transcript is the
-- task's reasoning history, and it is what lets any gateway process resume a task after a restart or
-- a reconnect. Screenshots are never written here; they live in memory for the turn that reads them.
--
-- Retention: an ordinary task and its messages are deleted 30 days after the task ends. A private
-- task is deleted the moment it ends. agent_model_call is the billing record of each model call and
-- carries no foreign key to the task, so it outlives both.

CREATE TABLE sonny.device (
  id uuid PRIMARY KEY,
  account_id uuid NOT NULL REFERENCES sonny.account(id) ON DELETE CASCADE,
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX device_account_idx ON sonny.device (account_id);

CREATE TABLE sonny.agent_task (
  id uuid PRIMARY KEY,
  account_id uuid NOT NULL REFERENCES sonny.account(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES sonny.device(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('live', 'completed', 'failed', 'cancelled')),
  private boolean NOT NULL,
  unattended boolean NOT NULL,
  goal text NOT NULL,
  origin text NOT NULL,
  mode text NOT NULL,
  prior_task uuid,
  last_seq_in integer NOT NULL DEFAULT 0 CHECK (last_seq_in >= 0),
  last_seq_out integer NOT NULL DEFAULT 0 CHECK (last_seq_out >= 0),
  last_seq_note integer NOT NULL DEFAULT 0 CHECK (last_seq_note >= 0),
  turns integer NOT NULL DEFAULT 0 CHECK (turns >= 0),
  model_calls integer NOT NULL DEFAULT 0 CHECK (model_calls >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  CHECK ((status = 'live') = (ended_at IS NULL))
);

CREATE INDEX agent_task_account_idx ON sonny.agent_task (account_id);
CREATE INDEX agent_task_ended_idx ON sonny.agent_task (ended_at) WHERE ended_at IS NOT NULL;
CREATE INDEX agent_task_live_idx ON sonny.agent_task (updated_at) WHERE status = 'live';

CREATE TABLE sonny.agent_message (
  -- The order messages were stored in, across all three directions. seq counts one direction only.
  ord bigint GENERATED ALWAYS AS IDENTITY,
  task_id uuid NOT NULL REFERENCES sonny.agent_task(id) ON DELETE CASCADE,
  direction text NOT NULL CHECK (direction IN ('in', 'out', 'note')),
  seq integer NOT NULL CHECK (seq >= 1),
  re integer CHECK (re >= 1),
  msg_id uuid NOT NULL UNIQUE,
  type text NOT NULL,
  body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, direction, seq)
);

CREATE INDEX agent_message_order_idx ON sonny.agent_message (task_id, ord);

CREATE TABLE sonny.agent_model_call (
  step_id uuid PRIMARY KEY,
  account_id uuid NOT NULL,
  task_id uuid NOT NULL,
  agent text NOT NULL CHECK (agent IN ('planner', 'screen')),
  tier text NOT NULL CHECK (tier IN ('fast', 'standard', 'strong')),
  period_start timestamptz NOT NULL,
  status text NOT NULL CHECK (status IN ('held', 'settled', 'released')),
  credits_held numeric(20, 6) NOT NULL CHECK (credits_held >= 0),
  credits_charged numeric(20, 6) CHECK (credits_charged >= 0),
  spend_reservation_id uuid,
  provider text,
  model text,
  input_tokens integer CHECK (input_tokens >= 0),
  output_tokens integer CHECK (output_tokens >= 0),
  outcome text CHECK (outcome IN ('ok', 'provider_error', 'cancelled', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz,
  CHECK ((status = 'held') = (settled_at IS NULL))
);

CREATE INDEX agent_model_call_account_period_idx
  ON sonny.agent_model_call (account_id, period_start);
CREATE INDEX agent_model_call_held_idx ON sonny.agent_model_call (created_at) WHERE status = 'held';

-- @rollback
-- @locks ACCESS EXCLUSIVE sonny.account, ACCESS EXCLUSIVE sonny.agent_message, ACCESS EXCLUSIVE sonny.agent_message_ord_seq, ACCESS EXCLUSIVE sonny.agent_model_call, ACCESS EXCLUSIVE sonny.agent_task, ACCESS EXCLUSIVE sonny.device
-- @scans none

DROP TABLE IF EXISTS sonny.agent_model_call;
DROP TABLE IF EXISTS sonny.agent_message;
DROP TABLE IF EXISTS sonny.agent_task;
DROP TABLE IF EXISTS sonny.device;
