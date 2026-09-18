#!/usr/bin/env bash
# Fetch one pinned cua-driver release into this experiment's own folder.
#
# The version and the SHA-256 are pinned HERE, not read from the release at download time: a
# checksum fetched from the same place as the tarball proves only that the two agree with each
# other. The pin below was read from the release's checksums.txt on 2026-09-17 (SONNY-517).
# Nothing is installed system-wide, nothing is added to PATH, and no sudo is used.
set -euo pipefail

VERSION="0.28.2"
TAG="cua-driver-rs-v${VERSION}"
ASSET="cua-driver-rs-${VERSION}-darwin-arm64.tar.gz"
SHA256="818ddefa0fa8ba2ec9cba837c7aa634a4b064221c748752cf49c5b08e2c94e8c"
URL="https://github.com/trycua/cua/releases/download/${TAG}/${ASSET}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HERE}/.cua-driver"
TARBALL="${DEST}/${ASSET}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "fetch-cua-driver: this pin is for macOS on Apple Silicon; found $(uname -s) $(uname -m)" >&2
  exit 1
fi

mkdir -p "${DEST}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "fetch-cua-driver: downloading ${ASSET} (~70 MB)"
  curl --fail --location --silent --show-error --output "${TARBALL}.partial" "${URL}"
  mv "${TARBALL}.partial" "${TARBALL}"
fi

ACTUAL="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL}" != "${SHA256}" ]]; then
  echo "fetch-cua-driver: checksum mismatch, refusing to unpack" >&2
  echo "  expected ${SHA256}" >&2
  echo "  actual   ${ACTUAL}" >&2
  rm -f "${TARBALL}"
  exit 1
fi

rm -rf "${DEST}/unpacked"
mkdir -p "${DEST}/unpacked"
tar -xzf "${TARBALL}" -C "${DEST}/unpacked"

BIN="$(find "${DEST}/unpacked" -type f -name 'cua-driver' -perm +111 | head -1)"
if [[ -z "${BIN}" ]]; then
  echo "fetch-cua-driver: unpacked the release but found no cua-driver executable in it" >&2
  exit 1
fi

# One stable path for the code to point at, whatever the tarball's inner layout is.
ln -sfn "${BIN}" "${DEST}/cua-driver"
echo "fetch-cua-driver: ready at ${DEST}/cua-driver"
"${DEST}/cua-driver" --version || true
