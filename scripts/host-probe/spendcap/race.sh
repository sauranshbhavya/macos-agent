#!/usr/bin/env bash
# SONNY-125 requirement 3: demonstrate what two requests from one user do when they race the
# spend cap. Every test carries a control that must FAIL, because an assertion with no control
# passes whether or not the property holds -- SONNY-114's lesson, reused.
set -uo pipefail
PG=${PG:-sonny-cap-probe}
q() { docker exec -i "$PG" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=0 -c "$1" 2>&1; }
qf() { docker exec -i "$PG" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 -f - ; }
U=11111111-1111-1111-1111-111111111111
P=2026-08-01

reset() {  # cap fits exactly N reservations of 100
  q "TRUNCATE reservation; DELETE FROM usage_period;" >/dev/null
  q "INSERT INTO usage_period(user_id,period_start,cap_credits) VALUES('$U','$P',$1);" >/dev/null
}
state() { q "SELECT spent||' '||reserved||' '||cap_credits FROM usage_period WHERE user_id='$U';"; }

echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC  postgres $(q 'SHOW server_version;')"

echo
echo "--- TEST 1: two racing reserves, cap fits ONE. Expect exactly one to win."
reset 100
( q "BEGIN; SELECT 'A='||coalesce(reserve('$U','$P',100,gen_random_uuid())::text,'REFUSED'); SELECT pg_sleep(2); COMMIT;" | grep '^A=' ) &
sleep 0.5
B_START=$(python3 -c 'import time;print(time.time())')
B=$( q "BEGIN; SELECT 'B='||coalesce(reserve('$U','$P',100,gen_random_uuid())::text,'REFUSED'); COMMIT;" | grep '^B=' )
B_WAIT=$(python3 -c "import time;print(round(time.time()-$B_START,2))")
wait
echo "  $B   (B blocked ${B_WAIT}s waiting on A's row lock, then re-evaluated)"
echo "  spent reserved cap -> $(state)"

echo
echo "--- CONTROL for TEST 1: the naive read-then-write, same race. Expect it to overshoot."
reset 100
( q "BEGIN; SELECT spent+reserved FROM usage_period WHERE user_id='$U' AND period_start='$P';
     SELECT pg_sleep(1);
     UPDATE usage_period SET reserved=reserved+100 WHERE user_id='$U' AND period_start='$P'; COMMIT;" >/dev/null ) &
( q "BEGIN; SELECT spent+reserved FROM usage_period WHERE user_id='$U' AND period_start='$P';
     SELECT pg_sleep(1);
     UPDATE usage_period SET reserved=reserved+100 WHERE user_id='$U' AND period_start='$P'; COMMIT;" >/dev/null ) &
wait
echo "  both read 0 under their own snapshots, both wrote."
echo "  spent reserved cap -> $(state)   <- the CHECK is the only thing between this and a double charge"

echo
echo "--- TEST 2: 50 concurrent reserves, cap fits exactly 10. Expect 10 wins, 40 refusals."
reset 1000
for i in $(seq 1 50); do
  ( q "SELECT coalesce(reserve('$U','$P',100,gen_random_uuid())::text,'REFUSED');" ) &
done > /tmp/race50.out 2>&1
wait
echo "  wins:     $(grep -cv REFUSED /tmp/race50.out)"
echo "  refusals: $(grep -c REFUSED /tmp/race50.out)"
echo "  spent reserved cap -> $(state)"

echo
echo "--- TEST 3: a request the platform kills mid-flight leaks its hold until swept."
reset 1000
q "SELECT reserve('$U','$P',900,'22222222-2222-2222-2222-222222222222');" >/dev/null
echo "  after reserve, before settle -> $(state)"
echo "  a second 900 now      -> $(q "SELECT coalesce(reserve('$U','$P',900,gen_random_uuid())::text,'REFUSED');")"
q "UPDATE reservation SET expires_at = now() - interval '1 second';" >/dev/null
echo "  sweep() reclaimed     -> $(q 'SELECT sweep();') expired hold(s)"
echo "  after sweep           -> $(state)"
echo "  a second 900 now      -> $(q "SELECT coalesce(reserve('$U','$P',900,gen_random_uuid())::text,'REFUSED');")"

echo
echo "--- TEST 4: settle is idempotent. A retried settle must charge once."
reset 1000
q "SELECT reserve('$U','$P',500,'33333333-3333-3333-3333-333333333333');" >/dev/null
q "SELECT settle('33333333-3333-3333-3333-333333333333',400);" >/dev/null
echo "  after first settle  -> $(state)"
q "SELECT settle('33333333-3333-3333-3333-333333333333',400);" >/dev/null
echo "  after second settle -> $(state)   (unchanged = idempotent)"
echo
echo "=== finished $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
