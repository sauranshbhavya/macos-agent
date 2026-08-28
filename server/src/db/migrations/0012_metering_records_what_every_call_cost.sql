-- 0012 — what every call cost, per account, per call (SONNY-133). Contract §11.
--
-- **This table is the measurement, and it is never the price.** SONNY-17 sets the credit weight and
-- the paid line from figures read out of here; nothing in this file, in `src/metering/` or in
-- `npm run usage` holds a price, a plan, a tier or a credit weight, and nothing should acquire one.
-- The column list below is tokens, bytes, pixels, milliseconds and outcomes — quantities a provider
-- or a clock produced — and the one thing that turns those into money lives on a different ticket.
--
-- **It holds no content, and that is what lets it outlive content.** §10.3 runs two clocks on
-- purpose: raw request and response content on the short one (30 days, SONNY-134's), derived metrics
-- and usage indefinitely. A single content column here would put this table on the short clock by
-- accident, so there is none — no prompt, no message, no transcript, no image, no provider error
-- body. `theMeteringTableHoldsNoContentColumn` asserts the whole column set rather than a sample, so
-- adding one fails a test rather than a review.
--
-- **`account_id` is a scope and not a foreign key**, for 0011's reason and one more of its own.
-- 0011's: the cascade that comes with `REFERENCES sonny.account(id)` would delete exactly what the
-- table exists to keep. This table's own: deletion of an account is a *state* here (`deleted_at`,
-- 0002) rather than a `DELETE`, so a FK would not fire today — and the day someone removes a row by
-- hand, the record of what that account spent is the last thing that should go with it. §11 names
-- this field `user_id`; the column is `account_id` because §5 makes the account the billable
-- identity and one person can hold two Supabase users on one account. The contract's §11 carries a
-- dated note saying so.
--
-- **There is no unique constraint on (account_id, idempotency_key), deliberately.** Contract §9.2's
-- "at most once per idempotency key, ever" is kept by `claimMeteringEvent` in
-- `src/idempotency/store.ts`, taken inside the same transaction as the insert below. SONNY-300's
-- hand-over says it in one line — "two things that both believe they enforce 'at most once' is how
-- it ends up enforced by neither" — and a second enforcement point here would change the failure
-- shape rather than add safety: a unique violation aborts the transaction, which rolls the claim
-- back with it, and the next retry would then be free to write the event the constraint just
-- refused. `theSameKeyCannotWriteTwoEventsUnderConcurrency` drives the real thing instead.
--
-- **Three columns are nullable that §11 writes as plain `int`, and each null means something.**
-- `upstream_duration_ms` is NULL when no upstream call was made at all — a validation refusal, an
-- oversize capture, a route with no configured adapter — where `0` would read as a provider that
-- answered instantly. `request_bytes` is NULL when the request declared no `Content-Length`; every
-- client this gateway serves declares one, and nothing here decodes a `Content-Encoding`, so the
-- declared length is the decoded size §11 asks for. `response_bytes` is NULL when the payload was
-- neither a string nor a Buffer, which no route produces today — the same distinction
-- `src/idempotency/hook.ts` already makes about a payload it cannot store.
--
-- `retention` is nullable for a fourth reason worth separating from those three: a request refused
-- before its body was read never declared one. It is NOT NULL in spirit and every served call has
-- it, which is what §10.1's "metering runs either way" needs — an incognito run is metered
-- identically and its event says `none` where the content store will hold nothing.

