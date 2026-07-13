# 08 — CLI

`omnia` is a Swift ArgumentParser-based binary, installed to `/usr/local/bin/omnia` (or `/opt/homebrew/bin` on Apple Silicon's default Homebrew prefix — matched at install time) by Omnia.app on first run. It talks to `vmd` over the same local XPC/socket interface the GUI uses — the CLI has no logic of its own beyond argument parsing and terminal I/O plumbing.

## Commands

| Command | Behavior |
|---|---|
| `omnia shell` | Interactive picker (arrow keys) if both guests exist: "Linux / Windows" → opens a shell in the chosen guest. If only one guest is set up, skips the picker. |
| `omnia linux [cmd...]` | Opens a shell in the Linux guest, or runs `cmd` non-interactively and streams output/exit code, e.g. `omnia linux ls -la ~`. Guest is resumed on demand per [06](06-lifecycle-memory.md) if suspended — CLI shows a one-line "Resuming Linux…" status during the ~1–3s wait. |
| `omnia win [cmd...]` | Same, for the Windows guest. Interactive shell defaults to PowerShell; `omnia win cmd /c ...` works for cmd.exe explicitly. |
| `omnia status` | Prints both guests' current state (`stopped` / `running` / `suspending` / `suspended` / `resuming`), matching the state machine in [06](06-lifecycle-memory.md) — this is also the primary tool for verifying M4's acceptance criteria. |
| `omnia ls-apps [--os linux\|windows]` | Lists installed guest apps (same data source as the export picker, [05](05-app-integration.md)) with export status. |
| `omnia launch <app>` | Launches an exported (or not-yet-exported — launches without creating a wrapper) app by name/fuzzy match, same underlying `EnsureRunning` + RAIL flow as double-clicking its `.app`. |
| `omnia export <app>` / `omnia unexport <app>` | CLI equivalent of the export picker toggle in [05](05-app-integration.md). |
| `omnia desktop linux` / `omnia desktop windows` | Opens full desktop mode for the given guest ([04](04-presentation-rail.md)) — the CLI path to the opt-in desktop feature. |
| `omnia suspend [--os linux\|windows\|all]` | Manually force-suspend, bypassing the idle timer (power-user override). |

## Shell transport

Interactive shells (`omnia shell`, `omnia linux`, `omnia win` with no trailing command) open a PTY-over-vsock session via `omnia-agent`'s shell service (see [protocols/agent.proto](protocols/agent.proto) `OpenShell` RPC): the guest spawns `bash`/`zsh` (Linux) or `pwsh.exe`/`powershell.exe` (Windows), and raw terminal I/O is streamed bidirectionally, with terminal resize events (`SIGWINCH`) forwarded so guest-side line-wrapping/TUI apps behave correctly. This is the same pattern as `ssh`/`docker exec`, deliberately — no novel protocol needed.

## Non-interactive command mode

`omnia linux <cmd>` / `omnia win <cmd>` with arguments runs the command via the same `OpenShell` RPC but without allocating an interactive PTY on the client side beyond what's needed to relay stdout/stderr and propagate the guest process's real exit code back to the host shell (`$?` on the Mac reflects the guest command's exit status) — this makes `omnia linux ...` composable in Mac shell scripts/pipelines.

## Explicitly not in scope for this doc

- The guest-side shell/PTY implementation inside `omnia-agent` — covered by [protocols/agent.proto](protocols/agent.proto) and the per-runtime docs ([02](02-linux-runtime.md), [03](03-windows-runtime.md)).
