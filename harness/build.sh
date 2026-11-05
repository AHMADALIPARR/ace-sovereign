#!/usr/bin/env bash
# build.sh — compile the harness modules with erlc. No deps beyond OTP.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/ebin"
erlc -o "$HERE/ebin" "$HERE/src/ace_json.erl" "$HERE/src/ace_harness.erl"
echo "built: $HERE/ebin"
