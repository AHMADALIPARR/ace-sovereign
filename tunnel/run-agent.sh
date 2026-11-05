#!/usr/bin/env bash
# run-agent.sh — start the inside agent on the sandbox host.
# Env: ACE_RELAY_HOST, ACE_AGENT_PORT (7701), ACE_TUNNEL_NAME,
#      ACE_TUNNEL_KEYFILE, ACE_TARGET_PORT (the local harness, 8765).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" >/dev/null
exec erl -noshell -pa "$HERE/ebin" -eval 'ace_agent:run_forever().'
