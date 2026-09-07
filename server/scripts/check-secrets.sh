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
  # Resend, whose key is the one this row is about to start using and which had NO vendor pattern
  # (PR #87 second round, F9) -- so a Resend key survived here unless it happened to sit beside its
  # own variable name, and in the JSON form even that missed it.
  #
  # Anchored on the `re_` prefix plus the long two-segment body an issued key carries. Deliberately
  # narrow: a single loose run after `re_` matches ordinary snake_case identifiers -- measured, four
  # of them in this repository, all of them `re_isolated_test_command` -- while this form matches
  # none. A key shaped some other way is still covered by the name-anchored pattern below, which is
  # what that pattern is for.
  're_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,}'   # Resend API key
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'   # JWT (Supabase anon/service keys)
  # A PEM header alone is not a secret -- it is four words, and this repo's redaction tests contain
  # several with no body or a decorative one. What makes it a secret is the key material after it,
  # so the pattern requires a long base64 run. Real keys carry ~1600 characters; the fixtures carry
  # under 60. Written this way instead of baselining the header, which would have exempted every
  # PEM in the tree forever -- including a real one. The selftest caught that.
  '-----BEGIN [A-Z ]*PRIVATE KEY-----([A-Za-z0-9+/=[:space:]]|\\\\n){120,}'
  'postgres(ql)?://[^:[:space:]]+:[^@[:space:]]+@'   # connection string with a real password
)

