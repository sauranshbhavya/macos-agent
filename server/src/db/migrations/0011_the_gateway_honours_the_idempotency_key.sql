-- 0011 — the key store contract §9.2's three guarantees are kept in (SONNY-300).
--
-- **One row per (scope, key), and it outlives the response it holds.** Two clocks run over this
-- table and they are deliberately different lengths, which is the same shape §10.3 already gives
-- content and usage. `response_expires_at` is §9.2's twenty-four hours: past it the stored response
-- is no longer replayed. The *row* has no expiry at all, because `metering_claimed_at` is what makes
-- §9.2's "a metering event is written at most once per idempotency key, **ever**" true, and a row
-- deleted at twenty-four hours would hand that same key a second metering event on day two. Pruning
-- therefore clears the payload and keeps the claim; `pruneExpiredResponses` in
-- `src/idempotency/store.ts` is that operation, and nothing here deletes a row.
--
-- **`account_scope` is a scope and not a foreign key, and both halves of that are deliberate.**
-- Scoping to the caller's account is what stops one account's key from colliding with — or worse,
-- replaying — another's: a key is a client-minted UUID, so a collision is negligible by accident and
-- entirely reachable on purpose, and a global key space would let a caller learn that some other
-- caller's key exists by the 409 it gets back. There is no `REFERENCES sonny.account(id)` because
-- the cascade that comes with one would delete the metering claims of a closed account, which is the
-- one thing this table exists to keep; the row holds no name, address or content of its own beyond
-- the stored response, and `deleteStoredResponsesForAccount` is how that half is removed.
--
-- **The nil UUID is the unauthenticated scope.** `sonny.account.id` is `gen_random_uuid()` (0002),
-- which is v4 and cannot produce `00000000-0000-0000-0000-000000000000`, so the sentinel can never
-- collide with a real account. It is a sentinel rather than a nullable column because NULL is not
-- comparable in a primary key — two unauthenticated rows carrying the same key would both be
-- accepted, and the uniqueness this whole mechanism rests on would be silently absent on exactly the
-- routes (`/v1/auth/email/start` and its neighbours) §9.3 says are safe to retry.

CREATE TABLE sonny.idempotency_key (
  -- The caller's account, or the nil UUID for a POST made before anyone is signed in.
  account_scope         uuid        NOT NULL,
  -- The client's `Idempotency-Key` header, verbatim. Bounded by the hook, not by a column type, so
  -- that an over-long header is refused with a contract code rather than by a database error.
  idempotency_key       text        NOT NULL,

  -- `POST /v1/plan` — diagnostics only. The fingerprint below already covers the route, so nothing
  -- reads this to make a decision; it is here because a row nobody can attribute to a route is a row
  -- nobody can debug.
  route                 text        NOT NULL,

  -- What "the same body" means, decided in `src/idempotency/fingerprint.ts`. Compared before every
  -- other branch, so §9.2's third guarantee holds whatever state the row is in.
  request_fingerprint   text        NOT NULL,

  -- **The fencing token: which claim this row is currently on.** A fresh value is minted by every
  -- claim, including a re-claim, and `completeClaim`/`releaseClaim` name it in their `WHERE`. Without
  -- it those two guard on `state = 'in_flight'`, which identifies *a* live claim rather than *this*
  -- one, and a holder whose lease expired then acts on its successor's claim — measured both ways in
  -- PR #142's review: a ghost's release frees the successor's claim and a third request calls the
  -- provider while the successor is still in flight (§9.2 bullet 4 defeated), and a ghost's
  -- completion stores its own stale body for twenty-four hours while the successor's real answer is
  -- silently discarded. A stale writer now matches zero rows, which is already the safe outcome
  -- everywhere else in this file.
  --
  -- No `DEFAULT`: every claim path supplies `gen_random_uuid()` explicitly, so a path that forgets to
  -- mint a new token fails to insert rather than silently reusing the last one.
  claim_token           uuid        NOT NULL,

  -- `in_flight`  — a request holding this key is running; a second one is §9.2's fourth bullet.
  -- `completed`  — a response is stored; a repeat inside `response_expires_at` replays it.
  -- `released`   — the response was a retryable failure (§9.3) or was not storable, so the key is
  --                immediately re-claimable. The row survives, and with it the metering claim, which
  --                is what keeps "at most once, ever" true across the re-attempt this state allows.
  state                 text        NOT NULL
                          CHECK (state IN ('in_flight', 'completed', 'released')),

  claimed_at            timestamptz NOT NULL,
  -- When an `in_flight` claim stops being believed. A process that dies mid-request would otherwise
  -- hold its key against every retry until the row was cleaned up by hand; past this instant the key
  -- is re-claimable. Set from the longest total deadline contract §12 gives any route (105 s) plus
  -- margin, so no request that is genuinely still running can have its key taken.
  lease_expires_at      timestamptz NOT NULL,

  completed_at          timestamptz,
  -- §9.2's twenty-four hours. NULL while `in_flight` or `released`.
  response_expires_at   timestamptz,
  response_status       integer,
  response_content_type text,
  response_body         bytea,
  -- The `Sonny-Request-Id` the original exchange carried. Replayed with the response rather than
  -- replaced by the repeat's own id: §2.3 makes that header the join key between an error the user
  -- saw, the metering event and the retained content, and a replay has exactly one of each — the
  -- original's. A fresh id on a replayed body would name a request that metered nothing and stored
  -- nothing, and would disagree with the `request_id` inside the body it is sent with.
  response_request_id   text,

  -- SONNY-133's one-shot claim. Set by `claimMeteringEvent` and never cleared by anything here.
  metering_claimed_at   timestamptz,

  PRIMARY KEY (account_scope, idempotency_key)
);

COMMENT ON TABLE sonny.idempotency_key IS
  'Contract section 9.2. Written by server/src/idempotency; the metering claim is read by SONNY-133.';

-- Pruning walks expired responses; without this it is a sequential scan over every key ever issued.
-- Partial, because a row with no stored response is never a candidate and there is no reason to
-- carry it in the index — which is the opposite call to 0010's, and for the opposite reason: there
-- the query's own predicate did not mention nullness, and here it does.
CREATE INDEX idempotency_key_response_expiry_idx
  ON sonny.idempotency_key (response_expires_at)
  WHERE response_body IS NOT NULL;

-- @rollback
DROP INDEX IF EXISTS sonny.idempotency_key_response_expiry_idx;
DROP TABLE IF EXISTS sonny.idempotency_key;
