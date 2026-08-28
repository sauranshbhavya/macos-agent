-- 0013 — the content store, its clock, the snapshots training reads from, and the records that make
-- deletion traceable (SONNY-134). Contract §10.
--
-- **Five tables, and the four that are not the content store are what stop this from being a
-- retention design that only answers "what do we store and for how long".** The founder's decision
-- of 2026-08-16 is that the backend keeps full request and response content — redacted screenshots,
-- command text, model replies and voice audio — for debugging and support, product analytics, and
-- training. A store alone satisfies none of the three things that decision also requires: that the
-- content goes away on a clock, that a user can make it go away sooner and have that reach the
-- training set, and that an incognito run never arrives in the first place.
--
-- **The content clock is 30 days, confirmed by the founder on 2026-08-28** — the short end of the
-- 30–90 range the decision names, and the number contract §10.3, this ticket and 0012's own header
-- had all already assumed in prose while nothing had confirmed it. It is `CONTENT_RETENTION_DAYS`
-- in `src/config.ts`; `expires_at` below is written from it at insert rather than computed at read,
-- so a row carries the window it was stored under and changing the setting never retroactively
-- extends the life of content already held.
--
-- **The other clock is 0012's and nothing here touches it.** §10.3 runs two on purpose: raw content
-- on the short one, derived metrics and usage indefinitely. `sonny.metering_event` holds no content
-- for exactly that reason, and this migration adds no content column to it and no expiry over it.
-- The pair is what makes "what did that session cost" answerable a year after the screenshots are
-- gone.

