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
| `npm run revocations` | What provider-side revocation is still owed — on closed accounts, and on live ones whose provider-side user id was superseded. Exit 1 when any is. See "Owed revocations" below. |
| `npm run usage -- sessions\|routes\|span` | What the calls this gateway served cost. Needs `DATABASE_URL` and a prior `npm run build`. See "Reading what a call cost" below. |
| `npm run support -- account\|content\|accesses\|deletions` | Answer a support question. Account state and usage read freely; **content only with `--operator` and `--reason`, and the lookup is recorded.** See "Retention" below. |
| `npm run snapshots -- build\|list\|trace\|sweep` | Build the documented corpus training reads from, see which snapshots hold a task's content, or run the content-expiry sweep by hand. |
| `npm run entitlements -- show\|grant\|revoke\|restore\|sweep\|public-key` | What an account is allowed and what it has spent, plus the operator writes that set it. Needs `DATABASE_URL` and a prior `npm run build`. See "What an account is allowed" below. |
| `npm run check:secrets` | Refuse a credential in the repository. Also `check-secrets.sh staged`. |
| `./scripts/check-secrets-selftest.sh` | Prove the scanner still refuses things. |
| `./scripts/deploy.sh local` | Build the image, run it, verify `/v1/health` serves that build. |
| `./scripts/deploy.sh staging\|production` | **Stubbed** — see "Deploying" below. |

### Owed revocations

Closing an account revokes its provider-side sessions. When the provider is unreachable at that
moment the account **still closes** — that is the state the user asked for and it is committed — and
the revocation is recorded as **owed**: `sonny.identity_provider_user.provider_session_revoked_at`
stays NULL.

**That column moved off `sonny.identity` in migration 0014** (SONNY-196/SONNY-230), because a
revocation is owed for a *provider-side user id* rather than for an identity. `sonny.identity` no
longer has it, so a query naming `sonny.identity.provider_session_revoked_at` answers `42703` rather
than an answer — this line said exactly that until PR #164's review found it.

**A closed account is no longer the only way to owe one.** `sonny.identity_provider_user` keeps every
Supabase user id an identity has ever named, and a **superseded** one — an id the identity used to
name and no longer does, which is what Supabase re-keying a subject looks like from here — is owed a
revocation from the moment it is superseded, on a live account. `provider_session_revoked_at` means
"the revocation owed for that id's **current episode** has been performed", not "this id has been
revoked at least once": observing the id again starts a new episode and clears the stamp.

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
all.** The debt lives on `sonny.identity_provider_user`, which cascades to `sonny.identity` on
`identity_id` and from there to `sonny.account` on `account_id`, so a
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

## Retention: what is kept, for how long, and how it goes (SONNY-134)

The backend retains **full request and response content** — request text, voice audio, redacted
screenshots, the served response, and provider error bodies — for **30 days**, disclosed on the
website's terms and privacy pages, for three named purposes: debugging and support, product
analytics, and training or fine-tuning a model. Founder decision, 2026-08-16; the thirty days is his
confirmation of 2026-08-28, from the 30–90 range that decision names. Contract §10.

**Nothing here may be read as "this system does not retain screen content." It does.** What it does
not do is let the provider retain it too — that is SONNY-110's, and a different claim.

### Two clocks, and a third

| What | Where | Clock |
|---|---|---|
| Request and response content | `sonny.retained_content` | `CONTENT_RETENTION_DAYS`, 30 by default |
| Usage and derived metrics | `sonny.metering_event` | Indefinite. That table holds no content, which is what lets it outlive it |
| Training snapshots | `sonny.training_snapshot` | Its own `expires_at`, **NULL unless a build asks for one** |

The third is NULL because §10.3 puts snapshots on a "separately-consented lifecycle" and no founder
has set a number. NULL means none is set, not "never expires by policy"; `expireSnapshots` skips
those rows, and the day a number exists the sweep that enforces it already runs.

