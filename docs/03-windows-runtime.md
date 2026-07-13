# 03 — Windows Runtime

Owns the Windows guest. Unlike Linux, Apple's `Virtualization.framework` does not support Windows guests on Apple Silicon, so the Windows runtime is a supervised **QEMU** process using Apple's **Hypervisor.framework (HVF)** accelerator — the same approach used by UTM. This is the highest-risk, highest-effort subsystem; budget accordingly (see M3).

## Licensing / distribution stance

Omnia does **not** ship, download, or embed any Windows installation media or product key. The first-run wizard requires the user to supply:
- A Windows 11 **ARM64** ISO (from Microsoft's own distribution — the wizard links to the official download page, does not proxy or bundle it), and
- Their own license (or use Microsoft's evaluation/free-trial terms — Omnia doesn't validate or care).

This keeps Omnia's distribution clean of Microsoft IP and licensing risk. Documented clearly in onboarding UI and in [10-security-distribution.md](10-security-distribution.md).

## VM configuration (QEMU invocation, conceptually)

`omnia-qemu` is a thin Swift/C process that shells out to a vendored, statically-built `qemu-system-aarch64` (built as part of the M3 toolchain, not fetched from Homebrew at runtime, so Omnia doesn't depend on the user's environment). Key flags/config (exact invocation finalized in M3):

| Aspect | Choice | Notes |
|---|---|---|
| Accelerator | `-accel hvf` | Apple Hypervisor.framework |
| Machine | `virt` (aarch64) with UEFI firmware (`edk2-aarch64`) | |
| CPU | `-cpu host` | Native ARM64 execution — no CPU emulation; only the guest's own x86 app emulation (built into Win11 ARM) is involved for x86/x64 apps |
| Disk | `virtio-blk` on qcow2, base+overlay layout mirroring the Linux runtime for fast re-provisioning | |
| Network | `virtio-net-pci`, usermode/NAT (`-netdev user`) — matches the Linux runtime's no-LAN-exposure policy | |
| Graphics | `virtio-gpu`, headless (`-display none` + Windows' own RDP/RAIL server for output, not QEMU's VNC/SPICE) | Desktop mode attaches a local display surface on demand, see [04](04-presentation-rail.md) |
| Control channel | `vhost-vsock-pci` (QEMU's vsock device) | Carries `agent.proto`, same contract as the Linux guest |
| Balloon | `virtio-balloon-pci` with `free-page-reporting=on` | Driven per [06](06-lifecycle-memory.md) |

## Debloated unattended install pipeline

This is the mechanism that satisfies "no bloatware auto-installs" and "no manual Windows setup wizard." Given the user's ISO:

1. **Generate `autounattend.xml`** from a template (`tools/windows-image/autounattend.template.xml`) that:
   - Skips OOBE network/Microsoft-account requirements (local account only, unless the user opts into MSA in settings).
   - Sets `oobe/HideOEMRegistrationScreen`, disables Cortana/consumer-features/telemetry via unattend `SkipMachineOOBE` + registry `FirstLogonCommands`.
   - Pre-accepts EULA, sets locale/timezone from host.
2. **First-boot provisioning script** (PowerShell, run via `FirstLogonCommands` in the unattend answer file):
   - Removes default bundled UWP apps (`Get-AppxPackage | Remove-AppxPackage` for a documented denylist: Xbox, Solitaire, Office hub, Skype, Bing apps, etc. — full list in M3's spec, kept updatable independent of code since Microsoft's bundle changes).
   - Disables Windows Consumer Features, tips/suggestions, telemetry to the minimum level the SKU allows.
   - Installs `virtio-win` guest drivers (network, balloon, vsock) and `omnia-agent` (built as a native Windows service, MSI-packaged).
   - Enables Remote Desktop + RemoteApp/RAIL support (`fDenyTSConnections=0`, RAIL is inherent to Windows' RDP server, no separate install).
   - Disables the Windows lock screen/screensaver (guest never needs a login screen after first boot — `omnia-agent` and RDP operate under an auto-logon account created during setup, matching how the Linux guest auto-logs into Weston).
   - Reboots once, then the image is snapshotted as the guest's "clean" base state (see below).
3. **Unattended install is driven by `omnia-qemu`**, not the user clicking through Windows Setup — the wizard shows progress (elapsed time, current stage read from `omnia-agent` heartbeats once it's installed, VM boot log before that).

## Snapshot / resume

QEMU doesn't have Virtualization.framework's one-call save/restore, so the Windows runtime uses QEMU's own **live migration to file** facility (`migrate "exec:cat > snapshot.img"` equivalent, or `savevm`/`loadvm` against an internal snapshot inside the qcow2, decided in M3 based on measured resume latency — internal qcow2 snapshots avoid a second large file but may be slower to load than a flat memory dump; this must be benchmarked, not assumed).

- **Suspend:** guest is paused, full state snapshotted to disk, `omnia-qemu` process exits. Target: comparable resume-side latency to the Linux runtime (~1–3s for a lightly loaded guest); Windows' larger baseline memory footprint makes this the harder target to hit and it must be measured, not assumed — document actual numbers in M3's acceptance criteria rather than repeating the Linux target as a promise.
- **Resume:** fresh `omnia-qemu` process loads the snapshot and continues execution.
- **Cold boot** happens once during the unattended-install pipeline above, and after any user-triggered "reset Windows" (discard overlay, re-run pipeline).

## Instant mode (deferred to M7)

For users who don't want a Windows VM at all, or want zero-latency launch for simple apps, `instant mode` runs the app directly via a per-app **Wine (via a Rosetta 2 x86_64 Windows-on-Wine build, e.g. based on the Whisky/CrossOver approach) prefix** on macOS — no VM, no `omnia-qemu`. This is opt-in per exported app (toggle in the export picker, [05](05-app-integration.md)) and is only offered for apps that don't require kernel drivers, .NET features Wine doesn't support well, or anti-cheat. M7 spec covers prefix management, DXVK/Rosetta interaction, and the compatibility-detection heuristic (or simply: user tries it, falls back to VM mode if it doesn't work, one click).

## Explicitly not in scope for this doc

- RAIL/window compositing — [04-presentation-rail.md](04-presentation-rail.md).
- Balloon target-setting policy and the auto-suspend timer — [06-lifecycle-memory.md](06-lifecycle-memory.md).
