#!/usr/bin/env bash
# SONNY-126: the gateway's deploy path.
#
#   ./scripts/deploy.sh <local|staging|production>
#
# **Two of the three targets are stubs today, and that is recorded rather than hidden.** The
# founder confirmed on 2026-08-21 that deploymind cannot receive a deploy yet. So this script
# builds and proves the entire path — image build, build-identifier injection, container start,
# health verification — against `local`, and refuses `staging` and `production` with an explicit
# message naming what is missing. It does not pretend to deploy, and it does not silently succeed.
#
# What makes the stub cheap to replace: every host on the timeline (deploymind, then Oracle, then
# AWS) receives the same thing — an OCI image and a set of environment variables. Filling in a
# target is a `push` and a `run` for that host, not a rewrite of this script.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

TARGET="${1:-}"
IMAGE="sonny-gateway"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# **A dirty tree must not ship under a clean-looking SHA.** The previous version computed this and
# then printed it in one log line, so the image, its tag, and the build identifier GET /v1/health
# reports all claimed to be exactly `$SHA` — while containing uncommitted changes that no commit
# holds. That makes the health endpoint's version field, which exists to identify a deployment,
# name a tree nobody can check out. The suffix now travels all the way into the tag and the
# build-arg, so it is visible in `docker images`, in the health response, and in the deploy log.
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  BUILD_ID="${SHA}-dirty"
else
  BUILD_ID="${SHA}"
fi

# The image the gateway runs on, and the architecture it is built for.
#
# `--platform` is set explicitly because this is built on Apple Silicon and the first real remote
# deploy is very unlikely to be arm64: Oracle Cloud's free tier is Ampere (arm64) but its paid
# shapes and AWS's defaults are x86_64, so an image built without a platform silently inherits the
# builder's. Overriding it is a one-word change here rather than a puzzling "exec format error" on
# a host. Recorded in SONNY-192's direction as the thing to decide when a host is chosen.
PLATFORM="${DEPLOY_PLATFORM:-linux/arm64}"