**A row carries the window it was written under.** `expires_at` is computed at insert from
`CONTENT_RETENTION_DAYS`, never at read — so raising the setting applies to what arrives afterwards
and cannot extend the life of content a user was told would be gone in thirty days.

### The clock actually runs

The gateway sweeps on a timer (`CONTENT_EXPIRY_SWEEP_SECONDS`, hourly by default), logs every pass,
and writes a row to `sonny.content_deletion` for every pass that took something. `npm run snapshots
-- sweep` runs one by hand. `npm run support -- deletions` is where "did the clock run, and what did
it take" is answered after the fact — for expiry sweeps, task deletes and account deletes alike.

**Four things happen on that sweep, not one.** Expired content; any training snapshot that has
reached a clock of its own; **the idempotency store's stored response bodies past their twenty-four
hours** (`pruneExpiredResponses`, which had no production call site until PR #148's review measured
that a body back-dated thirty days survived a full sweep — SONNY-318 keeps the policy question of
whether the *rows* should ever go, and they must not simply be deleted, since a row carries the
metering claim that stops a key billing twice); and the content of one closed account whose
in-request wipe could not finish.

### The second place response content lives

`sonny.idempotency_key.response_body` holds the served response for twenty-four hours so a retry can
be replayed (§9.2). That makes it the one place outside `sonny.retained_content` holding response
content, and two rules follow:

- **An incognito run stores no body there.** For `retention: "none"` the key is claimed and fenced
  exactly as always and the response is withheld, so a repeat re-executes rather than replaying. That
  is a deliberate §9.2 deviation with its own contract row; §9.2 carries what it costs.
- **`DELETE /v1/account` clears an account's stored bodies**, and the sweep prunes expired ones. A
  *per-task* delete cannot reach them, because that table has no `task_id` to key on.

### Three ways content stops being kept

- **`DELETE /v1/tasks/{task_id}`** — the user's own delete, from the app. Founder decision via
  SONNY-14: delete means deleted everywhere. It removes the live content **and every training
  snapshot member copied from it**, and records which snapshots it touched. A task with nothing
  stored answers 200 with `requests_deleted: 0`, never 404; 404 is reserved for a task belonging to
  someone else.
- **`DELETE /v1/account`** — content, snapshot membership, and the account's stored idempotency
  response bodies (SONNY-319). Usage survives, deliberately. If the wipe cannot finish inside the
  request — the account is closed by then, so the caller cannot retry — the sweep takes it on the
  next pass, which is also what reaches accounts closed before this existed.
- **The content clock**, above.

### Incognito is never stored, and that is structural

A run started with **"Don't save this task"** sends `retention: "none"`, and three separate things
have to fail before a byte of it is kept:

1. `content/hook.ts` refuses before it reads a body, decodes a capture or opens a connection.
2. `sonny.retained_content` carries a `CHECK` admitting exactly one value of `retention`, so the
   insert is refused even if something above it is wrong.
3. The snapshot builder's `FROM` names that table and nothing else — **so there is no `retention`
   filter in it to drop.** Deleting every predicate in the build statement widens the snapshot to
   every consenting account's content and still cannot reach one incognito run.
   `content.db.test.ts` runs exactly that unfiltered statement and asserts it.

**Metering runs either way.** Incognito changes what is stored, never what is billed.

### Training reads from snapshots, never from the live store

`npm run snapshots -- build --label <name>` copies eligible content into
`sonny.training_snapshot_member` and seals the snapshot. A member holds **a copy plus the
`content_id` it came from**, not a pointer — the copy because the live store is on a 30-day clock and
the snapshot is not, and the lineage because a deletion request has to be traceable to the snapshots
it touched after the source row is gone. That is the requirement §10.3 says cannot be retrofitted
once anything has been trained on.

Consent is honoured twice: the builder joins `sonny.account` and requires `training_consent` (which
defaults to false and is `NOT NULL`, so a user whose consent was never written is excluded), and a
trigger on the member table refuses the row anyway. `npm run snapshots -- trace --account <id>
--task <id>` says which snapshots hold one task's content without deleting anything.

