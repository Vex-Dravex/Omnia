# M1 — Linux Runtime + CLI Shell

**Goal:** prove the core resume-on-demand loop end to end, on the simpler of the two guest types, with the CLI as the only surface (no GUI, no RAIL yet). This is the foundation milestone — every later milestone depends on `vmd` and the Linux runtime existing and being reliable.

**Read first:** [docs/00-overview.md](../docs/00-overview.md), [docs/01-architecture.md](../docs/01-architecture.md), [docs/02-linux-runtime.md](../docs/02-linux-runtime.md), [docs/06-lifecycle-memory.md](../docs/06-lifecycle-memory.md) (state machine only — the balloon/dynamic-memory tuning is M4, don't build it now), [docs/08-cli.md](../docs/08-cli.md), [docs/protocols/agent.proto](../docs/protocols/agent.proto).

## Scope

In scope:
- `tools/build-linux-image/` — scripted build of the minimal Arch Linux ARM rootfs per [docs/02](../docs/02-linux-runtime.md), producing `omnia-linux-base.img.zst`.
- `omnia-agent` (Rust, crate at `guest-agent/`) implementing the gRPC-over-vsock server: `Hello`, `OpenShell`, `WatchEvents` (window-count only — no windows exist yet since RAIL isn't built; wire it up as a stub that never fires so the interface exists), `MountBlockDevice`/`UnmountBlockDevice` (implement fully — needed later, cheap to do now while touching this code).
- `vmd` (Swift executable target, `vmd/`) implementing: XPC service skeleton, `LinuxRuntime` wrapping `VZVirtualMachine` per [docs/02](../docs/02-linux-runtime.md)'s configuration table, the guest state machine from [docs/06](../docs/06-lifecycle-memory.md) (`stopped/running/suspending/suspended/resuming`) for the Linux guest only, `EnsureRunning` XPC method.
- `omnia` CLI (Swift ArgumentParser, `cli/`): `omnia status`, `omnia shell` (Linux-only for now — the picker can just always pick Linux since Windows doesn't exist yet, but write the picker logic so M3 only has to add a case), `omnia linux [cmd...]`.

Out of scope (do not build): Windows anything, RAIL/window presentation, app export/wrappers, marketplace, File Provider/Finder integration, dynamic-memory balloon tuning (leave the balloon device configured per [docs/02](../docs/02-linux-runtime.md) but don't build the controller logic from [docs/06](../docs/06-lifecycle-memory.md) — that's M4).

## Tasks

1. Set up the Xcode/SwiftPM workspace structure: `vmd/`, `cli/`, `guest-agent/` (separate Cargo workspace, cross-compiled for `aarch64-unknown-linux-musl`), `tools/build-linux-image/`.
2. Build `guest-agent`: implement the proto service (generate Swift + Rust stubs from `docs/protocols/agent.proto` via `protoc` — commit a `Makefile`/script that regenerates them, don't hand-write generated code). `OpenShell` spawns a real PTY and shell (`bash`), forwards resize.
3. Build `tools/build-linux-image/`: produces a bootable image with the guest agent installed as a systemd service, auto-starting on boot. Boot it manually once (outside Omnia, e.g. via a scratch VZVirtualMachine test harness or `qemu` for local iteration) to confirm the agent comes up and responds to `Hello`.
4. Build `vmd`'s `LinuxRuntime`: cold boot from the built image, connect vsock, call `Hello`, confirm handshake.
5. Implement `saveMachineStateTo`/`restoreMachineStateFrom` — suspend after boot, resume, confirm the guest resumes without a fresh boot (verify via a marker: write a file in the guest before suspend, confirm it exists with the same mtime after resume — proves it's a true resume, not disguised as a reboot).
6. Wire the state machine's `EnsureRunning` entry point: `stopped→running` (cold boot) and `suspended→resuming→running` (restore).
7. Build the CLI's `omnia shell`/`omnia linux` using `OpenShell` — should feel like `ssh`.
8. Manual idle-suspend: for M1, a fixed 90s timer with no window-count awareness (WatchEvents isn't meaningfully firing yet) is acceptable — start it whenever a shell session closes, cancel on new activity. Full window-count-driven suspend arrives in M2 (RAIL) and gets its policy pass in M4.

## Acceptance criteria

- `omnia status` correctly reports `stopped` before first use, `running` after `omnia linux echo hi`, and `suspended` ~90s after the shell session ends (poll, don't sleep-and-hope — script a test that polls every 5s for up to 2 minutes).
- `omnia linux uname -a` from a `suspended` state returns correct output within ~5s wall clock including resume (target resume itself: 1–3s per [docs/02](../docs/02-linux-runtime.md); allow slack for process spawn in this early milestone and tighten later).
- After suspend, `ps aux | grep vzlinux` on the host shows no process.
- A file written in the guest before suspend is unchanged (same content, same mtime) after resume — proves state, not reboot.
- `omnia linux <nonzero-exit-cmd>; echo $?` on the host reflects the guest command's real exit code.

## Test strategy

Shell-script integration test (`tests/m1_linux_runtime.sh`) driving the built `omnia` CLI against a real (test-only, disposable) guest image, asserting each acceptance criterion above via `omnia status` polling and file-marker checks. No mocking of `VZVirtualMachine` — this milestone's entire point is proving the real thing works.
