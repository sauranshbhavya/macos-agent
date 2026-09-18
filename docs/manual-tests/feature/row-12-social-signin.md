### Sign in with Google, and one account per Supabase user (new 2026-09-18, SONNY-129)

**What changed that a person can see.** The sign-in sheet has a **Sign in with Google** button above
the email form. It opens your own browser — your default one if it supports sign-in sessions, Safari
otherwise — never a window inside Sonny. There is no Apple button: Sign in with Apple was dropped from
v1 (SONNY-521). And an email code or a Google sign-in on an address that already has a Sonny account
reached the *other* way is refused with *"This address already has a Sonny account. Sign in the way
you did before."* rather than given a second account, because a second one used to lock both.

**One thing changes for every existing signed-in Mac, once.** The gateway now honours only sessions it
started, so a session from before migration 0023 is refused the first time it is used and the app asks
you to sign in again. That is expected and happens once.

**Use ONE named test account for every row below, and do not repeat the run with fresh addresses**
(founders' constraint, 2026-09-18). The rows at the end list exactly which rows the run creates and how
to remove them.

**Setup, once — all founder-owned, none of it a gateway variable** (`server/README.md`, "Turning on Sign
in with Google" has the why):

1. A Google Cloud OAuth client, type *Web application*, whose authorized redirect URI is the project's
   own callback, `https://<project-ref>.supabase.co/auth/v1/callback`.
2. Its client ID and secret into the Supabase dashboard, Authentication → Providers → Google, provider
   on. Nowhere else.
3. `com.sonny.macagent://auth/callback` into Authentication → URL Configuration → Redirect URLs,
   exactly.
4. **First, SONNY-280's resume checklist step 1: confirm in the Supabase dashboard (Project Settings →
   JWT Keys) that Legacy HS256 is the *current* signing key.** SONNY-280 found the project provisioned
   with an ECC (P-256) key current, and this gateway verifies HS256 only. Before this branch that state
   gave a sign-in that looked successful and then refused every request; **now it refuses every sign-in,
   email included, with `500 server.error`** — the app shows "Sonny can't be reached right now. Try again
   in a moment.", and the only explanation is the gateway's log line *"the provider minted a session
   whose access token this gateway cannot verify or read a session from; check that the project signs
   with the key SUPABASE_JWT_SECRET holds"*. If you see that, this step is the fix, not a retry (PR #275's
   review, finding 5).
5. The gateway's own variables for the real project exported in the launching shell (SONNY-280's resume
   checklist, step 4), then **apply the migrations and keep the output** — this is also the
   measurement that no data is already broken:
   ```
   cd server && npm run build && npm run migrate -- up; echo "MIGRATE=$?"
   ```
   `0023_the_gate_honours_only_sessions_the_gateway_started` refuses to apply, and says *"a
   provider-side user already backs two live accounts"*, if any Supabase user in the project already
   backs two live Sonny accounts. **If it refuses, stop and put the output on SONNY-129** — that is the
   broken state this ticket found, already present. If it applies, the state was measured absent at
   that moment; put the `MIGRATE=` line on SONNY-129 either way.
6. `./scripts/deploy.sh local`, then `defaults write com.sonny.MacAgent SonnyBackendBaseURL
   http://127.0.0.1:8080` once, then `./scripts/package-app.sh` and open
   `.build/arm64-apple-macosx/debug/MacAgent.app`.

- [ ] **(new 2026-09-18, SONNY-129) — Google, first time.** Open Account → **Sign in with Google**.
      **Expect:** your browser app comes forward (not a sheet drawn inside Sonny) showing Google's
      sign-in for the Sonny project; sign in with the test account; the browser hands back to Sonny
      (macOS may ask once whether to open Sonny); the sheet shows **Account** with the test account's
      Google address. Then use something that needs the gateway — open Account again so the subscription
      and allowance rows load — and **expect no "You're signed out"**.