### What the support lookup may see

Decided on SONNY-134, 2026-08-28, rather than left to whoever has database access:

- `npm run support -- account <uuid>` reads freely — account state, how it signs in, what it has
  been calling, **how many content rows are held and of what kinds**. Never content, and never the
  email address behind an identity.
- `npm run support -- content --request <id> --operator <name> --reason "<text>"` is the one command
  that reads content. It refuses without both flags, writes a `sonny.content_access` row whether or
  not it finds anything, and prints blobs as sizes rather than bytes.
- `npm run support -- accesses` reads that log back.

**It is a discipline and a trace, not a boundary.** Anyone who can run these commands holds
`DATABASE_URL` and can read the same rows from `psql`, leaving nothing behind. What it buys today is
that a lookup made through the product leaves a record; what it buys later is that the control
already exists the day a support surface is something other than a founder's terminal.

Entitlement plan and tier are not in the report because they do not exist: §5.3's signed entitlement
claim is SONNY-135's. The report says so rather than printing an empty section that reads like "no
entitlements".

## Reading what a call cost (SONNY-133)

Every call on every model route writes one row to `sonny.metering_event` — contract §11. The table
holds **no content**, which is what lets it sit on the long side of §10.3's two clocks: raw request
and response content lives 30 days, usage lives indefinitely, and nothing in this gateway deletes or
ages a metering row.

```
npm run usage -- sessions   # one block per screen-control session
npm run usage -- routes     # one block per route
npm run usage -- span       # how many events, and how far back they go
```

Every command takes `--account`, `--session`, `--task`, `--since` and `--until`.

**`sessions` is the one the pricing waits on.** A screen-control session is up to twelve iterations
(`VisionSessionLimits.default.maximumIterations`), each its own request, its own upstream call and
its own row; the gateway holds no session state, so a session's cost is the sum over the rows sharing
one client-minted `session_id`. That figure is what SONNY-17 turns into a credit weight, and it did
not exist anywhere before this row of work: `AIUsageCallKind` had three cases and none was vision.

**Two things every figure is read with, and the command prints both under every report.** Image size
drives vision token cost, and SONNY-114 changed what leaves the Mac — a cost measured over sessions
that ran before it is a number about to move. And a token count of `0` on `screen.analyze` is an
*absence* rather than a measurement: that route reports tokens only when the provider did and
estimates nothing, because the dominant term is an image whose cost is a function of pixel dimensions
and a provider's own tiling rule. The `no tokens` column counts those calls, and the megapixel figure
is what sizes them.

**It prints no price, and it must not learn one.** Tokens, bytes, pixels, iterations, durations and
outcomes are measurements; a rate, a plan or a credit weight is SONNY-17's decision, and putting one
here would be taking that decision in the wrong ticket.

**A command rather than a screen, by decision of 2026-08-28.** The usage UI is SONNY-214's. What this
row owes is the founders' pre-launch measurement, answerable before any UI exists.

### What is metered, and what is deliberately not

The five model routes are metered. Every other `POST` this gateway serves is declared unmetered by
name in `src/metering/event.ts`, and a population test walks the built app's real route table — so a
sixth content-bearing route fails the suite until somebody classifies it either way, rather than
shipping free.

Inside a metered route, a request is recorded when it holds its idempotency key's claim, or when it
carried no key at all. **A repeat that replayed a stored response writes nothing** — it ran nothing —
and neither does a `409 idempotency.conflict`, which is the subtler of the two: that request never
took the key's claim, so metering it would take the claim out from under the request that is doing
the work. Contract §9.2's "at most once per idempotency key, ever" is kept by
`claimMeteringEvent` in `src/idempotency/store.ts`, taken **inside the same transaction as the
insert**, and there is no second mechanism beside it — a unique constraint here would change the
failure shape rather than add safety.

