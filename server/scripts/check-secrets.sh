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
# Deliberately narrow, and tested against the matched substring rather than the line. Every entry
# is a literal that cannot appear inside a real credential. Two removals worth recording:
#   - `example` on its own matched `db.example.com`, exempting a password-bearing DSN.
#   - `<[a-z-]+>` was meant for `<your-key>` placeholders and matched **any HTML tag**, so a `<p>`
#     anywhere on a line exempted every pattern on it. Replaced with the angle-bracket forms this
#     repository actually uses for placeholders.
ALLOW='replace-me|placeholder|changeme|your-key-here|postgres://postgres:postgres@|<(ref|your-[a-z-]+|project-[a-z-]+)>'

BASELINE="server/scripts/secret-scan-baseline.txt"
[[ -f "$BASELINE" ]] || { echo "check-secrets: missing $BASELINE" >&2; exit 2; }

# grep is line-based, so a PEM written across real newlines -- which is how a private key file is
# actually shaped -- never matches the single-line pattern above. This is a separate whole-file
# pass for exactly that case.
multiline_findings=0
while IFS= read -r file; do
  [[ -z "$file" || ! -f "$file" ]] && continue
  [[ "$file" == "server/scripts/check-secrets.sh" ]] && continue
  [[ "$file" == "server/scripts/check-secrets-selftest.sh" ]] && continue
  if perl -0777 -ne 'exit(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s]*[A-Za-z0-9+\/=\s]{120,}/ ? 1 : 0)' \
       "$file" 2>/dev/null; then :; else
    echo "  $file  contains a multi-line PEM private key with material" >&2
    multiline_findings=$((multiline_findings + 1))
  fi
done <<< "$FILES"

findings=0
for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    # The scanner's own pattern list is not a finding.
    [[ "$file" == "server/scripts/check-secrets.sh" ]] && continue
    line=$(echo "$hit" | cut -d: -f2)
    text=$(echo "$hit" | cut -d: -f3-)
    # **The allowlist is tested against the MATCHED SUBSTRING, not the whole line.** Testing the
    # line meant any allowlisted term anywhere on it exempted every finding on that line -- so a
    # line containing the word "placeholder", or (before the term was narrowed) any HTML tag at
    # all, carried a real credential straight through. A reviewer landed four probes through it.
    matched=$(echo "$text" | grep -Eo -e "$pattern" | head -1)
    [[ -n "$matched" ]] && echo "$matched" | grep -Eq "$ALLOW" && continue
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

findings=$((findings + multiline_findings))
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

# ── What this does and does not prevent ──────────────────────────────────────────────────────
#
# PREVENTS
#   - A vendor-issued credential matching one of the ten patterns, on a single line of any tracked
#     or staged file, reaching a commit.
#   - A private key written across real newlines, via the separate whole-file pass above.
#   - Its own findings being printed: the location and the pattern are reported, never the value.
#
# DOES NOT PREVENT
#   - **A credential whose shape is not in the pattern list.** The patterns are anchored on vendor
#     prefixes on purpose -- a generic high-entropy rule would flag every lockfile hash and be
#     switched off within a week -- so a bearer token with no distinctive prefix passes unseen.
#   - **A credential in an untracked, unstaged file.** `server/.env` is exactly that, deliberately:
#     it is where a local credential is supposed to live, and flagging the file the design tells
#     you to create would train people to bypass the check.
#   - **A credential already in the repository's history.** This scans the working tree, not the
#     git object store. A key committed and then removed is still in the history and still leaked.
#   - **A credential split across lines by construction**, other than PEM key material. Nothing
#     here reassembles string concatenation, and this file's own selftest exploits that.
#   - **Anything at all, if nobody runs it.** There is no CI in this repository and no hook was
#     added; `npm run check:secrets` is a command, not a gate. Making it one is row 20's question.
#   - **A false sense of the baseline.** `secret-scan-baseline.txt` exempts by exact match, so an
#     entry added carelessly exempts that string everywhere, forever. Stale entries are reported;
#     wrong ones are not.
