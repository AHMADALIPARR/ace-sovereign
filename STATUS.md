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

## Staged, not yet built

- The harness service implementing `harness/PROTOCOL.md` (house choice:
  Erlang/OTP, per the sovereign-circuit-fabric console precedent).
- Public deployment of the relay: the software runs anywhere; choosing
  which always-on host holds the public port is the owner's call. No
  account or token is needed at any point — the tunnel key is generated
  on his machines.
- Jetson stage: KVM microVM wrap of the sbx lifecycle, density runs
  (many forks of one base), and the Bonsai backend (:8086) as the first
  tenant behind the tunnel.

## Repository state

Working name `ace-sovereign`. Local only; not pushed. License: the
sovereign license in `LICENSE`, copied verbatim.