**A retry that genuinely re-ran goes unbilled, and that is the guarantee rather than a gap.** §9.2
releases the key on a retryable failure so a `429` is not a twenty-four-hour ban on that operation;
the release does not clear the metering claim, so the second attempt's usage is not charged. The
direction is deliberate: "unable to double-bill a user" errs toward the user.

**An incognito run is metered identically.** §10.1: incognito changes what is stored, never what is
billed. Its event carries `retention: none` and every cost field a standard run's carries.

## What an account is allowed, and what stops it spending forever (SONNY-135)

Two questions, answered separately because they fail differently.

**"Is this user allowed to do this?"** is answered on the Mac, from a signed claim, **with no network
call** — contract §5.3. `GET /v1/account/entitlements` returns a JWS the client verifies against a
public key it ships with, carrying the account's plan, its capability list, an expiry, a grace window
and a skew tolerance. That is what makes §16.3's guarantee possible at all: a client that has to ask
the server "may I" is a client that cannot answer offline.

**"Have they used more than they are allowed?"** is answered here, in Postgres, before any provider
is called.

### The claim, and the four durations

| value | seconds | what it buys |
|---|---|---|
| lifetime | 86,400 (24 h) | how long a minted claim is valid |
| refresh after | 28,800 (8 h) | when a client should fetch a new one — a third of the lifetime, so one missed refresh does not spend the grace window |
| grace | 259,200 (72 h) | how far past expiry a cached claim may still be honoured |
| skew tolerance | 300 (5 min) | how much clock disagreement the client absorbs, in both directions |

**The revocation bound is those numbers and is stated in both directions, because they differ.**
Online, a cancelled subscription stops working within **8 hours** — the next refresh carries a fresh,
signed, capability-less claim, and nothing has to expire for it to take effect. Offline, nothing can
be delivered, so the bound is the claim's own life plus the grace window: **96 hours** on a Mac that
never reaches the network in that time, and immediate the moment it does. §5.3 says "revocation
reaches a live client within the claim's lifetime"; that is true of an online client and understates
the offline case, which is why both are written here.

**Signed with Ed25519 and never with a shared secret.** The access tokens this gateway verifies use
HS256, which is right there — the same process that verifies also has to call the project. It is
exactly wrong here: this claim is verified on every user's Mac, and a symmetric algorithm would mean
every copy of the app shipping a key that can *mint* a claim for any user with any capability list.
`ENTITLEMENT_SIGNING_KEY` is therefore the one credential on this page whose leak is a **write**.

### The spend cap, and what happens when two requests race it

The counter is a row per account per period in Postgres — `sonny.usage_period(account_id,
period_start, cap_units, spent, reserved)` — and the whole mechanism is **one statement**:

```sql
UPDATE sonny.usage_period
   SET reserved = reserved + $amount
 WHERE account_id = $account AND period_start = $period
   AND spent + reserved + $amount <= cap_units
RETURNING reserved;
```

No rows returned means the cap is reached, and the request is refused with `429 limit.spend` **before
any provider is called**. Under READ COMMITTED — Postgres's default and Supabase's — an `UPDATE` that
meets a row a concurrent transaction has just updated does not use the snapshot it began with: it
waits, then re-evaluates its own `WHERE` against the new row version. So the second racer tests the
cap against a row already carrying the first one's reservation and is skipped. No advisory lock, no
`SELECT … FOR UPDATE`, no retry loop, and no read-then-write window.

`docs/sonny-row-12-host-decision.md` §9 is where that mechanism was measured and named;
`test/entitlement.db.test.ts` is where this implementation is held to it, against a real Postgres,
under a forced interleaving and a fifty-way race — **with the naive read-then-write committed beside
it as a control**, because a race test with no control passes whether or not the property holds.

