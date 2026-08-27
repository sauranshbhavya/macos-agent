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
# container carrying the four Supabase names and not that one cannot serve a sign-in at all -- which
# is the outcome the single command exists for.
#
# Provider credentials (`OPENAI_API_KEY` and the four beside it) are deliberately **not** here. They
# belong to the routes SONNY-130 is building, that ticket is growing `config.ts` while this one is
# written, and its branch is where they are added if it needs them.
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
PASSTHROUGH=(
  SUPABASE_JWT_SECRET
  SUPABASE_JWT_ISSUER
  SUPABASE_JWT_AUDIENCE
  DATABASE_URL
  RATE_LIMIT_SALT
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
# **Forwarding the credentials above is not on its own enough to change what this prints**, and that
# is the part worth knowing before setting five variables and expecting a sign-in: `src/server.ts`
# calls `buildApp(config)` with no `auth` argument, and no concrete `AuthProvider` adapter exists, so
# no process this repository ships mounts an auth route whatever its environment holds. Measured at
# `f65e72e` with all five present inside the container -- still `404 resource.not_found`. Recorded on
# SONNY-306, which owns neither half of the fix.
#
# It is probed rather than stated so this cannot go stale: the day `server.ts` supplies `auth`, the
# same probe prints the other branch with no edit here.
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
    echo "    this deployment's honest state, not a defect, and no credential above changes it."
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
