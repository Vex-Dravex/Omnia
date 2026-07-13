# M2 — Linux Seamless GUI Apps + Wrappers

**Goal:** a real Linux GUI app (e.g. GIMP or a simple GTK app installed via Flatpak) opens as a genuine macOS window via RAIL, and can be exported to a double-clickable `.app`. This proves the entire presentation + export pipeline on the simpler guest before M3 repeats it for Windows.

**Read first:** [docs/04-presentation-rail.md](../docs/04-presentation-rail.md), [docs/05-app-integration.md](../docs/05-app-integration.md). Assumes M1 is complete and merged — build on `vmd`/`LinuxRuntime`/`omnia-agent`, don't reimplement.

## Scope

In scope:
- Add Weston (headless) + `weston-backend-rdp` to the Linux base image (`tools/build-linux-image/`), auto-started per [docs/02](../docs/02-linux-runtime.md).
- `OmniaRAILKit` (Swift/ObjC++ package wrapping FreeRDP's C API): connect to a guest's RDP/RAIL endpoint over the vsock-backed local port, receive RAIL window PDUs, render into real `NSWindow`s with Metal-backed content.
- Extend `omnia-agent`'s `ListApps` to enumerate installed Flatpak apps (start with whatever's pre-installed in the test image or manually `flatpak install`d — the marketplace install flow itself is M6).
- Extend `WatchEvents`' `WindowCountChanged` to actually fire based on Weston's RAIL session window count (real implementation, replacing M1's stub).
- Omnia.app (SwiftUI, first GUI code): minimal "Apps" list view driven by `ListApps`, with an Export toggle that generates a wrapper `.app` per [docs/05](../docs/05-app-integration.md).
- The `AppWrapperTemplate` stub binary and wrapper-generation code (icon conversion, `Info.plist`/`omnia-app.json` generation).

Out of scope: Windows anything, marketplace/install flow (use pre-installed test apps), desktop mode (full-desktop RAIL session — that's part of M3's/M4's broader polish, though the underlying `OmniaRAILKit` non-RAIL rendering path can be stubbed/noted, not built), File Provider/Finder drives.

## Tasks

1. Add Weston+RDP backend to the guest image; verify manually (e.g. connect a generic RDP client like Microsoft Remote Desktop to the guest's forwarded port during development) that a full-desktop RDP session works before attempting RAIL specifically.
2. Integrate FreeRDP as a vendored/SwiftPM C target; get a minimal RAIL connection working against Weston with a single test app, rendering to a debug window using whatever FreeRDP's default bitmap path gives you first — correctness before performance.
3. Replace the debug rendering path with the Metal-backed `CAMetalLayer` decode path per [docs/04](../docs/04-presentation-rail.md) — this is the highest-skill task in this milestone; budget real time for it.
4. Implement window lifecycle mapping: RAIL window-create → new `NSWindow`; RAIL move/resize PDUs → `NSWindow` frame updates; `NSWindow` close (user clicks red button) → send corresponding close to the guest app.
5. Implement clipboard passthrough via RDP `CLIPRDR` (bidirectional).
6. Build the `ListApps` UI + export toggle + wrapper generation pipeline per [docs/05](../docs/05-app-integration.md).
7. Wire `WindowCountChanged` events from Weston through `omnia-agent` to `vmd`, replacing M1's fixed-timer idle-suspend with the real signal (still using the fixed 90s countdown from [docs/06](../docs/06-lifecycle-memory.md) — tuning the countdown itself is M4).

## Acceptance criteria

- Exporting a Flatpak app produces a valid `.app` at `~/Applications/Omnia/<Name>.app` that shows in Spotlight search within macOS's normal indexing delay.
- Double-clicking the exported `.app` (guest suspended beforehand) results in the real app's window appearing on the Mac desktop, behaving like a native window: draggable, resizable, closable, appears in Cmd+Tab and Mission Control.
- Cold RAIL frame after an already-`running` guest: under 500ms from wrapper launch to first visible frame (per [docs/04](../docs/04-presentation-rail.md)'s target) — measure and record actual numbers.
- Closing the app's window (only open window) starts the idle-suspend countdown; opening it again cancels/resets appropriately.
- Copy in the guest app, paste on macOS (and vice versa) works via CLIPRDR.
- Un-exporting removes the `.app` and it disappears from Spotlight/Launchpad; the guest app itself remains installed.

## Test strategy

Manual verification is required for this milestone (window responsiveness/smoothness is not meaningfully unit-testable) — but automate what can be: wrapper bundle structure/`Info.plist` correctness (unit test), `WindowCountChanged` event delivery (integration test against the guest agent), CLIPRDR round-trip (scriptable via `osascript`/`pbcopy`/`pbpaste` plus a guest-side clipboard-echo test app). Document manual test steps in `tests/m2_manual_checklist.md` for the smoothness/responsiveness criteria that require a human.