**Reserve, then settle.** The hold is taken before the upstream call and closed after it: charged if
a provider was reached, released if none was. A request the host kills between the two leaks its hold
until `npm run entitlements -- sweep` reclaims it — the reservation's `expires_at` is 300 seconds,
which clears §12's longest route deadline (105 s) by enough that a running request can never have its
own hold swept out from under it. (If it could, the loss is not a double spend but a call charged to
nobody: `AND NOT settled` makes the late settle a no-op, measured.)

**`sweep` is the one command an operator schedules, and nothing schedules it yet.** It does two
things: reclaims expired holds from `sonny.usage_reservation`, and deletes rate-limit windows from
`sonny.auth_rate_limit` that nothing counts against any more. The second is here because the
per-account limit changed that table's load by an order of magnitude — a row per account per minute
rather than one per sign-in attempt — and its sweep had no caller outside a test. Both are safe to
run repeatedly, and the cut-off is computed from the declared limits so it can never delete a window
something is still counting against.

**One metered call is one unit, and that is a consequence rather than a price.** A cost-weighted cap
needs a credit weight, and credit weights are SONNY-212's. So the cap counts calls: it bounds a
leaked token to `SPEND_CAP_UNITS` calls in a period, each of them bounded in turn by §6.1's body
limits and §12's deadlines. It does **not** bound the money, because a `/v1/search` and a
twelve-iteration screen-control session are the same number of units and nowhere near the same number
of dollars. `unitsForMeteredCall` in `src/entitlement/store.ts` is the seam a real weight lands in.

### What an account is allowed, from a terminal

```
npm run entitlements -- show <account-id>
npm run entitlements -- grant <account-id> --plan <key> [--capability <key>]... [--cap <units>]
npm run entitlements -- revoke <account-id>      # next claim carries no capabilities
npm run entitlements -- restore <account-id>
npm run entitlements -- sweep                    # reclaim orphaned holds AND stale rate-limit windows
npm run entitlements -- public-key               # the public half, for a client's shipped key set
```

**Nothing else writes `sonny.entitlement` yet**, which is why this command exists: row 13 owns the
account and plan UI, and until it lands this is the only way to put an account into a state. `grant`
refuses without `--plan` rather than choosing one, because a plan key this command picked would be a
tier this repository invented.

**An account with no row is entitled to nothing and capped at the deployment's `SPEND_CAP_UNITS`.**
Both halves are fail-closed and they fail closed differently: no capabilities means every gated
capability is refused, and a `NULL` cap means the deployment's rather than none.

### Which routes are gated

**None, and that is this ticket's answer rather than an omission.** `CAPABILITY_REQUIRED` in
`src/entitlement/hook.ts` is empty: row 18 (SONNY-23) owns which capability keys gate which features,
and row 12 owns making that gating possible. Every metered route spends against the cap; nothing
requires a capability. An entry in that map is a product decision.

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

**And a token naming a superseded provider-side user is refused on the same read, immediately**
(SONNY-196/SONNY-230). `accountForSupabaseUser` matches `sonny.identity.supabase_user_id`, which is
only ever the id the identity names *now*; once Supabase re-keys a subject and the next sign-in
adopts the new id, the old one matches no live identity and the gate answers `401
auth.token_revoked` on the very next request rather than at `exp`. It must stay that way: the
history in `sonny.identity_provider_user` exists so a superseded id can be *revoked and reported*,
and joining it here would let a token minted for one attribute to the account again — the exact
inverse. At Supabase those tokens keep working until they expire, which is SONNY-237's window above
and not this one.

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
is publishable by design and is sent as `apikey` on every call.

