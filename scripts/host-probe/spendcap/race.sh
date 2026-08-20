#!/usr/bin/env bash
# SONNY-125: what two requests from one user do when they race the per-user spend cap.
#
# This script demonstrates the MECHANISM. The control -- the naive read-then-write that must
# fail, without which a passing test proves nothing -- lives in control.sh and is run
# separately. An earlier version of this file carried its own inline control that printed
# "both read 0 ... both wrote" while swallowing the error that contradicted it, and whose own
# final state disproved the line it printed; it was removed rather than repaired (PR #82
# cycle 1, F3). Run both scripts: neither is complete alone.
set -uo pipefail
PG=${PG:-sonny-cap-probe}
q() { docker exec -i "$PG" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=0 -c "$1" 2>&1; }
U=11111111-1111-1111-1111-111111111111
V=22222222-2222-2222-2222-222222222222
P=2026-08-01

reset() {
  q "TRUNCATE reservation; DELETE FROM usage_period;
     INSERT INTO usage_period(user_id,period_start,cap_credits) VALUES('$U','$P',$1);" >/dev/null
}
state() { q "SELECT spent||' '||reserved||' '||cap_credits FROM usage_period WHERE user_id='${1:-$U}';"; }

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
echo "  (the control for this test is control.sh, not this script)"

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
echo "--- TEST 3: requests the platform kills mid-flight leak their holds until swept."
echo "    THREE orphans for one user and one for a second, deliberately. A sweep that"
echo "    subtracts straight from the expired rows reclaims only ONE hold per user-period,"
echo "    because UPDATE ... FROM applies a single source row per target row -- and it marks"
echo "    the rest settled, so the remainder is lost for good. A single-orphan test cannot"
echo "    tell that sweep from a correct one; this one can (PR #82 cycle 1, F2)."
reset 1000
q "INSERT INTO usage_period(user_id,period_start,cap_credits) VALUES('$V','$P',1000);" >/dev/null
for i in 1 2 3; do q "SELECT reserve('$U','$P',300,gen_random_uuid());" >/dev/null; done
q "SELECT reserve('$V','$P',400,gen_random_uuid());" >/dev/null
echo "  after 3 holds for user A, 1 for user B"
echo "    A -> $(state $U)     B -> $(state $V)"
echo "  a 1000 for A now      -> $(q "SELECT coalesce(reserve('$U','$P',1000,gen_random_uuid())::text,'REFUSED');")"
q "UPDATE reservation SET expires_at = now() - interval '1 second';" >/dev/null
echo "  sweep() reclaimed     -> $(q 'SELECT sweep();') hold(s)   [must be 4 -- holds, not rows]"
echo "    A -> $(state $U)     B -> $(state $V)   [both must be 0 reserved]"
echo "  a 1000 for A now      -> $(q "SELECT coalesce(reserve('$U','$P',1000,gen_random_uuid())::text,'REFUSED');")"
echo "  a 1000 for B now      -> $(q "SELECT coalesce(reserve('$V','$P',1000,gen_random_uuid())::text,'REFUSED');")"

echo
echo "--- TEST 4: settle is idempotent. A retried settle must charge once."
reset 1000
q "SELECT reserve('$U','$P',500,'33333333-3333-3333-3333-333333333333');" >/dev/null
q "SELECT settle('33333333-3333-3333-3333-333333333333',400);" >/dev/null
echo "  after first settle  -> $(state)"
q "SELECT settle('33333333-3333-3333-3333-333333333333',400);" >/dev/null
echo "  after second settle -> $(state)   (unchanged = idempotent)"

echo
echo "--- TEST 5: settle caps the charge at the reservation. This is a RESIDUAL, not a feature."
echo "    LEAST(actual, reserved) means a call that cost more than was held is charged the"
echo "    hold and the excess is absorbed silently -- real provider spend that never reaches"
echo "    the cap. Shown so SONNY-135 decides it rather than inherits it (PR #82 cycle 1, F9)."
reset 1000
q "SELECT reserve('$U','$P',100,'44444444-4444-4444-4444-444444444444');" >/dev/null
q "SELECT settle('44444444-4444-4444-4444-444444444444',900);" >/dev/null
echo "  reserved 100, call actually cost 900 -> $(state)"
echo "  800 credits of real spend went uncharged."
echo
echo "=== finished $(date -u '+%Y-%m-%dT%H:%M:%SZ') UTC"
