# 02 — Linux Runtime

Owns the Linux guest: image, VM configuration, snapshot/resume, dynamic memory, and the vsock control channel. Implemented by `LinuxRuntime` (Swift, links `Virtualization.framework`), spawned by `vmd` as its own process (`vzlinux`).

## Guest image

- **Base:** minimal Arch Linux ARM rootfs (rolling release keeps kernel/driver support current for virtio devices; Alpine is the fallback if musl-related app compatibility issues arise in testing).
- **Build pipeline:** `tools/build-linux-image/` — a script (documented fully in M1) that:
  1. Bootstraps the rootfs with `pacstrap`-equivalent tooling in a build container.
  2. Installs: `flatpak`, `weston` + `weston-backend-rdp` (headless RDP/RAIL compositor — see [04](04-presentation-rail.md)), `openssh` (for `omnia linux` shell fallback), `virtiofsd` client utilities, kernel modules for `virtio_balloon`, `virtio_console`, `vsock`.
  3. Installs `omnia-agent` (cross-compiled Rust binary, see below).
  4. Configures `omnia-agent` and `weston` as systemd services, auto-login into a Weston session (headless — no framebuffer console needed).
  5. Produces a compressed disk image (`omnia-linux-base.img.zst`) published as a GitHub Release asset; Omnia.app downloads it on first-run Linux setup (no build-from-source required for end users).
- **Rosetta for Linux:** VZLinuxRosettaDirectoryShare mounted into the guest and registered per Apple's Rosetta-on-Linux documentation, so x86-64 Linux binaries (common in proprietary Flatpaks) run under translation without the user doing anything.

## VM configuration (VZVirtualMachineConfiguration)

| Setting | Value | Notes |
|---|---|---|
| CPU count | `min(4, physical performance cores)` at boot, adjustable live via `VZVirtualMachineConfiguration` hot-CPU where supported | Not the focus of dynamic scaling — memory is (see [06](06-lifecycle-memory.md)) |
| Memory | Ceiling set high (e.g. 75% of host RAM), actual usage governed by balloon — see [06](06-lifecycle-memory.md) | |
| Boot loader | `VZLinuxBootLoader` pointing at the image's kernel/initrd, or `VZEFIBootLoader` if the image ships GRUB — decide in M1 based on which gives faster cold boot | |
| Storage | `VZVirtioBlockDeviceConfiguration` on a copy-on-write disk image (base image + per-install overlay, so re-provisioning is just discarding the overlay) | |
| Network | `VZVirtioNetworkDeviceConfiguration`, NAT mode (`VZNATNetworkDeviceAttachment`) — guest can reach the internet (Flatpak installs) but is not reachable from the LAN | |
| Shared folders | `VZVirtioFileSystemDeviceConfiguration` (virtio-fs) for the "Shared with Mac" folder — separate from the block-device drive-mount path in [07](07-filesystem.md) | |
| Console | `VZVirtioConsoleDeviceConfiguration` — used for boot diagnostics/logs only | |
| Balloon | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` | Driven per [06](06-lifecycle-memory.md) |
| Entropy | `VZVirtioEntropyDeviceConfiguration` | |
| vsock | `VZVirtioSocketDeviceConfiguration` | Carries the `agent.proto` control channel — see [protocols/agent.proto](protocols/agent.proto) |
| GPU | `VZVirtioGraphicsDeviceConfiguration` in headless/offscreen mode — Weston composites to a virtual output consumed only by its RDP backend, no VZVirtualMachineView is shown to the user by default | Desktop mode ([04](04-presentation-rail.md)) attaches a `VZVirtualMachineView` on demand |

## Snapshot / resume

Apple's `VZVirtualMachine.saveMachineStateTo(url:)` / `restoreMachineStateFrom(url:)` (available on Apple Silicon) serialize full VM state (CPU + memory + device state) to disk. Flow:

- **Suspend:** `vmd` calls `saveMachineStateTo` on the idle timer firing (per [06](06-lifecycle-memory.md)), then stops the VM and exits the `vzlinux` process. Typical save time scales with resident guest memory — expect roughly 1–3s for a lightly loaded guest thanks to the balloon keeping resident memory small (see [06](06-lifecycle-memory.md)); this must be measured and documented as part of M1's acceptance criteria.
- **Resume:** `vmd` spawns a fresh `vzlinux` process, which calls `restoreMachineStateFrom` instead of a cold `start()`. Guest processes (including `omnia-agent` and Weston) resume exactly where they left off — no re-login, no re-launch.
- **Cold boot** only happens once, on first setup, and after the base image is updated (overlay reset).

## omnia-agent (Linux build)

Rust binary, statically linked (musl target) for portability across the base image. Responsibilities (full contract in [protocols/agent.proto](protocols/agent.proto)):
- Enumerate installed Flatpak apps (`flatpak list --app --columns=...`) with icon extraction, for the export picker ([05](05-app-integration.md)) and marketplace ([09](09-marketplace.md)).
- Launch/terminate apps on request from the host.
- Watch Weston's app-window lifecycle (via its RDP-RAIL backend's session events) and report "last app window closed" to `vmd` — the primary auto-suspend trigger.
- Report memory pressure hints to inform balloon target adjustments (see [06](06-lifecycle-memory.md)).
- Handle `omnia linux <cmd>` shell requests by spawning a PTY and streaming it over vsock ([08](08-cli.md)).
- Mount/unmount block devices passed through for the Finder drive-integration feature ([07](07-filesystem.md)).

## Explicitly not in scope for the Linux runtime doc

- How individual app windows get composited into macOS windows — that's [04-presentation-rail.md](04-presentation-rail.md).
- How exported apps become `.app` bundles — that's [05-app-integration.md](05-app-integration.md).
