#!/usr/bin/env bash
# SONNY-125 host probe driver. Prints every command before running it, so the log it writes
# is the evidence rather than a summary of it.
#
#   MODE=health|sizes|times|up|drip|ceiling ./probe.sh <base-url> <label> [auth-header]
#
# base-url carries no trailing slash and no route; routes are appended (/echo, /slow, ...).
# One curl per measurement -- body and metrics come from the same request, never two, so a
# figure can never be paired with a different request's outcome.
set -uo pipefail

BASE="${1:?base url}"; LABEL="${2:?label}"; AUTH="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PAY="$HERE/payloads"; OUT="$HERE/results/$LABEL.txt"
mkdir -p "$PAY" "$(dirname "$OUT")"
BODY=$(mktemp)

# One run per label at a time. Two probe.sh processes sharing a label append to one log through
# `tee -a`, and the result is a file whose runs interleave -- SONNY-125 produced exactly that in
# its local control log, ending up with a ceiling ladder it could not attribute to a command it
# had issued. A measurement whose provenance cannot be established is not a measurement, so this
# refuses rather than producing one. Same reasoning as scripts/mutate's run lock.
LOCK="$HERE/results/.$LABEL.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "probe.sh: a run is already writing results/$LABEL.txt (holder: $(cat "$LOCK/pid" 2>/dev/null || echo unknown))." >&2
  echo "  Use a different <label>, or remove $LOCK if a killed run left it behind." >&2
  exit 1
fi
echo "$$" > "$LOCK/pid"
trap 'rm -f "$BODY"; rm -rf "$LOCK"' EXIT

WFMT='%{http_code} %{time_total} %{size_upload} %{time_connect} %{time_starttransfer}'
say() { echo "$*" | tee -a "$OUT"; }
log() { echo "$*" >>"$OUT"; }

log ""
say "=== $LABEL  $BASE  MODE=${MODE:-all}"
say "=== started $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC   curl $(curl --version | head -1 | cut -d' ' -f2)"

payload() {  # payload <bytes> -> path; generated once, reused across runs
  local n="$1" f="$PAY/$1.json"
  [[ -f "$f" ]] || python3 "$HERE/make_payload.py" "$n" "$f" >/dev/null
  [[ -f "$f.gz" ]] || gzip -9 -c "$f" >"$f.gz"
  echo "$f"
}

post() {  # post <decoded-bytes> <raw|gzip> -> "http_code time_total"
  local n="$1" mode="$2" f file wire metrics
  f="$(payload "$n")"; file="$f"
  local hdrs=(-H 'content-type: application/json')
  [[ "$mode" == gzip ]] && { hdrs+=(-H 'content-encoding: gzip'); file="$f.gz"; }
  [[ -n "$AUTH" ]] && hdrs+=(-H "$AUTH")
  wire=$(wc -c <"$file" | tr -d ' ')
  log "--- POST $BASE/echo   decoded=$n  wire=$wire  mode=$mode"
  log "    curl -sS --max-time 420 -X POST -H 'content-type: application/json'$( [[ $mode == gzip ]] && printf " -H 'content-encoding: gzip'") \\"
  log "         --data-binary @$(basename "$file") -w '$WFMT' '$BASE/echo'"
  metrics=$(curl -sS --max-time 420 -X POST "${hdrs[@]}" --data-binary "@$file" \
                 -o "$BODY" -w "$WFMT" "$BASE/echo" 2>&1)
  log "    http_code time_total size_upload time_connect time_starttransfer"
  log "    $metrics"
  log "    body: $(head -c 500 "$BODY")"
  echo "$metrics" | awk '{print $1, $2}'
}

timed() {  # timed <route> <ms> -> "http_code time_total"
  local route="$1" ms="$2" metrics
  local hdrs=(); [[ -n "$AUTH" ]] && hdrs+=(-H "$AUTH")
  log "--- GET $BASE/$route?ms=$ms"
  log "    curl -sS --max-time 420 -w '%{http_code} %{time_total}' '$BASE/$route?ms=$ms'"
  metrics=$(curl -sS --max-time 420 "${hdrs[@]+"${hdrs[@]}"}" -o "$BODY" \
                 -w '%{http_code} %{time_total}' "$BASE/$route?ms=$ms" 2>&1)
  log "    $metrics"
  log "    body: $(head -c 400 "$BODY")"
  echo "$metrics"
}

case "${MODE:-}" in
  health) say "health -> $(timed health 0)" ;;
  sizes)  for n in ${SIZES:-664000 3512879 4004793 4200000}; do
            for mode in raw gzip; do say "size $n $mode -> $(post "$n" "$mode")"; done
          done ;;
  times)  for ms in ${TIMES:-1000 30000 60000 105000}; do say "slow ${ms}ms -> $(timed slow "$ms")"; done ;;
  up)     for ms in ${TIMES:-1000 30000 105000}; do say "up ${ms}ms -> $(timed up "$ms")"; done ;;
  ceiling)
    # Double from a known-good size until the host refuses, then bisect the gap. Raw mode:
    # a host that limits the *compressed* body would otherwise let a larger decoded body
    # through and the ceiling reported would not be the ceiling the contract cares about.
    # CEIL_CAP stops the ladder where a bigger answer would change no decision; when it is
    # hit the log says so rather than reporting an unfound ceiling as an absent one.
    lo=${CEIL_FROM:-4200000}; hi=0; cap=${CEIL_CAP:-33554432}; n=$lo
    say "ceiling: laddering from $lo, cap $cap"
    while :; do
      read -r code _ <<<"$(post "$n" raw)"
      say "ceiling probe $n -> $code"
      if [[ "$code" == 200 ]]; then
        lo=$n
        (( n*2 > cap )) && { say "ceiling: $lo passed and the ladder stopped at cap $cap without a refusal"; break; }
        n=$((n*2))
      else
        hi=$n; break
      fi
    done
    if (( hi > 0 )); then
      while (( hi-lo > 262144 && hi-lo > lo/20 )); do
        mid=$(( (lo+hi)/2 ))
        read -r code _ <<<"$(post "$mid" raw)"
        say "ceiling bisect $mid -> $code"
        if [[ "$code" == 200 ]]; then lo=$mid; else hi=$mid; fi
      done
      say "ceiling: last pass $lo, first refusal $hi"
      # One gzip datapoint above the raw ceiling: it separates a limit on the wire bytes
      # from a limit on the decoded body, which is the difference the contract 6.4 turns on.
      say "ceiling gzip-above-raw-ceiling $hi -> $(post "$hi" gzip)"
    fi ;;
  drip)   for ms in ${TIMES:-105000}; do say "drip ${ms}ms -> $(timed drip "$ms")"; done ;;
  *)      echo "set MODE=health|sizes|times|up|drip|ceiling" >&2; exit 2 ;;
esac
say "=== finished $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
