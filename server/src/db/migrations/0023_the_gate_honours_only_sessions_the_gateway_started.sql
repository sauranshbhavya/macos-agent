-- @locks SHARE ROW EXCLUSIVE sonny.account
-- @scans sonny.account, sonny.identity

-- 0023 — the gate honours only provider sessions this gateway started, and no provider-side user may
-- back two live accounts (SONNY-129).
--
-- **Why a table of sessions at all.** `auth/gate.ts` used to attribute a request from the token's
-- `sub` alone: any access token the project signed, naming a Supabase user some live identity names,
-- was that account's. That was sound while email was the only sign-in method, because Supabase keeps
-- one user per address and our identity rule keeps one account per address. It stops being sound the
-- moment a second method is enabled in the Supabase project. Supabase links a new sign-in to the
-- existing user whenever the verified addresses match — "Supabase Auth automatically links identities
-- with the same email address to a single user", its identity-linking guide, with no switch to turn
-- it off — and it will mint a session for that user to anyone who asks it directly: the project's
-- address is the `iss` of every token this gateway hands out, and its anon key is publishable by
-- Supabase's own design. So the person who inherits a recycled mailbox could sign in by email code
-- straight at Supabase, receive a session for the Google-created user of the mailbox's previous owner,
-- and present it here — and the gate would have let them into that owner's account. That is the
-- recycled-mailbox case the founders decided against on 2026-08-22
-- (`docs/sonny-identity-linking-rule.md` §2.1), reached around every rule this gateway's routes apply.
-- The founders chose on 2026-09-18 to close it in the gate rather than accept it.
--
-- **So every session the gate accepts is one of these rows.** `POST /v1/auth/email/verify` and
-- `POST /v1/auth/oauth/google` record the `session_id` of the token Supabase just minted, against the
-- account the sign-in resolved to, and `auth/gate.ts` and `POST /v1/auth/refresh` refuse a token whose
-- session has no row naming the same provider-side user and the same account. A session minted at
-- Supabase directly has no row and opens nothing here. A token that carries no `session_id` at all —
-- the `omitempty` shape migration 0022's header measured — is refused outright, because there is
-- nothing to look it up by; before this migration that shape was merely undeniable, and now it is
-- unacceptable, which is the fail-closed direction.
--
-- **What that costs every existing session: one more sign-in.** A session started before this
-- migration has no row, so the first request it makes afterwards is refused with
-- `auth.token_revoked`, which the Mac answers by clearing its Keychain entry and opening sign-in.
-- Nothing is backfilled: a backfill would have to trust exactly the kind of session this table exists
-- to refuse, since nothing on record says which existing sessions this gateway started.
--
-- **The guard at the top is a measurement, not a migration step.** The lockout SONNY-129 found is two
-- live accounts naming one `supabase_user_id` — `accountForSupabaseUser` then answers ambiguous and
-- every token for that user is refused, with no route able to recover it. Both sign-in routes now
-- refuse to create that state. Nothing should already be in it, because no route that could produce it
-- has ever been served — but "should" is not a measurement, and this migration is the one thing that
-- runs against every database this gateway has. So it refuses to apply while any such user exists,
-- naming the condition, and a database it applies to is one where the state was measured absent at
-- that moment.
--
-- **Why `session_id` is a primary key and `account_id` is stored beside it.** One provider session is
-- started once. The account is stored rather than derived because the gate checks the two against
-- each other: attribution still answers "which account does this provider-side user belong to", and
-- the row answers "did this gateway start this session for that account". A row whose account no
-- longer matches — an identity that has since moved — refuses, and the user signs in again. That is
-- deliberate, and SONNY-522's join, which moves identities, inherits it.
--
-- **Retention: kept while the account exists.** A row holds two provider ids, an account id, the
-- method and a start time — no address and no content. One is written per sign-in, and a Supabase
-- session has no fixed end this gateway can see, so there is no safe instant to prune one early. A
-- closed account keeps its rows, because accounts are marked closed and never deleted, and the gate
-- refuses them through attribution before this table is read. The reference is `ON DELETE CASCADE`,
-- the one `sonny.identity` already makes, so the rows go with an account row if one is ever removed.

DO $$
BEGIN
  IF EXISTS (
    SELECT i.supabase_user_id
      FROM sonny.identity i
      JOIN sonny.account a ON a.id = i.account_id
     WHERE i.supabase_user_id IS NOT NULL
       AND NOT i.account_closed
       AND a.deleted_at IS NULL
     GROUP BY i.supabase_user_id
    HAVING count(DISTINCT i.account_id) > 1
  ) THEN
    RAISE EXCEPTION 'a provider-side user already backs two live accounts; every token for that user '
      'is refused by attribution, and this migration will not apply over that state (SONNY-129). '
      'Find it with: SELECT supabase_user_id FROM sonny.identity i JOIN sonny.account a ON '
      'a.id = i.account_id WHERE NOT i.account_closed AND a.deleted_at IS NULL GROUP BY 1 HAVING '
      'count(DISTINCT i.account_id) > 1';
  END IF;
END
$$;

CREATE TABLE sonny.gateway_session (
  -- Supabase's `session_id` claim from the token the sign-in route received, verbatim.
  session_id uuid PRIMARY KEY,

  -- The token's `sub`. Checked against the presented token's own `sub`, so a row for one user can
  -- never admit a token for another that happens to carry the same session claim.
  supabase_user_id uuid NOT NULL,

  -- The account the sign-in resolved to.
  account_id uuid NOT NULL REFERENCES sonny.account(id) ON DELETE CASCADE,

  -- Which route started it. Nothing reads this for correctness; it is what answers "how did this
  -- person sign in" for support, and it costs one column.
  method text NOT NULL CHECK (method IN ('email', 'google')),

  started_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE sonny.gateway_session IS
  'Provider-side (Supabase) sessions this gateway started through one of its own sign-in routes. '
  'auth/gate.ts and POST /v1/auth/refresh accept a token only when its session_id has a row naming '
  'the same supabase_user_id and the account attribution resolves to, so a session minted at '
  'Supabase directly opens nothing here (SONNY-129). NOT contract 5.2''s task session, which is a '
  'different thing with the same spelling.';

-- The foreign key's own lookups when an account row goes. The gate's read is a primary-key lookup.
CREATE INDEX gateway_session_account ON sonny.gateway_session (account_id);

-- @rollback
-- @locks ACCESS EXCLUSIVE sonny.account, ACCESS EXCLUSIVE sonny.gateway_session
-- @scans none

DROP TABLE IF EXISTS sonny.gateway_session;
