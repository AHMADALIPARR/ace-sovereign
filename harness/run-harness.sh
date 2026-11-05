#!/usr/bin/env bash
# run-harness.sh — start the harness service.
# Env: SBX_HOME (sandbox state root), ACE_SBX (path to bin/sbx).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" >/dev/null
exec erl -noshell -pa "$HERE/ebin" -eval 'ace_harness:start().'
