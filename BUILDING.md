# Building Omnia — current status

This documents what has and hasn't actually been compiled/run, as of the M1
handoff. Read this before assuming any given file works.

## Environment this was written in

Linux container, no Xcode, no macOS SDK, no Swift toolchain at all. Rust/Cargo
was available. This shapes everything below: **the Rust guest-agent is real,
built, and tested. The Swift code (vmd, cli) is a careful first draft that
has never been compiled.**

## `guest-agent/` — Rust, verified (Linux x86_64 and macOS arm64)

```
cd guest-agent
cargo build          # clean
cargo test            # 10/10 passing, including a real client/server
                       # round trip over a Unix socket (see
                       # tests/integration_unix_socket.rs) that spawns an
                       # actual PTY process and propagates its real exit code
cargo clippy --all-targets -- -D warnings   # clean
cargo fmt -- --check                         # clean
```

Re-verified on macOS 15 / Apple Silicon (rustc 1.97.1): all of the above
pass there too. One platform fix was needed: `src/mount.rs` used the
Linux-shaped `nix::mount` API, which doesn't exist on macOS — the real
mount/umount impls are now gated `#[cfg(target_os = "linux")]`, with
non-Linux hosts (dev-mode) returning a clear "only in the Linux guest"
error. No tests needed gating; all 10 pass unmodified on macOS.

What's real: `Hello`, `OpenShell` (interactive + one-shot commands, real PTY,
real exit codes), `MountBlockDevice`/`UnmountBlockDevice` (real `mount(2)`
syscalls via `nix`, unit-tested through an injectable `BlockDeviceOps` trait
so the RPC-handling logic doesn't need root/real block devices in CI),
`WatchEvents` (M1-scope stub — never yields, by design; M2/M4 make it real).
`ListApps`/`LaunchApp`/`TerminateApp`/`InstallApp`/`UninstallApp` return
`Status::unimplemented` — they're out of scope until M2/M6.

Production transport is vsock (`src/main.rs`, gated `#[cfg(target_os =
"linux")]`, using `tokio-vsock`) — this compiles but has not been exercised
against a real VM guest, since this sandbox has no vsock device. Everything
above was tested via the `--unix-socket` dev-mode flag instead. **The first
thing to verify on real guest hardware/VM is that the vsock path behaves the
same way the UDS path was proven to.**

Not yet cross-compiled: the production target is
`aarch64-unknown-linux-musl` (for the guest image); this sandbox only has
the host `x86_64-unknown-linux-gnu` target installed. Add the target and
confirm `cargo build --release --target aarch64-unknown-linux-musl` works
before wiring it into `tools/build-linux-image/build.sh`.

## `vmd/` — Swift, UNVERIFIED

Depends on `Virtualization.framework` and XPC (`NSXPCConnection`,
`NSXPCListener`), both macOS-only and unavailable to compile-check here.

- `Sources/OmniaVMDCore/GuestState.swift` — the lifecycle state machine
  (docs/06-lifecycle-memory.md). Deliberately has zero Apple-only imports.
  This is the one part of `vmd` that could plausibly build with a
  Linux Swift toolchain if you have one handy for a quick sanity check
  before moving to Xcode — worth trying first since it'll surface basic
  syntax mistakes faster than a full Xcode build.
- `Tests/OmniaVMDCoreTests/GuestLifecycleControllerTests.swift` — written
  against that state machine, has never been run. Run `swift test` on a Mac
  as literally the first verification step for this repo's Swift code.
- `Sources/vmd/LinuxRuntime.swift` — `VZVirtualMachine` wrapper. The
  `VZLinuxBootLoader` vs `VZEFIBootLoader` choice is flagged as an open TODO
  matching M1 task #3's note; everything else follows docs/02's config table
  but needs real `swift build` iteration against actual Virtualization.framework
  API signatures, which may have shifted across SDK versions.
- `Sources/vmd/VsockControlProxy.swift` — bridges a guest's vsock control
  channel to a local Unix socket for the CLI to connect to. Explicitly
  flagged in its own header as a first draft: the byte-relay loop's
  shape is right, its behavior under real load/errors is not proven.
- `Sources/vmd/VMDService.swift`, `VMDXPCProtocol.swift`, `main.swift` — the
  XPC service wiring. Ordinary `NSXPCConnection`/`NSXPCListener` usage,
  lower risk than the two files above, but still unbuilt.

## `cli/` — Swift, UNVERIFIED, one file needs real reconciliation

- `Sources/omnia/main.swift`, `VMDClient.swift` — ArgumentParser commands and
  the XPC client talking to vmd. Ordinary Foundation code, lowest risk in
  this package.
- `Sources/omnia/ShellSession.swift` — **the highest-risk file in this whole
  handoff.** It drives `OpenShell` via grpc-swift's async client API,
  written from memory without being able to run `protoc-gen-grpc-swift` and
  check the real generated symbol names/signatures against grpc-swift's
  actual current API. Its own header comment says this explicitly. Do not
  trust it beyond "this is the intended shape" until you've run
  `scripts/generate-swift-proto.sh` and reconciled this file against
  whatever actually gets generated.

## What to do next, in order

1. `cd guest-agent && cargo test` — confirm the baseline still holds on
   whatever machine you're on.
2. On a Mac: `swift build` in `vmd/`, starting with `OmniaVMDCore` (no Apple
   frameworks) before `vmd` itself (Virtualization.framework/XPC). Fix
   compile errors — there will be some.
3. `swift test` in `vmd/` — validate `GuestLifecycleControllerTests` against
   the real Swift Testing/XCTest toolchain.
4. Boot the built Linux image (once `tools/build-linux-image/build.sh` has
   been run on real ARM build infra) under a scratch `VZVirtualMachine` and
   confirm `omnia-agent` answers `Hello` over real vsock — this is the one
   guest-agent behavior this sandbox couldn't prove.
5. `scripts/generate-swift-proto.sh`, then `swift build` in `cli/`, then
   reconcile `ShellSession.swift` against the real generated API.
6. Only then attempt the full milestones/M1-linux-runtime.md acceptance
   criteria end to end.