- [ ] **(new 2026-09-18, SONNY-129) — closing the browser is not an error.** Sign out, press **Sign in
      with Google**, and close the browser window or sheet without signing in. **Expect:** back on the
      address step with **no** message at all.
- [ ] **(new 2026-09-18, SONNY-129) — it survives a relaunch.** Signed in with Google, quit Sonny and
      open it again. **Expect:** still signed in, same address, no sign-in prompt.
- [ ] **(new 2026-09-18, SONNY-129) — a real refresh keeps you signed in.** Signed in with Google, leave
      Sonny running (or quit it) for **more than an hour**, so the access token's one-hour life has
      passed and the next request has to refresh it. Then open Account, or run anything that needs the
      gateway. **Expect:** no sign-in prompt and no "You're signed out". This is the one row that tests
      what the new gate depends on and no automated test can reach: refresh now accepts a rotated token
      only when its session is one the gateway recorded, which holds if Supabase keeps a session's id
      across a refresh, as its code does and SONNY-237's denylist already relies on. **If you are signed
      out at this point, report it on SONNY-129** — it would sign every user out at their first refresh
      (PR #275's review, finding 5).
- [ ] **(new 2026-09-18, SONNY-129) — Google again lands on the same account.** Sign out, then **Sign in
      with Google** with the same test account. **Expect:** signed in, and the query in the last row
      shows **one** Sonny account for it, not two.
- [ ] **(new 2026-09-18, SONNY-129) — the reverse order is refused, not doubled, against the real
      provider.** Sign out, then sign in **with an email code** to the test account's own address.
      **Expect:** after the code, *"This address already has a Sonny account. Sign in the way you did
      before."*, still signed out, and the query in the last row still shows **one** Sonny account. This
      is the live half of SONNY-129's finding: the automated tests assume Supabase joins the two into one
      user because its documentation says so; this row is where the real project either does or does
      not. **If you are signed in instead, and the query shows two accounts, report it on SONNY-129** —
      Supabase did not join them, which the gateway handles (rule 2's flag) but which the ticket's
      reasoning did not expect.
- [ ] **(new 2026-09-18, SONNY-129) — what the run created, and removing it.** In the Supabase SQL editor
      (or `psql "$DATABASE_URL"`), with `<address>` the test account's Google address:
      ```
      -- The one Sonny account and its identities (expect 1 account, 1 google identity):
      SELECT i.account_id, i.provider, i.subject, i.supabase_user_id, a.deleted_at
        FROM sonny.identity i JOIN sonny.account a ON a.id = i.account_id
       WHERE lower(i.email_hint) = lower('<address>');
      -- Every session the gateway recorded for it (one per successful sign-in above):
      SELECT session_id, method, started_at FROM sonny.gateway_session
       WHERE supabase_user_id IN (SELECT supabase_user_id FROM sonny.identity WHERE lower(email_hint) = lower('<address>'));
      -- The provider-side user and its identities (expect google, and email after the refused row):
      SELECT u.id, i.provider FROM auth.users u JOIN auth.identities i ON i.user_id = u.id
       WHERE lower(u.email) = lower('<address>');
      ```
      Put the three result sets on SONNY-129. **To remove them afterwards:** delete the user in the
      Supabase dashboard (Authentication → Users), which takes `auth.users`, `auth.identities` and its
      sessions; then `DELETE FROM sonny.account WHERE id = '<account_id from the first query>';`, which
      takes its identity and `sonny.gateway_session` rows with it (both reference the account `ON DELETE
      CASCADE`). If that delete is refused by another table's reference, the account was used beyond
      these rows; report it on SONNY-129 rather than forcing it. **The refused email row also left a sign-in-code record, which names the address in
      plain text and is never pruned**: `DELETE FROM sonny.sign_in_code_issue WHERE email_norm =
      lower('<address>');`. Rate-limit counters are keyed by salted hashes and pruned as their windows
      pass. The sign-in calls' idempotency records hold each response for §9.2's twenty-four hours and
      are keyed by request, not by address.
