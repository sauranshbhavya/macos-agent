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

It reports account ids and counts, never provider-side user ids. **It does not currently drain**:
`drainOwedRevocations` is written and tested, and it needs a real `AuthProvider` to call — which does
not exist yet, blocked on the same founder-owned Resend/Supabase work as the rest of sign-in. The
deletion route drains its own account on the way through, which covers every case where the provider
recovers inside the request. Wiring the residual to a schedule is one call and belongs to the ticket
that lands the adapter.

The full suite needs a Postgres. One line, and it is thrown away afterwards:

```sh
docker run -d --name sonny-gw-db -e POSTGRES_PASSWORD=postgres -p 55433:5432 postgres:17
DATABASE_URL="postgres://postgres:postgres@localhost:55433/postgres" npm test
docker rm -f sonny-gw-db
```

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

**`TRUST_PROXY` defaults to `false` and should stay that way unless a proxy really terminates the
connection in front of the container.** Fastify's `trustProxy` makes `request.ip` and
`request.protocol` read from `X-Forwarded-For` and `X-Forwarded-Proto`, which any caller can set —
so with nothing in front, the client chooses its own apparent address. Set it only where a load
balancer is genuinely there.

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

## Deploying

`./scripts/deploy.sh local` is real and works end to end: it builds the image with the current git
SHA as its build identifier, runs it, and **verifies `/v1/health` reports that same identifier** —
so a deploy that appeared to succeed while something older kept serving is a failure, not a pass.

`staging` and `production` **are stubs and exit 3.** The founder confirmed on 2026-08-21 that
deploymind cannot receive a deploy yet, and neither Oracle nor AWS exists. The script builds the
image, says plainly what did not happen, and lists the four things a real target needs. It does not
pretend. **The first real remote deploy is owed and is recorded on SONNY-126.**

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
