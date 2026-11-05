# STATUS

## Verified by execution (this VM, 2026-11-04)

- `test/run-tests.sh`: **18/18 pass.** Coverage: base creation; the
  credential gate refusing a base that contains a `.env`; sandbox
  creation over overlayfs; writes visible through the mount with base
  content showing through; the exec environment scrub (a host token
  variable does not cross); snapshot; fork carrying fork-time state;
  sibling divergence in both directions (writes and files invisible
  across the fork); total rollback (content restored, later files
  gone); destroy; and the ledger's SHA-256 chain recomputed end to end
  (9 entries in the test run).
- ACE's existence and shape were checked against Google's own
  2026-10-22 deep dive before the blueprint was written.

## The container machine (owner direction, 2026-11-04)

The owner directed the container layer the same evening: a 6502
machine in Erlang — "any hardware should work." `machine/` is that
machine: `ace6502` implements the full official NMOS 6502 opcode set
as a BEAM-side functional state (64 KB array memory), with BCD
ADC/SBC, the NMOS JMP-indirect page quirk, a memory-mapped output port
at $FE00, BRK as the halt, and a deterministic step budget in place of
a clock. `ace_asm` assembles program terms using opcodes inverted from
the machine's own table, so assembler and machine cannot disagree.

Verified by execution: `machine/test/run-machine-test.sh` **4/4**,
including 11 known-vector checks — arithmetic and flags, a 1..10 loop,
JSR/RTS, the output port, budget exhaustion on an infinite loop, BCD
(09+01=10; 99+01=00 with carry), the indirect-jump quirk landing at
$9934 and not $5634, a 16-bit sum-of-squares cross-checked against
Erlang's own arithmetic (650), SBC and stack round trips, and indexed
indirect addressing — plus the `run.sh` CLI executing a program file
end to end. The harness dispatches these programs directly
(`run6502`): protocol client now **16/16**, with budget stops,
program-name traversal refusal, and ledger entries all verified.

## Constraints found on this VM

- No `/dev/kvm` and no QEMU installed — and no longer load-bearing:
  the container machine above needs neither. The sbx overlay lifecycle
  is the workspace layer on every host; a KVM guest remains an optional
  extra wrap on hosts that have one.
- This VM's btrfs refuses overlay upper layers ("cannot mount overlay
  read-only"); overlay mounts succeed on tmpfs. On this host SBX_HOME
  must point at a tmpfs (sbx prints this hint on mount failure); tmpfs
  state is ephemeral across VM replacement. On conventional hosts the
  default `$HOME/.ace-sovereign` applies.

## The tunnel (owner correction, 2026-11-04)

The owner clarified the same evening: he has never used ngrok or any
vendor API/token (GitHub excepted) — "ngrok" named the *shape*, bare
metal, and the one key in the system is his own. The ngrok gateway
built earlier in the day was removed the same day and replaced by a
hand-rolled tunnel in `tunnel/` (Erlang/OTP; OTP's crypto and gen_tcp
are the whole supply chain).

Verified by execution (this VM, 2026-11-04): `tunnel/test/run-tunnel-test.sh`
**7/7 pass** — operator key generation; compilation; the agent
registering with the relay (HMAC over a relay-issued nonce); a public
HTTP request reaching a localhost-only harness through the tunnel; a
second stream pairing independently; an agent with the wrong key
refused, with the refusal logged by the relay.

## The harness (built 2026-11-04, after the tunnel)

`harness/` implements PROTOCOL.md as a service: `ace_harness` (Erlang/
OTP) listens on a Unix socket at `$SBX_HOME/harness.sock`, validates
each JSON-lines dispatch, and executes it through `sbx exec` — the
harness decides and dispatches; sbx remains the only executor. Two
supporting changes: `sbx exec` learned `--allow VAR` (a named variable
crosses the scrub; credential-shaped names are refused inside sbx too,
so the gate holds at both layers) and exec now replaces the sbx
process, so the harness's timeout kills the dispatched process exactly.

Verified by execution: `harness/test/run-harness-test.sh` **6/6**,
including the protocol client's 9/9 checks — dispatch returns exit
code, output, and a matching stdout hash; a benign env_allow variable
crosses; a credential-shaped one is refused and the refusal is
ledgered; unknown boxes are refused; an overrunning command is killed
at its timeout; and the shared ledger chain verifies end to end with
sbx and harness entries interleaved (12 entries in the test run). Two
defects were found and fixed under test: a socket-ownership race in
the Erlang accept paths (gated spawns), and atom map keys in the JSON
encoder.

## Staged, not yet built

- Public deployment of the relay: the software runs anywhere; choosing
  which always-on host holds the public port is the owner's call. No
  account or token is needed at any point — the tunnel key is generated
  on his machines.
- Fleet stage: density runs (many forks of one base), the engine
  running on the Jetson (BEAM is already its stack), and the Bonsai
  backend (:8086) as the first tenant behind the tunnel.

## Repository state

Working name `ace-sovereign`. Local only; not pushed. License: the
sovereign license in `LICENSE`, copied verbatim.
