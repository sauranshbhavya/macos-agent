#!/bin/bash
# Creates the local code-signing certificate that scripts/package-app.sh signs MacAgent.app with,
# and authorises codesign to use it. Run once per Mac, from a terminal. Safe to re-run: it creates
# nothing that already exists, and re-running is the way to answer the authorisation dialog again
# if it was missed the first time.
#
# WHY THIS EXISTS (SONNY-153). Before this, package-app.sh signed ad hoc — `codesign --sign -`.
# An ad-hoc signature has no identity, so macOS keys every permission grant to that one build's
# hash. Measured: the designated requirement of an ad-hoc build is the literal
# `cdhash H"41bdd194..."` and nothing else. Change one line of Swift, repackage, and the hash
# changes, so Screen Recording, Accessibility, Microphone and Desktop-folder access are all silently
# lost — macOS logs `Failed to match existing code requirement for subject com.sonny.MacAgent`
# while System Settings still shows the switches on. That made the founder's manual pass, which is
# the only verification some behaviour ever gets, impossible.
#
# Signing with a certificate instead changes the designated requirement to
# `identifier "com.sonny.MacAgent" and certificate leaf = H"..."`, which does not move when the
# build does. Grants then survive rebuilds and survive being packaged from a different worktree.
#
# WHAT THIS CERTIFICATE IS, AND IS NOT.
#   * It is a local build credential. The private key is created on this Mac, imported into this
#     user's login keychain, and never leaves it. It is never committed and never goes into Plane.
#     The temporary files holding it during creation are deleted before this script exits.
#   * It is NOT a distribution identity, and this is NOT the v1 release requirement. SONNY-106
#     section E requires a Developer ID signed AND notarized build, gated on the founder's Apple
#     Developer enrolment (section F). A self-signed certificate satisfies neither. It does nothing
#     for anyone else installing Sonny; Gatekeeper still refuses this build on any other Mac.
#     Do not tick that release condition off the back of this script.
#
# WHEN THE APPLE ENROLMENT COMPLETES: do not run this script. Install the Developer ID Application
# certificate from Apple, then put its identity name in Packaging/signing-identity. Nothing else
# changes. (This script refuses to fabricate a self-signed lookalike of an Apple identity name.)
#
# TO REMOVE THE CERTIFICATE AGAIN: security delete-identity -c "Sonny Local Dev"
#
# Usage: ./scripts/create-signing-identity.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/signing.sh
. "$ROOT_DIR/scripts/lib/signing.sh"

IDENTITY="$(sonny_read_signing_identity "$ROOT_DIR")"

if sonny_signing_identity_is_adhoc "$IDENTITY"; then
  cat >&2 <<EOF
error: $SONNY_SIGNING_IDENTITY_FILE is set to '-', which means ad-hoc signing.
       There is no certificate to create. Ad-hoc signing is what SONNY-153 removed: it loses every
       macOS permission grant on every rebuild. Put an identity name in that file and re-run.
EOF
  exit 1
fi

if sonny_signing_identity_is_apple_issued "$IDENTITY"; then
  cat >&2 <<EOF
error: '$IDENTITY' is an Apple-issued identity. This script cannot create it, and must not create
       a self-signed certificate wearing that name — the result would look like an Apple identity
       in every listing while being nothing of the kind.

       Get it from Apple instead: download the certificate from the Apple Developer account and
       open it, which installs it into the login keychain. Then re-run:
           ./scripts/package-app.sh debug
EOF
  exit 1
fi

# The private key exists on disk only inside this directory, only for the duration of the import.
# The trap fires on success, on error (set -e) and on interrupt alike.
WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------------------------
# Step 1 — the certificate itself. Skipped when it already exists, so re-running is cheap and safe.
# ---------------------------------------------------------------------------------------------

if sonny_signing_identity_present "$IDENTITY"; then
  echo "==> '$IDENTITY' already exists in the keychain — not creating it again."
