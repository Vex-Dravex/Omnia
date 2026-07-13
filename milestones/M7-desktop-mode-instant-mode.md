# M7 — Desktop Mode + Instant Mode (Wine)

**Goal:** two independent, additive features that round out the product: (1) an opt-in full-desktop view of either guest OS, and (2) a zero-VM "instant mode" for simple Windows apps via Wine+Rosetta. Neither is required for M1–M6's core experience to work — this milestone is purely additive polish/breadth. Assumes M1–M6 complete.

**Read first:** [docs/04-presentation-rail.md](../docs/04-presentation-rail.md)'s "Full desktop mode" section, [docs/03-windows-runtime.md](../docs/03-windows-runtime.md)'s "Instant mode" section, [docs/08-cli.md](../docs/08-cli.md)'s `omnia desktop` commands.

## Scope

### Part A — Desktop mode
- Extend `OmniaRAILKit` (built in M2) with a non-RAIL RDP session mode (`RemoteApplicationMode=false`) rendering the guest's full virtual display into one resizable/full-screenable `NSWindow`, reusing the same Metal-backed decode path.
- `omnia desktop linux` / `omnia desktop windows` CLI commands (already stubbed in [docs/08](../docs/08-cli.md), implement fully here).
- "Open Desktop" UI entry point in Omnia.app for each configured guest.
- Full-screen support (standard macOS full-screen `NSWindow` behavior) with correct guest display resolution negotiation on entering/exiting full-screen.

### Part B — Instant mode
- Wine+Rosetta runtime integration (based on the Whisky/CrossOver approach — a Wine build with a Rosetta-translated Windows x86_64 target) as a new, VM-free execution path.
- Per-app Wine prefix management: create/isolate a prefix per exported instant-mode app (avoiding shared-prefix DLL/registry conflicts between apps).
- Extend the wrapper format ([docs/05](../docs/05-app-integration.md)) with `mode: "instant"`; wrapper stub binary launches directly into the Wine prefix instead of opening a RAIL session when this mode is set.
- Export picker UI: an "Instant mode" toggle/option per app (only offered where sensible — see fallback note below), alongside the existing VM-backed export flow.
- Fallback guidance: if an app fails to launch or crashes repeatedly under instant mode, surface a clear UI prompt offering to re-export it in standard (VM) mode instead — this is a UX safety net, not an automated compatibility detector (don't build heuristic/ML compatibility prediction — keep this simple and user-driven for v1).

## Tasks

1. Implement the non-RAIL full-desktop RDP session path in `OmniaRAILKit`.
2. Build `omnia desktop <os>` CLI + Omnia.app "Open Desktop" entry points; verify resume-on-demand still applies (desktop mode uses the same `EnsureRunning` flow as any app).
3. Integrate a Wine build with Rosetta translation support as a vendored dependency (document the exact upstream source/version pinned, per the security/provenance bar set in [docs/10](../docs/10-security-distribution.md) for other vendored dependencies like QEMU).
4. Build per-app Wine prefix creation/management logic (host-side, in Omnia.app or a new `InstantModeKit` — no guest/VM involvement at all for this path).
5. Extend the wrapper stub binary to branch on `omnia-app.json`'s `mode` field; implement the instant-mode launch path (run the installer/exe inside its prefix directly, window compositing is native macOS/Wine — no RAIL involved).
6. Build the export picker's instant-mode toggle and the failure-fallback UI prompt.

## Acceptance criteria

- `omnia desktop linux` opens a full-screen-capable window showing the Linux guest's real desktop; window management (open apps within it, navigate) works as if using the guest directly.
- Desktop mode is reachable only via explicit user action (CLI command or UI button) — never opened automatically by any other flow (verify by auditing all `EnsureRunning` call sites introduced elsewhere in the codebase to confirm none of them silently open a desktop-mode session).
- At least 3 real, simple Windows apps (chosen for known-good Wine compatibility — e.g. a lightweight text editor, a simple utility) run correctly in instant mode with no VM process ever starting.
- Instant-mode apps are indistinguishable in Finder/Launchpad/Dock behavior from VM-backed exported apps (same wrapper format, same export/unexport UX).
- A deliberately Wine-incompatible app (chosen for the test) fails gracefully with the fallback-to-VM-mode prompt rather than crashing silently or hanging.

## Test strategy

Desktop mode: manual verification checklist (window/full-screen behavior is not meaningfully unit-testable) plus an automated check that `EnsureRunning` is never called from a code path other than the documented explicit-action entry points (a static grep-based check is acceptable and should be added to CI). Instant mode: integration tests running the chosen known-good test apps end-to-end (launch, verify window appears, verify clean exit) in CI on a Mac runner; the deliberately-incompatible-app fallback path gets its own explicit test.
