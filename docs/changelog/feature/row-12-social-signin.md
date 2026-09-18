### Branch: feature/row-12-social-signin
Status: complete, awaiting review
Date: 2026-09-18
Tickets: SONNY-129 — Sign in with Google, built; Sign in with Apple dropped from v1 after establishing that its native mechanism is unavailable to a Developer ID app; the refusal that keeps one Supabase user on one account; and the gate that honours only sessions the gateway started. Filed from it: SONNY-521 (the Apple drop, and when it returns) and SONNY-522 (the join prompt, moved out by founder decision). SONNY-301's prompt moved to SONNY-522.
Reviewed by: pending — deep adversarial review owed (auth, trust boundary, data model).

Spec sections covered: §16.3 (sign-in methods); the row-12 plan's §4.3 item 3 ("verify the Apple mechanism rather than assuming it") is answered and Apple is out of the v1 set by founder decision.

Files changed:
- `server/src/auth/signin-guard.ts` (new) — the guard both sign-in routes run before `resolve()`, and the per-Supabase-user advisory lock around guard, resolve and record.
- `server/src/auth/gateway-session.ts` (new) — reading a freshly minted token's session the gate's way, recording it, and the gate's one question of it.
- `server/src/auth/oauth.ts` (new) — the fixed redirect and the PKCE and code patterns.
- `server/src/db/migrations/0023_the_gate_honours_only_sessions_the_gateway_started.sql` (new) — `sonny.gateway_session`, and a guard that refuses to apply while any Supabase user backs two live accounts.
- `server/src/auth/provider.ts`, `server/src/auth/supabase.ts` — two seam methods and their Supabase implementations (the authorize URL; the PKCE exchange and its identity pick).
- `server/src/routes/auth.ts` — `POST /v1/auth/oauth/google/start` and `POST /v1/auth/oauth/google`; both sign-in routes end in one shared completion step; refresh checks the session.
- `server/src/auth/gate.ts` — the started-here check; the public list gains `/start` and loses Apple.
- `server/src/auth/ratelimit.ts`, `server/src/metering/event.ts` — the exchange's per-source limit, and both routes declared unmetered.
- `server/test/oauth.db.test.ts`, `server/test/migration-shared-supabase-user-guard.db.test.ts` (new); `server/test/support/gateway-session.ts`, `server/test/support/without-oauth.ts` (new); the 23 suites whose `AuthProvider` fakes now extend `WithoutOAuth`; the database suites that present tokens for accounts they inserted by hand now record the session; `auth.db.test.ts`, `denylist.test.ts` and `denylist.db.test.ts` each had one test inverted, with the reason in the test; `schema.test.ts`'s runner allow-list, `gate.test.ts`, `migration-round-trip.db.test.ts`, `supabase-provider.test.ts`.
- `Sources/MacAgentCore/SonnyGoogleSignIn.swift` (new) — PKCE, the callback, what the Mac will open, the browser seam.
- `Sources/MacAgent/SystemWebAuthenticator.swift` (new) — `ASWebAuthenticationSession`.
- `Sources/MacAgentCore/SonnyAccountService.swift`, `SonnyBackendClient.swift`, `SonnyBackendError.swift`, `SignInCopy.swift`, and the three switches that had to learn the new cases (`SonnyModelGateway.swift`, `BillingPortalCopy.swift`, `BillingSettingCopy.swift`); `Sources/MacAgent/SignInView.swift`.
- `Tests/MacAgentCoreTests/SonnyGoogleSignInTests.swift` (new), `SignInCopyTests.swift`; `Tests/MacAgentTests/SignInSurfaceTests.swift`, `SignInTestFixtures.swift`, `ResumeOfferPresentationTests.swift`.
- `docs/sonny-backend-api-contract.md` (§2.2, §3.6, §4.1, §7.2, §9.3, §13, §14), `docs/sonny-identity-linking-rule.md` (a dated correction in §3, the prompt's owner, §6), `server/README.md`.
- `mutation/plans/feature/row-12-social-signin-server.txt`, `mutation/plans/feature/row-12-social-signin-swift.txt`, `docs/manual-tests/feature/row-12-social-signin.md`, and this entry.

Tests: the Swift figures are measured at `3599a299`, the head before this entry's own commit; that commit adds this entry and the manual-test file and nothing else (`git diff --name-only 3599a299 <this entry's commit> -- Sources Tests Package.swift server` prints nothing). The server figures were measured at `5d9993d7` and are carried to `3599a299` by a tree-identity proof rather than re-run: `git rev-parse --verify --quiet 5d9993d7:server` and the same at `3599a299` both print `360b30f5ba94a852c5cf0eb6650699bdff287aa1`. The loop that printed it read each side's exit code and was shown producing all three outcomes on that pair — `server`, `Tests` and `Package.swift` IDENTICAL, `Sources` MOVED, and a path that resolves nowhere exiting 1.
- Flagged Swift suite (`CLAUDE.md`'s command) → exit 0, **3466 tests in 251 suites passed**, 8 known issues, 92.725s; `grep -cE 'failed after [0-9]'` → 0, `grep -c 'recorded an issue at'` → 0, `grep -cE '\) skipped'` → 6 (the environment-gated tests `CLAUDE.md` names).
- `scripts/warnings` → exit 0, **0 warnings**, its own header reading `measured at : 3599a299 (clean)`, every file in `Sources/` and `Tests/` compiled.
- `cd server && npm run build` → exit 0; `npm run typecheck` → exit 0 (each read with nothing between the command and `$?`).
- `npm test` → exit 0, `Test Files  34 passed | 28 skipped (62)`, `Tests  951 passed | 503 skipped (1454)`. The skips are the database suites, which the next line runs.
- `npm run test:db` against a lane-named Postgres (`sonny-gw-db-lane-129`, Docker-assigned port) → exit 0, `Test Files  62 passed (62)`, `Tests  1454 passed (1454)`, nothing skipped.
- `server/scripts/check-secrets.sh`, `scripts/no-attribution tree` and `scripts/changelog-order` are run at the head that carries this entry, since each reads the tracked files this entry is one of; their exit codes and summary lines are on SONNY-129's closing comment and the pull request, stamped with that head.
- `scripts/mutate <plan> --check` on both plans → exit 0, every mutant's `from` block matches exactly once. **Not a battery**: no test ran; batteries are founder-triggered.
Mutation plan: `mutation/plans/feature/row-12-social-signin-server.txt` (17 mutants, database suite) and `mutation/plans/feature/row-12-social-signin-swift.txt` (11 mutants). One per half, because a plan may not mix them. Founder-triggered, not run on this branch; each header names the expected killers, read from the tests and not measured.

Behavior added:
- `POST /v1/auth/oauth/google/start` answers the auth provider's authorize address for a PKCE S256 challenge, with the redirect fixed at `com.sonny.macagent://auth/callback` and never taken from the request.
- `POST /v1/auth/oauth/google` exchanges the code and the verifier for the §3.2 token response, resolving the account by Google's `sub`, and returns the asserted address as `user.email` for display.
- Both sign-in routes refuse `409 auth.account_exists` when the Supabase user a sign-in came back as already backs a different live account, end that fresh session at `scope=local`, and create nothing.
- The gate and refresh honour only sessions a sign-in route recorded, for the same Supabase user and account; a token with no session claim is refused.
- A sign-in route refuses to hand out a token the gateway cannot verify, or one whose `sub` disagrees with the user the provider reported (`500 server.error`), instead of issuing a session every later request would refuse.
- Migration 0023 refuses to apply while any Supabase user backs two live accounts.
- The Mac signs in with Google in the user's own browser through `ASWebAuthenticationSession`, with a PKCE verifier from `SecRandomCopyBytes` that is sent only at the exchange, and writes the session to the Keychain before returning.
- The sign-in sheet has a **Sign in with Google** button; a closed browser shows nothing; `auth.account_exists` reads *"This address already has a Sonny account. Sign in the way you did before."*; a refused Google code reads *"Sonny couldn't finish signing you in with Google. Try again."* rather than the email flow's mistyped-code sentence.

Behavior preserved (required, no blanket claims):
- **Email sign-in** — start, verify, the three distinct code failures and who they are disclosed to, the rate limits, and the Keychain-before-return ordering are unchanged; `auth.db.test.ts` passes in the database run below, one of its tests inverted (below).
- **The identity-linking rule** — `resolve()` is untouched; rule 1 still lands a repeat sign-in; rule 2 still flags a verified match where the provider did not join the two (`oauth.db.test.ts`, "still flags a verified address match under a DIFFERENT Supabase user"); `linking.db.test.ts` passes unchanged.
- **Sign-out and the denylist** — a signed-out session is still refused first, before attribution, and the sign-out route stays reachable with a denylisted token; `denylist.db.test.ts` and `denylist.test.ts` pass, one test in each inverted (below).
- **Attribution of a closed, ambiguous or superseded user** — unchanged, and still what refresh and the gate answer; the new check runs after it.
- **Refresh rotation, overlap and reuse detection** — the provider's, unchanged; refresh additionally refuses a session the gateway did not start.
- **Every authenticated route's own behaviour** — reached through the same gate, now with one more read on the connection it already leases; every non-auth suite passes with the shared fake answering it.
- **Billing, model and content routes' error copy** — `auth.account_exists` joins each switch's catch-all arm, where no such route can produce it.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- **Native Sign in with Apple is unavailable to a Developer ID app.** Apple's capability table, read raw — a summarising fetch tool reported the opposite and was wrong. The browser flow that remained needs a client secret Apple caps at six months. Founders dropped Apple on 2026-09-18; SONNY-521 is the record and says when it returns.
- **Supabase's automatic linking and the 2026-08-22 rule, together, lock a person out.** Email then Google on one verified address comes back as one Supabase user; rule 2 filed a second account under it; attribution then refused every token for that user, on both accounts, with no route able to recover it. Measured in both orders against a real Postgres. The fix is a refusal before `resolve()`, not a change to the rule (founders' option A).
- **A route-level fix was not enough, because the gate trusted any token the project signed.** Supabase mints sessions for a joined user to anyone who asks it directly, so the recycled-mailbox case the 2026-08-22 decision refused was reachable around every route. The gate now honours only sessions the gateway started. **Every session from before migration 0023 signs in once more**, and nothing is backfilled, because nothing on record says which earlier sessions the gateway started.
- **Two tests pinned the lockout as correct behaviour.** `auth.db.test.ts` asserted that two addresses under one Supabase user "stay two accounts", and `denylist.db.test.ts`/`denylist.test.ts` asserted that a token with no session claim keeps working. Each is inverted and says why in the test, so the inversion is a decision on the record rather than a quiet flip.
- **The gateway never holds the Google client secret.** Supabase runs the exchange, so the client ID and secret go into the Supabase dashboard; the founders' first plan to set them in a lane's terminal was corrected on 2026-09-18.
- **`ASWebAuthenticationSession` is the system browser, not an embedded web view** — Apple's documentation says it opens the user's default browser, or Safari. It also delivers the callback to the session alone, so `Info.plist` registers no URL scheme.
- **Pitfall: two scans count method names across the whole app, and a rename walked from one into the other.** `ResumeOfferPresentationTests` counts every `start(` as a route into a task run and failed on the browser session's helper and its `start()`; the session's `start` got a named exclusion and the helper was renamed `begin` — which `FirstRunSequenceTests`, counting every `.begin(` as a first-run decision, then failed on, visible only in the next full run. The helper is `openWebAuthenticationSession` now and its doc comment names both scans. **A `scripts/warnings` run was stopped** rather than reported: it had stamped `5d9993d7 (clean)` and the rename was edited into the tree mid-build, so its count would have described a tree nobody built.
- **Pitfall: Plane's firewall refuses a comment that quotes a curl command with its short flags** (recorded on SONNY-363). The method that found it: send the text to a work item that does not exist, where Plane's own JSON 403 means the firewall let it through and Cloudflare's page means it did not.

