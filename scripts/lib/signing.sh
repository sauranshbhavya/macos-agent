# Shared code-signing helpers. Sourced by scripts/package-app.sh and
# scripts/create-signing-identity.sh; not executable on its own.
#
# Everything here exists so that both scripts read the identity from the same one place —
# Packaging/signing-identity — rather than each hardcoding a name. That file is the seam SONNY-153
# was built around: swapping the local development certificate for a real Developer ID one is a
# one-line change there, not an edit to either script.

SONNY_SIGNING_IDENTITY_FILE="Packaging/signing-identity"

# Prints the configured identity to stdout. The first line that is neither blank nor a full-line
# comment wins. Comments are full-line only, deliberately: a real Developer ID name is of the form
# `Developer ID Application: Name (TEAMID)`, and stripping inline `#` would be a trap waiting for a
# name that happens to contain one.
sonny_read_signing_identity() {
  local root="$1"
  local file="$root/$SONNY_SIGNING_IDENTITY_FILE"

  if [ ! -f "$file" ]; then
    echo "error: signing identity file not found at $file" >&2
    return 1
  fi

  local identity
  identity="$(grep -v '^[[:space:]]*#' "$file" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' \
    | head -1)"

  if [ -z "$identity" ]; then
    echo "error: $file names no identity (every line is blank or a comment)" >&2
    return 1
  fi

  echo "$identity"
}

sonny_signing_identity_is_adhoc() {
  [ "$1" = "-" ]
}

# True when codesign can find the named identity.
#
# Deliberately NOT `security find-identity -v`. The `-v` flag lists only identities with a trusted
# chain, and a certificate created locally has none — `find-identity -v -p codesigning` reports it
# as absent while `find-identity -p codesigning` lists it as `(CSSMERR_TP_NOT_TRUSTED)` and codesign
# signs with it without complaint. Both behaviours were measured directly on macOS 26.5.2 before
# this was written, in a throwaway keychain. Using -v here would make every local identity look
# missing.
#
# The name is matched with its surrounding quotes so that a shorter configured name cannot match a
# longer identity's line by accident.
sonny_signing_identity_present() {
  security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$1\""
}

# True for identity names that only Apple can issue, which scripts/create-signing-identity.sh must
# refuse to fabricate a self-signed lookalike of.
sonny_signing_identity_is_apple_issued() {
  case "$1" in
    "Developer ID Application:"* | \
    "Developer ID Installer:"* | \
    "Apple Development:"* | \
    "Apple Distribution:"* | \
    "Mac Developer:"* | \
    "3rd Party Mac Developer"*)
      return 0
      ;;
  esac
  return 1
}
