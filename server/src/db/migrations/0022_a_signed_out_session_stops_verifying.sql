-- 0022 — a signed-out access token stops working before its own `exp` (SONNY-237).
--
-- **The defect.** A Supabase access token is a self-contained JWT and this gateway verifies it
-- locally with the project's JWT secret (the founder decision of 2026-08-21), which is what keeps an
-- authenticated request off the provider's latency and availability — and is equally why this
-- gateway cannot un-issue one. `POST /v1/auth/signout` revokes the *refresh* family at the provider,
-- so no new access token can be minted; the token already in the user's hand kept verifying until
-- its own `exp` plus `EXPIRY_SKEW_TOLERANCE_SECONDS`. On a shared or borrowed Mac that is a working
-- session left behind by someone who pressed Sign out.
--
-- **What this table is.** The one thing a local verifier can consult without asking the provider: a
-- list of provider-side sessions this gateway has been told to stop honouring. `auth/gate.ts` reads
-- it on every authenticated request, on the connection it already leases for attribution.
--
-- **The name says `provider_session` and never `session`, deliberately.** `session_id` already means
-- contract §5.2's *task* session in this tree — the metering and content tables carry it — so a
-- table called `revoked_session` would be read for that within the month. Supabase's JWT claim is a
-- third thing with the same spelling, and this table is about that third thing only.
--
-- **`session_id` is a real claim and it is optional, verified rather than assumed** (the ticket and
-- the founders' comment of 2026-08-30 both asked for this before anything was built on it). Read
-- 2026-09-06 against `supabase/auth` master `0907af9bd6be3c76f472c40a7dcc0dc34abeffaf`:
-- `internal/tokens/service.go:88` declares `SessionId string` inside `AccessTokenClaims`, with
-- the struct tag `json:"session_id,omitempty"`, and `:726` sets it on every token that service
-- mints; and
-- `internal/api/token.go:311` reads it back with `uuid.FromString` — which is where this column's
-- type comes from. The `omitempty` is not decoration: `internal/api/logout.go:52` logs
-- `"user has an empty session_id claim"` and, for such a token, falls through to
-- `models.Logout(tx, u.ID)` — a *global* logout whatever scope was asked for. So a token with no
-- session claim is a shape the provider itself handles, and it is the one shape this table cannot
-- key on. `auth/gate.ts` and `server/README.md` state that residual rather than papering over it.
--
-- **Retention: a row is kept until the token would have expired anyway, then pruned** (founder
-- decision of 2026-08-30, Sauransh and Bhavya). A row whose token has passed its own expiry can no
-- longer authorise anything, so keeping it buys nothing and costs storage. No configurable
-- retention and no scheduler: `revokeProviderSession` prunes what has expired in the same statement
-- that records a new revocation, so the table is bounded by the sign-outs of one token lifetime.
--
-- **`expires_at` is `exp` PLUS the skew tolerance, not `exp`.** `auth/clock.ts` grants
-- `EXPIRY_SKEW_TOLERANCE_SECONDS` past `exp` in one direction, so `gate.ts` accepts a token for that
-- much longer than its own claim says. A row pruned at `exp` would leave exactly the tolerance
-- window in which the token verifies and this table has forgotten it — the same understatement PR
-- #104's F9 found in three prose statements of this window, arriving as an off-by-thirty-seconds in
-- a table instead.
--
-- **No foreign key, and no account column.** A row is keyed on a provider-side session id, which is
-- a uuid the provider mints and which is unique without help. Referencing the account would tie a
-- revocation to an identity model it does not depend on — the gate refuses a closed account through
-- attribution already, so this table's job is the *live* account's signed-out session — and storing
-- the account beside it would retain a link between a person and the moment they signed out for no
-- mechanism that reads it.

CREATE TABLE sonny.revoked_provider_session (
  -- Supabase's `session_id` claim, verbatim. PRIMARY KEY because one session is revoked once; a
  -- second sign-out presenting another token of the same session is an upsert rather than a row.
  session_id uuid PRIMARY KEY,

  -- When this gateway was asked to stop honouring it. Nothing reads this for correctness; it is what
  -- makes a support question answerable at all, and it costs one column.
  revoked_at timestamptz NOT NULL DEFAULT now(),

  -- The instant after which this row can be dropped: the revoked token's own `exp` plus the skew
  -- tolerance the gate grants past it. Past this, the token is refused by `verifyAccessToken`
  -- before the gate ever reaches this table, so the row is dead weight.
  expires_at timestamptz NOT NULL
);

COMMENT ON TABLE sonny.revoked_provider_session IS
  'Provider-side (Supabase) sessions this gateway has been told to stop honouring, so that a '
  'signed-out access token stops verifying before its own exp. Consulted by auth/gate.ts on every '
  'authenticated request whose token carries a session_id claim, and written by POST '
  '/v1/auth/signout. NOT contract 5.2''s task session, which is a different thing with the same '
  'spelling. A row is kept until the token would have expired anyway and is then pruned by the next '
  'write (SONNY-237; retention decided by the founders 2026-08-30).';

COMMENT ON COLUMN sonny.revoked_provider_session.expires_at IS
  'The revoked token''s exp PLUS auth/clock.ts''s EXPIRY_SKEW_TOLERANCE_SECONDS, because the gate '
  'accepts a token for that much longer than its own claim says. Pruning at exp alone would leave '
  'the tolerance window uncovered.';

-- The prune's working set. The consult is a primary-key lookup and needs nothing.
CREATE INDEX revoked_provider_session_expiry ON sonny.revoked_provider_session (expires_at);

-- @rollback

DROP TABLE IF EXISTS sonny.revoked_provider_session;
