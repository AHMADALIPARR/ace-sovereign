#!/usr/bin/env bash
# End-to-end lifecycle tests for sbx: base gate, create, exec environment
# scrub, snapshot, fork divergence, total rollback, ledger chain.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
export SBX_HOME=$(mktemp -d /tmp/sbx-test.XXXXXX)
SBX="$REPO/bin/sbx"
PASS=0; FAIL=0
ok()   { if [ "$1" = 0 ]; then PASS=$((PASS+1)); echo "ok   - $2"; else FAIL=$((FAIL+1)); echo "FAIL - $2"; fi; }
cleanup() {
    for m in "$SBX_HOME"/boxes/*/merged; do mountpoint -q "$m" 2>/dev/null && umount "$m"; done
    rm -rf "$SBX_HOME"
}
trap cleanup EXIT
cleanup

# fixture base
mkdir -p "$SBX_HOME/fixture/sub"
echo "v1" > "$SBX_HOME/fixture/app.txt"
echo "code" > "$SBX_HOME/fixture/sub/code.txt"
"$SBX" base create core "$SBX_HOME/fixture" >/dev/null; ok $? "base create"

# credential gate: a poisoned base must be refused
mkdir -p "$SBX_HOME/poison"
echo "x" > "$SBX_HOME/poison/app.txt"
echo "TOKEN=abc" > "$SBX_HOME/poison/.env"
"$SBX" base create poisoned "$SBX_HOME/poison" >/dev/null 2>&1
[ $? -ne 0 ]; ok $? "credential gate refuses a base containing .env"

# create + exec + environment scrub
"$SBX" create alpha --base core >/dev/null; ok $? "create alpha"
"$SBX" exec alpha -- sh -c 'echo alpha-1 > note.txt' ; ok $? "exec writes into the box"
[ "$(cat "$SBX_HOME/boxes/alpha/merged/note.txt")" = "alpha-1" ]; ok $? "write visible in merged tree"
[ "$(cat "$SBX_HOME/boxes/alpha/merged/app.txt")" = "v1" ]; ok $? "base content visible through overlay"
SCRUB=$("$SBX" exec alpha -- sh -c 'echo "HOME=$HOME TOKEN=${HOST_SECRET_TOKEN:-unset}"')
echo "$SCRUB" | grep -q 'TOKEN=unset'; ok $? "exec environment is scrubbed (no host tokens)"

# snapshot, diverge, fork
"$SBX" snapshot alpha s1 >/dev/null; ok $? "snapshot alpha s1"
"$SBX" exec alpha -- sh -c 'echo alpha-2 > note.txt; echo later > post.txt'
"$SBX" fork alpha beta >/dev/null; ok $? "fork alpha -> beta"
[ "$(cat "$SBX_HOME/boxes/beta/merged/note.txt")" = "alpha-2" ]; ok $? "fork carries the fork-time state"
"$SBX" exec beta -- sh -c 'echo beta-1 > note.txt; echo b > beta-only.txt'
[ "$(cat "$SBX_HOME/boxes/alpha/merged/note.txt")" = "alpha-2" ]; ok $? "sibling writes invisible (alpha unchanged)"
[ ! -e "$SBX_HOME/boxes/alpha/merged/beta-only.txt" ]; ok $? "sibling files invisible (no beta-only.txt in alpha)"

# rollback is total
"$SBX" rollback alpha s1 >/dev/null; ok $? "rollback alpha -> s1"
[ "$(cat "$SBX_HOME/boxes/alpha/merged/note.txt")" = "alpha-1" ]; ok $? "rolled-back content matches the snapshot"
[ ! -e "$SBX_HOME/boxes/alpha/merged/post.txt" ]; ok $? "files created after the snapshot are gone"

# ledger chain recompute
python3 - "$SBX_HOME/ledger.log" <<'EOF'
import hashlib, sys
prev = '0' * 64
n = 0
for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    if not line:
        continue
    h, payload = line.split(' ', 1)
    assert hashlib.sha256(f'{prev}|{payload}'.encode()).hexdigest() == h, f'chain broken at entry {n}'
    prev = h
    n += 1
print(f'ledger chain verified: {n} entries')
assert n >= 8
EOF
ok $? "ledger hash chain recomputes end to end"

"$SBX" destroy beta >/dev/null; ok $? "destroy beta"
"$SBX" destroy alpha >/dev/null; ok $? "destroy alpha"

echo "---"
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
