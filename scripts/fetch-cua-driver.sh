#!/usr/bin/env bash
# Puts cua-driver's in-process library where the Swift package links it: Vendor/cua-driver/.
#
# Sonny drives other apps through cua-driver (https://github.com/trycua/cua, MIT), loaded into
# Sonny's own process as libcua_driver_sdk.dylib (founders, 2026-09-24). The library is 54 MB, so
# it is fetched rather than committed. Run this once before `swift build`; package-app.sh runs it
# itself. It does nothing when the pinned version is already in place.
#
# The version and the SHA-256 are pinned HERE and never read from the release at download time:
# a changed asset under the same tag fails the check instead of reaching a build. To move to a new
# release, change both lines together, from that release's checksums.txt.
set -euo pipefail

VERSION="0.28.3"
ASSET="cua-driver-rs-${VERSION}-darwin-arm64.tar.gz"
SHA256="65b50e2f43df3dbd61dc615855c424f8c744dbb1527153b0dbbedb6f256d3801"
URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${VERSION}/${ASSET}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${REPO}/Vendor/cua-driver"
FILES=(libcua_driver_sdk.dylib cua_driver_abi.h LICENSE)

if [[ -f "${DEST}/VERSION" && "$(cat "${DEST}/VERSION")" == "${VERSION}" ]]; then
  present=1
  for file in "${FILES[@]}"; do [[ -f "${DEST}/${file}" ]] || present=0; done
  if [[ ${present} -eq 1 ]]; then
    echo "cua-driver ${VERSION} is already in Vendor/cua-driver"
    exit 0
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> fetching cua-driver ${VERSION}"
curl --fail --location --silent --show-error --output "${WORK}/${ASSET}" "${URL}"
ACTUAL="$(shasum -a 256 "${WORK}/${ASSET}" | awk '{print $1}')"
if [[ "${ACTUAL}" != "${SHA256}" ]]; then
  echo "error: ${ASSET} does not match its pinned SHA-256" >&2
  echo "  expected ${SHA256}" >&2
  echo "  got      ${ACTUAL}" >&2
  exit 1
fi

tar -xzf "${WORK}/${ASSET}" -C "${WORK}"
UNPACKED="${WORK}/cua-driver-rs-${VERSION}-darwin-arm64"

# Sonny switches cua's telemetry off always (founders, 2026-09-24). The in-process library carries
# none — the PostHog sender lives in the CLI — and this keeps it that way: a release that brings it
# into the library stops here rather than shipping inside Sonny.
if strings -n 8 "${UNPACKED}/libcua_driver_sdk.dylib" | grep -qi 'posthog'; then
  echo "error: cua-driver ${VERSION}'s library contains telemetry code; Sonny ships none" >&2
  exit 1
fi

mkdir -p "${DEST}"
for file in "${FILES[@]}"; do
  cp "${UNPACKED}/${file}" "${DEST}/${file}"
done
echo "${VERSION}" > "${DEST}/VERSION"
echo "==> cua-driver ${VERSION} is in Vendor/cua-driver"
