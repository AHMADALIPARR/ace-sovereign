#!/usr/bin/env bash
# build.sh — compile the tunnel modules with erlc. No rebar, no deps:
# OTP's crypto and gen_tcp are the whole supply chain.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/ebin"
erlc -o "$HERE/ebin" "$HERE/src/ace_tunnel.erl" "$HERE/src/ace_relay.erl" "$HERE/src/ace_agent.erl"
echo "built: $HERE/ebin"
