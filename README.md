# Omnia

Run Windows and Linux apps natively alongside macOS — without the boot waits, the bloat, or the background resource drain.

Omnia is a macOS app (Apple Silicon, macOS 14+) that gives you Parallels-Desktop-class virtualization — seamless per-app windows, native file access, near-native performance — while fixing the parts of that experience people complain about most:

- **No standing VM.** Windows/Linux resume from a memory snapshot in ~1–3 seconds when you open an app, and suspend to disk (freeing all host RAM/CPU) shortly after you close it. No boot screens, no "shutting down" dialogs, nothing idling in the background.
- **No RAM slider.** Memory is reclaimed dynamically from the guest while it runs (virtio-balloon + free-page reporting). You never assign a fixed amount.
- **No bloatware.** Windows is installed unattended from your own ISO with consumer apps, telemetry, and OEM junk stripped before first boot.
- **You choose what shows up.** Nothing is exported to Finder/Launchpad/Spotlight until you pick it. Each exported app is a real, deletable `.app` bundle.
- **Native file access.** Plug in an ext4/btrfs drive and it mounts in Finder like any other volume — real Linux drivers do the I/O, not a compatibility shim.
- **A real CLI.** `omnia win`, `omnia linux`, `omnia shell` — pick an OS, run a command, done.
- **A marketplace**, not a package manager tutorial. Install a Windows or Linux app and it just appears as a Mac app.
- **Desktop mode is optional.** Every OS is available as a full desktop session if you want it — full-screen, navigable — but it's never required to run an app.

## Status

Architecture and implementation blueprint — see [`docs/`](docs/) and [`milestones/`](milestones/). No product code yet.

## Documentation

Start with [`docs/00-overview.md`](docs/00-overview.md) for goals, non-goals, and how every feature in this README maps to a subsystem and a milestone.

| Doc | Covers |
|---|---|
| [00-overview.md](docs/00-overview.md) | Goals, non-goals, glossary, requirement traceability |
| [01-architecture.md](docs/01-architecture.md) | Components, processes, data flow |
| [02-linux-runtime.md](docs/02-linux-runtime.md) | Virtualization.framework Linux VM, rootfs, snapshots |
| [03-windows-runtime.md](docs/03-windows-runtime.md) | QEMU/HVF Windows VM, debloated unattended install |
| [04-presentation-rail.md](docs/04-presentation-rail.md) | Seamless per-app windows (RDP RemoteApp) |
| [05-app-integration.md](docs/05-app-integration.md) | `.app` wrappers, icons, export/unexport |
| [06-lifecycle-memory.md](docs/06-lifecycle-memory.md) | Resume-on-demand, auto-suspend, dynamic memory |
| [07-filesystem.md](docs/07-filesystem.md) | Finder integration for guest drives and shares |
| [08-cli.md](docs/08-cli.md) | `omnia` command-line tool |
| [09-marketplace.md](docs/09-marketplace.md) | App catalog and install flow |
| [10-security-distribution.md](docs/10-security-distribution.md) | Entitlements, signing, updates |
| [protocols/agent.proto](docs/protocols/agent.proto) | Host↔guest control protocol |

Milestones (`milestones/M1`–`M8`) break the above into implementable, independently-buildable units with explicit acceptance criteria.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14 (Sonoma) or later
- Your own Windows 11 ARM64 ISO (Omnia does not distribute Windows)

## License

See [LICENSE](LICENSE).
