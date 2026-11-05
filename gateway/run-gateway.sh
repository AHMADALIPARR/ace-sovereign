#!/usr/bin/env bash
# run-gateway.sh — start the tunnel edge.
#
# Credential discipline, enforced here rather than documented:
#  1. The ngrok authtoken comes from the environment of THIS host (the
#     gateway), is handed to the ngrok agent, and is never written into
#     the repository or into any sandbox tree.
#  2. Before the tunnel opens, every sandbox tree is scanned for the
#     token string. If the token is found inside a sandbox, the gateway
#     refuses to start: a credential that reached a sandbox is treated
#     as compromised, not as a warning.
set -euo pipefail

SBX_HOME="${SBX_HOME:-$HOME/.ace-sovereign}"
HERE=$(cd "$(dirname "$0")" && pwd)

: "${NGROK_AUTHTOKEN:?set NGROK_AUTHTOKEN in the gateway environment}"
command -v ngrok >/dev/null || { echo "gateway: ngrok not installed on this host" >&2; exit 1; }

if [ -d "$SBX_HOME/boxes" ]; then
    if grep -rqs "$NGROK_AUTHTOKEN" "$SBX_HOME/boxes"; then
        echo "gateway: REFUSED — the tunnel token was found inside a sandbox tree." >&2
        echo "gateway: treat the token as compromised and rotate it." >&2
        exit 1
    fi
fi

ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null
exec ngrok start --config "$HERE/ngrok.yml" harness
