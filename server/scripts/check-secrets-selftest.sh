#!/usr/bin/env bash
# Proves check-secrets.sh actually refuses things. A scanner that has only ever printed "clean" is
# a scanner nobody has tested, and this repository has already been burned once by a check whose
# passing output was indistinguishable from a check that ran over nothing (SONNY-169's warnings).
#
# Every case plants a string in a real tracked file inside a scratch git repository, runs the
# scanner against it, and restores. Nothing here touches the working tree.
set -uo pipefail
SCANNER="$(cd "$(dirname "$0")" && pwd)/check-secrets.sh"
BASELINE="$(cd "$(dirname "$0")" && pwd)/secret-scan-baseline.txt"
pass=0; fail=0

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/server/scripts"
cp "$SCANNER" "$scratch/server/scripts/check-secrets.sh"
cp "$BASELINE" "$scratch/server/scripts/secret-scan-baseline.txt"
git -C "$scratch" init -q && git -C "$scratch" config user.email t@t && git -C "$scratch" config user.name t

check() {  # check <name> <expected-exit> <file-content>
  local name="$1" want="$2" content="$3"
  printf '%s\n' "$content" > "$scratch/fixture.txt"
  git -C "$scratch" add -A >/dev/null 2>&1
  ( cd "$scratch" && ./server/scripts/check-secrets.sh tracked >/dev/null 2>&1 )
  local got=$?
  if [[ "$got" == "$want" ]]; then
    echo "  ok    $name (exit $got)"; pass=$((pass+1))
  else
    echo "  FAIL  $name — wanted exit $want, got $got"; fail=$((fail+1))
  fi
}

echo "=== check-secrets selftest ==="
# Each of these is a synthetic string of the right SHAPE. None is a real credential.
check "OpenAI classic key is refused"      1 'const k = "sk-'"$(printf 'A%.0s' {1..40})"'";'
check "Anthropic key is refused"           1 'const k = "sk-ant-'"$(printf 'B%.0s' {1..30})"'";'
check "GitHub PAT is refused"              1 'token: ghp_'"$(printf 'C%.0s' {1..36})"
check "Supabase PAT is refused"            1 'token: sbp_'"$(printf 'D%.0s' {1..40})"
check "a private key WITH material is refused" 1 '-----BEGIN RSA PRIVATE KEY-----'"$(printf 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ%.0s' {1..4})"'-----END RSA PRIVATE KEY-----'
check "a bare PEM header alone is not a secret" 0 '-----BEGIN RSA PRIVATE KEY-----'
dsn_scheme="postgres://user:"
dsn_password="$(printf 'hunter%s' '2hunter2')"
# **`example.com` on purpose.** `example` was once in ALLOW and matched this host, exempting a
# password-bearing DSN; the comments record that, but with an `@db.internal` fixture nothing
# would have failed if someone re-added the term. Now re-adding it breaks this case.
dsn_rest="@db.example.com:5432/x"
check "password-bearing DSN is refused"    1 "DATABASE_URL=${dsn_scheme}${dsn_password}${dsn_rest}"
check "a baselined test fixture passes"    0 'let secret = "sk-rationaleAAAAAAAAAAAAAAAAAAAA1234"'
check "the local default DSN passes"       0 'DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres'
check "an explicit placeholder passes"     0 'OPENAI_API_KEY=replace-me'
check "ordinary prose passes"              0 'The gateway holds provider credentials and forwards to model providers.'

