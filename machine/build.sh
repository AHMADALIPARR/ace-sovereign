#!/usr/bin/env bash
# build.sh — compile the 6502 machine and its assembler. OTP only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/ebin"
erlc -o "$HERE/ebin" "$HERE/src/ace6502.erl" "$HERE/src/ace_asm.erl"
echo "built: $HERE/ebin"
