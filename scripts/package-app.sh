#!/bin/bash
# Packages the MacAgent executable into a real, code-signed MacAgent.app bundle.
#
# Why this exists: several macOS APIs Sonny depends on (UNUserNotificationCenter for system
# notifications, AVCaptureDevice's microphone permission prompt, NSAppleEventsUsageDescription-
# gated automation of Finder/Word) require the running process to have a real app-bundle identity
# registered with LaunchServices. `swift run`'s bare executable has none of that and either
# silently fails or crashes outright when those APIs are touched — this script is the actual fix,
# not a workaround: it gives the built binary a genuine bundle so those APIs work for real.
#
# `swift build`/`swift test` are untouched by this — this is an optional extra packaging step for
# when you want to manually test bundle-dependent behavior, not a replacement for the normal dev
# loop.
#
# Signing identity: read from Packaging/signing-identity, which is the one place it is named.
# First run on a new Mac needs ./scripts/create-signing-identity.sh — read that script's header for
# why ad-hoc signing was replaced (SONNY-153) and for what the local certificate is and is not.
#
# Release entitlements and hardening: read from Packaging/MacAgent.entitlements, which is the one
# place they are named (SONNY-156). Release adds the hardened runtime and that file; debug keeps
# SwiftPM's own generated plist and no hardening, unchanged. After signing, this script reads the
# entitlements back off the bundle and refuses to finish if a release build carries
# com.apple.security.get-task-allow or is missing the hardened runtime — both are notarization
# blockers that would otherwise surface as a confusing rejection from Apple rather than here.
#
# Neither this script nor anything else in the repo notarizes. That step does not exist yet and is
# gated on the founder's Apple Developer enrolment; SONNY-106 section E is the condition it serves.
#
# Usage: ./scripts/package-app.sh [debug|release]
# Output: .build/<triple>/<configuration>/MacAgent.app — launch with `open` or run the binary
# inside it directly (Contents/MacOS/MacAgent) to see console output live.

set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/signing.sh
. "$ROOT_DIR/scripts/lib/signing.sh"

# This script builds whatever is on disk and hands the founder a .app to test by hand — which for
# some behaviour is the only verification it ever gets. A tree that is mid-mutant, or that a killed
# battery left mutated, would be packaged into that bundle without a word, and the manual pass would
# then be testing a deliberate defect (SONNY-258, SONNY-347).
# shellcheck source=lib/battery-state.sh
. "$ROOT_DIR/scripts/lib/battery-state.sh"
battery_state
case "$BATTERY_STATE" in
  live|abandoned)
    battery_journal "scripts/package-app.sh" "refused to package: battery state is $BATTERY_STATE"
    printf 'error: refusing to package — this working tree is under a mutation battery.\n\n' >&2
    battery_state_detail >&2
    printf '\nA bundle built now would carry a mutant, and the manual pass over it is the only\n' >&2
    printf 'verification some of this behaviour ever gets.\n' >&2
    exit 1
    ;;
esac

SIGN_IDENTITY="$(sonny_read_signing_identity "$ROOT_DIR")"

if sonny_signing_identity_is_adhoc "$SIGN_IDENTITY"; then
  echo "warning: $SONNY_SIGNING_IDENTITY_FILE selects ad-hoc signing." >&2
  echo "         Every macOS permission grant (Screen Recording, Accessibility, Microphone," >&2
  echo "         Desktop folder) will be lost the next time this app is rebuilt. See SONNY-153." >&2
elif ! sonny_signing_identity_present "$SIGN_IDENTITY"; then
  cat >&2 <<EOF
error: codesign cannot find the signing identity '$SIGN_IDENTITY'.

       $SONNY_SIGNING_IDENTITY_FILE names it, but it is not in this Mac's keychain.

       If this is a development machine, create it once:
           ./scripts/create-signing-identity.sh

       If that file has been switched to an Apple-issued Developer ID identity, install the
       certificate from the Apple Developer account first — this script cannot create that one.

       Refusing to fall back to ad-hoc signing: an ad-hoc build loses every macOS permission grant
       on every rebuild, silently, while System Settings keeps showing the switches on. That
       failure is what SONNY-153 removed, and it is not worth reintroducing quietly to save a
       packaging run.
EOF
  exit 1
fi

echo "==> Building MacAgent ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION"

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/MacAgent"
RESOURCE_BUNDLE="$BIN_PATH/MacAgent_MacAgent.bundle"
ENTITLEMENTS="$BIN_PATH/MacAgent-entitlement.plist"
RELEASE_ENTITLEMENTS="$ROOT_DIR/Packaging/MacAgent.entitlements"

