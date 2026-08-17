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
# Usage: ./scripts/package-app.sh [debug|release]
# Output: .build/<triple>/<configuration>/MacAgent.app — launch with `open` or run the binary
# inside it directly (Contents/MacOS/MacAgent) to see console output live.

set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib/signing.sh
. "$ROOT_DIR/scripts/lib/signing.sh"

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
  if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
  else
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
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