# ── The credential passthrough, local only (SONNY-306) ────────────────────────────────────────
#
# The names below are forwarded from the launching shell into the container when they are set, so
# that a credentialed local gateway is this one command rather than an undocumented hand-run
# `docker run`. Founder decision of 2026-08-27, option (a), over leaving that container hand-run.
#
# **This list tracks `server/src/config.ts` and was read off it rather than guessed.** That file
# decides which names the gateway reads, and nothing else does: a name here it does not read is
# forwarded to nothing, and a name it reads that is missing here is a credential this one command
# cannot deliver. The schema's whole set is
# `grep -oE '^  [A-Z_]+:' src/config.ts | tr -d ' :' | sort` -> eleven names at f65e72e. Of those,
# SONNY_ENV and LOG_LEVEL are set explicitly below, PORT/HOST/SONNY_BUILD_ID are the container's own
# and injected at build time, and TRUSTED_PROXIES is correct empty with no proxy in front. The five
# that remain are these.
#
# **Mail is empty, and that is a measurement rather than an omission.** SONNY-306 asks for the
# Supabase *and mail* names; `config.ts` reads none for mail --
# `grep -cE '(RESEND|SMTP|MAIL)[A-Z_]*' src/config.ts` prints 0, and exits 1, which is what `grep -c`
# does on no match rather than a failure to read the file. The reason is that no concrete
# `AuthProvider` adapter exists yet: `src/auth/provider.ts` is a seam, and its own docstring gives
# the cause, the founder's Resend sending domain not being ready. `scripts/check-secrets.sh` already
# carries RESEND_API_KEY and SMTP_PASSWORD on its name-anchored list, which is the scanner
# anticipating them rather than the config reading them -- so do not read that list as evidence the
# gateway takes those variables. When mail names land in `config.ts`, they are added here.
#
# **RATE_LIMIT_SALT is on the list and belongs to neither Supabase nor mail**, stated rather than
# smuggled in. `requireRateLimitSalt` refuses to start wherever the auth routes are mounted, so a
# container carrying the three Supabase names and not that one cannot serve a sign-in at all -- which
# is the outcome the single command exists for.
#
# **Provider credentials arrived on SONNY-130**, at the extension point the sentence that used to
# stand here left open: it said they belong to the routes that ticket was building and that its
# branch is where they are added if it needs them. It needs two. `OPENAI_API_KEY` serves `/v1/plan`,
# `/v1/research/synthesize` and `/v1/transcriptions`; `TAVILY_API_KEY` serves `/v1/search`. Unlike
# the auth routes, those four **are** mounted by a running container — `app.ts` registers them
# outside its `if (auth)` — so a container started without these serves them and answers
# `502 provider.unavailable`, which is honest and is not what a manual pass wants.
#
# The other three provider names in `config.ts` — `ANTHROPIC_API_KEY`, `CEREBRAS_API_KEY`,
# `VISION_API_KEY` — are **not** here, because no route reads them yet: the vision route is
# SONNY-131's and the provider router is SONNY-132's. Same rule as mail above, one row down.
#
# **The endpoint and model settings SONNY-130 also added are deliberately not here either** —
# `OPENAI_BASE_URL`, `OPENAI_TEXT_MODEL`, `OPENAI_TRANSCRIPTION_MODEL`, `SEARCH_BASE_URL`. Every one
# has a real default matching what the Mac app compiled in before the gateway existed, so a
# container that forwards none of them behaves correctly, and this list is for values a container
# cannot invent. Pointing a local run at a stub instead of at a vendor is done by editing this array
# for that run, and the count and absent-name lines below both derive from its length, so nothing
# else needs touching.
#
# **No value is read, stored, defaulted, printed or written down here.** `docker run -e NAME` with
# no `=` is Docker's own pass-from-the-environment form: the value never reaches a variable in this
# script, a command line, `ps`, or any line it prints. Absent names are reported by name only.
#
# **What that does not mean, stated so nobody reads the sentence above as wider than it is:** the
# running container holds these values in its environment, because that is what forwarding them is,
# so `docker inspect sonny-gateway-local` prints them and so does `printenv` inside it -- measured,
# at `f65e72e` plus this change. That is the same exposure the host's own environment configuration
# has on staging and production (`README.md`, "Deploying"), and it is the exposure a credentialed
# container is *for*. What this script guarantees is narrower and is the part it controls: nothing
# it reads, logs or leaves behind on the Mac carries a value.
#
# **One name was added by SONNY-307 and the mail paragraph above still stands.** That ticket built
# the concrete `AuthProvider` and wired `server.ts`, and it grew this list by exactly one name --
# `SUPABASE_ANON_KEY`, the credential for *calling* the project as opposed to verifying its tokens.
# It grew it by **no mail name**, and that is now measured rather than pending: Supabase's own mailer
# sends the sign-in code, the gateway neither mints it nor receives it, and the production sending
# domain is configured as Supabase's custom SMTP inside the Supabase project. So
# `grep -cE '(RESEND|SMTP|MAIL)[A-Z_]*' src/config.ts` still prints 0, and the sentence above about
# adding them "when mail names land in config.ts" is now a sentence about something that is not
# expected to happen.
#
# **`SUPABASE_SERVICE_ROLE_KEY` is deliberately absent, and it is the one name here whose absence is
# a decision rather than an omission** (founder decision of 2026-08-27, option (c), at PR #137's
# review). `config.ts` reads it, so by this list's own tracking rule it would belong -- but it is the
# project's most dangerous credential and **nothing calls the one method that uses it**, `deleteUser`.
# Forwarding it would put that key inside a container that cannot spend it, which is a standing risk
# bought for nothing. **The ticket that lands a caller (SONNY-196's, likely) adds the name here and to
# the required set in the same change.** A founder who wants it in a local container today can still
# `docker run -e SUPABASE_SERVICE_ROLE_KEY` by hand; the adapter takes it whenever it is present.
#
# **Setting some of these and not others now refuses to start**, which is a change SONNY-307 made
# deliberately and is worth knowing before reading the probe below. Three Supabase names are the
# switch -- `SUPABASE_JWT_SECRET`, `SUPABASE_JWT_ISSUER`, `SUPABASE_ANON_KEY`: none set is
# health-only, all set (plus `DATABASE_URL` and `RATE_LIMIT_SALT`) mounts sign-in, and a partial set
# exits 78 naming what is missing rather than serving a gateway that answers 404 to every sign-in
# while looking healthy.
PASSTHROUGH=(
  SUPABASE_JWT_SECRET
  SUPABASE_JWT_ISSUER
  SUPABASE_JWT_AUDIENCE
  SUPABASE_ANON_KEY
  DATABASE_URL
  RATE_LIMIT_SALT
  # SONNY-130's two. See the block above for why these two and not the other three.
  OPENAI_API_KEY
  TAVILY_API_KEY
)

