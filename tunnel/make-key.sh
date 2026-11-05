#!/usr/bin/env bash
# make-key.sh — generate the tunnel key: the operator's own cryptographic
# key for his own tunnel. 32 random bytes, hex-encoded, mode 600.
# Place the same file on the relay host and the agent host, by hand.
# It is never committed and never lives inside a sandbox tree.
set -euo pipefail
OUT="${1:-$HOME/.ace-tunnel-key}"
[ -e "$OUT" ] && { echo "make-key: $OUT exists, refusing to overwrite" >&2; exit 1; }
umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$OUT"
echo >> "$OUT"
chmod 600 "$OUT"
echo "key written: $OUT (copy it to the other tunnel host yourself)"
