#!/usr/bin/env bash
# run-contract-tests.sh — backend contract + RLS suite (Layer 1).
#
# Hermetic by convention: all fixtures use unique test-<epoch> identities so
# concurrent/leftover runs never collide. Target is chosen by environment:
#
#   Local stack (default):  ./run-contract-tests.sh
#     Uses BASE=http://127.0.0.1:54321 + ANON from `supabase status -o env`.
#     Requires the local stack UP (`supabase start` in backend/) with the
#     repo migrations applied and functions served with test secrets.
#   Staging project:        BASE=https://<ref>.supabase.co ANON=<anon> ./run-contract-tests.sh
#     NEVER point this at production — tests create users, calls, and cron
#     probes. Pass CLEANUP=1 to also delete auth.users rows it created
#     (requires the service-role key via SERVICE_ROLE for the admin API).
#
# Exit code: 0 = all pass, 1 = any failure. Each assertion prints PASS/FAIL.
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:54321}"
ANON="${ANON:-}"
if [ -z "$ANON" ]; then
  echo "ANON is empty. Local: export \$(supabase status -o env | grep ANON_KEYkubean | sed 's/ANON_KEYkubean=/ANON=/') — see README. Staging: export ANON=<anon key>."
  exit 2
fi
TS=$(date +%s)
PASS=0
FAIL=0
# Phones are UNIQUE in public.users, so each run needs its own pair or a
# second run against the same project collides with the first run's users.
PHONE_A="+1555${TS: -6}1"
PHONE_B="+1555${TS: -6}2"

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 -- $2"; }

# assert_status <label> <expected> <curl-args...>: checks HTTP status only.
assert_status() {
  local label="$1" expected="$2"; shift 2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$@")
  if [ "$code" = "$expected" ]; then pass "$label"; else fail "$label" "want $expected got $code"; fi
}

# api <method> <path> <jwt-or-empty> [data]: prints body, sets HTTP_CODE.
api() {
  local method="$1" path="$2" jwt="${3:-}" data="${4:-}"
  local args=(-s -w $'\n%{http_code}' -X "$method" "$BASE$path" -H "apikey: $ANON" -H "Content-Type: application/json")
  [ -n "$jwt" ] && args+=(-H "Authorization: Bearer $jwt")
  [ -n "$data" ] && args+=(-d "$data")
  local out
  out=$(curl "${args[@]}")
  HTTP_CODE=$(echo "$out" | tail -1)
  echo "$out" | sed '$d'
}

echo "== target: $BASE (ts=$TS) =="

echo "--- auth + trigger ---"
A_JSON=$(api POST /auth/v1/signup "" "{\"email\":\"test-a-$TS@gmail.com\",\"password\":\"TestPass123!\",\"data\":{\"display_name\":\"Test A $TS\"}}")
A_ID=$(echo "$A_JSON" | python3 -c "import sys,json; print((json.load(sys.stdin).get('user') or {}).get('id',''))")
A_TOK=$(echo "$A_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or (d.get('session') or {}).get('access_token') or '')")
[ -n "$A_ID" ] && [ -n "$A_TOK" ] && pass "signup A returns user + session" || fail "signup A" "$A_JSON"
B_JSON=$(api POST /auth/v1/signup "" "{\"email\":\"test-b-$TS@gmail.com\",\"password\":\"TestPass123!\",\"data\":{\"display_name\":\"Test B $TS\"}}")
B_ID=$(echo "$B_JSON" | python3 -c "import sys,json; print((json.load(sys.stdin).get('user') or {}).get('id',''))")
B_TOK=$(echo "$B_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or (d.get('session') or {}).get('access_token') or '')")
[ -n "$B_ID" ] && [ -n "$B_TOK" ] && pass "signup B returns user + session" || fail "signup B" "$B_JSON"

echo "--- profile phones (profile function) ---"
# Clients cannot write public.users directly (migration 008), so phones are
# set through the service-role profile function, same as the app does.
A_PROF=$(api POST /functions/v1/profile "$A_TOK" "{\"phone\":\"$PHONE_A\"}")
B_PROF=$(api POST /functions/v1/profile "$B_TOK" "{\"phone\":\"$PHONE_B\"}")
echo "$A_PROF" | grep -q "\"phone\":\"$PHONE_A\"" && pass "profile sets phone A" || fail "profile phone A" "$A_PROF"
echo "$B_PROF" | grep -q "\"phone\":\"$PHONE_B\"" && pass "profile sets phone B" || fail "profile phone B" "$B_PROF"

