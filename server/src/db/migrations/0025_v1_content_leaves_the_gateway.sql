-- @locks ACCESS EXCLUSIVE sonny.content_access, ACCESS EXCLUSIVE sonny.content_deletion, ACCESS EXCLUSIVE sonny.credit_topup, ACCESS EXCLUSIVE sonny.retained_content, ACCESS EXCLUSIVE sonny.training_snapshot, ACCESS EXCLUSIVE sonny.training_snapshot_member
-- @scans sonny.training_snapshot_member

-- 0025 — V1's content store leaves the gateway (docs/sonny-v2-implementation-plan.md, phase 7).
--
-- V2 keeps a task's transcript in agent_task and agent_message (0024) and nothing else: the V1
-- content store, its training snapshots, and its deletion and access audit go, with every row in
-- them (decision 1: nothing is migrated). Credits are spent by tokens now (decision 8), so a top-up
-- no longer records how many screen-control runs were left when it was triggered.

DROP INDEX IF EXISTS sonny.content_access_occurred_idx;
DROP TABLE IF EXISTS sonny.content_access;
DROP INDEX IF EXISTS sonny.content_deletion_account_idx;
DROP INDEX IF EXISTS sonny.content_deletion_occurred_idx;
DROP TABLE IF EXISTS sonny.content_deletion;
DROP TRIGGER IF EXISTS training_snapshot_member_consent ON sonny.training_snapshot_member;
DROP FUNCTION IF EXISTS sonny.training_snapshot_member_requires_consent();
DROP INDEX IF EXISTS sonny.training_snapshot_member_content_idx;
DROP INDEX IF EXISTS sonny.training_snapshot_member_task_idx;
DROP TABLE IF EXISTS sonny.training_snapshot_member;
DROP TABLE IF EXISTS sonny.training_snapshot;
DROP INDEX IF EXISTS sonny.retained_content_occurred_idx;
DROP INDEX IF EXISTS sonny.retained_content_expires_idx;
DROP INDEX IF EXISTS sonny.retained_content_account_task_idx;
DROP TABLE IF EXISTS sonny.retained_content;

ALTER TABLE sonny.credit_topup DROP COLUMN runs_left_at_trigger;

-- @rollback
-- @locks ACCESS EXCLUSIVE sonny.credit_topup
-- @scans none
-- The tables come back empty, in the shape 0013, 0020 and 0021 left them.

CREATE TABLE sonny.retained_content (
  content_id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  request_id             text        NOT NULL UNIQUE,

  account_id             uuid        NOT NULL,
  task_id                text,
  session_id             text,
  session_iteration      integer,

  route                  text        NOT NULL
                           CHECK (route IN ('plan', 'research.synthesize', 'transcription',
                                            'search', 'screen.analyze')),

  occurred_at            timestamptz NOT NULL DEFAULT now(),

  expires_at             timestamptz NOT NULL,

  retention              text        NOT NULL
                           CHECK (retention = 'standard'),

  provider               text,
  provider_request_id    text,


  request_text           jsonb,

  voice_audio            bytea,
  voice_audio_media_type text,
  voice_audio_filename   text,

  screenshot             bytea,
  screenshot_media_type  text,

  response_status        integer,
  response_content_type  text,
  response_body          bytea,

  provider_error_status  integer,
  provider_error_body    text
);

COMMENT ON TABLE sonny.retained_content IS
  'Contract section 10. Full request and response content per call - request text, voice audio, '
  'redacted screenshots, the served response, and provider error bodies - on the 30-day content '
  'clock. Cannot hold an incognito run: the retention CHECK admits one value. Written by '
  'server/src/content; read by the snapshot builder and npm run support.';

COMMENT ON COLUMN sonny.retained_content.voice_audio IS
  'Voice audio from POST /v1/transcriptions. Named explicitly because section 10.3 requires it to '
  'be: the most personally sensitive of the four content types and the one most likely to be '
  'overlooked because nobody listed it.';

CREATE INDEX retained_content_account_task_idx
  ON sonny.retained_content (account_id, task_id);

CREATE INDEX retained_content_expires_idx
  ON sonny.retained_content (expires_at);

CREATE INDEX retained_content_occurred_idx
  ON sonny.retained_content (occurred_at);


CREATE TABLE sonny.training_snapshot (
  snapshot_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  label             text        NOT NULL UNIQUE,

  created_at        timestamptz NOT NULL DEFAULT now(),

  sealed_at         timestamptz,

  expires_at        timestamptz,

  window_start      timestamptz,
  window_end        timestamptz,
  routes            text[]      NOT NULL DEFAULT '{}',

  consent_basis     text        NOT NULL DEFAULT 'account.training_consent granted at build time',

  builder_version   text        NOT NULL,
  member_count      integer     NOT NULL DEFAULT 0
);