Known limitations / deferred scope:
- **The end-to-end run against the real Supabase project has not happened.** It needs the founder's Google OAuth client in the Supabase dashboard, the redirect allow-list entry, the gateway's variables for the real project, and a person at the browser; the manual rows are the runbook, including the migration output that measures the real data and the list of rows the run creates.
- **The join is SONNY-522's** (founder decision, 2026-09-18). Until it lands, someone whose address already has an account reached the other way cannot use the second method; they are told to sign in the way they did before.
- **A sign-in that fails after the provider minted its session does not end that session at the provider** — a database error inside `resolve()` or the record answers `500`, and only the two refusals call `endUnissuedSession`. The session is inert rather than live: it was never recorded, so the gate and refresh refuse every token of it. It lives at Supabase until it expires. The same was true of `email/verify` before this branch, without the gate that now makes it harmless.
- **Sessions started before migration 0023 cannot be signed out through Sonny** — the gate refuses them first, the Mac treats that refusal as "already signed out" and clears its Keychain, and the provider-side family lives until it expires. They open nothing in Sonny.
- **`sonny.gateway_session` is not pruned.** One row per sign-in, kept while the account row exists; a Supabase session has no end this gateway can see. Recorded in migration 0023's header.
- **Google's own button artwork is not used** — a functional label, per the founders' rule for this surface. Whether v1 adopts Google's branding is SONNY-109's.

Open questions (required, write "none" if true):
- Whether the real Supabase project joins the two sign-ins into one user as its documentation says. The fifth manual row is where that is observed; the gateway is correct either way, and only the reasoning in this entry assumes it.

Next branch: none named; SONNY-522 is the join, and it should read SONNY-129's comments before designing anything.
