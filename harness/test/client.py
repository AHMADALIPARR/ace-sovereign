#!/usr/bin/env python3
"""Harness protocol test client: speaks JSON lines over the Unix socket
and asserts the responses. Prints one line per check."""
import hashlib
import json
import socket
import sys
import time

sock_path = sys.argv[1]
results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(("ok   - " if cond else "FAIL - ") + name)


def rpc(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        f = s.makefile("rw", encoding="utf-8", newline="\n")
        f.write(json.dumps(req) + "\n")
        f.flush()
        return json.loads(f.readline())


# 1. plain dispatch: output and its hash come back, exit is real
r = rpc({"id": "t1", "box": "alpha", "argv": ["sh", "-c", "echo hello"]})
check("dispatch returns exit 0", r.get("exit") == 0)
check("dispatch returns the output", r.get("stdout") == "hello\n")
check("stdout hash matches the output",
      r.get("stdout_sha256") == hashlib.sha256(b"hello\n").hexdigest())
check("response carries the ledger head", len(r.get("ledger_head", "")) == 64)

# 2. env_allow: a benign variable vouched by the harness crosses
r = rpc({"id": "t2", "box": "alpha",
         "argv": ["sh", "-c", "echo $TEST_MARKER"], "env_allow": ["TEST_MARKER"]})
check("env_allow passes a benign variable", r.get("stdout") == "vouched\n")

# 3. env_allow: a credential-shaped name is refused
r = rpc({"id": "t3", "box": "alpha", "argv": ["true"],
         "env_allow": ["AWS_SECRET_TOKEN"]})
check("credential-shaped env_allow is refused", r.get("error") == "env_allow_refused")

# 4. unknown box
r = rpc({"id": "t4", "box": "nope", "argv": ["true"]})
check("unknown box is refused", r.get("error") == "unknown_box")

# 5. timeout kills the command
t0 = time.time()
r = rpc({"id": "t5", "box": "alpha", "argv": ["sleep", "5"], "timeout_s": 1})
elapsed = time.time() - t0
check("overrunning command times out", r.get("error") == "timeout")
check("timeout fires promptly", elapsed < 4)

failed = [n for n, ok in results if not ok]
print(f"client: {len(results) - len(failed)}/{len(results)} checks passed")
sys.exit(1 if failed else 0)
