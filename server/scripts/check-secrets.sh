#!/usr/bin/env bash
# SONNY-126: refuse to let a real credential into the repository.
#
# The ticket requires "no secrets in the repo, and a check for it" because provider keys are the
# entire reason this backend exists, and server/ is the first place in this repo where writing one
# down would even be tempting.
#
# What it scans: every tracked file, plus anything staged. Untracked-and-unstaged files are
# deliberately out of scope -- server/.env is exactly that, it is gitignored, and flagging the file
# the design tells you to create would train people to pass --no-verify.
#
# Exit 0 clean, 1 for a finding, 2 for a usage error.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

MODE="${1:-tracked}"
case "$MODE" in
  tracked) FILES=$(git ls-files) ;;
  staged)  FILES=$(git diff --cached --name-only --diff-filter=ACM) ;;
  *) echo "usage: check-secrets.sh [tracked|staged]" >&2; exit 2 ;;
esac
[[ -z "$FILES" ]] && { echo "check-secrets: nothing to scan ($MODE)"; exit 0; }

# Vendor-issued key shapes. Each is anchored on a prefix the vendor actually uses, so the pattern
# matches issued credentials rather than any long string -- a generic "40+ chars of base64" rule
# would flag every lockfile hash in the tree and get switched off within a week.
PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}'        # Anthropic
  'sk-proj-[A-Za-z0-9_-]{20,}'       # OpenAI project keys
  'sk-[A-Za-z0-9]{32,}'              # OpenAI classic
  'csk-[A-Za-z0-9]{20,}'             # Cerebras
  'tvly-[A-Za-z0-9_-]{16,}'          # Tavily
  'ghp_[A-Za-z0-9]{30,}'             # GitHub PAT
  'sbp_[A-Za-z0-9]{30,}'             # Supabase personal access token
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'   # JWT (Supabase anon/service keys)
  # A PEM header alone is not a secret -- it is four words, and this repo's redaction tests contain
  # several with no body or a decorative one. What makes it a secret is the key material after it,
  # so the pattern requires a long base64 run. Real keys carry ~1600 characters; the fixtures carry
  # under 60. Written this way instead of baselining the header, which would have exempted every
  # PEM in the tree forever -- including a real one. The selftest caught that.
  '-----BEGIN [A-Z ]*PRIVATE KEY-----([A-Za-z0-9+/=[:space:]]|\\\\n){120,}'
  'postgres(ql)?://[^:[:space:]]+:[^@[:space:]]+@'   # connection string with a real password
)

# Placeholders the repository is supposed to contain. Kept narrow on purpose: this list is the
# only thing standing between the scanner and being useless, so every entry is a literal that
# could not be a credential.
# Deliberately narrow. Every entry is a literal that could not be a credential. `example` on its
# own used to be here and was removed: it matched `db.example.com` and so exempted a
# password-bearing connection string, which the selftest caught on its first run.
ALLOW='replace-me|placeholder|changeme|your-key-here|postgres://postgres:postgres@|<[a-z-]+>'

BASELINE="server/scripts/secret-scan-baseline.txt"
[[ -f "$BASELINE" ]] || { echo "check-secrets: missing $BASELINE" >&2; exit 2; }

findings=0
for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    # The scanner's own pattern list is not a finding.
    [[ "$file" == "server/scripts/check-secrets.sh" ]] && continue
    line=$(echo "$hit" | cut -d: -f2)
    text=$(echo "$hit" | cut -d: -f3-)
    echo "$text" | grep -Eq "$ALLOW" && continue
    # Exact-match baseline of known-synthetic fixtures. See secret-scan-baseline.txt for why this
    # is an exact-string list rather than a path skip or a looser pattern.
    baselined=0
    while IFS= read -r fixture; do
      [[ -z "$fixture" || "$fixture" == \#* ]] && continue
      case "$text" in *"$fixture"*) baselined=1; break ;; esac
    done < "$BASELINE"
    (( baselined )) && continue
    # Report the location and the shape, never the value -- a scanner that prints the secret it
    # found has copied it into your terminal scrollback and your CI log.
    echo "  $file:$line  matches /$pattern/" >&2
    findings=$((findings + 1))
  done < <(echo "$FILES" | tr '\n' '\0' | xargs -0 grep -EnI -e "$pattern" 2>/dev/null)
done

if (( findings > 0 )); then
  echo >&2
  echo "check-secrets: $findings finding(s) in $MODE files. Nothing was printed but the location." >&2
  echo "  A real credential belongs in the host's environment configuration, never in this repo." >&2
  echo "  server/.env is gitignored and is where a local one goes." >&2
  exit 1
fi
# A baseline entry that no longer appears anywhere is reported, not ignored: a stale exemption is
# an exemption nobody is reviewing, and it would silently cover a future string that happens to match.
stale=0
while IFS= read -r fixture; do
  [[ -z "$fixture" || "$fixture" == \#* ]] && continue
  if ! echo "$FILES" | tr '\n' '\0' | xargs -0 grep -qFI -- "$fixture" 2>/dev/null; then
    echo "check-secrets: baseline entry no longer present, remove it -- ${fixture:0:12}..." >&2
    stale=$((stale + 1))
  fi
done < "$BASELINE"

echo "check-secrets: clean ($(echo "$FILES" | wc -l | tr -d ' ') $MODE files scanned, ${#PATTERNS[@]} patterns, $(grep -cvE '^\s*(#|$)' "$BASELINE") baselined fixtures)"
(( stale > 0 )) && exit 1
exit 0
