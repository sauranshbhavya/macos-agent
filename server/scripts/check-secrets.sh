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
  # An assignment of a KNOWN-SECRET variable to something that is not a placeholder.
  #
  # SONNY-127 introduced RATE_LIMIT_SALT, whose value is `openssl rand -hex 32` -- 64 hex
  # characters carrying no vendor prefix, so every pattern above misses it entirely and a real one
  # could be committed unnoticed. The answer is NOT a generic high-entropy rule: this file's own
  # "does not prevent" section explains why one would flag every lockfile hash and be switched off
  # within a week. Anchoring on the variable NAME is narrow, cannot false-positive on a hash, and
  # extends to the next such variable by adding one word here.
  #
  # **Quotes optional, and `:` is back** (PR #87 R9). The first version took `=` with a bare value,
  # which is the one way almost nobody writes these: `KEY="value"`, `KEY='value'`, YAML's
  # `KEY: "value"`, `export KEY="value"` and compose's `- KEY=value` all went straight through, six
  # probes' worth.
  #
  # `:` was dropped in an earlier round because it matched TypeScript type annotations --
  # `RATE_LIMIT_SALT: nonEmpty.optional()` in config.ts became a finding. It is safe again because
  # **the value class no longer contains a dot**: that annotation's value stops at `nonEmpty`, eight
  # characters, under the sixteen this needs. A hex salt, a base64 key and a `re_`-prefixed token
  # contain no dot either, so nothing real is lost. Anything dotted and secret-shaped is a JWT, and
  # JWTs have their own pattern above.
  "(RATE_LIMIT_SALT|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_JWT_SECRET|RESEND_API_KEY|SMTP_PASS(WORD)?)[[:space:]]*[=:][[:space:]]*[\"']?[A-Za-z0-9+/=_-]{16,}"   # name-anchored secret assignment
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
#     anywhere on a line exempted every pattern on it. Narrowing it to `<(ref|your-…|project-…)>`
#     was NOT enough, and the narrowed form is gone too. The DSN pattern is built from NEGATED
#     classes -- `[^:[:space:]]+` and `[^@[:space:]]+` -- so `<` and `>` pass straight through
#     them and land inside the matched substring. That made Supabase's own pooler shape,
#     `postgresql://postgres.<project-ref>:<the password>@…pooler.supabase.com`, exempt with the
#     password intact**, while the identical string with an ordinary user part was caught. The
#     four placeholders it existed for appear only in prose that no pattern matches, so nothing
#     needed it. (PR #85 cycle 4, R3b.)
ALLOW='\breplace-me\b|\bplaceholder\b|\bchangeme\b|\byour-key-here\b|postgres://postgres:postgres@'

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
    # **Every match on the line, not the first.** `head -1` took only the leading match, so a line
    # whose FIRST match was allowlisted -- the local `postgres://postgres:postgres@` DSN is the
    # obvious one -- exempted a real credential of the SAME pattern appearing later on it. That was
    # a live probe of the cycle-1 reviewer's and it still landed after the substring fix. The line
    # is a finding if ANY of its matches is not allowlisted.
    unallowed=0
    while IFS= read -r matched; do
      [[ -z "$matched" ]] && continue
      echo "$matched" | grep -Eq "$ALLOW" || { unallowed=1; break; }
    done < <(echo "$text" | grep -Eo -e "$pattern")
    (( unallowed )) || continue
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
#   - A vendor-issued credential matching one of the patterns above, on a single line of any tracked
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
#   - **An ENCRYPTED private key.** A PEM carrying `Proc-Type: 4,ENCRYPTED` and a `DEK-Info` header
#     puts those lines between the BEGIN marker and the base64 body, which breaks the 120-character
#     run the multi-line pass requires, so the file passes. An encrypted key still needs its
#     passphrase, but it is a credential in the repository either way.
#   - **A placeholder term sitting inside a matchable key body.** The alphanumeric ALLOW terms are
#     word-anchored above, which stops the common case, but a key body containing `placeholder`
#     with non-word characters either side would still exempt its own match. Fixing that properly
#     means the allowlist knowing which pattern matched, which is more machinery than this script
#     is worth today.
#   - **A false sense of the baseline.** `secret-scan-baseline.txt` exempts by exact match, so an
#     entry added carelessly exempts that string everywhere, forever. Stale entries are reported;
#     wrong ones are not.