# Signing differs by configuration, and only for release (SONNY-156).
#
# Debug keeps exactly what it had: SwiftPM's own generated entitlement plist, whose single key is
# `com.apple.security.get-task-allow` — the thing that lets a debugger attach — and no hardened
# runtime. That is the founder's daily loop and this change deliberately leaves it alone.
#
# Release signs with the hardened runtime, which notarization requires, and with the committed
# Packaging/MacAgent.entitlements rather than anything SwiftPM generated. Read that file for why
# each key is in it; the short version is that hardened runtime restricts microphone access and
# Apple Events, both of which Sonny uses, so the flag cannot be added on its own.
#
# Measured at d1cea05: SwiftPM writes MacAgent-entitlement.plist for debug and NOT for release, so
# release never carried get-task-allow to begin with. That was an accident of the toolchain rather
# than a decision — nothing in this repo checked it. The verification step after signing is what
# turns it into a checked property.
if [ "$CONFIGURATION" = "release" ]; then
  if [ ! -f "$RELEASE_ENTITLEMENTS" ]; then
    echo "error: release entitlements not found at $RELEASE_ENTITLEMENTS" >&2
    echo "       A release build must be signed with a known entitlement set, not with whatever" >&2
    echo "       SwiftPM happened to generate. See SONNY-156." >&2
    exit 1
  fi
  SIGN_ENTITLEMENTS="$RELEASE_ENTITLEMENTS"
  # Deliberately a plain string rather than an array: this script runs under macOS's /bin/bash 3.2,
  # where expanding an empty array under `set -u` is an unbound-variable error. The value is a
  # controlled literal, so the unquoted expansion below is the intended word split.
  SIGN_OPTIONS="--options runtime"
else
  SIGN_ENTITLEMENTS="$ENTITLEMENTS"
  SIGN_OPTIONS=""
fi

if [ ! -x "$EXECUTABLE" ]; then
  echo "error: built executable not found at $EXECUTABLE" >&2
  exit 1
fi
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "error: resource bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi

APP_DIR="$BIN_PATH/MacAgent.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/MacAgent"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

# Deliberately Contents/Resources/, not the app's top level. SwiftPM's own auto-generated
# resource_bundle_accessor.swift looks for this bundle at Bundle.main.bundleURL's top level
# (correct only for a bare `swift run` executable, where bundleURL is the .build directory itself)
# — for a real .app, that resolves to the app's outer directory, and `codesign` refuses to seal
# anything placed there outside Contents/ ("unsealed contents present in the bundle root",
# confirmed directly, not assumed). AppDelegate.swift no longer uses that generated accessor at
# all for exactly this reason — it resolves this same bundle itself, checking Contents/Resources/
# first.
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/MacAgent_MacAgent.bundle"

# codesign refuses to seal a bundle carrying resource-fork/Finder-info xattrs. Stripping them once
# isn't reliable: macOS (Finder/Spotlight) can asynchronously re-stamp a freshly created *.app
# directory with `com.apple.FinderInfo` moments after it appears on disk, racing the strip — this
# was directly observed (an identical strip+sign that failed once succeeded a few seconds later
# with no code change), not a hypothetical. Retry the strip+sign cycle instead of hoping the first
# attempt wins the race.
sign_app() {
  xattr -cr "$APP_DIR"
  # shellcheck disable=SC2086 # $SIGN_OPTIONS is a controlled literal; the word split is intended.
  if [ -n "$SIGN_ENTITLEMENTS" ] && [ -f "$SIGN_ENTITLEMENTS" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" $SIGN_OPTIONS --entitlements "$SIGN_ENTITLEMENTS" "$APP_DIR"
  else
    codesign --force --deep --sign "$SIGN_IDENTITY" $SIGN_OPTIONS "$APP_DIR"
  fi
}

echo "==> Code signing as '$SIGN_IDENTITY' (with xattr-strip retries)"
if ! sonny_signing_identity_is_adhoc "$SIGN_IDENTITY"; then
  # If codesign has never been authorised to use this key, macOS blocks here on a GUI dialog and
  # this script produces no further output until someone clicks it — a hang with no explanation,
  # which is exactly how it presented the first time. Say so before it can happen.
  echo "    (if this stops here, macOS is asking whether codesign may use the key —"
  echo "     answer it with \"Always Allow\", or run ./scripts/create-signing-identity.sh)"
fi
SIGN_ATTEMPTS=5
attempt=1
while true; do
  if sign_app; then
    break
  fi
  if [ "$attempt" -ge "$SIGN_ATTEMPTS" ]; then
    echo "error: code signing failed after $SIGN_ATTEMPTS attempts" >&2
    exit 1
  fi
  echo "codesign attempt $attempt failed, likely lost the Finder-info-xattr race — retrying ($((attempt + 1))/$SIGN_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep 1
done

echo "==> Verifying signature"
codesign --verify --verbose "$APP_DIR"

# What the bundle is actually sealed with, read back off the signature rather than inferred from
# what was passed in (SONNY-156). `codesign -d --entitlements` prints `Executable=...` on stderr and
# the plist on stdout, so stderr is dropped here.
echo "==> Verifying entitlements"
SEALED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_DIR" 2>/dev/null || true)"

# The notarization blocker this check exists for. Apple's notary service rejects any submission
# carrying com.apple.security.get-task-allow, and it presents as a confusing rejection rather than
# as an obvious build-script problem. Fail here instead, where the cause is on screen.
#
# Checked for every configuration, not just release. Debug is *expected* to carry it and says so
# below; the point of checking both is that this script stops being the thing that has to remember
# which configuration is which.
case "$SEALED_ENTITLEMENTS" in
  *get-task-allow*)
    if [ "$CONFIGURATION" = "release" ]; then
      cat >&2 <<EOF
