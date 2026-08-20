#!/usr/bin/env bash
# The control for race.sh TEST 1, rebuilt. The first version asserted "both read 0, both
# wrote" without showing either, and its final state (reserved=100, not 200) proved the
# opposite: the second write never landed. What actually stopped it was the CHECK, so the
# control was demonstrating the constraint rather than the race it claimed to control for.
#
# This version separates the two. `naive_unguarded` drops the CHECK, so an over-spend is
# visible as an over-spend. `naive_guarded` keeps it, so the failure mode a real deployment
# would meet is visible too -- and it is not a clean refusal, which is the point.
set -uo pipefail
PG=${PG:-sonny-cap-probe}
q() { docker exec -i "$PG" psql -U postgres -d postgres -qAt -c "$1" 2>&1; }
U=11111111-1111-1111-1111-111111111111; P=2026-08-01

setup() {
  q "DROP TABLE IF EXISTS naive; CREATE TABLE naive (user_id uuid, period_start date,
       cap_credits bigint, spent bigint DEFAULT 0, reserved bigint DEFAULT 0
       ${1:+, CONSTRAINT never_over_cap CHECK (spent + reserved <= cap_credits)});
     INSERT INTO naive(user_id,period_start,cap_credits) VALUES('$U','$P',100);" >/dev/null
}
naive_txn() {  # read, pause, write -- two statements, which is the whole defect
  q "BEGIN;
     SELECT 'read=' || (spent+reserved) FROM naive WHERE user_id='$U';
     SELECT pg_sleep(1);
     UPDATE naive SET reserved = reserved + 100 WHERE user_id='$U';
     COMMIT;" | grep -Ev '^$|^COMMIT|^BEGIN|^UPDATE|^$' | tr '\n' ' '
}

echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC  postgres $(q 'SHOW server_version;')"
for guard in "" "1"; do
  label=$([[ -n "$guard" ]] && echo "WITH the CHECK constraint" || echo "WITHOUT the CHECK constraint")
  echo; echo "--- naive read-then-write, two racers, cap 100. $label"
  setup "$guard"
  ( echo "  racer A: $(naive_txn)" ) & ( echo "  racer B: $(naive_txn)" ) &
  wait
  echo "  final spent/reserved/cap -> $(q "SELECT spent||' '||reserved||' '||cap_credits FROM naive WHERE user_id='$U';")"
done
echo
echo "--- and the single-statement reserve, same race, for comparison"
q "TRUNCATE reservation; DELETE FROM usage_period;
   INSERT INTO usage_period(user_id,period_start,cap_credits) VALUES('$U','$P',100);" >/dev/null
( echo "  racer A: $(q "SELECT coalesce(reserve('$U','$P',100,gen_random_uuid())::text,'REFUSED');")" ) &
( echo "  racer B: $(q "SELECT coalesce(reserve('$U','$P',100,gen_random_uuid())::text,'REFUSED');")" ) &
wait
echo "  final spent/reserved/cap -> $(q "SELECT spent||' '||reserved||' '||cap_credits FROM usage_period WHERE user_id='$U';")"
echo; echo "=== finished $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
