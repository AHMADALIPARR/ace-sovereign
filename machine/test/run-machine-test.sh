#!/usr/bin/env bash
# Machine test suite: compile, run the Erlang known-vector checks, and
# run one program through the CLI runner end to end.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok() { if [ "$1" = 0 ]; then PASS=$((PASS+1)); echo "ok   - $2"; else FAIL=$((FAIL+1)); echo "FAIL - $2"; fi; }
TMP=$(mktemp -d /tmp/ace-machine.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

"$HERE/build.sh" >/dev/null 2>&1; ok $? "machine compiles (erlc, OTP only)"
erlc -o "$HERE/ebin" "$HERE/test/ace6502_tests.erl" 2>/dev/null
erl -noshell -pa "$HERE/ebin" -eval 'case ace6502_tests:run_tests() of ok -> halt(0); _ -> halt(1) end.' \
    > "$TMP/unit.log" 2>&1
UNIT_RC=$?
cat "$TMP/unit.log"
[ "$UNIT_RC" = 0 ]; ok $? "known-vector checks (ace6502_tests)"

# CLI end to end: assemble the HI program to a file, run it via run.sh
erl -noshell -pa "$HERE/ebin" -eval "
  {ok, Bin, _} = ace_asm:assemble([{lda, {imm, \$H}}, {sta, {abs, 16#FE00}},
                                   {lda, {imm, \$I}}, {sta, {abs, 16#FE00}},
                                   {brk, imp}], 16#0200),
  ok = file:write_file(\"$TMP/hi.bin\", Bin), halt(0)."
OUT=$(bash "$HERE/run.sh" "$TMP/hi.bin" 2>"$TMP/run.err"); RC=$?
[ "$OUT" = "HI" ] && [ "$RC" = 0 ]; ok $? "run.sh executes a program file and returns its output"
grep -q "halted: brk" "$TMP/run.err"; ok $? "run.sh reports the halt on stderr"

echo "---"
echo "machine tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