error: this release bundle is sealed with com.apple.security.get-task-allow.

       Apple's notary service rejects any submission carrying it, so this build cannot be
       notarized. Refusing to finish rather than handing over a bundle that fails later, at a
       step where the cause is much harder to see.

       Nothing should have put it there: release signs with $RELEASE_ENTITLEMENTS, which omits it.
       Check whether SwiftPM has started generating MacAgent-entitlement.plist for release — it did
       not at d1cea05 — and whether something is passing that file through. See SONNY-156.
EOF
      exit 1
    fi
    echo "    com.apple.security.get-task-allow: present (expected for debug — lets a debugger attach)"
    ;;
  *)
    echo "    com.apple.security.get-task-allow: absent"
    ;;
esac

if [ "$CONFIGURATION" = "release" ]; then
  # Hardened runtime is the other notarization requirement, and it is a signature flag rather than
  # anything visible in the entitlements, so it is checked separately. `codesign -d -v` prints it as
  # `flags=0x10000(runtime)`.
  #
  # The output is captured first and matched second, deliberately. Piping straight into `grep -q`
  # looks tidier and is wrong here: this script runs under `set -o pipefail`, `grep -q` exits the
  # moment it matches, and `codesign` then dies of SIGPIPE — so the pipeline reports failure exactly
  # when the match succeeds. That inverted check reported a correctly hardened bundle as unhardened
  # on the first run of this code, which is a false negative on a release gate.
  CODESIGN_INFO="$(codesign -d -v "$APP_DIR" 2>&1 || true)"
  if printf '%s\n' "$CODESIGN_INFO" | grep -q 'flags=[^ ]*runtime'; then
    echo "    hardened runtime: on"
  else
    echo "error: this release bundle is not signed with the hardened runtime." >&2
    echo "       Notarization requires it. Expected codesign to report flags=0x10000(runtime)." >&2
    echo "       See SONNY-156." >&2
    exit 1
  fi
  echo "    sealed entitlements:"
  echo "$SEALED_ENTITLEMENTS" | /usr/bin/plutil -p - 2>/dev/null | sed 's/^/      /' \
    || echo "      (could not pretty-print; raw plist above)"
fi

# Print the designated requirement, because it — not the identity name — is what macOS actually
# keys permission grants to. A requirement that is a bare `cdhash H"..."` means the grants will not
# survive the next rebuild; anything naming an identifier and a certificate means they will.
echo "==> Designated requirement (what macOS keys permission grants to)"
# An ad-hoc signature's requirement prints commented out — `# designated => cdhash H"..."` — while
# a certificate's prints bare: `designated => identifier "..." and certificate leaf = H"..."`.
# Matching only the bare form silently dropped the ad-hoc case, which is the one this warning
# exists for. Tolerate the leading `#`.
REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>/dev/null | grep -E '^#?[[:space:]]*designated' || true)"
echo "${REQUIREMENT:-  (none reported)}"
case "$REQUIREMENT" in
  *"cdhash"*)
    echo "warning: this build's grants are pinned to its own hash and will be lost on the next" >&2
    echo "         rebuild. See SONNY-153 and ./scripts/create-signing-identity.sh." >&2
    ;;
esac

echo "==> Done: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
echo "Or, to see console output live: \"$APP_DIR/Contents/MacOS/MacAgent\""