# **Name-anchored patterns, matched CASE-INSENSITIVELY** (PR #87 third round, F6).
#
# Separate from the array above because the two want opposite treatment. A vendor prefix is a
# literal the vendor issues -- `sk-ant-`, `ghp_`, `re_` -- and matching those without regard to case
# would widen them for nothing and invite false positives on ordinary prose. A variable NAME is not
# issued by anyone: the same secret is `RATE_LIMIT_SALT` in a `.env`, `rate_limit_salt` in a Helm
# values file or a Terraform tfvars, and `Rate_Limit_Salt` wherever somebody felt like it.
#
# Case-sensitivity here was a real hole rather than a theoretical one, and it was worst exactly where
# it mattered most: these three -- RATE_LIMIT_SALT, SUPABASE_JWT_SECRET, SUPABASE_SERVICE_ROLE_KEY --
# have **no vendor-prefix fallback** (a hex salt and a project secret carry no recognisable shape),
# so the name is the only thing that can catch them, and the lowercase form is the natural YAML,
# Helm, Docker-compose and Terraform spelling. Verified missed before this split and caught after.
PATTERNS_CI=(
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
  #
  # **The NAME may be quoted too** (PR #87 second round, F9). R9 added the optional quote around the
  # *value* and left the name bare, so every JSON form went straight through -- `"RATE_LIMIT_SALT":
  # "..."`, which is how these appear in a Kubernetes secret, a Terraform variables file, a
  # `docker inspect` dump or anything else that serialises an environment. Verified missed before
  # the `["']?` was added and caught after. The optional closing quote does not widen anything else:
  # without a following `=` or `:` there is still no match.
  # `ENTITLEMENT_SIGNING_KEY` joined this list with SONNY-135, and it is the one on it whose leak is
  # not a read but a WRITE: it is the Ed25519 private half every entitlement claim is signed with, so
  # anyone holding it can mint a claim granting any capability to any account, on any deployment
  # still using that key. It carries no vendor prefix -- it is base64 of a DER key -- so the name is
  # the only thing that can catch it, exactly as for the three beside it.
  #
  # `BILLING_WEBHOOK_SECRET` joined it with SONNY-211, and it is the SECOND on this list whose leak
  # is a write. It is the HMAC secret every subscription webhook is signed with, so anyone holding it
  # can sign a `subscription.active` delivery for any account and grant themselves a paid
  # entitlement -- against a route that is, necessarily, reachable by anyone on the internet. The
  # provider issues it as an opaque string with no vendor prefix, so the name is again the only thing
  # that can catch it. `BILLING_CHECKOUT_URL` and `BILLING_PLANS` are deliberately NOT here: a
  # checkout link is meant to be given to users and a plan map names products and capability keys,
  # neither of which is a credential, and adding them would train people to baseline this scanner.
  #
  # `BILLING_PROVIDER_ACCESS_TOKEN` joined it with SONNY-216, the THIRD whose leak is a write and the
  # first provider API credential this gateway holds at all. Whoever holds it can mint a customer
  # portal session for any customer of the organization -- that customer's invoices, payment method
  # and cancel button -- without touching this gateway. Opaque and vendor-prefixless like the two
  # above, so again only the name can catch it. `BILLING_API_BASE_URL` beside it is deliberately NOT
  # here, for the reason the checkout link is not: an API origin is a hostname, not a credential.
  # `SUPABASE_JWT_SECRET(_[0-9]+)?` is SONNY-238's widening. That ticket gives the JWT secret a single
  # overlap slot -- `SUPABASE_JWT_SECRET_2` -- so a rotation is three deploys instead of every user
  # being signed out; the slot holds a real project secret and the bare name anchored here could not
  # catch it, because after `SUPABASE_JWT_SECRET` the pattern wants `[=:]` and finds `_`.
  #
  # **`_[0-9]+` rather than `_2`, and the two are not interchangeable** (PR #218's F1). This shipped
  # as `(_2)?` on the reasoning that a narrow suffix is safer, and narrow was the wrong axis: the
  # gateway reads only `_2`, but the SCANNER's question is not "does this deployment read it", it is
  # "is a credential-shaped value sitting in this repository under a credential-shaped name". A real
  # project secret committed as `SUPABASE_JWT_SECRET_02` is a leak whether or not any code reads that
  # name, and nothing else here would catch it -- `PATTERNS` above is vendor prefixes, a JWT shape, a
  # PEM header and a Postgres URL, and a Supabase project secret has none of those shapes. So the
  # scanner is deliberately WIDER than `config.ts`'s reader, which refuses every numbered spelling it
  # does not read.
  #
  # **What the widening still must not take with it, which is why it is `_[0-9]+` and not `.*`**: the
  # deadline beside the slot, `SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL`, is a date an operator has to be
  # able to write down. `_[0-9]+` cannot reach it -- after the digits the pattern wants `[=:]` and
  # finds `_`, and dropping the group leaves `_` in the same position -- while `.*` reaches straight
  # past the name and flags a basic-format instant, which is exactly sixteen value-class characters.
  # The `ENTITLEMENT_SIGNING_KEY_ID` case three lines above is the same shape and the same hazard.
  # Every one of those directions has its own selftest arm.
  "(RATE_LIMIT_SALT|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_JWT_SECRET(_[0-9]+)?|ENTITLEMENT_SIGNING_KEY|BILLING_WEBHOOK_SECRET|BILLING_PROVIDER_ACCESS_TOKEN|RESEND_API_KEY|SMTP_PASS(WORD)?)[\"']?[[:space:]]*[=:][[:space:]]*[\"']?[A-Za-z0-9+/=_-]{16,}"   # name-anchored secret assignment
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
# The same body for both arrays; `$1` is the extra grep flag, empty for case-sensitive and `-i` for
# the name-anchored set. Called normally rather than piped into, so it runs in this shell and its
# `findings` increments are the real ones.
scan_patterns() {
  local case_flag="$1"; shift
  local pattern
  for pattern in "$@"; do
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
    done < <(echo "$text" | grep -Eo ${case_flag:+"$case_flag"} -e "$pattern")
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
  done < <(echo "$FILES" | tr '\n' '\0' | xargs -0 grep -EnI ${case_flag:+"$case_flag"} -e "$pattern" 2>/dev/null)
  done
}

scan_patterns "" "${PATTERNS[@]}"
scan_patterns "-i" "${PATTERNS_CI[@]}"

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

echo "check-secrets: clean ($(echo "$FILES" | wc -l | tr -d ' ') $MODE files scanned, $(( ${#PATTERNS[@]} + ${#PATTERNS_CI[@]} )) patterns, $(grep -cvE '^\s*(#|$)' "$BASELINE") baselined fixtures)"
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
#   - **A vendor key whose issued shape differs from the pattern written for it.** The Resend
#     pattern above describes the two-segment body an issued key carries; a key in some other shape
#     is caught only when it sits beside its own variable name. The name-anchored pattern is the
#     backstop for exactly this, and it is a backstop rather than a guarantee.
#   - **A secret whose VARIABLE NAME is not on the name-anchored list.** That list is five names
#     long. Matching is case-insensitive now (PR #87 third round, F6), so `rate_limit_salt` and
#     `Rate_Limit_Salt` are caught alongside `RATE_LIMIT_SALT` -- but a sixth secret introduced
#     under a name nobody adds here is invisible unless it carries a vendor prefix. Adding a name is
#     one word; noticing that one is missing is the part with no mechanism behind it.
#   - **A name and its value on DIFFERENT LINES.** grep is line-based, so pretty-printed JSON or
#     wrapped YAML -- `"RATE_LIMIT_SALT":` on one line and its value on the next -- splits the two
#     halves the name-anchored pattern needs to see together and evades it entirely, even though the
#     single-line JSON form is specifically covered. Known and filed rather than fixed here: closing
#     it means the scanner parsing structure rather than matching lines.
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