# Filled by `collect_passthrough`. Declared here, empty, because `set -u` plus bash 3.2 --
# which is what `/usr/bin/env bash` is on a founder's Mac -- treats "${ARR[@]}" on an unset or
# empty array as an unbound variable, and "nothing was set" is this list's ordinary case.
PASSTHROUGH_ARGS=()
PASSTHROUGH_ABSENT=()
PASSTHROUGH_FORWARDED=0

usage() { echo "usage: $0 <local|staging|production>" >&2; exit 2; }
[[ -z "$TARGET" ]] && usage

build() {
  echo "==> building ${IMAGE}:${BUILD_ID} for ${PLATFORM}"
  [[ "$BUILD_ID" == *-dirty ]] && \
    echo "    WORKING TREE IS DIRTY -- this image contains changes no commit holds," >&2 && \
    echo "    and it is tagged and reports itself as ${BUILD_ID} so that is visible." >&2
  docker build --platform "${PLATFORM}" --build-arg SONNY_BUILD_ID="${BUILD_ID}" \
    -t "${IMAGE}:${BUILD_ID}" -t "${IMAGE}:latest" . \
    || { echo "build failed" >&2; exit 1; }
}

verify() {  # verify <base-url> — a deploy that was not verified is a deploy that may not have happened
  local url="$1" attempt
  echo "==> verifying ${url}/v1/health"
  for attempt in $(seq 1 20); do
    if body=$(curl -sf -m 5 "${url}/v1/health" 2>/dev/null); then
      echo "    $body"
      # The build identifier must be the one just built, or something older is still serving.
      if echo "$body" | grep -q "\"version\":\"${BUILD_ID}\""; then
        echo "==> ok — serving ${BUILD_ID}"
        return 0
      fi
      echo "    health answered but reports a different build than ${BUILD_ID}" >&2
      return 1
    fi
    sleep 1
  done
  echo "    no healthy response after 20 attempts" >&2
  return 1
}

# Splits the passthrough list into `-e NAME` arguments and a list of names to report.
#
# **A variable set to the empty string counts as absent.** `config.ts` parses every one of these
# with a non-empty schema, so forwarding an empty one turns a missing credential into a startup
# refusal (`exit 78`, EX_CONFIG) instead of the health-only degraded mode this script promises --
# which is the one outcome the ticket rules out, since it would make the script refuse something.
collect_passthrough() {
  local name
  for name in "${PASSTHROUGH[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      # `-e NAME`, never `-e NAME=value`: the value is read by Docker from this process's
      # environment and is never handled here.
      PASSTHROUGH_ARGS+=(-e "$name")
      PASSTHROUGH_FORWARDED=$((PASSTHROUGH_FORWARDED + 1))
    else
      PASSTHROUGH_ABSENT+=("$name")
    fi
  done
}