# The allowlist must apply to the MATCHED SUBSTRING, not the whole line. Each of these puts an
# allowlisted term on the same line as a real-shaped credential; every one slipped through
# before, because testing the line exempted every finding on it.
check "allowlisted word beside a key"        1 'OPENAI_API_KEY=sk-'"$(printf 'F%.0s' {1..40})"'  # replace-me later'
check "an HTML tag does not exempt a key"    1 '<p>token ghp_'"$(printf 'G%.0s' {1..36})"'</p>'
check "placeholder DSN beside a real key"    1 'postgres://postgres:postgres@localhost/db sk-ant-'"$(printf 'H%.0s' {1..30})"
# R3b. THE hole this term left open, and the reason the term is gone rather than narrowed.
# The DSN pattern uses negated classes, so `<` and `>` pass through into the matched substring --
# which made Supabase's own pooler connection string, the literal shape this project's database
# hands out, exempt with its password intact. The two checks below are a pair: the placeholder
# form must be refused exactly as the ordinary-user form is, and re-adding any angle-bracket ALLOW
# term breaks the first one.
pooler_scheme="postgresql://"
pooler_pw="$(printf 'R%.0s' {1..14})"
pooler_tail="@aws-0-eu.pooler.supabase.com:5432/postgres"
pooler_ph="postgres.<project-ref>:${pooler_pw}"
pooler_ord="postgres.abcdefg:${pooler_pw}"
check "Supabase pooler DSN with a <placeholder> user is refused" 1 "DATABASE_URL=${pooler_scheme}${pooler_ph}${pooler_tail}"
check "the same pooler DSN with an ordinary user is refused"    1 "DATABASE_URL=${pooler_scheme}${pooler_ord}${pooler_tail}"