-- ---------------------------------------------------------------------------------------------
-- The content store
-- ---------------------------------------------------------------------------------------------
--
-- **One row per call, and the row cannot exist for an incognito one.** `retention` carries a CHECK
-- that admits exactly one value, so `retention = 'none'` is not a row this table will hold — a
-- constraint violation rather than a stored secret. §10.1's first rule is that incognito is
-- "enforced where the storing happens, not at the call site", and this is where the storing
-- happens. `src/content/hook.ts` refuses first and never sends the insert; this is what is true
-- even when something above it is wrong.
--
-- **The column is written by the production insert, and it carries no DEFAULT** (corrected
-- 2026-08-28, PR #148's review, F3). Both halves matter and the first draft had neither: the writer
-- omitted the column and the column defaulted to `'standard'`, so every row was labelled storable
-- whatever the caller had asked for and **the CHECK could only ever refuse a hand-written statement
-- the running gateway cannot emit**. A wrong `isStorable` one layer up would have stored an
-- incognito call labelled `standard` and this constraint would have passed it — which is the
-- opposite of the sentence above. `src/content/store.ts` now binds the value the caller declared,
-- unnarrowed, so a wrong guard writes `'none'` and this refuses it; and with no DEFAULT, a writer
-- that forgets the column fails on NOT NULL rather than being quietly assumed storable. A default is
-- what let the first version go unnoticed, which is why there is not one.
--
-- **A missing `retention` is not a stored row either, and that is §2.4.2 rather than an extra
-- rule.** The field has no default on the wire: a request without it is a `400`, precisely so that
-- a client which forgets it neither silently stores content the user asked not to store nor
-- silently loses the retention the founder decided to have. The storage layer honours the same
-- rule by storing only what explicitly said `standard` — so a refused, unparseable or half-read
-- request contributes nothing here, while its metering event is written as usual.
--
-- **`account_id` is a scope and not a foreign key, exactly as 0011 and 0012 chose.** A cascade from
-- `sonny.account` would fire on a hand-deletion of the row and take the content with it silently;
-- deletion here is a path with a record (`sonny.content_deletion` below), not a side effect of
-- someone removing a row. Account closure is a state anyway (`deleted_at`, 0002), so a cascade
-- would not fire on the path that actually happens.

CREATE TABLE sonny.retained_content (
  content_id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- §2.3's `Sonny-Request-Id`. The join key between an error a user quotes, the metering event that
  -- says what the call cost, and the content it carried. **Unique here and deliberately not unique
  -- in 0012**: a replayed response carries the original's id and writes no content, because the
  -- handler did not run and there is no new content to keep.
  request_id             text        NOT NULL UNIQUE,

  account_id             uuid        NOT NULL,
  task_id                text,
  session_id             text,
  session_iteration      integer,

  route                  text        NOT NULL
                           CHECK (route IN ('plan', 'research.synthesize', 'transcription',
                                            'search', 'screen.analyze')),

  occurred_at            timestamptz NOT NULL DEFAULT now(),

  -- The content clock, written at insert. The sweep in `src/content/expiry.ts` is what makes it a
  -- deletion rather than a column: `content.db.test.ts` ages a row and watches it go.
  expires_at             timestamptz NOT NULL,

  -- The one value this column accepts, and no default. See the header.
  retention              text        NOT NULL
                           CHECK (retention = 'standard'),

  -- Which provider served, and the provider's own id for the call. §10.3: "Provider request IDs are
  -- kept for correlation" — this is that field, and it is the half of a provider error body that
  -- survives being unreadable.
  provider               text,
  provider_request_id    text,

  -- ## The content itself
  --
  -- Four kinds, each named rather than collapsed into one opaque blob, because the disclosure the
  -- founders owe on the website names four and a schema that named one would leave the mapping in
  -- somebody's head.

  -- The textual half of the request as the client sent it: the `messages` array on the two text
  -- routes, the `query` on search, the `prompt` on screen control. `jsonb` rather than `text` so
  -- the shape survives, since a training snapshot's consumer needs the roles.
  request_text           jsonb,

  -- **Voice audio, named explicitly.** §10.3: it is the most personally sensitive of the four types
  -- and the one most likely to be overlooked because nobody listed it. `POST /v1/transcriptions`
  -- carries `retention` like every other content route and its audio lands here, on this clock, and
  -- goes out with everything else when a task is deleted.
  voice_audio            bytea,
  voice_audio_media_type text,
  voice_audio_filename   text,

  -- The redacted capture `/v1/screen/analyze` sent. Redaction ran on the Mac before this left it
  -- (SONNY-89), and `RedactedPayload`'s initializer makes that structurally non-bypassable — which
  -- is a real mitigation and is why the stakes on redaction quality are higher under retention than
  -- they were without it. That consequence is SONNY-19's, recorded here because this is the column
  -- it is about.
  screenshot             bytea,
  screenshot_media_type  text,

  -- The response as it left this gateway, bytes and status. The model's reply is inside it. Kept as
  -- the served bytes rather than as a parsed field so that what is retained is what the user's Mac
  -- actually received, which is the thing a support question is about.
  response_status        integer,
  response_content_type  text,
  response_body          bytea,

  -- **A provider's error body is content and lands here, on this clock** (§10.3). An error body that
  -- echoes the input carries the user's own command back, and until this column existed the
  -- adapters' only safe option was to drop it unread — `openai.ts`, `anthropic.ts` and `vision.ts`
  -- each said so in a comment, and each was right that §7.1's `message` was the wrong home for it.
  -- A field nobody classified is the failure this closes: it is neither in a log outside the clock's
  -- reach nor thrown away, it is here with everything else the call carried.
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

-- Every deletion path starts from an account and most from a task under it.
CREATE INDEX retained_content_account_task_idx
  ON sonny.retained_content (account_id, task_id);

-- The sweep's own query, and the only index it needs.
CREATE INDEX retained_content_expires_idx
  ON sonny.retained_content (expires_at);

-- The snapshot builder walks a time window.
CREATE INDEX retained_content_occurred_idx
  ON sonny.retained_content (occurred_at);

-- ---------------------------------------------------------------------------------------------
-- Training snapshots, and the lineage that is the point of them
-- ---------------------------------------------------------------------------------------------
--
-- **Training reads from here and never from the live store, and the reason is the deletion path
-- rather than tidiness.** §10.3 and row 12's plan §4.2 consequence 3: a deletion request has to be
-- traceable to which snapshots it touched, and that "cannot be retrofitted once data has been
-- trained on". A snapshot that were merely a query over `sonny.retained_content` would leave
-- nothing to trace — after the content is deleted there would be no record that it had ever been
-- selected, and no way to answer which training set a deleted task reached.
--
-- **So a member carries a copy, not a pointer.** The live store is on a 30-day clock and a snapshot
-- is on its own, so a pointer would break the moment content expired — training would silently lose
-- rows and the two clocks §10.3 separates would collapse back into one. `content_id` is recorded
-- beside the copy as lineage, and is deliberately **not** a foreign key: `ON DELETE CASCADE` would
-- make ordinary content expiry silently empty a sealed snapshot, and `RESTRICT` would make expiry
-- fail. What it is instead is a value that keeps naming its source after the source is gone.

CREATE TABLE sonny.training_snapshot (
  snapshot_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- **Documented, in §10.3's sense**: a snapshot is named, and the name is what a training run and a
  -- deletion report both quote. Unique so two builds cannot answer to one name.
  label             text        NOT NULL UNIQUE,

  created_at        timestamptz NOT NULL DEFAULT now(),

  -- Set when the build finishes. A snapshot with this NULL is mid-build or abandoned, and is not
  -- something to train from.
  sealed_at         timestamptz,

  -- **Nullable, and the null is the honest value rather than a missing feature.** §10.3 puts
  -- snapshots on "their own separately-consented lifecycle" and names no number, and no founder has
  -- set one. A default here would be a decision taken in the wrong place that reads afterwards as
  -- one that was made. NULL means no expiry has been set; `sweepExpiredSnapshots` skips those rows
  -- rather than inventing a window for them.
  expires_at        timestamptz,

  -- What selected the rows, so the snapshot documents itself. A reader a year later can see the
  -- window and the routes without reconstructing them from the membership.
  window_start      timestamptz,
  window_end        timestamptz,
  routes            text[]      NOT NULL DEFAULT '{}',

  -- The consent this snapshot was built under, in words, beside the mechanism that enforced it.
  -- §10.2's field is a boolean in this tree and a pair of strings in the contract; this column names
  -- the basis rather than restating either spelling.
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

  -- Lineage. Names the `sonny.retained_content` row this was copied from, and keeps naming it after
  -- that row is deleted or expires. Not a foreign key; see this section's header.
  content_id             uuid        NOT NULL,

  account_id             uuid        NOT NULL,
  task_id                text,
  request_id             text        NOT NULL,
  route                  text        NOT NULL,
  source_occurred_at     timestamptz NOT NULL,
  added_at               timestamptz NOT NULL DEFAULT now(),

  -- The copy. Same four kinds as the live store, same names, so a reader does not have to work out
  -- which column corresponds to which.
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

-- Both deletion paths reach members by these, and neither can afford a sequential scan over a
-- snapshot while a user waits for a delete to answer.
CREATE INDEX training_snapshot_member_task_idx
  ON sonny.training_snapshot_member (account_id, task_id);
CREATE INDEX training_snapshot_member_content_idx
  ON sonny.training_snapshot_member (content_id);

-- **Consent enforced by the database and not only by the builder's WHERE clause.**
--
-- The builder joins `sonny.account` and requires `training_consent`, which is the mechanism §10.2
-- asks for. This trigger is the second one, and it exists because of what the first one costs when
-- it is wrong: training on the content of a user who did not consent is not a bug that can be fixed
-- afterwards. A row that reaches this table without consent is refused rather than inserted, so a
-- builder that lost its join — or a hand-written INSERT during an incident — fails loudly.
--
-- A closed account is refused too. Its content is being deleted; adding it to a training set on the
-- way out would be the opposite of what closing an account means.
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

-- ---------------------------------------------------------------------------------------------
-- What was deleted, and what it touched
-- ---------------------------------------------------------------------------------------------
--
-- **This is the table that makes two separate requirements answerable, and both of them are about
-- being able to say what happened rather than to believe it did.**
--
-- - §10.3's clock has to "actually run and be observable, not be a column nobody enforces". A sweep
--   writes a row here, so "did expiry run, and what did it take" is a query rather than a log grep.
-- - §4.6's delete-by-task has to be "traceable to which snapshots it touched". `snapshots_touched`
--   is that trace, and it is why the lineage above is worth carrying.
--
-- It holds no content. `task_id` is a client-minted opaque identifier and lives here on the same
-- footing it lives on the metering event: it is what a deletion is *about*, and a record of a
-- deletion that could not name what was deleted would not be one.

CREATE TABLE sonny.content_deletion (
  deletion_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at       timestamptz NOT NULL DEFAULT now(),

  -- `task` is the user pressing delete on one task, `account` is `DELETE /v1/account`, `expiry` is
  -- the content clock coming round, `snapshot_expiry` is a snapshot reaching its own.
  reason            text        NOT NULL
                      CHECK (reason IN ('task', 'account', 'expiry', 'snapshot_expiry')),

  -- NULL on an expiry sweep, which spans accounts by construction.
  account_id        uuid,
  task_id           text,

  content_rows      integer     NOT NULL DEFAULT 0,
  snapshot_rows     integer     NOT NULL DEFAULT 0,
  snapshots_touched uuid[]      NOT NULL DEFAULT '{}',

  -- Cleared idempotency response payloads, for the account path (SONNY-319). Counted separately
  -- because it is a different table with a different clock, and a wipe that says "3 rows" without
  -- saying which three things it reached is the kind of record that gets misread later.
  stored_responses  integer     NOT NULL DEFAULT 0
);

COMMENT ON TABLE sonny.content_deletion IS
  'Contract sections 4.6 and 10.3. One row per deletion - a task delete, an account delete, a '
  'content expiry sweep, a snapshot expiry - naming what went and which training snapshots it '
  'reached. Holds no content.';

CREATE INDEX content_deletion_occurred_idx ON sonny.content_deletion (occurred_at DESC);
CREATE INDEX content_deletion_account_idx ON sonny.content_deletion (account_id, occurred_at DESC);

-- ---------------------------------------------------------------------------------------------
-- Who read content, and why
-- ---------------------------------------------------------------------------------------------
--
-- **Decided on this ticket, 2026-08-28, rather than left to whoever has database access** — which
-- is requirement 9's own wording. `npm run support` reads a user's account state and recent usage
-- freely, and reaches content only through a command that refuses to run without an operator and a
-- reason and writes a row here before it prints anything.
--
-- **It is a discipline and a trace, not a boundary, and the difference is stated rather than
-- implied.** Everyone who can run the command also holds `DATABASE_URL`, and `psql` reads the same
-- bytes with no row here at all. What this buys today is that a lookup made through the product
-- leaves a record; what it buys later is that the control already exists on the day a support
-- surface is something other than a founder's terminal. Claiming more than that would be the
-- failure this table exists to avoid.

CREATE TABLE sonny.content_access (
  access_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  operator     text        NOT NULL,
  reason       text        NOT NULL,
  account_id   uuid,
  request_id   text        NOT NULL,
  -- Whether there was anything to show. A lookup that found nothing is still a lookup that was
  -- made, and a log that recorded only the hits would understate what was looked for.
  found        boolean     NOT NULL
);

COMMENT ON TABLE sonny.content_access IS
  'Who read retained content through npm run support, and why. A trace rather than a boundary: '
  'anyone holding DATABASE_URL reads the same rows from psql and leaves nothing here.';

CREATE INDEX content_access_occurred_idx ON sonny.content_access (occurred_at DESC);

-- @rollback
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
