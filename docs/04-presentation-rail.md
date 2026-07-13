# 04 — Presentation Layer (Coherence / RAIL)

This is Omnia's answer to Parallels' Coherence mode: a guest app's window(s) render as ordinary macOS windows, indistinguishable in behavior from a native app — resizable, movable, minimizable, participate in Mission Control and Cmd+Tab.

## Mechanism: RDP RemoteApp (RAIL) + embedded FreeRDP

Both guest types expose a standard **RDP server with RemoteApp/RAIL support**:
- **Windows:** native — Windows' built-in RDP server already implements RAIL (`ts_remote_app`). No custom server code needed on the Windows side beyond enabling RDP in the unattended install ([03](03-windows-runtime.md)).
- **Linux:** **Weston** (headless, no physical output) running `weston-backend-rdp`, which implements the same RAIL extension — this is the identical mechanism Microsoft uses to project Linux GUI apps onto the Windows desktop in WSLg. Reusing it means Omnia doesn't invent Linux-side remoting.

The host embeds **FreeRDP** (via its C API, wrapped in a small Swift/ObjC++ interop layer, `OmniaRAILKit`) as the RAIL client. One client codebase talks to both guest types since both speak the same protocol extension.

## Per-app window flow

1. App wrapper process ([05](05-app-integration.md)) starts, asks `vmd` to ensure its guest is resumed ([06](06-lifecycle-memory.md)).
2. Wrapper opens an RDP connection to the guest's local vsock-backed RDP endpoint (not a network port — see [01](01-architecture.md)) with `RemoteApplicationMode=true` and the specific `RemoteApplicationProgram` (Windows exe path or Weston app id) baked into the wrapper at export time ([05](05-app-integration.md)).
3. FreeRDP's RAIL channel receives window-create/move/resize/destroy/Z-order PDUs for that app's window(s) and `OmniaRAILKit` mirrors each into a real `NSWindow`, backed by a Metal-rendered surface for the RDP graphics stream (FreeRDP's software/GDI rendering path is not acceptable for "smooth like Parallels" — a Metal-backed render target is required, decoding the RDP bitmap/AVC444 stream directly to a `CAMetalLayer`).
4. Standard `NSWindow` chrome, traffic-light buttons, and window management are native macOS — only the content area is RDP-driven. Closing the `NSWindow` sends the corresponding close to the guest app.
5. Input (keyboard/mouse/trackpad gestures where mappable) is forwarded through the RDP input channel; clipboard through RDP's `CLIPRDR` channel (bidirectional, works for both guest types automatically since it's part of the base RDP spec, not something Omnia builds).
6. Audio: RDP's `RDPSND`/`AUDIO_OUTPUT` channel piped to Core Audio.

## Multi-window apps

RAIL natively supports an app opening multiple top-level windows (e.g., a Windows app's dialog boxes) — each becomes its own `NSWindow`, grouped under the same Dock icon by sharing the wrapper's bundle identifier and using `NSApplication` window-grouping. This is standard AppKit behavior once the wrapper process owns multiple `NSWindow`s; no custom Dock/window-grouping logic is required beyond correctly setting `CFBundleIdentifier` and activation policy.

## Full desktop mode (opt-in)

Separate from per-app RAIL sessions: `omnia desktop windows` / `omnia desktop linux` (CLI, [08](08-cli.md)) or a "Open Desktop" action in the app opens a **non-RAIL** RDP session (`RemoteApplicationMode=false`), rendering the guest's entire virtual display in one resizable/full-screenable `NSWindow`. This reuses the same `OmniaRAILKit` rendering path (Metal-backed RDP bitmap decode) minus the per-window PDU handling, and reuses the same resume-on-demand flow. It is never launched automatically — only via explicit user action — matching the "opt-in, not default" requirement.

## Performance targets (acceptance criteria for M2/M3)

- Window resize/move latency: perceptually instantaneous (<1 frame at 60fps) on the same Mac's display refresh — validated by manual comparison against a native window drag, not by a numeric spec that can't be reasonably tested from this doc alone.
- Cold RAIL session start (guest already resumed): under 500ms from process launch to first frame.
- No visible tearing/artifacting during video playback inside a guest app — validated via a standard test clip.

## Explicitly not in scope for this doc

- How a wrapper decides *which* `RemoteApplicationProgram` to launch, and how it's built — [05-app-integration.md](05-app-integration.md).
- Guest-side RDP/RAIL server setup — [02](02-linux-runtime.md) and [03](03-windows-runtime.md).