# Which routes the container actually mounts, **measured rather than asserted**.
#
# The founder running the sign-in rows in `docs/sonny-manual-test-checklist.md` §7 against this
# container needs a 404 on an auth route to read as this deployment's known state rather than as a
# defect to report. So it is probed and printed, once, next to the health check that already runs.
#
# **Forwarding the credentials above is now exactly what changes what this prints, and until
# SONNY-307 it was not** -- which is the whole reason this probe exists rather than a sentence. As
# SONNY-306 left it, `src/server.ts` called `buildApp(config)` with no `auth` argument and no
# concrete `AuthProvider` adapter existed, so no process this repository shipped mounted an auth
# route whatever its environment held: measured at `f65e72e` with all five names then forwarded
# present inside the container, still `404 resource.not_found`. SONNY-307 built the adapter
# (`src/auth/supabase.ts`) and the wiring (`src/auth/deps.ts`), and this probe flipped to the mounted
# branch on its own, with no edit to the function below -- which is what "probed rather than stated"
# was for.
#
# So the two branches now mean what they say: a 404 here is a container that was given none of the
# three Supabase names, and anything else is a container serving sign-in. A container given SOME of
# them never reaches this probe at all -- it exits 78 at startup and `verify` fails first.
#
# **The body is `{}` deliberately.** Once the route exists, `startBody` rejects that before anything
# is issued, so this probe can never send anyone a code and never needs a database. It reports and
# returns 0 whatever it finds: a deploy is not failed by this.
probe_auth_mount() {  # probe_auth_mount <base-url>
  local url="$1" code
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST "${url}/v1/auth/email/start" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
  if [[ "$code" == "404" ]]; then
    echo "==> auth routes are NOT mounted — POST /v1/auth/email/start answers 404. Health-only is"
    echo "    this deployment's honest state, not a defect. Since SONNY-307 this means the three"
    echo "    SUPABASE_ names were not set in the launching shell; set them to mount sign-in."
  elif [[ -z "$code" ]]; then
    echo "==> auth routes could not be probed — no response from ${url}/v1/auth/email/start"
  else
    echo "==> auth routes are mounted — POST /v1/auth/email/start answers ${code}, not 404"
  fi
  return 0
}

case "$TARGET" in
  local)
    build
    collect_passthrough
    echo "==> starting container"
    echo "    forwarding ${PASSTHROUGH_FORWARDED} of ${#PASSTHROUGH[@]} gateway credentials from this shell, by name"
    if (( ${#PASSTHROUGH_ABSENT[@]} > 0 )); then
      # Names only. No value is read to produce this line, and none could be.
      echo "    not set here, so not forwarded: ${PASSTHROUGH_ABSENT[*]}"
    fi
    docker rm -f sonny-gateway-local >/dev/null 2>&1
    docker run -d --name sonny-gateway-local -p 8080:8080 \
      -e SONNY_ENV=local -e LOG_LEVEL=debug \
      ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"} \
      "${IMAGE}:${BUILD_ID}" >/dev/null \
      || { echo "container failed to start" >&2; exit 1; }
    verify "http://localhost:8080" || { docker logs sonny-gateway-local >&2; exit 1; }
    probe_auth_mount "http://localhost:8080"
    echo "==> stop with: docker rm -f sonny-gateway-local"
    ;;

  staging|production)
    build
    cat >&2 <<STUB

==> STUB: no host is configured for "${TARGET}".

    The image was built and is ready: ${IMAGE}:${BUILD_ID}
    What did NOT happen: it was not pushed anywhere and nothing is running.

    This is deliberate, not an error to work around. The founder confirmed on 2026-08-21 that
    deploymind — the development host, and the first of the three — cannot receive a deploy yet.
    Beta runs on Oracle Cloud and v1 on AWS, and neither exists either.

    To fill this in, one host at a time, add below:
      1. a registry push        docker push ${IMAGE}:${BUILD_ID}
      2. a run on the host      whatever that host uses to run an OCI image
      3. the environment        SONNY_ENV=${TARGET}, DATABASE_URL, provider keys —
                                from the HOST's environment configuration, never from this repo
      4. the base URL           so verify() can confirm the new build is the one serving

    Then delete this message. The verify step above already works and needs no change.

    Owed: the first real remote deploy, recorded on SONNY-126.

STUB
    exit 3
    ;;

  *) usage ;;
esac
