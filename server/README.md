# Sonny gateway

The backend. It holds provider credentials, authenticates users, checks entitlement, meters usage,
retains content, and forwards to model providers. Sonny's agent loop stays on the Mac
(`docs/sonny-row-12-plan.md` §4.1).

TypeScript on Node 22, Fastify, Vitest, plain-SQL migrations, one container image.
`docs/sonny-backend-api-contract.md` is the API contract and governs every route.

**Today this is a foundation, not a gateway.** SONNY-126 builds the toolchain, the configuration,
the container and the deploy path plus one route — `GET /v1/health`. Accounts, the model routes,
metering and retention each have their own ticket, and none is here.

## Commands

Run from `server/`.

| Command | What it does |
|---|---|
| `npm install` | Dependencies. |
| `npm run build` | TypeScript → `dist/`, **and copies the `.sql` migrations beside the compiled runner** — tsc does not copy non-TS assets, and `npm run migrate` reads them from `dist`. |
| `npm test` | Vitest. Database tests skip when `DATABASE_URL` is unset, announced by `test/global-setup.ts` before the reporter owns the terminal. |
| `npm run test:db` | The full suite including migrations, against a throwaway Postgres. |
| `npm run typecheck` | Types without emitting, over `src/`, `test/` **and** `vitest.config.ts`. The build's own tsconfig has `rootDir: src`, so it checked zero test files. |
| `npm run dev` | Local server with reload. |
| `npm run migrate -- up\|down\|status` | Apply, roll back one, or list. Needs `DATABASE_URL` and a prior `npm run build`. **The same command works inside the container image**, which is why it runs the compiled runner rather than the source. |
| `npm run revocations` | What provider-side revocation is still owed on closed accounts. Exit 1 when any is. See "Owed revocations" below. |
| `npm run check:secrets` | Refuse a credential in the repository. Also `check-secrets.sh staged`. |
| `./scripts/check-secrets-selftest.sh` | Prove the scanner still refuses things. |
| `./scripts/deploy.sh local` | Build the image, run it, verify `/v1/health` serves that build. |
| `./scripts/deploy.sh staging\|production` | **Stubbed** — see "Deploying" below. |

### Owed revocations

Closing an account revokes its provider-side sessions. When the provider is unreachable at that
moment the account **still closes** — that is the state the user asked for and it is committed — and
the revocation is recorded as **owed**: `sonny.identity.provider_session_revoked_at` stays NULL.

