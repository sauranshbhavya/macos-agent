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
check "a <ref> placeholder is still allowed" 0 'deploy probe --project-ref <ref>'

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
