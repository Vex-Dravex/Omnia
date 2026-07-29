# Building Omnia — current status

**M1 (milestones/M1-linux-runtime.md) is verified end to end on a real
Mac** (Apple Silicon, macOS 26, Xcode 26.2, 2026-07-29):
`tests/m1_linux_runtime.sh` passes all nine checks — cold boot via
`omnia linux echo hi`, real guest exit-code propagation, idle-suspend to
zero VM footprint ~90s after the last session closes, resume-from-snapshot
answering `uname -a` in ~2s wall clock, and a marker file with identical
mtime+content across suspend/resume proving true resume, not a reboot.

This file is the honest ledger of what's proven vs. written-but-unproven.
Update it whenever something moves from one column to the other.

## Component status

### `guest-agent/` — Rust, verified

```
cd guest-agent
cargo test                                   # 10/10 (Linux x86_64 AND macOS arm64)
cargo clippy --all-targets -- -D warnings    # clean
cargo fmt -- --check                         # clean
cargo build --release --target aarch64-unknown-linux-musl   # static ELF, ~6MB
```

The cross-compile needs no external toolchain: `.cargo/config.toml` sets
`rust-lld` as the linker for the musl target. `src/mount.rs`'s real
mount/umount are `#[cfg(target_os = "linux")]` (nix's mount API is
Linux-shaped; non-Linux dev-mode returns a clear unsupported error).

Verified against a real guest over real vsock: `Hello` and `OpenShell`
(one-shot commands, exit codes) — the full M1 path. Not yet exercised for
real: `MountBlockDevice`/`UnmountBlockDevice` against an actual attached
disk (unit-tested through the `BlockDeviceOps` seam only), and
`WatchEvents` is an intentional never-yielding stub until M2/M4.

### `vmd/` — Swift, verified against a real booted guest

`swift build` + `swift test` (7/7 lifecycle tests) clean. Runtime-proven:
cold boot, suspend-to-snapshot, restore, vsock→UDS control-channel proxy.
Hard-won fixes the drafts needed, so nobody re-learns them:

- Snapshot restore fails with VZErrorDomain code 12 ("invalid argument")
  unless the restore-time configuration matches the saved one **including
  identity that VZ randomizes per-config**: the
  `VZGenericMachineIdentifier` AND the network device's MAC address. Both
  are persisted next to the image (`machine-id`, `mac-address`) on first
  boot.
- `saveMachineStateTo` requires the VM to be paused first.
- `VZVirtualMachine` is queue-bound: every VM/device call happens on the
  serial queue the VM was created with (see LinuxRuntime).
- A bare `VZVirtioConsoleDeviceConfiguration` fails validation; the
  guest's `console=hvc0` is a `VZVirtioConsoleDeviceSerialPortConfiguration`
  with a file attachment — the guest boot log lands in
  `~/Library/Application Support/Omnia/linux/console.log`.
- vmd ignores SIGPIPE (main.swift) — relay writes to reset sockets
  otherwise kill the daemon silently.
- "Running" means "the agent answers on vsock" (LinuxRuntime probes port
  5151 after start/restore), not "vCPUs are executing" — without that,
  every caller races the guest boot.
- Guest-initiated stops and VZ runtime failures reset the state machine
  via `VZVirtualMachineDelegate` → `GuestLifecycleController.noteGuestStopped`.

Still unproven: suspend/resume under real memory pressure, the proxy
under concurrent load, WatchEvents-driven suspend policy (M2/M4).

### `cli/` — Swift, verified against a real guest

Uses **gRPC Swift 2** (GRPCCore + grpc-swift-nio-transport +
grpc-swift-protobuf; the brew `grpc-swift` formula's plugin binary is
`protoc-gen-grpc-swift-2`). Consequence: the cli package's platform floor
is **macOS 15** (gRPC Swift 2's minimum; vmd itself remains macOS 14, and
every Apple Silicon Mac can run 15). gRPC Swift 1.x is maintenance-only
and its protoc plugin no longer ships as a brew bottle — don't go back.

