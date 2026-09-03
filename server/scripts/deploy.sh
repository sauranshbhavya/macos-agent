#!/usr/bin/env bash
# SONNY-126: the gateway's deploy path.
#
#   ./scripts/deploy.sh <local|staging|production>
#
# **Two of the three targets are stubs today, and that is recorded rather than hidden.** No remote
# host is provisioned: Oracle Cloud is the first one and it does not exist yet. So this script
# builds and proves the entire path — image build, build-identifier injection, container start,
# health verification — against `local`, and refuses `staging` and `production` with an explicit
# message naming what is missing. It does not pretend to deploy, and it does not silently succeed.
#
# What makes the stub cheap to replace: both hosts on the timeline (Oracle, then AWS) receive the
# same thing — an OCI image and a set of environment variables. Filling in a target is a `push` and
# a `run` for that host, not a rewrite of this script.
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
# **SONNY-132 added two of the three names that sentence held open, and left the third.** The
# sentence said `ANTHROPIC_API_KEY`, `CEREBRAS_API_KEY` and `VISION_API_KEY` were absent because no
# route read them. The provider router now reads two: `ANTHROPIC_API_KEY` serves `/v1/plan` and
# `/v1/research/synthesize` as the shipped failover candidate, and `CEREBRAS_API_KEY` serves them
# whenever a `MODEL_ROUTE_*` chain names it. `VISION_API_KEY` stays absent for the original reason —
# `/v1/screen/analyze` is SONNY-131's and no route reads it yet.
#
# **A container given no Anthropic key is not broken.** The chain drops an entry it has no credential
# for, so a local run with only `OPENAI_API_KEY` behaves exactly as it did before the router existed.
# Forwarding the name costs nothing when it is unset, and is what makes a founder's failover check a
# matter of exporting one variable.
#
# **The endpoint, model, routing and data-policy settings are forwarded too, by a second array**,
# `PASSTHROUGH_SETTINGS` below. They are not credentials — every one has a real default and none is
# a secret — so they are reported as a count rather than by name, and the credential lines above and
# below keep meaning exactly what they meant: "did my key get in".
#
# **They are forwarded because otherwise the one thing this ticket exists to demonstrate cannot be
# demonstrated with this command.** SONNY-132's headline acceptance criterion is that a planner
# request is served by one provider or another *purely by changing server configuration*, and the
# founder's manual rows are written as `MODEL_ROUTE_PLAN=anthropic ./scripts/deploy.sh local`. With
# only credentials forwarded, that line starts a container that silently uses the default chain and
# prints a routing log saying so — measured, at `06031ac`, before this array existed: `MODEL_ROUTE_PLAN`
# exported as `anthropic,openai`, the container's own line reading `"plan":["openai","anthropic"]`.
# A demonstration that quietly does not demonstrate the thing is worse than one that refuses.
#
# **The rule the two arrays together track is "a name that changes what the gateway does with a
# request", not "every name `config.ts` reads".** What is deliberately still absent is the set that
# describes the *container* rather than the traffic: `SONNY_ENV` and `LOG_LEVEL` are set explicitly
# below, `PORT`, `HOST` and `SONNY_BUILD_ID` are the image's own and injected at build time, and
# `TRUSTED_PROXIES` is correct empty with no proxy in front and actively wrong inherited from a
# shell. `VISION_API_KEY` is absent for its own reason, above.
#
# **The paragraph stamped at `f65e72e` says "eleven names ... the five that remain are these", and
# both halves are that tree's rather than this one's.** Re-measured on the working tree: the schema
# holds **26** names (`grep -oE '^  [A-Z_]+:' src/config.ts | tr -d ' :' | sort | wc -l` -> 26),
# `providerDataPolicies` reads a further **10** off the environment that the schema never sees, this
# credential array holds **11** and the settings array **25**. The historical figure is left as it
# was written, per this repository's rule about dated records, rather than edited to agree with a
# tree it was not taken on.
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
  # SONNY-135's three. All three are required wherever auth is mounted, so a container given the
  # Supabase names and not these exits 78 naming them -- which is the intended failure and not a
  # regression: the alternative is a gateway that mounts authenticated routes it cannot check
  # entitlements or spend for.
  ENTITLEMENT_SIGNING_KEY
  ENTITLEMENT_SIGNING_KEY_ID
  SPEND_CAP_UNITS
  # SONNY-212's one, joining the three above on exactly their rule: `CREDIT_PLANS` is required
  # wherever auth is mounted, so a container given the Supabase names and not this exits 78 naming
  # it. It is the one entry here that is not a credential -- it holds tiers, allowances and credit
  # weights, no secret of any kind -- and it is forwarded the same way regardless, because what
  # decides this list is what `src/config.ts` requires and not what is sensitive.
  CREDIT_PLANS
  # SONNY-130's two, and SONNY-132's two. See the block above for why these four and not VISION_API_KEY.
  OPENAI_API_KEY
  TAVILY_API_KEY
  # SONNY-131's one, on the same rule: `POST /v1/screen/analyze` is mounted by a running container
  # whatever the environment holds, so a container without this serves `502 provider.unavailable`.
  VISION_API_KEY
  # SONNY-132's two. The sentence that stood here said ANTHROPIC and CEREBRAS "stay off, because no
  # route reads them"; the provider router reads both, so both are forwarded. A container given
  # neither is unchanged -- a chain entry with no credential is not a candidate.
  ANTHROPIC_API_KEY
  CEREBRAS_API_KEY
)

