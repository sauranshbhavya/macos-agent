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
dsn_rest="@db.internal:5432/x"
check "password-bearing DSN is refused"    1 "DATABASE_URL=${dsn_scheme}${dsn_password}${dsn_rest}"
check "a baselined test fixture passes"    0 'let secret = "sk-rationaleAAAAAAAAAAAAAAAAAAAA1234"'
check "the local default DSN passes"       0 'DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres'
check "an explicit placeholder passes"     0 'OPENAI_API_KEY=replace-me'
check "ordinary prose passes"              0 'The gateway holds provider credentials and forwards to model providers.'

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