echo "--- users-lookup ---"
OUT=$(api GET "/functions/v1/users-lookup?phone=%2B${PHONE_B#+}" "$A_TOK")
echo "$OUT" | grep -q "\"id\":\"$B_ID\"" && pass "lookup hit returns B" || fail "lookup hit" "$OUT"
assert_status "lookup unknown → 404" 404 "$BASE/functions/v1/users-lookup?phone=%2B19998887777" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK"
assert_status "lookup missing phone → 400" 400 "$BASE/functions/v1/users-lookup" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK"
assert_status "lookup no token → 401" 401 "$BASE/functions/v1/users-lookup?phone=%2B1" -H "apikey: $ANON"

echo "--- calls/ ---"
CALL_JSON=$(api POST /functions/v1/calls "$A_TOK" "{\"calleeId\":\"$B_ID\"}")
CALL_ID=$(echo "$CALL_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callId',''))")
[ -n "$CALL_ID" ] && pass "startCall returns callId" || fail "startCall" "$CALL_JSON"
echo "$CALL_JSON" | grep -q '"pushDelivered":false' && pass "pushDelivered false without device" || fail "pushDelivered" "$CALL_JSON"
assert_status "self-call → 400" 400 -X POST "$BASE/functions/v1/calls" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK" -H "Content-Type: application/json" -d "{\"calleeId\":\"$A_ID\"}"
assert_status "unknown callee → 404" 404 -X POST "$BASE/functions/v1/calls" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK" -H "Content-Type: application/json" -d '{"calleeId":"00000000-0000-0000-0000-000000000000"}'

echo "--- call-join ---"
JOIN_JSON=$(api POST /functions/v1/call-join "$B_TOK" "{\"callId\":\"$CALL_ID\"}")
echo "$JOIN_JSON" | grep -q '"agoraChannel"' && pass "join returns channel tokens" || fail "join" "$JOIN_JSON"
assert_status "caller join → 403" 403 -X POST "$BASE/functions/v1/call-join" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK" -H "Content-Type: application/json" -d "{\"callId\":\"$CALL_ID\"}"

echo "--- call-end + history ---"
END_JSON=$(api POST /functions/v1/call-end "$A_TOK" "{\"callId\":\"$CALL_ID\"}")
echo "$END_JSON" | grep -q '"status":"ended"' && pass "end active → ended" || fail "end" "$END_JSON"
HIST_JSON=$(api GET "/functions/v1/call-history?limit=5" "$B_TOK")
echo "$HIST_JSON" | grep -q '"direction":"incoming"' && pass "history direction incoming for B" || fail "history" "$HIST_JSON"
assert_status "join after end → 410" 410 -X POST "$BASE/functions/v1/call-join" -H "apikey: $ANON" -H "Authorization: Bearer $B_TOK" -H "Content-Type: application/json" -d "{\"callId\":\"$CALL_ID\"}"

echo "--- push-token ---"
TOK_JSON=$(api POST /functions/v1/push-token "$A_TOK" '{"pushToken":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}')
echo "$TOK_JSON" | grep -q '"ok":true' && pass "push-token stores" || fail "push-token" "$TOK_JSON"
assert_status "short token → 400" 400 -X POST "$BASE/functions/v1/push-token" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK" -H "Content-Type: application/json" -d '{"pushToken":"short"}'

echo "--- RLS via REST ---"
# A must not see B's profile row.
A_SEES_B=$(api GET "/rest/v1/users?id=eq.$B_ID&select=id" "$A_TOK")
[ "$A_SEES_B" = "[]" ] && pass "A cannot read B profile" || fail "RLS users read" "$A_SEES_B"
# A must not update B's profile: with Prefer: return=representation a
# blocked UPDATE returns 200 with an empty array (vs the updated row).
UPD_BODY=$(curl -s -X PATCH "$BASE/rest/v1/users?id=eq.$B_ID" -H "apikey: $ANON" -H "Authorization: Bearer $A_TOK" -H "Content-Type: application/json" -H "Prefer: return=representation" -d '{"display_name":"pwned"}')
[ "$UPD_BODY" = "[]" ] && pass "A cannot update B profile" || fail "RLS users update" "$UPD_BODY"
# Anon (no JWT) sees no calls.
ANON_CALLS=$(curl -s "$BASE/rest/v1/calls?select=id&limit=1" -H "apikey: $ANON")
[ "$ANON_CALLS" = "[]" ] && pass "anon sees no calls" || fail "RLS calls anon" "$ANON_CALLS"
# Direct RPC of the trigger function is revoked.
assert_status "anon RPC handle_new_user denied" 404 -X POST "$BASE/rest/v1/rpc/handle_new_user" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{}'

echo "--- cleanup ---"
assert_status "cleanup wrong method → 405" 405 "$BASE/functions/v1/cleanup" -H "apikey: $ANON"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