# Everything else that changes what the gateway does with a request: where each provider sends, what
# it asks for, which providers serve which route, and what this deployment has been told about each
# provider's retention and training terms. Not secrets, all defaulted, so absence is uninteresting
# and is reported as a count rather than as a list of names.
PASSTHROUGH_SETTINGS=(
  OPENAI_BASE_URL
  OPENAI_TEXT_MODEL
  OPENAI_TRANSCRIPTION_MODEL
  SEARCH_BASE_URL
  ANTHROPIC_BASE_URL
  ANTHROPIC_TEXT_MODEL
  ANTHROPIC_MAX_OUTPUT_TOKENS
  CEREBRAS_BASE_URL
  CEREBRAS_TEXT_MODEL
  # SONNY-131's, on this array's own rule: they change what the gateway does with a request, they are
  # not credentials, and they have real defaults. The vision route is not part of the provider router,
  # so it has no MODEL_ROUTE_* entry — only an endpoint and a model.
  VISION_BASE_URL
  VISION_MODEL
  MODEL_ROUTE_PLAN
  MODEL_ROUTE_SYNTHESIZE
  MODEL_ROUTE_TRANSCRIPTIONS
  MODEL_ROUTE_SEARCH
  OPENAI_DATA_RETENTION
  OPENAI_TRAINING
  ANTHROPIC_DATA_RETENTION
  ANTHROPIC_TRAINING
  CEREBRAS_DATA_RETENTION
  CEREBRAS_TRAINING
  TAVILY_DATA_RETENTION
  TAVILY_TRAINING
  VISION_DATA_RETENTION
  VISION_TRAINING
  # SONNY-134's two, on this array's own rule: they change what the gateway does with a request, they
  # are not credentials, and both have real defaults. **The first is the one that matters**: without
  # it here, `CONTENT_RETENTION_DAYS` is unsettable on any deployment, so the founder's confirmed
  # thirty days would be a number the container could never be told — which is how a configurable
  # window ends up being one value forever. Measured rather than reasoned: with
  # `CONTENT_EXPIRY_SWEEP_SECONDS=60` in the launching shell and neither name on this list, the
  # container swept once at startup and not again, and an already-expired row planted in its database
  # was still there seventy-five seconds later.
  CONTENT_RETENTION_DAYS
  CONTENT_EXPIRY_SWEEP_SECONDS
  # SONNY-204's three, on this array's own rule and for the reason the two above it record. They
  # change what the gateway does with every request -- below MINIMUM_SUPPORTED_CLIENT it answers 410
  # on every route, and below RECOMMENDED_CLIENT it adds two headers -- and none of the three is a
  # secret: two are version numbers and the third is a public download page.
  #
  # **Without them here the version gate is unconfigurable on the only deploy target that exists.**
  # Both bounds default to 0.0.0, which disarms the gate, so a container that can never be told a
  # minimum is a container where this feature is permanently off -- which is exactly the shape
  # CONTENT_RETENTION_DAYS' comment above records ("how a configurable window ends up being one
  # value forever"), and the founder's manual rows for this feature are `curl` against a local
  # container and cannot be run at all without them.
  #
  # **UPGRADE_URL is the one entry on this list with no default**, which is the credential array's
  # rule rather than this one's. It sits here anyway, because what the other array's by-name absence
  # report is for is "did my key get in", and this name is legitimately unset on every deployment
  # today -- listing it as missing on every run would be noise around the lines that mean something.
  # Its absence is not silent either way: startup refuses to arm either bound without it, by name.
  MINIMUM_SUPPORTED_CLIENT
  RECOMMENDED_CLIENT
  UPGRADE_URL
)

# Filled by `collect_passthrough`. Declared here, empty, because `set -u` plus bash 3.2 --
# which is what `/usr/bin/env bash` is on a founder's Mac -- treats "${ARR[@]}" on an unset or
# empty array as an unbound variable, and "nothing was set" is this list's ordinary case.
PASSTHROUGH_ARGS=()
PASSTHROUGH_ABSENT=()
PASSTHROUGH_FORWARDED=0
SETTINGS_FORWARDED=0

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
  # Same `-e NAME` form, same no-value guarantee. Counted separately so the credential lines above
  # keep saying only what they have always said.
  for name in "${PASSTHROUGH_SETTINGS[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      PASSTHROUGH_ARGS+=(-e "$name")
      SETTINGS_FORWARDED=$((SETTINGS_FORWARDED + 1))
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
# three *trigger* names, and anything else is a container serving sign-in. **The 404 branch used to
# say "the three SUPABASE_ names" while the `not set here` line above it listed four** (PR #137
# review, N5): `PASSTHROUGH` carries four `SUPABASE_`-prefixed names and only three of them are the
# switch, `SUPABASE_JWT_AUDIENCE` being defaulted and therefore no signal of intent. A founder
# reading the two lines together had to derive that, so the branch now names the three. A container given SOME of
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
    echo "    this deployment's honest state, not a defect. Since SONNY-307 this means none of"
    echo "    SUPABASE_JWT_SECRET, SUPABASE_JWT_ISSUER or SUPABASE_ANON_KEY was set in the"
    echo "    launching shell — those three are the switch. Set them to mount sign-in."
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
    # A count, not names: these are defaulted settings rather than credentials, so "not set" is the
    # ordinary case and listing twenty-five of them every run would bury the credential line above.
    # What the container actually resolved to is printed by the gateway itself, at startup, on its
    # `"msg":"model routing"` line -- which is the honest place to read routing from, since it
    # reports what the process decided rather than what this script forwarded.
    echo "    forwarding ${SETTINGS_FORWARDED} of ${#PASSTHROUGH_SETTINGS[@]} routing/endpoint settings; the rest take their defaults"
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

    This is deliberate, not an error to work around. Oracle Cloud is the first host — beta runs
    there and v1 on AWS — and neither is provisioned yet, so there is nowhere to push to.

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
