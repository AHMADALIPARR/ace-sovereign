#!/usr/bin/env bash
# run-relay.sh — start the relay on the public host.
# Env: ACE_AGENT_PORT (7701), ACE_PUBLIC_PORT (8801), ACE_TUNNEL_KEYFILE.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" >/dev/null
exec erl -noshell -pa "$HERE/ebin" -eval 'ace_relay:start(), receive after infinity -> ok end.'
