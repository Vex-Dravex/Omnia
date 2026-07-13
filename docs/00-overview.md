# 00 — Overview

## Goals

Omnia lets a macOS user run Windows and Linux applications so that they feel like native Mac apps: individual windows on the Mac desktop, in the Dock, in Cmd+Tab, backed by a guest OS the user never has to think about managing. It targets **Apple Silicon Macs only** (M1+, macOS 14 Sonoma or later).

Design priorities, in order:
1. **Feel native.** Window behavior, responsiveness, and file access should not remind the user they're running a VM.
2. **Cost nothing when idle.** A guest that isn't actively serving an app should consume ~0 host RAM/CPU.
3. **Minimize ceremony.** No manual VM power management, no fixed resource sliders, no bundled bloatware.
4. **User controls surface area.** Only explicitly exported guest apps appear anywhere in macOS.
5. **Maximum compatibility** for Windows apps (this is why the Windows engine is VM-first, not translation-first — see [01-architecture.md](01-architecture.md)).

## Non-goals (v1)

- **Intel Mac support.** Apple Silicon only; revisit only if there's demand.
- **Gaming / GPU passthrough / anti-cheat compatibility.** Best-effort via virtio-gpu; not a design target.
- **Hosting or redistributing Windows or copyrighted app binaries.** Omnia orchestrates; the user supplies their own Windows license/ISO. The marketplace indexes and installs from existing open catalogs (Flathub, winget) — it does not mirror binaries.
- **Multi-VM fleets / server use cases.** Omnia is a single-user desktop tool: one Linux guest, one Windows guest, run locally.
- **Windows-hosting-macOS or Linux-hosting-macOS.** One direction only.

## Glossary

| Term | Meaning |
|---|---|
| **Guest** | The Windows or Linux VM running under Omnia |
| **Host** | The macOS machine and its processes |
| **Runtime** | The per-OS subsystem that owns a guest's VM process (Linux runtime, Windows runtime — see [01](01-architecture.md)) |
| **RAIL** | RemoteApp and Desktop Integration — the RDP extension that lets a single guest app's window be composited as a standalone window on the client, rather than showing a full desktop |
| **Coherence** | Parallels' name for seamless per-app windows; Omnia's equivalent is built on RAIL (see [04](04-presentation-rail.md)) |
| **Export** | Making a guest app show up as a `.app` bundle in `~/Applications/Omnia/`, Launchpad, Spotlight (see [05](05-app-integration.md)) |
| **Suspend** | Guest state saved to disk, VM process exited, host resources fully released |
| **Resume** | Guest state restored from a suspend snapshot, guest running again in 1–3s |
| **Agent** | The small daemon inside each guest that Omnia's host talks to over vsock (see [protocols/agent.proto](protocols/agent.proto)) |
| **Instant mode** | (v2/M7) Wine+Rosetta execution of a Windows app with no VM at all |

## Requirement traceability

Every requirement from the product brief maps to a primary doc and milestone:

| Requirement | Doc | Milestone |
|---|---|---|
| Near-native Windows + Linux app performance | [01](01-architecture.md), [02](02-linux-runtime.md), [03](03-windows-runtime.md) | M1, M3 |
| Coherence-style seamless Windows app windows | [04](04-presentation-rail.md) | M3 |
| Open Linux-formatted external drives in Finder | [07](07-filesystem.md) | M5 |
| Only user-chosen apps show in Finder/Launchpad | [05](05-app-integration.md) | M2 |
| No Windows/Linux running in the background | [06](06-lifecycle-memory.md) | M1, M4 |
| No repeated boot/shutdown per app launch | [06](06-lifecycle-memory.md) | M1, M4 |
| Dynamic RAM, no fixed assignment | [06](06-lifecycle-memory.md) | M4 |
| CLI with per-OS terminal selection | [08](08-cli.md) | M1 |
| Marketplace for Windows/Linux apps | [09](09-marketplace.md) | M6 |
| Debloated Windows, no auto-installed junk | [03](03-windows-runtime.md) | M3 |
| Optional full desktop mode, not default | [01](01-architecture.md), [04](04-presentation-rail.md) | M7 |
| Reactive, smooth UX comparable to Parallels | all | all |

## Reading order

New contributor / new implementing session: `00 → 01`, then whichever milestone doc you've been assigned — each milestone doc links back to the specific subsystem docs it needs. You should not need to read docs outside your milestone's citations to implement it.