# SONNY-127: a secret whose VALUE has no recognisable shape. RATE_LIMIT_SALT is 64 hex characters
# with no vendor prefix, so it is caught by its variable name or not at all.
salt_value="$(printf '%s' "$(openssl rand -hex 32 2>/dev/null || printf 'a%.0s' {1..64})")"
check "a real RATE_LIMIT_SALT is refused"     1 "RATE_LIMIT_SALT=${salt_value}"
check "a placeholder RATE_LIMIT_SALT passes"  0 'RATE_LIMIT_SALT=replace-me'
check "a service-role key assignment is refused" 1 "SUPABASE_SERVICE_ROLE_KEY=${salt_value}"
check "a Resend key assignment is refused"    1 "RESEND_API_KEY=${salt_value}"
# SONNY-135: the entitlement claim's Ed25519 signing key, which is base64 of a DER key and so has
# no vendor prefix either. It is the only name on that list whose leak lets the holder MINT rather
# than merely read -- a claim granting any capability to any account -- so the two directions are
# both checked: the key itself is refused, and the `_ID` beside it, which is not a secret and whose
# values are long enough to have been caught by a looser pattern, is not.
entitlement_key="$(openssl genpkey -algorithm ed25519 -outform DER 2>/dev/null | base64 | tr -d '\n')"
[[ -n "$entitlement_key" ]] || entitlement_key="$(printf 'M%.0s' {1..64})"
check "an entitlement signing key is refused" 1 "ENTITLEMENT_SIGNING_KEY=${entitlement_key}"
check "its lowercase YAML spelling is refused" 1 "  entitlement_signing_key: \"${entitlement_key}\""
check "the key ID beside it is not a secret"  0 "ENTITLEMENT_SIGNING_KEY_ID=entitlement-2026-08-28-a"
# SONNY-238: the JWT secret's one overlap slot. `SUPABASE_JWT_SECRET_2` holds a real project secret
# during a rotation -- the whole point is that both values are live at once -- and the bare name on
# that list could not catch it, because after `SUPABASE_JWT_SECRET` the pattern wants `[=:]` and
# finds `_`. Measured blind before the suffix was added and caught after. Three directions, because
# the widening is the kind that can take too much with it: the slot is refused, its lowercase YAML
# spelling is refused, and the DEADLINE beside it -- a date, and the one thing an operator must be
# able to write down -- is not a secret. That last arm is what a blanket `_[0-9]+` or a trailing
# `.*` would break, along with the ENTITLEMENT_SIGNING_KEY_ID arm directly above.
jwt_secret_2="$(openssl rand -hex 24 2>/dev/null)"
[[ -n "$jwt_secret_2" ]] || jwt_secret_2="$(printf 'j%.0s' {1..48})"
check "the JWT secret's overlap slot is refused"  1 "SUPABASE_JWT_SECRET_2=${jwt_secret_2}"
# PR #218's F1, on the scanner's side of it. The gateway reads only the literal `_2` and refuses
# every other numbered spelling at startup -- but a secret committed under `_02` is a leak whether or
# not any code reads that name, and nothing else in this file would catch it: a Supabase project
# secret carries no vendor prefix, no JWT shape and no PEM header. So the anchor is `_[0-9]+`, wider
# than the reader on purpose, and these are the spellings that proves it on.
check "a zero-padded overlap slot is refused"     1 "SUPABASE_JWT_SECRET_02=${jwt_secret_2}"
check "a doubly-padded one is refused"            1 "SUPABASE_JWT_SECRET_002=${jwt_secret_2}"
check "a two-digit slot nothing reads is refused" 1 "SUPABASE_JWT_SECRET_10=${jwt_secret_2}"
# Named distinctly rather than reusing the "its lowercase YAML spelling" wording three arms above
# use: this file reports by name, and four identical names make a failure line say which secret only
# by counting.
check "the overlap slot's YAML spelling is refused" 1 "  supabase_jwt_secret_2: \"${jwt_secret_2}\""
check "the overlap deadline beside it is not a secret" 0 "SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL=2026-09-14T00:00:00Z"
# **The arm above passes under a WIDER pattern too, and this one does not** -- found by mutating the
# scanner and running this file against it. Replacing the suffix with `.*` leaves all the other arms
# green, because an extended-format instant carries colons and its longest run of value-class
# characters is `2026-09-14T00`, thirteen, under the sixteen the pattern needs. The BASIC ISO format
# has no separators at all: `20260914T000000Z` is sixteen, so `.*` reaches past the name and reports
# a date as a credential. That is the whole difference between the shipped pattern and the
# over-general one, and without this line the selftest could not tell them apart -- exactly the
# shared-marker shape `CLAUDE.md` warns about, arriving as a fixture that could not reach the
# property. **It still separates them after PR #218 widened the suffix to `_[0-9]+`**: digits cannot
# reach past the `_` that follows them, and `.*` can. (`requireSupabaseJwtPolicy` refuses this
# spelling separately, now by a shape check rather than by the date parser -- a different mechanism
# and not this one's job. A scanner that flags a date teaches people to baseline the scanner.)
check "a basic-format deadline is not a secret either" 0 "SUPABASE_JWT_SECRET_2_ACCEPTED_UNTIL=20260914T000000Z"
# SONNY-211: the webhook endpoint secret. The second name on that list whose leak is a WRITE --
# whoever holds it can sign a `subscription.active` delivery for any account, against a route that
# has to be reachable by anyone on the internet. An opaque provider-issued string with no vendor
# prefix, so the name is the only thing that can catch it. Both directions again: the secret is
# refused, and the two billing variables that are NOT credentials are not.
billing_secret="$(openssl rand -hex 24 2>/dev/null)"
[[ -n "$billing_secret" ]] || billing_secret="$(printf 'b%.0s' {1..48})"
check "a billing webhook secret is refused"   1 "BILLING_WEBHOOK_SECRET=${billing_secret}"
check "its lowercase YAML spelling is refused" 1 "  billing_webhook_secret: \"${billing_secret}\""
check "a checkout link is not a secret"       0 "BILLING_CHECKOUT_URL=https://buy.polar.sh/polar_cl_abcdefghijklmnop"
check "a plan map is not a secret"            0 "BILLING_PLANS=prod_abcdefghijklmnop=paid:screen_control"
# SONNY-216: the provider API access token. The THIRD name on that list whose leak is a write, and
# the first provider API credential this gateway holds -- whoever has it can mint a portal session
# for any customer of the organization. Opaque and vendor-prefixless like the two above. Both
# directions again: the token is refused, and the API origin beside it is not.
provider_token="$(openssl rand -hex 24 2>/dev/null)"
[[ -n "$provider_token" ]] || provider_token="$(printf 'p%.0s' {1..48})"
check "a provider access token is refused"   1 "BILLING_PROVIDER_ACCESS_TOKEN=${provider_token}"
check "its lowercase YAML spelling is refused" 1 "  billing_provider_access_token: \"${provider_token}\""
check "an API origin is not a secret"        0 "BILLING_API_BASE_URL=https://sandbox-api.polar.sh"
# A lockfile-style hash must NOT be caught: a generic entropy rule would flag every one of them,
# and this pattern is name-anchored precisely so it does not.
check "a bare hash is not a secret"           0 "integrity sha512-${salt_value}"
# A TypeScript type annotation names the same variable and is not an assignment. This was a real
# false positive on the pattern's first run, against config.ts.
check "a type annotation is not an assignment" 0 '  RATE_LIMIT_SALT: nonEmpty.optional(),'