**The service-role key is a real secret and is deliberately not required** (founder decision
2026-08-27, option (c)). It bypasses every row-level policy and can act as any user, and **exactly
one method reaches for it — `deleteUser` — which nothing calls today**: account closure revokes
sessions and deliberately keeps identities. **No ticket owns a caller for it today.** This named
SONNY-196, which closed without one: that ticket decided *not* to probe or delete at Supabase — a
per-sign-in `/admin/*` call would need this key on every gateway serving sign-in, reversing the
decision this paragraph records. SONNY-313 is where a caller would most likely arrive, as its
option (a) — delete the provider-side user, which takes its sessions with it — and that choice has
not been made.
Requiring it would have made every gateway serving sign-in hold the project's most dangerous
credential in order to use none of it. So startup does not ask for it, `deploy.sh local` does not
forward it, and `deleteUser` throws `ServiceRoleKeyNotConfigured` at its own call site if a future
caller reaches it without one — a deployment fault reported as one, rather than a 502 that sends an
operator hunting a Supabase outage. **The ticket that lands a caller adds it back to the required set
and the passthrough in the same change.**

**There is no `SUPABASE_URL`**: the auth base URL is
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

## The five model routes (SONNY-130, and SONNY-131's vision row)

`POST /v1/plan`, `POST /v1/research/synthesize`, `POST /v1/transcriptions`, `POST /v1/search` and
`POST /v1/screen/analyze`. All five are authenticated — they are covered by *not* appearing in
`PUBLIC_ROUTES`, which is what deny-by-default means — and all five hold the provider credential
here so the Mac app never sees one. `docs/sonny-backend-api-contract.md` §4.2–§4.5 is the wire
shape; what belongs here is the operational half.

**Which provider serves which route is one function for four routes and a second for the fifth.**
`modelProvidersFrom` in `src/model/providers.ts` answers for `/v1/plan`,
`/v1/research/synthesize`, `/v1/transcriptions` and `/v1/search`, reading the endpoints, model
identifiers and route chains from the environment; `visionProviderFrom` in `src/model/vision.ts`
answers for `/v1/screen/analyze`. That is what makes SONNY-110's move to a paid zero-retention route
a redeploy: nothing in the Mac app names a provider, a model or an endpoint, so changing any of the
three never needs an app release.

**The two were expected to collapse when SONNY-132 landed, and they did not.** SONNY-131 and
SONNY-132 ran in parallel and this paragraph used to say the split was temporary. It survived the
merge because nothing forced it: `/v1/screen/analyze` reads no `ModelProviders` field, so the
provider router grew its four chains without touching that route, and the vision route was on
SONNY-132's never-touch list. Collapsing it is worthwhile and unclaimed — a `MODEL_ROUTE_SCREEN_ANALYZE`
chain would give the vision route the same failover and the same per-provider retention policy the
other four have, which is what SONNY-110 needs of it. `src/app.ts` carries the same note at the
mount.

**`/v1/screen/analyze` is the one route with a body worth thinking about, and its limit is derived
rather than chosen.** `src/model/limits.ts` holds `MAXIMUM_IMAGE_BYTES` — 3,000,000, the same
ceiling `RedactedCaptureEncoder` on the Mac encodes down to — and computes §6.1's 4,200,000 body
limit from it, so the two numbers cannot drift apart. The image is refused above that ceiling with
a `413 request.too_large` carrying `limit_bytes` and `actual_bytes`, which a correct client never
sees: the Mac refuses at the same number before it builds a request body. **The server never
resamples, re-encodes, crops or rotates the image** (§4.5 rule 1) — the base64 string the client
sent is spliced into the provider's data URL verbatim, and the only decode is the one that counts
its bytes. A server-side resize would leave every coordinate the model returns scaled by a factor
nothing on the Mac knows about, which is a click landing inside the window, plausible-looking, and
wrong.

**A route whose provider has no credential answers `502 provider.unavailable`, not `404`.** The
route table does not change shape with the environment, because a 404 tells the client "no such
route" — which it does not retry and cannot explain — when the truth is a deployment missing a key.

### The provider router and failover (SONNY-132)

**A route resolves to an ordered chain of providers, not to one.** Four variables decide it —
`MODEL_ROUTE_PLAN`, `MODEL_ROUTE_SYNTHESIZE`, `MODEL_ROUTE_TRANSCRIPTIONS`, `MODEL_ROUTE_SEARCH` —
each a comma-separated list whose first entry serves and whose remainder are the failover
candidates. Unset means the shipped default: `openai,anthropic` on the two text routes, `openai` on
transcription (Anthropic serves no transcription API), `tavily` on search. Three providers have text
adapters — OpenAI, Anthropic and Cerebras — so moving the planner between them is one variable and a
redeploy, with no change to the app and no new release.