CREATE TABLE sonny.metering_event (
  event_id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- §2.3's `Sonny-Request-Id`, the join key between an error a user quotes, this event, and the
  -- content SONNY-134 retains. Not unique: a replayed response carries the *original's* id
  -- (0011's header says why), and the original is the one that wrote the event.
  request_id             text        NOT NULL,

  -- The client's `Idempotency-Key`, or NULL for a POST that carried none. A keyless request is
  -- served by founder decision of 2026-08-28 and is metered anyway — dropping the event would make
  -- it free — but it has no at-most-once guarantee available to it, because there is no key for one
  -- to be about. NULL is that fact, recorded rather than inferred.
  idempotency_key        text,

  -- §11's `user_id`. See the header: the account is the billable identity, not the Supabase user.
  account_id             uuid        NOT NULL,

  occurred_at            timestamptz NOT NULL DEFAULT now(),

  -- §11's route enum, exactly. `transcription` is singular where the path is `/v1/transcriptions`,
  -- matching §11 and matching what `recordServingProvider` already logs.
  route                  text        NOT NULL
                           CHECK (route IN ('plan', 'research.synthesize', 'transcription',
                                            'search', 'screen.analyze')),

  -- Which provider actually served it (SONNY-132), and which were tried and could not. NULL and
  -- empty respectively when no upstream call was made. **Never returned to the client** — §4.2:
  -- "The response names no provider and no model."
  provider               text,
  failed_over            text[]      NOT NULL DEFAULT '{}',
  model                  text,

  input_tokens           integer,
  output_tokens          integer,
  total_tokens           integer,
  -- §4.2's `usage.source`, mirroring `AIUsageTokenSource` on the Mac. NULL when the provider
  -- reported nothing and this gateway estimated nothing either, which is the vision route's normal
  -- state: `src/model/vision.ts` deliberately sends no estimate there, because the dominant term is
  -- an image and a text-only estimate would omit most of the cost. A missing token count is
  -- therefore never zero, and pricing that route reads the pixel columns below instead.
  token_source           text        CHECK (token_source IN ('reported', 'estimated')),

  -- `screen.analyze` only. Bytes are what left the Mac; **pixels are what the cost tracks** (§4.5
  -- rule 3), which is why both are here and why the dimensions are on the wire at all.
  image_bytes            integer,
  image_pixel_width      integer,
  image_pixel_height     integer,
  -- Which of the two formats `RedactedCaptureEncoder` picked for this capture. Not in §11's table;
  -- kept because roughly half of real captures are each, and the byte figure beside it cannot be
  -- read without knowing which — the same reason §4.5 rule 2 puts the media type on the wire.
  image_media_type       text,

  -- `transcription` only. Maps to `AIUsageRecord.audioDurationSeconds`.
  audio_duration_seconds double precision,

  request_bytes          integer,
  response_bytes         integer,
  duration_ms            integer     NOT NULL,
  upstream_duration_ms   integer,

  -- §11's five. SONNY-131's proposal named four — `served`, `client_cancelled`, `provider_failed`,
  -- `refused_before_upstream` — and every one of them maps onto a value below without loss:
  -- `ok`, `client_cancelled`, `provider_error`, `refused`. §11's spelling wins because it is the
  -- contract twelve tickets were written against, and `server_error` is the fifth that the
  -- proposal's four did not cover — this gateway's own bug, which is neither a provider's failure
  -- nor a refusal. What the proposal's `refused_before_upstream` insisted on survives in full and is
  -- the reason `refused` and `provider_error` are separate: a 413 over the image ceiling, a 400 on
  -- validation and a 502 with no configured adapter all happen before anything is spent, and an
  -- event that could not tell them from a failed provider call would bill for a request that never
  -- left the gateway. `outcomeFor` in `src/metering/event.ts` is that mapping, and it is keyed on
  -- the error `code` rather than on a status, which is §9.3's own rule.
  outcome                text        NOT NULL
                           CHECK (outcome IN ('ok', 'provider_error', 'server_error',
                                              'refused', 'client_cancelled')),

  -- §5.1 and §5.2. Client-minted keys, opaque here. `session_id` is what makes "what did that
  -- screen-control session cost" a GROUP BY rather than a second event shape: the gateway holds no
  -- session state (§4.5 rule 5), twelve iterations are twelve upstream calls with twelve costs, and
  -- the last iteration does not know it is the last.
  task_id                text,
  session_id             text,
  session_iteration      integer,

  -- §10.1. Recorded so an incognito run's *usage* is visible while its content is not.
  retention              text        CHECK (retention IN ('standard', 'none')),

  -- §2.2's `Sonny-Client-Version`. Caller-controlled, so it is bounded before it is written
  -- (`src/metering/hook.ts`) rather than by a column type.
  client_version         text
);

COMMENT ON TABLE sonny.metering_event IS
  'Contract section 11. What every call cost, per account. Holds no content, so it outlives content '
  'on the longer of section 10.3''s two clocks. Written by server/src/metering; read by '
  'npm run usage. Carries no price, no plan and no credit weight - those are SONNY-17''s.';

-- The two queries this table actually has. An index for a query nobody makes is a write cost on
-- every metered request with no reader, so `request_id` and `task_id` get none until the support
-- lookup and the task delete (SONNY-134) exist to make them.
--
-- Every founder query starts from an account and a time window.
CREATE INDEX metering_event_account_occurred_idx
  ON sonny.metering_event (account_id, occurred_at DESC);

-- The per-session rollup SONNY-17's credit weight is the sum of. Partial, because only
-- `screen.analyze` carries a session and the other four routes have no reason to be in it — the
-- same call 0011 made about its own partial index, and for the same reason: the query's predicate
-- names the nullness.
CREATE INDEX metering_event_session_idx
  ON sonny.metering_event (session_id, occurred_at)
  WHERE session_id IS NOT NULL;

-- @rollback
DROP INDEX IF EXISTS sonny.metering_event_session_idx;
DROP INDEX IF EXISTS sonny.metering_event_account_occurred_idx;
DROP TABLE IF EXISTS sonny.metering_event;
