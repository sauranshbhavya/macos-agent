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
BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && DIRTY=" (working tree dirty)"

usage() { echo "usage: $0 <local|staging|production>" >&2; exit 2; }
[[ -z "$TARGET" ]] && usage

build() {
  echo "==> building ${IMAGE}:${BUILD_ID}${DIRTY}"
  docker build --build-arg SONNY_BUILD_ID="${BUILD_ID}" -t "${IMAGE}:${BUILD_ID}" -t "${IMAGE}:latest" . \
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

case "$TARGET" in
  local)
    build
    echo "==> starting container"
    docker rm -f sonny-gateway-local >/dev/null 2>&1
    docker run -d --name sonny-gateway-local -p 8080:8080 \
      -e SONNY_ENV=local -e LOG_LEVEL=debug "${IMAGE}:${BUILD_ID}" >/dev/null \
      || { echo "container failed to start" >&2; exit 1; }
    verify "http://localhost:8080" || { docker logs sonny-gateway-local >&2; exit 1; }
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