**A deployment holding only `OPENAI_API_KEY` behaves exactly as it did before the router existed**,
because a chain entry with no credential is not a candidate. **A chain entry with no *adapter* is
refused at startup instead** — `MODEL_ROUTE_SEARCH=openai` exits 78 naming the variable — because
silently dropping it would leave you believing you had configured a fallback you do not have. An
unknown provider and a repeated entry are refused the same way.

**Failover triggers on `provider.unavailable` and on nothing else.** That is the provider being
unreachable, rate-limiting this gateway, or answering `5xx`: the request is fine and the provider is
not. A `provider.rejected` is not failed over — §9.3 makes it non-retryable because the same request
fails identically, and a refusal is usually about the content, so shopping it to a second vendor is
routing around one vendor's answer rather than resilience. A `provider.timeout` is not either: the
whole chain runs inside one route deadline and shares one abort signal, so a second attempt would
fail before it opened a socket, and giving each attempt a fresh deadline would push the handler past
§12's total and hand the failure to whatever sits in front of this gateway.

**The user is never told which provider served, and that is the contract rather than a preference.**
§4.2: "The response names no provider and no model." What the router produces instead is a
server-side attribution — who served, and who was tried first — logged on every model route
(`model route served`, or `model route served after failover` at `warn`) with the request id §2.3
makes the support join key. §11's metering event carries the same fact in a `provider` column;
SONNY-133 builds the event that will record it.

**Per-provider retention and training terms are configuration**, per spec §16.5:
`<PROVIDER>_DATA_RETENTION` (`unknown` / `none` / `retains`) and `<PROVIDER>_TRAINING` (`unknown` /
`none` / `reserved`). **Every one defaults to `unknown`, which is the honest current value rather
than a placeholder** — no vendor agreement has been read on this project's behalf, and recording a
vendor's published default as though it were checked would be a claim nobody made. SONNY-110 is
where real values come from, and a provider clears its bar only with `none` on *both* axes: one that
retains nothing but reserves training rights has not protected the content, because training is one
of retention's own named purposes. Nothing routes on it yet, deliberately; the values are printed in
the `model routing` log line at startup so a deployment's beliefs are visible rather than inferred.

**Which vendors this gateway can currently speak to, and how each maps a JSON Schema.** OpenAI's
Responses API takes `text.format` with `type: "json_schema"` and `strict: true`. Anthropic's
Messages API takes `output_config.format` with the same `type`, after the adapter prunes the
keywords structured outputs do not accept — the planner's own schema carries `minItems`, so an
unpruned schema would fail every plan request rather than an unusual one. Cerebras takes the schema
in the system prompt: its native mode caps a schema at 5,000 characters and ours is longer, which
was re-verified live on 2026-08-13, so the adapter appends the schema instruction and strips a
wrapping markdown fence off the reply. §4.2 names all three shapes as the server's to choose, and
says the client "does not know which mechanism was used and must not need to".

