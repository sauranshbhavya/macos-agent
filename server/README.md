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
| `npm run build` | TypeScript → `dist/`. |
| `npm test` | Vitest. Database tests skip, loudly, when `DATABASE_URL` is unset. |
| `npm run test:db` | The full suite including migrations, against a throwaway Postgres. |
| `npm run typecheck` | Types without emitting. |
| `npm run dev` | Local server with reload. |
| `npm run migrate -- up\|down\|status` | Apply, roll back one, or list. Needs `DATABASE_URL`. |
| `npm run check:secrets` | Refuse a credential in the repository. Also `check-secrets.sh staged`. |
| `./scripts/check-secrets-selftest.sh` | Prove the scanner still refuses things. |
| `./scripts/deploy.sh local` | Build the image, run it, verify `/v1/health` serves that build. |
| `./scripts/deploy.sh staging\|production` | **Stubbed** — see "Deploying" below. |

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
as they are. That is why nothing in this directory names a host: what each one receives is an OCI
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
or it is refused at load, each migration runs in its own transaction, and `test/migrate.test.ts`
pins apply → roll back → re-apply against a real Postgres.

## Configuration and secrets

**No credential is ever read from anywhere but the process environment.** There is no config file,
no default for any secret, no fallback. `src/config.ts` validates the environment once at startup
with Zod and fails with `EX_CONFIG` (78) naming the offending variable — never its value, because
an invalid-config line that echoed the environment would put credentials into the logs.

`.env.example` is committed and carries placeholders only. `server/.env` is gitignored, along with
every `.env.*` variant, so a file named after staging or production cannot slip in either.

`npm run check:secrets` scans every tracked file for vendor-issued credential shapes and reports
**location and pattern, never the matched value** — a scanner that prints what it found has copied
it into your scrollback. Known-synthetic strings already in the tree, all of them fixtures for the
local redaction feature, are exempted by exact match in `scripts/secret-scan-baseline.txt`, which
explains why an exact-string baseline is safer than a path skip or a looser pattern.

`./scripts/check-secrets-selftest.sh` plants credential-shaped strings in a scratch repository and
proves the scanner refuses each one. It found two real defects in the scanner on its first run, so
it is not decoration.

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