# PR #87 R9: the QUOTED forms, which are how these are actually written. All six went through the
# first version of the pattern, which required a bare value after `=`.
check "a double-quoted salt is refused"      1 "RATE_LIMIT_SALT=\"${salt_value}\""
check "a single-quoted salt is refused"      1 "RATE_LIMIT_SALT='${salt_value}'"
check "a YAML quoted secret is refused"      1 "  RESEND_API_KEY: \"${salt_value}\""
check "a YAML unquoted secret is refused"    1 "  RESEND_API_KEY: ${salt_value}"
check "an exported shell secret is refused"  1 "export SMTP_PASSWORD=\"${salt_value}\""
check "a compose list entry is refused"      1 "- RESEND_API_KEY=\"${salt_value}\""

# PR #87 second round, F9. R9 made the VALUE's quotes optional and left the NAME bare, so every
# serialised-environment form went through: a Kubernetes secret, a Terraform tfvars file and a
# `docker inspect` dump all write the name in quotes. Verified missed before the fix.
check "a JSON-quoted salt name is refused"    1 "  \"RATE_LIMIT_SALT\": \"${salt_value}\","
check "a JSON-quoted key with no space is refused" 1 "{\"RESEND_API_KEY\":\"${salt_value}\"}"
check "a quoted name with no value stays clean"    0 '  "RATE_LIMIT_SALT": null,'

# F9's other half: RESEND_API_KEY had no VENDOR pattern, so a key not sitting beside its own name
# had zero coverage. `re_` plus the two-segment body an issued key carries.
resend_key="re_$(printf 'a%.0s' {1..10})_$(printf 'b%.0s' {1..24})"
check "a bare Resend key is refused"          1 "curl -H 'Authorization: Bearer ${resend_key}'"
# ...and the narrowness that keeps it usable: an ordinary snake_case identifier beginning `re_` is
# not a credential. This repository contains four of them.
check "a re_-prefixed identifier is not a key" 0 'local re_isolated_test_command="$1"'

# PR #87 third round, F6. The name-anchored pattern was case-SENSITIVE, so the lowercase and
# snake_case spellings -- the natural YAML, Helm, compose and Terraform shapes -- were invisible.
# It matters most for exactly these three: they have no vendor-prefix fallback, so the variable name
# is the only thing that can catch them at all. Each of the four below was verified to pass (exit 0,
# i.e. NOT caught) before the case-insensitive split.
check "a lowercase salt assignment is refused"     1 "rate_limit_salt=${salt_value}"
check "a lowercase YAML jwt secret is refused"     1 "  supabase_jwt_secret: \"${salt_value}\""
check "a mixed-case service-role key is refused"   1 "Supabase_Service_Role_Key=${salt_value}"
check "a lowercase Helm-style value is refused"    1 "  rate_limit_salt: ${salt_value}"
# ...and the vendor-prefix patterns stay case-SENSITIVE, which is the other half of the split. An
# uppercased prefix is not a shape any vendor issues, and loosening it buys nothing.
check "an uppercased vendor prefix is not a key"   0 'const k = "SK-ANT-'"$(printf 'B%.0s' {1..30})"'";'

