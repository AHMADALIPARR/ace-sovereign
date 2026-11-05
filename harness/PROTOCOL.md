# Harness dispatch protocol

The harness is the only component that decides. The sandbox is the only
component that executes. They speak over a Unix stream socket at
`$SBX_HOME/harness.sock` in newline-delimited JSON. There is no TCP
listener inside the engine; the gateway tunnel terminates at the
harness's own authenticated front door, never at this socket.

## Requests

A command dispatch:

```json
{"id": "01J…", "box": "alpha", "argv": ["python3", "job.py"],
 "env_allow": ["LANG"], "timeout_s": 600}
```

A 6502 dispatch — the program is a file in the sandbox's merged tree
and runs in the container machine (ace6502), bounded by a step budget
instead of a clock:

```json
{"id": "01J…", "box": "alpha", "run6502": "job.bin", "budget": 1000000}
```

The response adds `reason` (`brk`, `budget_exhausted`,
`{illegal_opcode, …}`) and `steps`. Program names are plain relative
file names; anything containing `..` or starting with `/` is refused
(`bad_program_name`), as is a missing file (`no_such_program`).

- `box` — an existing sandbox name.
- `argv` — executed via `sbx exec`: working directory is the sandbox's
  merged tree; the environment is the scrub allowlist (PATH, LANG,
  SBX_BOX) plus any `env_allow` names the harness itself vouches for.
  Host credentials are never vouchable: the harness rejects `env_allow`
  entries matching `*TOKEN*`, `*SECRET*`, `*KEY*`, `*PASSWORD*`.
- Every request is ledgered before execution (event `dispatch`) and
  after (event `dispatch-done`, with exit code and the SHA-256 of the
  captured output).

## Response

```json
{"id": "01J…", "exit": 0, "stdout": "…", "stdout_sha256": "…", "ledger_head": "…"}
```

Output itself returns on the socket; the ledger stores only its hash.
Refusals and failures return an `error` field instead of `exit`:
`env_allow_refused` (with the refused names), `unknown_box`,
`bad_argv`, `bad_request`, `timeout` (the command is killed at
`timeout_s`). A sandbox's identity in the ledger is its name plus the
chain position of its `create` entry — the local analogue of an
attested workload identity: short-lived boxes, long-lived proof.

## Rules

- The harness never executes `argv` itself; it only dispatches.
- A sandbox never learns the harness's environment, the gateway token,
  or any other sandbox's name or state.
- Dispatch to a destroyed sandbox, or with a credential-shaped
  `env_allow`, is refused and the refusal is ledgered.