This matters because a closed account can no longer be attributed to its caller, by design, so the
user cannot retry it themselves. Before the debt was recorded (PR #87 third round, F1) one transient
provider error meant every identity after it in the loop was never attempted and nothing anywhere
remembered, so the session survived indefinitely.

```
npm run revocations     # exit 0 when nothing is owed, 1 when something is
```

It reports account ids and counts, never provider-side user ids. The deletion route drains **its own
account** after the close, which covers every case where the provider recovers inside the request.

**The adapter now exists and this particular debt still cannot be paid, for a different reason
(SONNY-307).** `src/auth/supabase.ts` is a real `AuthProvider`, so the sentence that used to stand
here — no adapter, blocked on Resend — is gone. What replaced it is narrower and is a property of
Supabase rather than of this repository: the operation `drainOwedRevocations` needs is "revoke every
session of user X, given X's id and no token of theirs", and **Supabase Auth exposes no endpoint that
does it**. `/logout` derives the user from the caller's own bearer token, and the whole `/admin/*`
surface carries no session route. So `signOutAllForUser` raises `ProviderUnavailable`, the row stays
owed by design, and this command keeps reporting it — which is the mechanism working, not failing.
The two ways to close it (delete the provider user, or have the gateway mint a token for that user
and present it to `/logout?scope=global`) are both founder decisions and neither is an adapter's to
take; the reasoning is in that method's docstring.

**The constraint this places on anything that deletes accounts — `feature/row-12-retention` above
all.** The debt lives on the identity row, and `sonny.identity.account_id` cascades on delete, so a
hard `DELETE FROM sonny.account` would take the record of the debt with it while the provider-side
session stayed live — and this command would then report a clean sweep, which is the worst possible
answer (PR #87 fifth round, F2). **Migration 0008 refuses that delete** with a
`foreign_key_violation` naming the account and this command. The ordering it enforces is: **drain
first, then delete.** Two things a sweep needs to know about it:

- `TRUNCATE` bypasses it, because row triggers do not fire for `TRUNCATE`. That is deliberate — it is
  a whole-table operator action, and the test suite resets itself with it — but a retention sweep
  must not reach for `TRUNCATE` to get around a refusal.
- Soft-deleting (`deleted_at`) is unaffected and always was. The refusal is only about removing the
  row.

The full suite needs a Postgres. One line, and it is thrown away afterwards:

```sh
docker run -d --name sonny-gw-db -e POSTGRES_PASSWORD=postgres -p 55433:5432 postgres:17
DATABASE_URL="postgres://postgres:postgres@localhost:55433/postgres" npm test
docker rm -f sonny-gw-db
```

## Authenticating a request

**Supabase Auth is the login service; this gateway verifies its tokens and never implements a
sign-in of its own** (founder decision, 2026-08-21). Verification is symmetric — HS256 with the
project's JWT secret, **with the algorithm pinned** — plus `iss`, `aud` and `exp`, and the `sub`
claim is trusted as the Supabase user id. `src/auth/token.ts` is the whole of it and
`src/auth/gate.ts` is where it is applied.

**Every route is protected unless it is on a list.** `PUBLIC_ROUTES` in `src/auth/gate.ts` is that
list, and it is the contract's §4.1 `Auth: none` column. The direction matters more than the
mechanism: a route added by a later ticket whose author never thinks about authentication answers
`401` to everyone including its author, rather than serving quietly. Opt-in authentication fails the
other way and does it silently.

Three variables, all required wherever an authenticated route is mounted, all refused at startup
rather than at request time:

| Variable | What it is |
|---|---|
| `SUPABASE_JWT_SECRET` | The project's JWT Secret. **Gateway-only** — never in the app, never in this repo. Refused under 32 characters. |
| `SUPABASE_JWT_ISSUER` | The project's auth URL, compared exactly against each token's `iss`. |
| `SUPABASE_JWT_AUDIENCE` | Defaults to Supabase's own `authenticated`. |

The secret is a **signing** key as much as a verifying one: anyone holding it can mint a token for
any user. That is why it lives in exactly one process, and why `npm run check:secrets` carries the
variable name on its name-anchored list — a project secret has no vendor prefix, so the name is the
only thing that can catch it.

### What a refused caller is told

| Situation | Status | `code` | Client does |
|---|---|---|---|
| No token, a forged one, a wrong `iss`/`aud`/`sub`, a token not yet valid | 401 | `auth.unauthenticated` | opens sign-in |
| Past `exp` beyond the 30-second tolerance | 401 | `auth.token_expired` | refreshes once, retries once |
| Verified, but names no single live account | 401 | `auth.token_revoked` | clears the Keychain entry, opens sign-in |

The **reason** a token was refused is logged and never returned. A caller learns that it was refused
and whether refreshing would help; answering "wrong audience" to one attempt and "bad signature" to
the next is a tuning signal for the third. `auth.token_revoked` is the same code
`POST /v1/auth/refresh` already answers for a closed or ambiguous account, so the two surfaces cannot
disagree about what that state means.

### An access token outlives a sign-out, and this is the bound on it

A Supabase access token is self-contained. That is what lets this gateway verify one without a
network round trip to the provider on every request — and it is equally why it cannot un-issue one.
Signing out revokes the **refresh** family at the provider, so no new access token can be minted; the
one already in the user's hand keeps verifying until its own `exp` **plus the 30-second skew
tolerance** — so **one hour and thirty seconds** on Supabase's default lifetime. The extra thirty
seconds are this gateway's own (`src/auth/clock.ts`, one-directional by design), which is exactly why
they belong in the number: quoting `exp` alone would understate the window by the amount the gate
adds to it.

What *is* closed, on every single request: a token naming a **closed or deleted account** is refused,
because attribution reads live state rather than remembering a decision. So `DELETE /v1/account`
takes effect immediately for every token that names it, including tokens minted before the deletion.

Closing the remaining window means a denylist of revoked sessions consulted per request — a table, a
migration, and a dependency on Supabase's `session_id` claim being present. Filed as **SONNY-237**
rather than built into SONNY-203, which owns verification and the gate.

**Rotating `SUPABASE_JWT_SECRET` signs everyone out.** One secret is accepted, not an ordered list
like the provider credentials below, so tokens signed with the previous one stop verifying the moment
the new value is deployed. That is a deliberate difference: an accepted-but-retired signing secret
extends the life of a leaked one, and Supabase rotates this rarely. Filed as **SONNY-238** if an
overlap is ever wanted.

## The three environments

`local`, `staging`, `production` — set by `SONNY_ENV`, which has no default and is a startup
failure when absent or unrecognised. Each has its own configuration and its own credentials.

**Environments are not hosts, and the distinction is load-bearing here.** The gateway's host
changes across the product's life — development first tries deploymind, beta runs on Oracle Cloud,
v1 on AWS (`docs/sonny-row-12-host-decision.md` §12.2) — while the three environments stay exactly
as they are. **Nothing in this directory couples to a host** — the three are named in prose here
and in the Dockerfile's own header, which is the point of saying which they are; what none of them
gets is a code path, a build flag or a config default of its own. What each one receives is an OCI
image and a set of environment variables, so moving between them is a redeploy.

### Staging is seeded with synthetic data and never holds real user data

Not a copy of production, not a subset, not "just the last week", not "just for this one bug".

The reason is specific rather than general caution. Under the 2026-08-16 retention decision this
backend keeps **screenshots, command text and voice audio** (`docs/sonny-row-12-plan.md` §4.2).
Seeding staging from production would put real users' screen contents — whatever was on their
display when they asked Sonny to do something — into a second place with weaker access controls and
more people touching it. Staging exists to rehearse changes, and a rehearsal does not need real
screens.

**This is written here because it is the kind of rule that gets undone by someone being helpful**,
in a hurry, reproducing a bug that only shows up with real data. If that is genuinely the only way,
the answer is synthetic data shaped like the real case, not a copy of it.

### Verifying a migration before it touches production

Staging exists precisely for this, so the rule is stated rather than implied:

1. Apply on **staging** (`npm run migrate -- up`) and check the change is what was intended.
2. **Roll it back** on staging (`npm run migrate -- down`) and check the database is where it
   started. A migration whose rollback has never been run is a migration with no way out.
3. Apply on staging **again**, so what production receives is a path that has been walked twice.
4. Only then apply on production.

The runner supports this by construction: every migration file must carry a `-- @rollback` section
or it is refused at load, each migration runs in its own transaction, and the suites pin the whole
lot. They are split on purpose — `test/migrate.load.test.ts` needs no database and so runs on every
`npm test`, because the rollback-or-refuse rule is the runner's core promise and it was previously
skipped on every run of the documented command; `test/migrate.db.test.ts` needs one and pins apply →
roll back → re-apply, a half-failed migration leaving neither schema nor ledger row, and the ledger's
schema.

**The ledger lives in `sonny_meta`, not `public` and not `sonny`.** Not `public`, because that is
the schema Supabase exposes over HTTP through PostgREST, and a table there without row-level security
is readable by anyone holding the publishable anon key — an inventory of every schema change and its
timing has no reason to be on the internet. Not `sonny` either, because that schema's rollback is
`DROP SCHEMA sonny CASCADE`, which would destroy the very record of the rollback it is completing.

## Configuration and secrets

**No credential is ever read from anywhere but the process environment.** There is no config file,
no default for any secret, no fallback. `src/config.ts` validates the environment once at startup
with Zod and fails with `EX_CONFIG` (78) naming the offending variable — never its value, because
an invalid-config line that echoed the environment would put credentials into the logs.

**`TRUSTED_PROXIES` is empty by default — trust nothing — and should stay that way unless a proxy
really terminates the connection in front of the container.** Fastify's `trustProxy` makes
`request.ip` and `request.protocol` read from `X-Forwarded-For` and `X-Forwarded-Proto`, which any
caller can set, so with nothing in front the client chooses its own apparent address. Name the
proxies where a load balancer is genuinely there: it is a comma-separated list of CIDRs, IPs or
Fastify's named sets, and `src/config.ts` validates every entry rather than letting a typo throw
from inside the Fastify constructor. (**This paragraph named `TRUST_PROXY` and called it a boolean**,
which the variable has not been since PR #87 F4 replaced it — a boolean had no safe setting, and the
`.env.example` beside it already described the list form. Corrected in passing by SONNY-203, whose
own section above is the reason anyone was reading this one.)

**`SUPABASE_JWT_SECRET` is the one credential this gateway holds that is also a *signing* key** —
anyone with it can mint a token for any user, so it is gateway-only and refused at startup under 32
characters. "Authenticating a request" above has the three variables and what each is checked for.

**Two credentials for *calling* Supabase, added by SONNY-307, and the distinction is worth keeping
straight.** The three above verify a token this gateway was handed: local, symmetric, no network.
`SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are for the other direction — asking the project
to send a sign-in code, exchanging one, rotating, signing out, deleting a provider user. The anon key
is publishable by design and is sent as `apikey` on every call; the service-role key is a real secret
that bypasses every row-level policy, is on the secret scanner's name-anchored list, and is sent by
exactly one method, the admin user delete. **There is no `SUPABASE_URL`**: the auth base URL is
`SUPABASE_JWT_ISSUER`, so the project this gateway calls and the project whose tokens it accepts
cannot be pointed at two different places — a mistake that presents as every request answering 401
with nothing in the logs to say why.

**No mail credential, and that is measured rather than pending.** Supabase's own mailer sends the
sign-in code; this gateway neither mints it nor receives it, so `RESEND_API_KEY` and `SMTP_PASSWORD`
appear on the secret scanner's list — anticipating them — and nowhere in `src/config.ts`. The
production sending domain is still owed and still founder-owned, one layer away: Supabase's default
SMTP is documented as best-effort, non-production, two messages an hour, and the fix is a **custom
SMTP transport configured in the Supabase project**, after which Supabase Auth still composes and
sends. That changes deliverability, not this gateway.

`.env.example` is committed and carries placeholders only. `server/.env` is gitignored, along with
every `.env.*` variant, so a file named after staging or production cannot slip in either.

`npm run check:secrets` scans every tracked file for vendor-issued credential shapes and reports
**location and pattern, never the matched value** — a scanner that prints what it found has copied
it into your scrollback. Known-synthetic strings already in the tree, all of them fixtures for the
local redaction feature, are exempted by exact match in `scripts/secret-scan-baseline.txt`, which
explains why an exact-string baseline is safer than a path skip or a looser pattern.

`./scripts/check-secrets-selftest.sh` plants credential-shaped strings in a scratch repository and
proves the scanner refuses each one — including two guards measured rather than assumed. Re-adding
the `example` term the allowlist once carried makes `a key whose body contains 'example' is refused`
fail. And re-adding any angle-bracket term breaks the paired pooler checks: **that term was a live
hole, not the harmless leftover an earlier version of this file called it.** The DSN pattern uses
negated character classes, so `<` and `>` reach the matched substring — which exempted
`postgresql://postgres.<project-ref>:<the password>@…pooler.supabase.com`, Supabase's own pooler shape,
with the password intact. **It found three defects in the scanner** — two on its first
run (a pattern beginning with a hyphen that `grep` parsed as options, so it silently never ran; and
`example` in the allowlist matching `db.example.com`) and a third on the next (a fix that would have
exempted every PEM header in the tree, a real key included). It is not decoration. (This line said
"two" while the changelog said three; the changelog was right — PR #85 cycle 1, R18.)

### Rotating a provider credential with no downtime

Each provider reads `<PROVIDER>_API_KEY`, then `_2`, `_3`, … in order, stopping at the first gap.
Index 0 is what new requests use; later entries stay accepted through the overlap.

A rotation is **three independent deploys, each valid on its own**:

| step | environment | active | still accepted |
|---|---|---|---|
| 1 | `OPENAI_API_KEY=old`, `OPENAI_API_KEY_2=new` | old | old, new |
| 2 | `OPENAI_API_KEY=new`, `OPENAI_API_KEY_2=old` | new | new, old |
| 3 | `OPENAI_API_KEY=new` | new | new |

At no point is the server without a working credential. That is why credentials are an ordered list
rather than a `primary`/`secondary` pair: with two named fields, retiring the primary means editing
two variables at once, and a deploy that catches them half-applied has either a duplicated key or
none. `test/config.test.ts` walks all three steps and asserts a usable key at every one.

## The four model routes (SONNY-130)

`POST /v1/plan`, `POST /v1/research/synthesize`, `POST /v1/transcriptions` and `POST /v1/search`.
All four are authenticated — they are covered by *not* appearing in `PUBLIC_ROUTES`, which is what
deny-by-default means — and all four hold the provider credential here so the Mac app never sees
one. `docs/sonny-backend-api-contract.md` §4.2–§4.4 is the wire shape; what belongs here is the
operational half.

**Which provider serves which route is one function**, `modelProvidersFrom` in
`src/model/providers.ts`, reading the endpoints and model identifiers from the environment. That is
what makes SONNY-110's move to a paid zero-retention route a redeploy: nothing in the Mac app names
a provider, a model or an endpoint, so changing any of the three never needs an app release.

**A route whose provider has no credential answers `502 provider.unavailable`, not `404`.** The
route table does not change shape with the environment, because a 404 tells the client "no such
route" — which it does not retry and cannot explain — when the truth is a deployment missing a key.

**Two numbers are pinned on both sides and must move together.** `src/model/limits.ts` holds
contract §6.1's per-route body limits and §12's deadlines; `SonnyBackendTimeouts` in
`Sources/MacAgentCore/SonnyBackendClient.swift` holds the client timeouts, each above this server's
total deadline for the same route — by fifteen seconds on the three long routes and by five on
`search`, which is §12's table rather than one constant. The *ordering* is the governing rule — the
client's timeout is always longer than the server's — so a slow route surfaces as this server's
typed `504 provider.timeout` rather than as the client's opaque transport timeout, which it cannot
tell apart from a dead network.

**The audio limit is enforced in different units on each side, on purpose.** The Mac caps a
*recording* at `VoiceRecordingLimit.maximumDurationSeconds` (180 s) and refuses before a byte is
sent; this server caps *bytes* at §6.1's 10 MiB. The Mac is the side holding the recorder, so it is
the only side that knows a duration honestly — a client-supplied one would be a client-trust
decision on the field that decides the bill, which §2.4.1 forbids in general. At this recorder's
bitrate, 180 s is roughly 2 MB, so the client's cap binds an order of magnitude before this one:
the byte ceiling is the backstop for a client that is not ours, or is broken.

**`retention` is validated and not yet honoured, and that is stated rather than implied.** §2.4.2
makes an omitted `retention` a loud `400` rather than a quiet guess in either direction, and these
routes enforce that. What they do not do is store anything at all — there is no content store yet,
and SONNY-134 builds it along with §10.1's rule that retention is enforced where the storing
happens rather than at the call site. Claiming the guarantee now would be claiming a promise nothing
keeps.

## Deploying

`./scripts/deploy.sh local` is real and works end to end: it builds the image with the current git
SHA as its build identifier, runs it, and **verifies `/v1/health` reports that same identifier** —
so a deploy that appeared to succeed while something older kept serving is a failure, not a pass.

**It forwards the gateway's own credentials from the launching shell** (SONNY-306, founder
decision 2026-08-27), so a credentialed local container is this one command rather than a hand-run
`docker run`. The list is `SUPABASE_JWT_SECRET`, `SUPABASE_JWT_ISSUER`, `SUPABASE_JWT_AUDIENCE`,
`SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `DATABASE_URL`, `RATE_LIMIT_SALT` and — added by
SONNY-130 at the extension point SONNY-306 left — `OPENAI_API_KEY` and `TAVILY_API_KEY`, the two
credentials the four model routes need. It tracks `src/config.ts`, which is the only thing that
decides what the gateway reads, and the script's own comment carries the command that re-derives it.
Each is forwarded with `docker run -e NAME` — no `=`, so no value is read by the script or printed
by it — and only when it is set to something non-empty. Nothing is refused when one is missing: the
absent ones are named, by name only, and the container starts anyway.

**What that container serves depends on what you set, and the script probes it rather than asserting
it**: after the health check it asks `POST /v1/auth/email/start` what it answers and prints the
result. Set none of the four `SUPABASE_` names and it is `404 resource.not_found` — health-only,
which is a supported deployment. Set all seven and it answers `400`, which is `startBody` refusing
the probe's empty body: the route exists. **Until SONNY-307 it was 404 whatever you set**, because
`src/server.ts` called `buildApp(config)` with no `auth` argument and no concrete `AuthProvider`
existed; that ticket built both and the probe flipped with no edit to it, which is what probing was
for.

**Set some of the four and the container refuses to start**, exiting 78 (EX_CONFIG) with the missing
names printed. That is deliberate: an operator who set three of them has said what they want, and
serving health-only there would answer 404 to every sign-in while looking perfectly healthy — which
is indistinguishable from the defect SONNY-307 fixed, and was measured reading exactly that way.

`staging` and `production` **are stubs and exit 3.** The founder confirmed on 2026-08-21 that
deploymind cannot receive a deploy yet, and neither Oracle nor AWS exists. The script builds the
image, says plainly what did not happen, and lists the four things a real target needs. It does not
pretend. **The first real remote deploy is owed and is recorded on SONNY-126.**

**The four model routes still answer `401` against that container**, and the reason is the one the
subsection above names rather than a missing credential: `src/server.ts` supplies no `AuthDeps`, so
the gate refuses every protected route on a process with no way to authenticate anyone. SONNY-307 is
what makes the forwarded credentials matter; until it lands, forwarding more of them changes
nothing a caller can see.

**The passthrough carries seven names, and SONNY-130 added two of them** — `OPENAI_API_KEY` and
`TAVILY_API_KEY`, the credentials the four model routes need. It stops there on purpose, and the
block above the array in `deploy.sh` carries the same reasoning: `ANTHROPIC_API_KEY`,
`CEREBRAS_API_KEY` and `VISION_API_KEY` are excluded because no route reads them yet, and
`OPENAI_BASE_URL`, `OPENAI_TEXT_MODEL`, `OPENAI_TRANSCRIPTION_MODEL` and `SEARCH_BASE_URL` are
excluded because each has a real default and this list is for values a container cannot invent.
Pointing a local run at a stub instead of at a vendor — which is how SONNY-130 demonstrated all four
routes end to end with no vendor key anywhere — is done by editing the array for that run, and both
the count and the absent-name lines derive from its length, so nothing else needs touching.

## `GET /v1/health`

```json
{ "status": "ok", "version": "4b0e338", "environment": "local" }
```

Unauthenticated, `Cache-Control: no-store`. `version` is the build identifier, injected at image
build time, which is what makes two deployments distinguishable from a browser.

It deliberately reports **nothing else** — no dependency status, no database check, no
configured-provider list. This route is reachable by anyone who finds the hostname, and a liveness
probe that lists which providers have credentials gives away the shape of the system for free. A
liveness probe that checks the database also turns one database blip into a load balancer removing
every healthy instance. Readiness is a different concern and belongs to the first ticket with a
dependency worth gating traffic on. A test pins the response's exact key set so a later helpful
addition fails rather than ships.
