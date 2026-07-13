# 01 — Architecture

## Component overview

```
┌───────────────────────────────────────────────────────────────────────┐
│ macOS host                                                             │
│                                                                         │
│  ┌────────────────┐   XPC    ┌───────────────────┐                    │
│  │ Omnia.app        │◄───────►│ com.omnia.vmd       │  (LaunchAgent,   │
│  │ (SwiftUI,        │         │ (VM supervisor       │   privileged    │
│  │  menu bar +      │         │  daemon)             │   ops split via │
│  │  windows)        │         │                      │   helper tool)  │
│  └───────┬──────────┘         └──────┬───────┬───────┘                │
│          │                            │       │                        │
│          │ launches per exported app  │       │                        │
│          ▼                            ▼       ▼                        │
│  ┌────────────────┐          ┌─────────────┐ ┌─────────────┐          │
│  │ Omnia app       │          │ LinuxRuntime │ │ WinRuntime   │          │
│  │ wrapper (.app)  │          │ (VZVirtual-  │ │ (QEMU+HVF    │          │
│  │ → RAIL client   │◄─RDP/RAIL┤  Machine     │ │  process,    │          │
│  │  window         │          │  process)    │ │  RDP server  │          │
│  └────────────────┘          └──────┬──────┘ └──────┬───────┘          │
│                                       │ vsock          │ vsock          │
│  ┌────────────────┐                  │                │                │
│  │ File Provider   │◄─────────────────┘                │                │
│  │ extension       │◄──────────────────────────────────┘                │
│  └────────────────┘                                                     │
│                                                                         │
│  ┌────────────────┐                                                     │
│  │ omnia (CLI)     │──── talks to vmd over XPC / local socket ──────────┘
│  └────────────────┘                                                     │
└───────────────────────────────────────────────────────────────────────┘
              │ vsock (control: agent.proto)         │ vsock
              ▼                                       ▼
   ┌────────────────────┐                  ┌────────────────────┐
   │ Linux guest          │                  │ Windows 11 ARM64    │
   │ - omnia-agent (Rust)│                  │ - omnia-agent (Rust,│
   │ - Weston (headless)  │                  │   Windows service)  │
   │   + RDP/RAIL backend │                  │ - native RDP server │
   │ - Flatpak apps        │                  │   (RAIL built in)   │
   └────────────────────┘                  └────────────────────┘
```

## Processes

| Process | Owner | Lifetime | Responsibility |
|---|---|---|---|
| **Omnia.app** | User session | App lifetime | Menu bar UI, onboarding wizard, settings, app export picker, marketplace UI |
| **com.omnia.vmd** | LaunchAgent (user), spawns a root helper for disk-claiming ops only | Runs continuously (idle when no guest is active) but is *not* the guest — negligible footprint | Owns runtime state machines (see [06](06-lifecycle-memory.md)), starts/stops/suspends/resumes VM processes, exposes control API to the app, CLI, and File Provider extension |
| **LinuxRuntime (`vzlinux`)** | Spawned by vmd | Only while resumed/active | Wraps a `VZVirtualMachine` in its own process (crash isolation), exposes vsock ports |
| **WinRuntime (`omnia-qemu`)** | Spawned by vmd | Only while resumed/active | Wraps the QEMU process (HVF accelerator), exposes vsock-equivalent channel (QEMU virtio-vsock device) |
| **App wrapper (`.app`)** | User launches (Finder/Dock/Spotlight) | Per app-session | Thin Swift binary embedding the FreeRDP-based RAIL client (see [04](04-presentation-rail.md)); on launch, asks vmd to ensure the owning guest is resumed, then opens a RAIL session for its one app |
| **File Provider extension** | macOS, on-demand | While Finder needs it | Presents guest-mounted volumes and shared folders in Finder (see [07](07-filesystem.md)) |
| **omnia (CLI)** | User's terminal | Per invocation | Talks to vmd for shells, app management, status (see [08](08-cli.md)) |
| **omnia-agent** | Inside each guest | Guest lifetime | Rust daemon: app enumeration, launch/kill, window-close→idle signaling, clipboard/file bridge (see [protocols/agent.proto](protocols/agent.proto)) |

**Why a separate `vmd` daemon instead of doing everything in Omnia.app:** guest lifecycle must continue to work (e.g., auto-suspend after the last window closes) even if the user quits the menu bar app, and privileged operations (claiming a raw disk via DiskArbitration, installing the File Provider extension) need a stable, narrowly-scoped process to authorize against — not the whole GUI app.

## Data flow: launching an exported app

1. User double-clicks `Notepad++.app` in `~/Applications/Omnia/` (or Spotlight/Dock).
2. The wrapper's `main()` calls `vmd` over XPC: `EnsureRunning(guest: .windows)`.
3. `vmd` checks guest state (see [06](06-lifecycle-memory.md)): if `suspended`, it resumes `omnia-qemu` from the snapshot (~1–3s); if `running`, returns immediately; if `stopped` (first-ever launch), performs a cold boot.
4. `vmd` returns the guest's RDP endpoint (a local Unix-domain-socket-backed port, not exposed on any network interface).
5. The wrapper opens a RAIL session scoped to that one app's `RemoteApplicationProgram`/`RemoteApplicationName` (Windows) or Weston app id (Linux), per [04](04-presentation-rail.md).
6. The guest's RDP/RAIL server spawns or attaches to the app process and streams just its window(s).
7. `omnia-agent` in the guest notifies `vmd` (over the vsock control channel, not RDP) when the app process exits and when it was the last tracked foreground app — this drives auto-suspend ([06](06-lifecycle-memory.md)).
8. When the wrapper's window closes, the RAIL session ends; `vmd` starts (or resets) the idle-suspend timer.

## Why these technology choices

- **Virtualization.framework for Linux, QEMU+HVF for Windows** — Virtualization.framework only supports Linux and macOS guests on Apple Silicon; it does not support Windows. QEMU with Apple's Hypervisor.framework accelerator is the established, open path for Windows-on-Apple-Silicon (this is what UTM uses) and adds Rosetta-equivalent x86 emulation via Windows 11's own built-in emulation layer for the guest's x86/x64 apps.
- **RDP RemoteApp (RAIL) for seamless windows, not a custom protocol** — Windows ships a production-grade RDP/RAIL server for free; Linux gets the same behavior via a headless Weston compositor using its existing RDP-RAIL backend (the same mechanism WSLg uses). One client implementation (embedded FreeRDP) handles both guest types. Building a custom low-latency remoting protocol is a multi-year effort RDP/RAIL already solves.
- **vsock for control, not TCP** — vsock is host↔guest only, requires no guest network configuration, and isn't exposed to LAN/Internet, which matters since Omnia's guests should not be reachable from the network by default.
- **Separate runtime processes per guest, supervised by vmd** — isolates a VM crash from the UI and from the other guest; lets `vmd` restart a runtime without killing Omnia.app.

## What's explicitly deferred to instant mode (M7, later)

Some Windows apps (simple, .NET-free, no drivers) can run via a Wine+Rosetta prefix with zero VM overhead — this is the "instant mode" path noted in [03](03-windows-runtime.md) and scheduled in M7. It's additive: the VM path is the default and what makes M1–M6 compatible with "any Windows app," instant mode is a later fast-path option per app.