COMMENT ON TABLE sonny.training_snapshot IS
  'Contract section 10.3. The documented snapshots training reads from - never the live store - so '
  'that a deletion request is traceable to the snapshots it touched. expires_at is nullable because '
  'no founder has set a snapshot lifecycle; NULL means none is set, not "never expires by policy".';

CREATE TABLE sonny.training_snapshot_member (
  snapshot_id            uuid        NOT NULL
                           REFERENCES sonny.training_snapshot(snapshot_id) ON DELETE CASCADE,

  content_id             uuid        NOT NULL,

  account_id             uuid        NOT NULL,
  task_id                text,
  request_id             text        NOT NULL,
  route                  text        NOT NULL,
  source_occurred_at     timestamptz NOT NULL,
  added_at               timestamptz NOT NULL DEFAULT now(),

  request_text           jsonb,
  voice_audio            bytea,
  voice_audio_media_type text,
  voice_audio_filename   text,
  screenshot             bytea,
  screenshot_media_type  text,
  response_status        integer,
  response_content_type  text,
  response_body          bytea,
  provider_error_status  integer,
  provider_error_body    text,

  PRIMARY KEY (snapshot_id, content_id)
);

CREATE INDEX training_snapshot_member_task_idx
  ON sonny.training_snapshot_member (account_id, task_id);
CREATE INDEX training_snapshot_member_content_idx
  ON sonny.training_snapshot_member (content_id);

CREATE OR REPLACE FUNCTION sonny.training_snapshot_member_requires_consent()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM sonny.account
     WHERE id = NEW.account_id AND training_consent AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION
      'account % has not granted training consent, or is closed; it cannot enter a training snapshot',
      NEW.account_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER training_snapshot_member_consent
  BEFORE INSERT ON sonny.training_snapshot_member
  FOR EACH ROW EXECUTE FUNCTION sonny.training_snapshot_member_requires_consent();


CREATE TABLE sonny.content_deletion (
  deletion_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at       timestamptz NOT NULL DEFAULT now(),

  reason            text        NOT NULL
                      CHECK (reason IN ('task', 'account', 'expiry', 'snapshot_expiry')),

  account_id        uuid,
  task_id           text,

  content_rows      integer     NOT NULL DEFAULT 0,
  snapshot_rows     integer     NOT NULL DEFAULT 0,
  snapshots_touched uuid[]      NOT NULL DEFAULT '{}',

  stored_responses  integer     NOT NULL DEFAULT 0
);

COMMENT ON TABLE sonny.content_deletion IS
  'Contract sections 4.6 and 10.3. One row per deletion - a task delete, an account delete, a '
  'content expiry sweep, a snapshot expiry - naming what went and which training snapshots it '
  'reached. Holds no content.';

CREATE INDEX content_deletion_occurred_idx ON sonny.content_deletion (occurred_at DESC);
CREATE INDEX content_deletion_account_idx ON sonny.content_deletion (account_id, occurred_at DESC);


CREATE TABLE sonny.content_access (
  access_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  operator     text        NOT NULL,
  reason       text        NOT NULL,
  account_id   uuid,
  request_id   text        NOT NULL,
  found        boolean     NOT NULL
);

COMMENT ON TABLE sonny.content_access IS
  'Who read retained content through npm run support, and why. A trace rather than a boundary: '
  'anyone holding DATABASE_URL reads the same rows from psql and leaves nothing here.';

CREATE INDEX content_access_occurred_idx ON sonny.content_access (occurred_at DESC);

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'task_screenshots', 'account', 'expiry', 'snapshot_expiry'));

ALTER TABLE sonny.content_deletion
  ADD COLUMN screenshots_cleared integer NOT NULL DEFAULT 0;

ALTER TABLE sonny.content_deletion
  ADD COLUMN snapshot_screenshots_cleared integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN sonny.content_deletion.screenshots_cleared IS
  'Live retained_content rows whose screenshot was set to NULL by DELETE /v1/tasks/{task_id}/'
  'screenshots. Counted apart from content_rows because no row was removed.';

COMMENT ON COLUMN sonny.content_deletion.snapshot_screenshots_cleared IS
  'Training snapshot member copies whose screenshot was set to NULL by the same route. Counted '
  'apart from snapshot_rows for the same reason.';

ALTER TABLE sonny.content_deletion
  DROP CONSTRAINT content_deletion_reason_check;

ALTER TABLE sonny.content_deletion
  ADD CONSTRAINT content_deletion_reason_check
  CHECK (reason IN ('task', 'task_screenshots', 'account', 'account_content',
                    'expiry', 'snapshot_expiry'));

ALTER TABLE sonny.credit_topup ADD COLUMN runs_left_at_trigger int NOT NULL DEFAULT 0;
ALTER TABLE sonny.credit_topup ALTER COLUMN runs_left_at_trigger DROP DEFAULT;
