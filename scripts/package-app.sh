#!/bin/bash
# Packages the MacAgent executable into a real, ad-hoc-signed MacAgent.app bundle.
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
# Usage: ./scripts/package-app.sh [debug|release]
# Output: .build/<triple>/<configuration>/MacAgent.app — launch with `open` or run the binary
# inside it directly (Contents/MacOS/MacAgent) to see console output live.

set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
  else
    codesign --force --deep --sign - "$APP_DIR"
  fi
}

echo "==> Code signing (ad hoc, with xattr-strip retries)"
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

echo "==> Done: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
echo "Or, to see console output live: \"$APP_DIR/Contents/MacOS/MacAgent\""