else
  KEYCHAIN="$(security default-keychain -d user 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
  if [ -z "$KEYCHAIN" ]; then
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  fi

  echo "==> Creating a self-signed code-signing certificate: $IDENTITY"

  cat > "$WORK_DIR/codesign.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -config "$WORK_DIR/codesign.cnf" >/dev/null 2>&1

  # The passphrase protects the bundle for the few milliseconds it sits in $WORK_DIR before import.
  # It is never stored anywhere and is not the keychain's password.
  TRANSIT_PASSPHRASE="$(openssl rand -hex 32)"

  # macOS's Security framework cannot read OpenSSL 3's default PKCS#12 encryption (AES-256-CBC with
  # PBKDF2) — `security import` fails with "MAC verification failed during PKCS12 import (wrong
  # password?)", which reads like a passphrase bug and is not one. The legacy SHA1/3DES encoding is
  # what it understands. Found the hard way; do not remove these flags.
  openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$TRANSIT_PASSPHRASE" \
    -name "$IDENTITY" >/dev/null 2>&1

  echo "==> Importing into $KEYCHAIN"
  security import "$WORK_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$TRANSIT_PASSPHRASE" \
    -A -T /usr/bin/codesign

  if ! sonny_signing_identity_present "$IDENTITY"; then
    echo "error: import reported success but codesign still cannot find '$IDENTITY'" >&2
    echo "       check: security find-identity -p codesigning" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------------------------
# Step 2 — authorise codesign to use the key. Runs every time, including when step 1 was skipped,
# because a certificate that exists but is unauthorised is exactly the state a missed dialog leaves
# behind, and re-running this script has to be able to fix it.
#
# macOS guards a new private key with a per-application access list, and neither `-A` nor
# `-T /usr/bin/codesign` on import is enough on its own — the modern partition list overrides both.
# Until codesign is authorised, EVERY build pops a GUI dialog and blocks until someone clicks it.
# That was found the hard way while building this: `./scripts/package-app.sh` hung with no output
# at all, waiting on an invisible SecurityAgent prompt.
#
# So the authorisation is forced to happen here, in the script whose whole job is one-time setup,
# rather than ambushing a build later. Signing a throwaway copy of a system binary is what triggers
# the dialog. The alternative — `security set-key-partition-list` — needs the login keychain
# password, and a script that asks for that is worse than a dialog macOS asks for itself.
# Signing again once already authorised is instant and shows nothing, so this is safe to repeat.
# ---------------------------------------------------------------------------------------------

echo "==> Authorising codesign to use the key"

if [ -t 0 ]; then
  cp /bin/echo "$WORK_DIR/warmup"
  cat <<'EOF'

    macOS may now ask whether codesign can use this key. If it does:

    >>> Click "Always Allow", not "Allow". <<<

    "Allow" answers only this one time, and the dialog comes back on every single build.
    "Always Allow" answers it permanently. Nothing else on this Mac is affected — the
    answer applies to this one key. If no dialog appears, it is already answered.

EOF
  if codesign --force --sign "$IDENTITY" "$WORK_DIR/warmup" >/dev/null 2>&1; then
    echo "    signed successfully — builds will not be interrupted."
  else
    echo "    warning: that signing attempt failed or was cancelled." >&2
    echo "             Builds will keep blocking on the dialog until it is answered with" >&2
    echo "             \"Always Allow\". Re-run this script to be asked again." >&2
  fi
else
  echo "    skipped — not running in a terminal, so a GUI dialog could not be answered."
  echo "    Run this script from a terminal before packaging, or the first build will block"
  echo "    on an invisible macOS dialog with no output explaining why."
fi

echo
echo "==> Done. codesign can now find it:"
security find-identity -p codesigning | grep -F "\"$IDENTITY\""
echo
cat <<EOF
It is listed as CSSMERR_TP_NOT_TRUSTED, and that is expected and fine. The certificate signed
itself, so no authority vouches for it. codesign signs and verifies with it regardless; what
matters here is that the identity is stable, not that anyone trusts it.

Next, once only:

  1. Clear the permission grants macOS is still holding against old ad-hoc builds:
         killall MacAgent 2>/dev/null
         tccutil reset All com.sonny.MacAgent

  2. Rebuild and launch:
         ./scripts/package-app.sh debug
         open .build/arm64-apple-macosx/debug/MacAgent.app

  3. Grant Screen Recording and Accessibility again, and relaunch when the app asks.

From then on the grants persist across rebuilds. Full procedure:
docs/sonny-manual-test-checklist.md, section 0.
EOF
