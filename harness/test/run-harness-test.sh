#!/usr/bin/env bash
# Harness end-to-end test: real sandboxes via sbx, real dispatches over
# the Unix socket, and the shared ledger chain verified afterwards.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
export SBX_HOME=$(mktemp -d /tmp/sbx-harness.XXXXXX)
SBX="$REPO/bin/sbx"
PASS=0; FAIL=0
ok() { if [ "$1" = 0 ]; then PASS=$((PASS+1)); echo "ok   - $2"; else FAIL=$((FAIL+1)); echo "FAIL - $2"; fi; }
HPID=""
cleanup() {
    [ -n "$HPID" ] && kill "$HPID" 2>/dev/null
    for m in "$SBX_HOME"/boxes/*/merged; do mountpoint -q "$m" 2>/dev/null && umount "$m"; done
    rm -rf "$SBX_HOME"
}
trap cleanup EXIT

mkdir -p "$SBX_HOME/fixture"
echo "app" > "$SBX_HOME/fixture/app.txt"
"$SBX" base create core "$SBX_HOME/fixture" >/dev/null
"$SBX" create alpha --base core >/dev/null; ok $? "sandbox alpha ready"

"$REPO/harness/build.sh" >/dev/null; ok $? "harness compiles (erlc, OTP only)"

"$REPO/machine/build.sh" >/dev/null
# 6502 fixtures inside the sandbox: HI (prints via $FE00) and a spinner
python3 - "$SBX_HOME/boxes/alpha/merged" <<'EOF'
import sys
merged = sys.argv[1]
open(f"{merged}/hi.bin", "wb").write(bytes(
    [0xA9, 0x48, 0x8D, 0x00, 0xFE, 0xA9, 0x49, 0x8D, 0x00, 0xFE, 0x00]))
open(f"{merged}/spin.bin", "wb").write(bytes([0x4C, 0x00, 0x02]))
EOF

TEST_MARKER=vouched ACE_SBX="$SBX" erl -noshell -pa "$REPO/harness/ebin" "$REPO/machine/ebin" \
    -eval 'ace_harness:start().' > "$SBX_HOME/harness.log" 2>&1 &
HPID=$!
for i in $(seq 1 50); do [ -S "$SBX_HOME/harness.sock" ] && break; sleep 0.2; done
[ -S "$SBX_HOME/harness.sock" ]; ok $? "harness socket is listening"

python3 "$REPO/harness/test/client.py" "$SBX_HOME/harness.sock"
[ $? = 0 ]; ok $? "protocol client checks"

python3 - "$SBX_HOME/ledger.log" <<'EOF'
import hashlib, sys
prev = '0' * 64
events = []
for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    if not line:
        continue
    h, payload = line.split(' ', 1)
    assert hashlib.sha256(f'{prev}|{payload}'.encode()).hexdigest() == h, 'chain broken'
    prev = h
    events.append(payload.split('|')[1])
for want in ('dispatch', 'dispatch-done', 'dispatch-refused'):
    assert want in events, f'missing ledger event: {want}'
print(f'ledger chain verified: {len(events)} entries, dispatch events present')
EOF
ok $? "shared ledger chain verifies with harness entries interleaved"

"$SBX" destroy alpha >/dev/null; ok $? "destroy alpha"
echo "---"
echo "harness tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
