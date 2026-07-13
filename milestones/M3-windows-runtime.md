# M3 — Windows Image Pipeline + Runtime

**Goal:** the Windows equivalent of M1+M2 combined: a debloated Windows 11 ARM64 guest, unattended-installed from a user-supplied ISO, running under QEMU/HVF, with RAIL-based seamless app windows and export working. This is the largest, highest-risk milestone — treat it as M1+M2's scope applied to a much harder guest, reusing `OmniaRAILKit`, the state machine, and the export pipeline from earlier milestones rather than rebuilding them.

**Read first:** [docs/03-windows-runtime.md](../docs/03-windows-runtime.md) in full, plus re-read [docs/04-presentation-rail.md](../docs/04-presentation-rail.md) and [docs/05-app-integration.md](../docs/05-app-integration.md) for what's being reused vs. added. Assumes M1+M2 complete.

## Scope

In scope:
- Vendored static build of `qemu-system-aarch64` with HVF support, as part of Omnia's own build toolchain (documented build steps, not assumed present on dev/user machines).
- `WinRuntime` (Swift, `vmd/`): wraps the QEMU process per [docs/03](../docs/03-windows-runtime.md)'s config table, participates in the same `06-lifecycle-memory.md` state machine abstraction M1 built (refactor the state machine to be guest-type-generic if M1 hardcoded Linux assumptions — flag and fix that coupling here rather than duplicating the state machine).
- `tools/windows-image/`: `autounattend.template.xml`, the first-boot PowerShell debloat/provisioning script, the documented UWP-app denylist (as a separate, easily updatable data file, not hardcoded in the script).
- `omnia-agent` Windows build (Rust, cross-compiled or built via `cargo` on a Windows/CI runner for `aarch64-pc-windows-msvc`), packaged as an MSI, installed by the provisioning script, running as a Windows service.
- QEMU snapshot save/restore (benchmark internal qcow2 snapshot vs. migrate-to-file per [docs/03](../docs/03-windows-runtime.md); pick one, document the choice and measured numbers).
- Windows RDP/RAIL enablement as part of the provisioning script (no new client code — reuses `OmniaRAILKit` from M2 unchanged, proving the "one client for both guests" design in [docs/01](../docs/01-architecture.md)/[docs/04](../docs/04-presentation-rail.md)).
- Wire Windows into the CLI's `omnia shell` picker, `omnia win`, export picker, and `vmd`'s `EnsureRunning` — extending, not duplicating, M1/M2's implementations.

Out of scope: instant mode/Wine (M7), marketplace (M6), Finder drive integration (M5).

## Tasks

1. Get the vendored QEMU/HVF build working standalone (outside Omnia) booting a Windows 11 ARM64 ISO manually — validate the base virtualization path before automating anything.
2. Write and iterate on `autounattend.xml` until a fully hands-off install completes from ISO boot to a logged-in desktop with no user interaction.
3. Write the first-boot provisioning PowerShell script; test the UWP-removal denylist doesn't break the OS (some packages are load-bearing — verify a clean boot and functioning Start Menu/Settings after removal).
4. Build and integrate `virtio-win` drivers (network, balloon, vsock) into the provisioning script.
5. Build the Windows `omnia-agent` (MSI), auto-installed during provisioning, running as a service with an auto-logon account (matching Linux's headless-autologin approach).
6. Enable RDP/RAIL (`fDenyTSConnections=0` + related registry/group-policy settings) as part of provisioning.
7. Snapshot the fully-provisioned state as the guest's clean base image (equivalent of the Linux base image, but produced by running the pipeline once rather than a static download — document whether the resulting qcow2 is itself distributed/cached or re-run per install, and why).
8. Implement `WinRuntime`'s suspend/resume using the chosen QEMU snapshot mechanism; benchmark against [docs/03](../docs/03-windows-runtime.md)'s targets.
9. Point `OmniaRAILKit` at the Windows guest's RDP/RAIL endpoint for a real Windows app (e.g. Notepad) — confirm windowing, clipboard, and export work identically to the Linux path from the user's perspective.

## Acceptance criteria

- A fresh Windows 11 ARM64 ISO, run through the unattended pipeline with zero user interaction, produces a guest with: no Xbox/Solitaire/Bing/consumer-feature apps (verify against the documented denylist), a working Start Menu, RDP/RAIL enabled, `omnia-agent` running and responding to `Hello`.
- `omnia win systeminfo` works from a cold/first-ever state through the full pipeline, and from `suspended` afterward.
- Suspend→resume latency is measured and documented (actual numbers, not assumed equal to Linux's target) in this milestone's PR/commit description.
- An exported Windows app (e.g. Notepad, then a real downloaded app like Notepad++) opens as a native-feeling macOS window, indistinguishable in manual testing from the M2 Linux flow's quality bar.
- `omnia status` correctly reports Windows guest state alongside Linux guest state (both trackable independently, per the state-machine-is-per-guest design in [docs/06](../docs/06-lifecycle-memory.md)).

## Test strategy

Given the heavy reliance on real Windows install behavior, this milestone leans more manual than M1/M2. Automate: the state machine integration (reusing M1's test harness pattern), `omnia-agent` proto conformance (same test suite structure as the Linux agent, run against the Windows build via CI on a Windows/ARM runner if available, otherwise documented as a manual pre-release gate). Manually verify and document: full unattended-install-from-ISO run, debloat correctness, RAIL window quality.
