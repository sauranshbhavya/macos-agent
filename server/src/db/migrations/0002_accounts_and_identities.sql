-- 0002 — accounts, identities, sign-in code issuance, and auth rate limits (SONNY-127).
--
-- The shape here exists to answer one question the ticket calls first-release correctness: when one
-- person signs in three different ways, do they land on one account? Everything below follows from
-- the answer, which is recorded in docs/sonny-identity-linking-rule.md.
--
-- **The account is not the Supabase user, and that separation is the whole design.** Supabase Auth
-- automatically links identities that share a *verified* email onto one `auth.users` row, which is
-- useful and is not sufficient: Sign in with Apple can hand over an `@privaterelay.appleid.com`
-- address, which matches nothing, so the same person becomes a second `auth.users` row. If the
-- account were the Supabase user, that person would hold two accounts and one subscription. With an
-- account of our own, two Supabase users can resolve to one account, which is exactly the case
-- Supabase cannot express.

CREATE TABLE sonny.account (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at                  timestamptz NOT NULL DEFAULT now(),

  -- Deletion is a state, not a DELETE. Retained content and training snapshots are
  -- feature/row-12-retention's to reach, and a row removed here before that path exists would
  -- orphan them with no key to find them by. `deleted_at` is set by this ticket's endpoint; the
  -- retention ticket sweeps what hangs off it. Stated on both tickets.
  deleted_at                  timestamptz,

  -- Training consent (founder, 2026-08-16). Captured on the website, never in the app.
  -- **Default false, and the column is NOT NULL so it cannot be unset**: a user whose consent was
  -- never written is not consented, and there is no third state that could be mistaken for one.
  training_consent            boolean NOT NULL DEFAULT false,
  training_consent_updated_at timestamptz
);

-- **There is no write path on this branch, and that is recorded rather than implied** (PR #87 F6).
-- The ticket assigns this ticket "the field and the write path", and consent is captured on the
-- website (founder, 2026-08-16), so the write path is an authenticated endpoint the website calls.
-- Authenticated-request middleware is SONNY-128's and does not exist, so the endpoint is deferred
-- to SONNY-128 with the field landing here. What SONNY-127 guarantees is the default: not
-- consented, NOT NULL, so there is no third state that could be mistaken for consent and no user
-- is consented by omission.
COMMENT ON COLUMN sonny.account.training_consent IS
  'Website-captured training consent. Never written from the app. Honouring it when building '
  'training snapshots is feature/row-12-retention''s; this column and its write path are SONNY-127''s.';

-- One row per (provider, subject). **This is the identity key, and it is never the email address.**
CREATE TABLE sonny.identity (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id        uuid NOT NULL REFERENCES sonny.account(id) ON DELETE CASCADE,

  provider          text NOT NULL CHECK (provider IN ('email', 'google', 'apple')),

  -- The provider's own stable identifier for this person. For `email` it is the normalised address,
  -- because possession of the mailbox is what was proven and there is nothing more stable to use.
  -- For an OAuth provider it is the provider's subject claim, which survives the user changing or
  -- hiding their address -- which is the entire reason it is the key.
  subject           text NOT NULL,

  -- The address the provider asserted, kept as a HINT only: it may be a relay, it may change, and
  -- it is never what two identities are matched on. Used to offer an explicit link and to fill a
  -- form, never to merge.
  email_hint        text,
  email_verified    boolean NOT NULL DEFAULT false,

  -- True when `email_hint` is an Apple private relay. Stored rather than recomputed so that a
  -- future change to the detection rule cannot silently reclassify rows that were already decided.
  email_is_relay    boolean NOT NULL DEFAULT false,

  -- The `auth.users` row this identity corresponds to. Nullable because an identity can exist
  -- before its Supabase user does in a restore, and because two identities on one account routinely
  -- point at two different Supabase users -- the case that motivated this table.
  supabase_user_id  uuid,

  -- How this identity came to be on this account. Recorded because "why are these two joined?" is
  -- the first question asked when a merge turns out to be wrong, and reconstructing it later is
  -- impossible.
  link_method       text NOT NULL CHECK (link_method IN ('primary', 'verified_email_match', 'explicit')),
  linked_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT identity_provider_subject_unique UNIQUE (provider, subject)
);

CREATE INDEX identity_account_idx ON sonny.identity (account_id);
-- Supports the verified-email match, and only ever consulted for verified, non-relay addresses.
CREATE INDEX identity_email_hint_idx ON sonny.identity (lower(email_hint))
  WHERE email_verified AND NOT email_is_relay;

-- The gateway's own record of every code it asked Supabase to send.
--
-- **It does not store the code.** Supabase Auth issues and verifies it; this table exists for the
-- two things Supabase cannot give us. First, the contract's three distinct failures
-- (`auth.code_invalid`, `auth.code_expired`, `auth.code_used`): Supabase returns one `otp_expired`
-- reading "Token has expired or is invalid" for all three, and SONNY-128 has to say three different
-- things to the user. They are derived here from issuance state rather than from the provider's
-- error. Second, rate limiting per address and per source, which is below.
CREATE TABLE sonny.sign_in_code_issue (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_norm     text NOT NULL,
  issued_at      timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  consumed_at    timestamptz,

  -- Salted hash, never the raw value. A source identifier is personal data and a table of them is
  -- a liability that buys nothing: rate limiting only needs equality.
  source_hash    text NOT NULL
);

CREATE INDEX sign_in_code_issue_email_idx ON sonny.sign_in_code_issue (email_norm, issued_at DESC);

-- Per-address and per-source counters, in fixed windows.
--
-- **The counter is incremented and tested in one statement** (see `server/src/auth/ratelimit.ts`).
-- SONNY-125 measured what a read-then-write costs under concurrency against a cap, and the answer
-- was an over-spend that the naive implementation reported as success; a rate limit read then
-- written has the identical shape, and an auth endpoint is where it would be exercised
-- deliberately rather than by accident.
CREATE TABLE sonny.auth_rate_limit (
  bucket        text NOT NULL,
  window_start  timestamptz NOT NULL,
  count         integer NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);

-- @rollback
DROP TABLE IF EXISTS sonny.auth_rate_limit;
DROP TABLE IF EXISTS sonny.sign_in_code_issue;
DROP TABLE IF EXISTS sonny.identity;
DROP TABLE IF EXISTS sonny.account;
