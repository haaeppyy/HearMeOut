#!/usr/bin/env bash
# virtual-callee.sh — headless User B for single-device testing.
#
# With one physical iPhone, the device (User A) can't be both ends of a
# call. This script plays the OTHER end over plain HTTPS so every
# device-side transition is exercisable:
#   Incoming path:  ./virtual-callee.sh call <USER_A_ID>   # device rings
#   Outgoing path:  start the call on-device, then join/end it here.
#
# Setup (once, after `supabase functions deploy`):
#   export SUPABASE_URL="https://xyzcompany.supabase.co"
#   export SUPABASE_ANON_KEY="<anon key>"
#   export CALLEE_EMAIL="test-b@example.com"     # headless user
#   export CALLEE_PASSWORD="<password>"
#   ./virtual-callee.sh setup                     # signs B up + sets phone
#   ./virtual-callee.sh token                     # prints B's JWT (debug)
#
# Commands:
#   setup                  sign B up (idempotent: falls back to sign-in),
#                          sets B's phone so A can resolve it via users-lookup
#   token                  print B's access token
#   call <calleeId> [name] POST calls/ as B  -> prints callId (device rings)
#   join <callId>          POST call-join/ as B
#   end <callId>           POST call-end/ as B
#   history                GET call-history as B
#   lookup <phone>         GET users-lookup as B
set -euo pipefail

: "${SUPABASE_URL:?export SUPABASE_URL first}"
: "${SUPABASE_ANON_KEY:?export SUPABASE_ANON_KEY first}"
: "${CALLEE_EMAIL:?export CALLEE_EMAIL first}"
: "${CALLEE_PASSWORD:?export CALLEE_PASSWORD first}"

AUTH_URL="$SUPABASE_URL/auth/v1"
FN_URL="$SUPABASE_URL/functions/v1"
STATE_DIR="${TMPDIR:-/tmp}/virtual-callee"
mkdir -p "$STATE_DIR"
TOKEN_FILE="$STATE_DIR/token"

auth_header() { echo "apikey: $SUPABASE_ANON_KEY"; }

b_signin() {
  curl -s -X POST "$AUTH_URL/token?grant_type=password" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$CALLEE_EMAIL\",\"password\":\"$CALLEE_PASSWORD\"}"
}

cmd_setup() {
  echo "-- sign-up (falls back to sign-in if B already exists)"
  resp=$(curl -s -X POST "$AUTH_URL/signup" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$CALLEE_EMAIL\",\"password\":\"$CALLEE_PASSWORD\",\"data\":{\"display_name\":\"Virtual Callee\"}}")
  token=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('access_token') or (d.get('session') or {}).get('access_token') or ''))")
  if [ -z "$token" ]; then
    echo "-- sign-up returned no session (likely already registered / email confirmation on); signing in"
    token=$(b_signin | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")
  fi
  [ -n "$token" ] || { echo "FAILED: $resp"; exit 1; }
  echo "$token" > "$TOKEN_FILE"
  echo "-- B token cached. NOTE: if the project requires email confirmation,"
  echo "   confirm B in Supabase dashboard > Authentication > Users first."
  echo "-- setting B phone (+15550001111) so A can resolve it via users-lookup"
  uid=$(echo "$token" | cut -d. -f2 | python3 -c "import sys,json,base64; s=sys.stdin.read().strip(); s+='='*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s))['sub'])")
  curl -s -X PUT "$AUTH_URL/user" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"phone":"+15550001111","data":{"display_name":"Virtual Callee"}}' > /dev/null
  echo "B user id: $uid"
  echo "Add a contact on-device with phone +15550001111, then call it."
}

cmd_token() { [ -f "$TOKEN_FILE" ] && cat "$TOKEN_FILE" && echo || { echo "run setup first"; exit 1; }; }

bearer() { echo "Authorization: Bearer $(cmd_token)"; }

cmd_call() {
  [ $# -ge 1 ] || { echo "usage: $0 call <calleeId>"; exit 1; }
  curl -s -X POST "$FN_URL/calls" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "$(bearer)" -H "Content-Type: application/json" \
    -d "{\"calleeId\":\"$1\"}" | python3 -m json.tool
}

cmd_join() {
  [ $# -ge 1 ] || { echo "usage: $0 join <callId>"; exit 1; }
  curl -s -X POST "$FN_URL/call-join" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "$(bearer)" -H "Content-Type: application/json" \
    -d "{\"callId\":\"$1\"}" | python3 -m json.tool
}

cmd_end() {
  [ $# -ge 1 ] || { echo "usage: $0 end <callId>"; exit 1; }
  curl -s -X POST "$FN_URL/call-end" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "$(bearer)" -H "Content-Type: application/json" \
    -d "{\"callId\":\"$1\"}" | python3 -m json.tool
}

cmd_history() {
  curl -s "$FN_URL/call-history?limit=20" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "$(bearer)" | python3 -m json.tool
}

cmd_lookup() {
  [ $# -ge 1 ] || { echo "usage: $0 lookup <phone>"; exit 1; }
  curl -s "$FN_URL/users-lookup?phone=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "$(bearer)" | python3 -m json.tool
}

case "${1:-}" in
  setup)   cmd_setup ;;
  token)   cmd_token ;;
  call)    shift; cmd_call "$@" ;;
  join)    shift; cmd_join "$@" ;;
  end)     shift; cmd_end "$@" ;;
  history) cmd_history ;;
  lookup)  shift; cmd_lookup "$@" ;;
  *) echo "usage: $0 {setup|token|call|join|end|history|lookup}"; exit 1 ;;
esac