**Two numbers are pinned on both sides and must move together.** `src/model/limits.ts` holds
contract §6.1's per-route body limits and §12's deadlines; `SonnyBackendTimeouts` in
`Sources/MacAgentCore/SonnyBackendClient.swift` holds the client timeouts, each above this server's
total deadline for the same route — by fifteen seconds on `plan`, `synthesize`, `transcriptions` and
`screenAnalyze`, and by five on `search`, which is §12's table rather than one constant. The *ordering* is the governing rule — the
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
makes an omitted `retention` a loud `400` rather than a quiet guess in either direction, and all
five routes enforce that. What they do not do is store anything at all — there is no content store yet,
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
`SUPABASE_ANON_KEY`, `DATABASE_URL`, `RATE_LIMIT_SALT` and — added at the extension point
SONNY-306 left, by SONNY-130 then SONNY-131 — `OPENAI_API_KEY`, `TAVILY_API_KEY` and
`VISION_API_KEY`, the three credentials the five model routes need, and — by SONNY-135 —
`ENTITLEMENT_SIGNING_KEY`, `ENTITLEMENT_SIGNING_KEY_ID` and `SPEND_CAP_UNITS`, which are required
wherever auth is mounted. **The count is deliberately not written here**: it is
`awk '/^PASSTHROUGH=\(/,/^\)/' server/scripts/deploy.sh | grep -cE '^  [A-Z]'`, run against the
tree in front of you, because this sentence has already been a number that a later ticket made stale.
`SUPABASE_ANON_KEY` is SONNY-307's, which also decided that
`SUPABASE_SERVICE_ROLE_KEY` is **not** forwarded, above. It tracks `src/config.ts`, which is the
only thing that decides what the gateway reads, and the script's own comment carries the command
that re-derives it. Each is forwarded with `docker run -e NAME` — no `=`, so no value is read by the
script or printed by it — and only when it is set to something non-empty. Nothing is refused when
one is missing: the absent ones are named, by name only, and the container starts anyway.

**What that container serves depends on what you set, and the script probes it rather than asserting
it**: after the health check it asks `POST /v1/auth/email/start` what it answers and prints the
result. Set none of the three `SUPABASE_` names and it is `404 resource.not_found` — health-only,
which is a supported deployment. Set the whole auth set and it answers `400`, which is `startBody` refusing
the probe's empty body: the route exists. **Until SONNY-307 it was 404 whatever you set**, because
`src/server.ts` called `buildApp(config)` with no `auth` argument and no concrete `AuthProvider`
existed; that ticket built both and the probe flipped with no edit to it, which is what probing was
for.

**Set some of the three and the container refuses to start**, exiting 78 (EX_CONFIG) with the missing
names printed. That is deliberate: an operator who set three of them has said what they want, and
serving health-only there would answer 404 to every sign-in while looking perfectly healthy — which
is indistinguishable from the defect SONNY-307 fixed, and was measured reading exactly that way.

`staging` and `production` **are stubs and exit 3.** The founder confirmed on 2026-08-21 that
deploymind cannot receive a deploy yet, and neither Oracle nor AWS exists. The script builds the
image, says plainly what did not happen, and lists the four things a real target needs. It does not
pretend. **The first real remote deploy is owed and is recorded on SONNY-126.**

**The five model routes still answer `401` against that container**, and the reason is the one the
subsection above names rather than a missing credential: `src/server.ts` supplies no `AuthDeps`, so
the gate refuses every protected route on a process with no way to authenticate anyone. SONNY-307 is
what makes the forwarded credentials matter; until it lands, forwarding more of them changes
nothing a caller can see.

**The passthrough carries nine names: SONNY-130 added two and SONNY-131 a third** —
`OPENAI_API_KEY` and `TAVILY_API_KEY` for the four text routes, `VISION_API_KEY` for
`/v1/screen/analyze`. It stops there on purpose, and the block above the array in `deploy.sh`
carries the same reasoning: `ANTHROPIC_API_KEY` and `CEREBRAS_API_KEY` are excluded because no route
reads them yet, and
`OPENAI_BASE_URL`, `OPENAI_TEXT_MODEL`, `OPENAI_TRANSCRIPTION_MODEL`, `SEARCH_BASE_URL`,
`VISION_BASE_URL` and `VISION_MODEL` are excluded because each has a real default and this list is
for values a container cannot invent. Pointing a local run at a stub instead of at a vendor — which
is how SONNY-130 demonstrated all four text routes and SONNY-131 the vision route, end to end with
no vendor key anywhere — is done by editing the array for that run, and both the count and the
absent-name lines derive from its length, so nothing else needs touching.

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
