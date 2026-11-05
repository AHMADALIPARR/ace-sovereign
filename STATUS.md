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

## Constraints found on this VM

- No `/dev/kvm` and no QEMU installed: microVM boot is not exercised
  here. The sbx verbs manage workspace state; wrapping a guest around
  the workspace is the Jetson stage (KVM present there; qemu-img
  snapshots take over the snapshot/fork verbs).
- This VM's btrfs refuses overlay upper layers ("cannot mount overlay
  read-only"); overlay mounts succeed on tmpfs. On this host SBX_HOME
  must point at a tmpfs (sbx prints this hint on mount failure); tmpfs
  state is ephemeral across VM replacement. On conventional hosts the
  default `$HOME/.ace-sovereign` applies.

## Staged, not yet built

- The harness service implementing `harness/PROTOCOL.md` (house choice:
  Erlang/OTP, per the sovereign-circuit-fabric console precedent).
- The live ngrok tunnel: needs ngrok installed on the gateway host and
  the owner's ngrok authtoken in that host's environment. Nothing about
  the tunnel is testable before the token exists, and the token never
  enters this repository.
- Jetson stage: KVM microVM wrap of the sbx lifecycle, density runs
  (many forks of one base), and the Bonsai backend (:8086) as the first
  tenant behind the gateway.

## Repository state

Working name `ace-sovereign`. Local only; not pushed. License: the
sovereign license in `LICENSE`, copied verbatim.