# C2: two matches of the SAME pattern on one line, the first allowlisted. `head -1` took only
# the leading match, so the allowlisted local DSN shadowed a real credential after it.
check "an allowlisted match does not shadow a later one" 1 'postgres://postgres:postgres@localhost/db then postgres://real:'"$(printf 'S%.0s' {1..12})"'@prod.internal/db'

# R3. Three documents claimed the selftest guarded two regressions -- the `example` term and the
# any-HTML-tag term. Measured: re-adding either passed 18/18, so neither was guarded.
#
# The two turn out to be different problems. `example` CAN still bite, because a key body is
# alphanumeric and can contain the letters e-x-a-m-p-l-e; the check below plants it inside a
# matched substring and fails if the term returns -- verified by re-adding it, which takes the
# suite to 20/21.
#
# The angle-bracket term cannot bite at all any more, and no check is added for it. Since the
# allowlist tests the MATCHED SUBSTRING rather than the line, and every credential pattern here
# matches only alphanumerics and a few separators, a term requiring literal `<` and `>` can never
# match what it is now shown. That is belt-and-braces, not a guard, and the documents say so.
check "a key whose body contains 'example' is refused" 1 'k = sk-'"$(printf 'e%.0s' {1..6})"'xample'"$(printf 'T%.0s' {1..30})"

# The multi-line pass. grep is line-based, so a PEM shaped the way a real key file is -- header,
# newline, base64 body across many lines -- is invisible to every single-line pattern. This writes
# one and requires a refusal, and writes a header with no body and requires a pass.
{
  echo "-----BEGIN RSA PRIVATE KEY-----"
  for _ in 1 2 3 4 5 6; do printf 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ\n'; done
  echo "-----END RSA PRIVATE KEY-----"
} > "$scratch/fixture.txt"
git -C "$scratch" add -A >/dev/null 2>&1
( cd "$scratch" && ./server/scripts/check-secrets.sh tracked >/dev/null 2>&1 )
if [[ $? == 1 ]]; then
  echo "  ok    a multi-line PEM private key is refused"; pass=$((pass+1))
else
  echo "  FAIL  a multi-line PEM private key is refused"; fail=$((fail+1))
fi

printf -- '-----BEGIN RSA PRIVATE KEY-----\n-----END RSA PRIVATE KEY-----\n' > "$scratch/fixture.txt"
git -C "$scratch" add -A >/dev/null 2>&1
( cd "$scratch" && ./server/scripts/check-secrets.sh tracked >/dev/null 2>&1 )
if [[ $? == 0 ]]; then
  echo "  ok    a multi-line PEM with no material is not a secret"; pass=$((pass+1))
else
  echo "  FAIL  a multi-line PEM with no material is not a secret"; fail=$((fail+1))
fi

# The property that matters most: the scanner must never print the value it found.
printf 'k = "sk-%s"\n' "$(printf 'E%.0s' {1..40})" > "$scratch/fixture.txt"
git -C "$scratch" add -A >/dev/null 2>&1
out=$( cd "$scratch" && ./server/scripts/check-secrets.sh tracked 2>&1 )
if echo "$out" | grep -q "EEEEEEEE"; then
  echo "  FAIL  a finding must not print the matched value"; fail=$((fail+1))
else
  echo "  ok    a finding reports location and pattern, never the value"; pass=$((pass+1))
fi

echo "=== $pass passed, $fail failed ==="
(( fail > 0 )) && exit 1
exit 0