Notable: for UDS targets the NIO transport derives HTTP/2 `:authority`
from the socket path, which tonic's h2 rejects (slashes/spaces make an
invalid URI authority) with a protocol-error RST_STREAM —
ShellSession.swift overrides the authority to "localhost".

Generated stubs are intentionally not committed — run
`scripts/generate-swift-proto.sh` after cloning and after any
`docs/protocols/agent.proto` change (Rust stubs regenerate automatically
via `guest-agent/build.rs`; regenerate both sides in the same commit).

One-shot `omnia linux <cmd>` output arrives CRLF because the agent always
allocates a PTY. A no-PTY mode for non-interactive commands (ssh-like)
is a nice-to-have for M2+.

## Building the Linux guest image (from macOS)

```
cd guest-agent && cargo build --release --target aarch64-unknown-linux-musl
./tools/build-linux-image/build-in-vm.sh
```

`build-in-vm.sh` boots a throwaway aarch64 Ubuntu cloud VM under
qemu+HVF (`brew install qemu`), runs `build-rootfs-inner.sh` inside it
(Arch Linux ARM base tarball + omnia-agent + systemd unit + vsock
module-load, packed with `mkfs.ext4 -d` — no loop devices, no partition
table: LinuxRuntime boots `root=/dev/vda`, the disk IS the filesystem),
and drops `rootfs.img` / `vmlinuz` (uncompressed arm64 Image for
`VZLinuxBootLoader`) / `initramfs.img` (mkinitcpio, autodetect skipped)
into `tools/build-linux-image/.output/`. The original `build.sh` remains
the native-Arch-infra path; it predates the whole-disk layout and needs
the same partition-table correction before anyone uses it.

## Local dev setup (vmd + CLI against a real guest)

1. Install the image artifacts:
   `mkdir -p ~/Library/Application\ Support/Omnia/linux && cp tools/build-linux-image/.output/{rootfs.img,vmlinuz,initramfs.img} ~/Library/Application\ Support/Omnia/linux/`
2. Build and sign vmd (Virtualization.framework needs the entitlement,
   ad-hoc signing is fine locally):
   `cd vmd && swift build && codesign --force --sign - --entitlements vmd.entitlements .build/debug/vmd`
3. Register vmd as a per-user LaunchAgent named `com.omnia.vmd`
   (`NSXPCListener(machServiceName:)` requires launchd): a plist with
   `MachServices = {com.omnia.vmd: true}` and `ProgramArguments` pointing
   at `.build/debug/vmd`, then
   `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.omnia.vmd.plist`.
   After every rebuild: re-sign, then
   `launchctl kickstart -k gui/$UID/com.omnia.vmd`.
4. Build the CLI: `scripts/generate-swift-proto.sh && cd cli && swift build`.
5. Run the acceptance suite: `tests/m1_linux_runtime.sh` (~3 minutes,
   treats the guest as disposable).

If the image or VM configuration changes shape, delete
`~/Library/Application Support/Omnia/linux/snapshot.vzstate` — a stale
snapshot can't restore into a changed config (and `machine-id` /
`mac-address` in that directory must survive for snapshots to work).

## CI

`.github/workflows/ci.yml`: Rust job on ubuntu-latest (fmt, clippy,
tests), Swift jobs on macos-26 (grpc-swift-nio-transport needs a newer
SDK than macos-15's default Xcode, and the proto plugin bottle needs a
recent image). The cli job regenerates proto stubs before building. CI
proves compilation + unit tests only — the M1 acceptance flow needs a
real Apple Silicon host with Virtualization and stays local for now.

## Known gaps / where M2 picks up

- RAIL/Weston presentation (M2) — weston/xwayland aren't in the M1 image
  (build-rootfs-inner.sh installs nothing beyond the ALARM base).
- `WatchEvents` is a never-yielding stub; idle-suspend currently keys off
  "no active control-socket sessions" (VsockControlProxy session count).
- Interactive `omnia shell`/`omnia linux` (raw-mode TTY) is wired but has
  only been exercised non-interactively.
- Root password in the image is a dev placeholder (`omnia`); the
  agent-mediated path is the only supported entry point.
