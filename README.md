# ACE — a sovereign Agent Compute Engine

An agent compute engine on owned hardware, built to the shape Google
formalized with its Agent Compute Engine (2026): a **harness** that
decides and a **sandbox** that executes, split by a hard boundary. Here
the layers run on the owner's fleet — phone as console, Jetson as the
compute host, agent VMs of the same shape — and the cloud's policy machinery is replaced by the owner's:
hash-chained receipts instead of
a vendor attestation service, a credential gate instead of a credential
vault, and one reverse tunnel as the only public edge.

## The pieces

- **`bin/sbx`** — the sandbox lifecycle. A sandbox is a copy-on-write
  workspace: immutable lower layers (a base tree plus frozen snapshots)
  under a writable upper, joined by overlayfs. Verbs: `base create`
  (with a credential scan that *refuses* bases containing `.env`,
  tokens, keys, or secret-shaped files), `create`, `exec` (scrubbed
  environment — PATH, LANG, and the box name cross, nothing else),
  `snapshot`, `fork` (a sibling that carries the fork-time state and
  then diverges), `rollback` (total: post-snapshot files are gone, not
  hidden), `destroy`, `list`, `status`. Every verb extends an append-only
  SHA-256 hash-chained ledger — the sandbox fleet's identity and audit
  trail in one file.
- **`harness/`** — the brain's contract: a dispatch protocol
  (JSON lines over a Unix socket) in which the harness decides, the
  sandbox executes, host credentials are unvouchable, and every dispatch
  is ledgered before and after it runs.
- **`gateway/`** — the only public edge: an ngrok reverse tunnel to the
  harness's localhost port, outbound-only. The gateway holds the tunnel
  token in its own environment, scans every sandbox tree for that token
  before opening, and refuses to start if it is ever found inside one.

## Design

`BLUEPRINT.md` maps each ACE pillar to this build: zero-credential
guests, no direct network in the sandbox, per-request credential
brokering at the gateway, snapshot/fork/rollback as native verbs, and
density through shared immutable bases instead of rented deduplication.

## Status

See `STATUS.md` for what is verified by execution and what is staged:
the lifecycle and its gates are proven here; the microVM wrap and the
live tunnel are Jetson-stage work.
