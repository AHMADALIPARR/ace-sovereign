#!/usr/bin/env bash
# End-to-end tunnel test: a public client reaches a localhost-only
# harness through the relay, over connections the agent dialed out.
# Plus the auth gate: an agent with the wrong key is refused.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/ace-tunnel-test.XXXXXX)
PASS=0; FAIL=0
ok() { if [ "$1" = 0 ]; then PASS=$((PASS+1)); echo "ok   - $2"; else FAIL=$((FAIL+1)); echo "FAIL - $2"; fi; }
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

export ACE_AGENT_PORT=17701 ACE_PUBLIC_PORT=18801 ACE_TARGET_PORT=18765 ACE_RELAY_HOST=127.0.0.1
export ACE_TUNNEL_KEYFILE="$TMP/tunnel-key"
bash "$HERE/make-key.sh" "$ACE_TUNNEL_KEYFILE" >/dev/null; ok $? "operator key generated"
bash "$HERE/make-key.sh" "$TMP/wrong-key" >/dev/null

# the "harness": a localhost-only HTTP server with a marker file.
# Started directly (no subshell wrapper) so $! is the server itself
# and cleanup really kills it — a wrapper leaves a zombie listener.
mkdir -p "$TMP/www"; echo "harness-behind-the-tunnel" > "$TMP/www/marker.txt"
python3 -m http.server 18765 --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
PIDS="$PIDS $!"

"$HERE/build.sh" >/dev/null; ok $? "tunnel compiles (erlc, OTP only)"

erl -noshell -pa "$HERE/ebin" -eval 'ace_relay:start(), receive after infinity -> ok end.' \
    > "$TMP/relay.log" 2>&1 &
PIDS="$PIDS $!"
erl -noshell -pa "$HERE/ebin" -eval 'ace_agent:run_forever().' \
    > "$TMP/agent.log" 2>&1 &
PIDS="$PIDS $!"

# wait for registration
for i in $(seq 1 50); do grep -q "agent registered" "$TMP/relay.log" && break; sleep 0.2; done
grep -q "agent registered" "$TMP/relay.log"; ok $? "agent registered with the relay (HMAC over nonce)"

BODY=$(curl -s --max-time 10 http://127.0.0.1:18801/marker.txt)
[ "$BODY" = "harness-behind-the-tunnel" ]; ok $? "public request reached the localhost harness through the tunnel"
BODY2=$(curl -s --max-time 10 http://127.0.0.1:18801/marker.txt)
[ "$BODY2" = "harness-behind-the-tunnel" ]; ok $? "second stream pairs independently"

# wrong key: a one-shot agent must be refused
ACE_TUNNEL_KEYFILE="$TMP/wrong-key" erl -noshell -pa "$HERE/ebin" -eval '
  case ace_agent:run_once() of
    {error, auth_refused} -> io:format("AUTH REFUSED~n"), halt(0);
    Other -> io:format("UNEXPECTED ~p~n", [Other]), halt(1)
  end.' > "$TMP/bad-agent.log" 2>&1
[ $? = 0 ] && grep -q "AUTH REFUSED" "$TMP/bad-agent.log"; ok $? "agent with the wrong key is refused"
grep -q "auth REFUSED" "$TMP/relay.log"; ok $? "relay logged the refusal"

echo "---"
echo "tunnel tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
