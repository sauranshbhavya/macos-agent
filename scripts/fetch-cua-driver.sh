#!/bin/bash
# SONNY-80 experiment: fetches the pinned cua-driver release binary into vendor/ (gitignored —
# the ~59MB universal binary never enters git history). The CUA-backed vision substrate resolves
# it from vendor/cua-driver/cua-driver, a SONNY_CUA_DRIVER_PATH override, or the app bundle's
# Resources, in that order.
#
# Pin discipline: cua-driver is pre-1.0 with real wire-breaking releases (v0.11, v0.13.1, v0.15
# all changed surfaces this experiment depends on). Bump VERSION and SHA256 together, from
# https://github.com/trycua/cua/releases (tag cua-driver-rs-v<version>, checksums.txt), and
# re-run the founder-attended smoke test before trusting a new pin.

set -euo pipefail

VERSION="0.19.3"
ASSET="cua-driver-rs-${VERSION}-darwin-universal-binary.tar.gz"
SHA256="733e28a3782ac8d325f8fce8b5d97486c1054af755b40dfd086151b34c79377e"
URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${VERSION}/${ASSET}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/vendor/cua-driver"
mkdir -p "$DEST"
cd "$DEST"

if [ -x cua-driver ] && ./cua-driver --version 2>/dev/null | grep -q "cua-driver ${VERSION}"; then
  echo "cua-driver ${VERSION} already vendored at $DEST/cua-driver"
  exit 0
fi

echo "==> Downloading cua-driver ${VERSION}"
curl -fsSL -o "$ASSET" "$URL"

echo "==> Verifying checksum"
echo "${SHA256}  ${ASSET}" | shasum -a 256 -c -

echo "==> Extracting"
tar -xzf "$ASSET" cua-driver
rm -f "$ASSET"

./cua-driver --version

# Upstream enables content-free product telemetry by default; this runs on the founder's real
# workstation, so it stays off. Best-effort: an older/newer binary without the subcommand still
# vendors fine.
./cua-driver telemetry disable >/dev/null 2>&1 || true

echo "==> Done: $DEST/cua-driver"
