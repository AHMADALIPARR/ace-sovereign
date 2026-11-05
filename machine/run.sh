#!/usr/bin/env bash
# run.sh — run a 6502 program in the container machine.
#   run.sh PROGRAM.bin [ORG_HEX] [BUDGET]
# Program output ($FE00 writes) goes to stdout; the halt status line
# goes to stderr; exit code 0 on a clean BRK halt, 1 otherwise.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" >/dev/null
PROG="${1:?usage: run.sh PROGRAM.bin [ORG_HEX] [BUDGET]}"
ORG="${2:-0200}"
BUDGET="${3:-1000000}"
exec erl -noshell -pa "$HERE/ebin" -eval "
  {ok, Bin} = file:read_file(\"$PROG\"),
  Org = list_to_integer(\"$ORG\", 16),
  case ace6502:run_binary(Bin, Org, $BUDGET) of
    {ok, Out, M} ->
      io:format(\"~s\", [Out]),
      io:format(standard_error, \"halted: brk, steps=~p~n\", [maps:get(steps, ace6502:registers(M))]),
      halt(0);
    {error, Reason, Out, M} ->
      io:format(\"~s\", [Out]),
      io:format(standard_error, \"halted: ~p, steps=~p~n\", [Reason, maps:get(steps, ace6502:registers(M))]),
      halt(1)
  end."
