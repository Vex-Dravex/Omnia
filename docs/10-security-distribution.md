# 10 — Security & Distribution

## Entitlements

| Component | Key entitlement(s) | Why |
|---|---|---|
| `Omnia.app` | `com.apple.security.app-sandbox` (with exceptions below), `com.apple.security.virtualization` | Required to create `VZVirtualMachine` instances at all on Apple Silicon |
| `com.omnia.vmd` (LaunchAgent) | `com.apple.security.virtualization`, `com.apple.developer.system-extension.install` (for the File Provider extension's lifecycle, if managed via vmd rather than the app) | Runs the actual VM processes |
| Root helper (SMJobBless or equivalent modern replacement — verify current Apple-recommended mechanism at implementation time, as SMJobBless is legacy) | Narrowly scoped: DiskArbitration disk-claim only | Claiming a raw disk for passthrough ([07](07-filesystem.md)) requires elevated privilege; nothing else should run as root |
| `OmniaFileProvider.appex` | `com.apple.security.application-groups` (shared with main app), File Provider entitlement | Standard requirement for any File Provider extension |

Principle: **the smallest possible piece runs with elevated privilege.** The root helper does exactly one thing (claim/release a disk) and is invoked via XPC with a hardened, fixed message schema — not a general-purpose privileged shell.

## Network exposure

Every vsock-based channel (agent control, RDP/RAIL, shell) is host↔guest only by construction — vsock has no route to any network interface. QEMU's virtio-vsock device provides the same guarantee for the Windows runtime. **No guest RDP/service port is ever bound to 0.0.0.0 or the LAN interface**; this must be an explicit acceptance check in M2/M3 (verify with `lsof`/`nettop` during testing that nothing guest-related listens beyond loopback/vsock).

## Signing & notarization

- `Omnia.app`, `com.omnia.vmd`, `OmniaFileProvider.appex`, and each generated app wrapper ([05](05-app-integration.md)) must be code-signed. Wrapper generation at export time uses a **Developer ID** signing identity embedded in Omnia.app's own signing setup — ad-hoc signing per-wrapper is acceptable for local-only launch (no Gatekeeper quarantine concern since the file never crosses a network boundary) but should be verified against Gatekeeper's actual behavior for locally-generated bundles during M2, not assumed safe.
- The main app and extensions are notarized via the standard `notarytool` flow for distribution outside the Mac App Store (a VM/hypervisor + File Provider + privileged-helper app is not compatible with App Store sandboxing rules, so **direct/Developer ID distribution**, not the Mac App Store, is the distribution model).

## Updates

Sparkle (the standard third-party macOS auto-update framework) for `Omnia.app` itself. Guest **base images** ([02](02-linux-runtime.md)'s `omnia-linux-base.img.zst`) are versioned and updatable independently — Omnia.app checks the published image manifest and offers "Update Linux base image" as a distinct action from app updates, since re-provisioning a guest is a heavier, user-visible operation (it resets the overlay) that shouldn't happen silently as part of a routine app update.

## Data at rest

- VM disk images/overlays and snapshot files live under `~/Library/Application Support/Omnia/` (or `~/Library/Containers/...` if sandboxing requires it — confirm exact path once sandbox entitlements are finalized in M1). No special encryption beyond relying on FileVault at the host level — consistent with how Parallels/UTM/Docker Desktop handle guest disk storage.
- No telemetry is collected by Omnia itself in v1 (explicitly out of scope; if added later it must be opt-in and disclosed, matching the product's "no unwanted background behavior" ethos).

## Explicitly not in scope for v1

- Code-signing/notarizing third-party marketplace-installed guest apps — those run inside the guest under the guest OS's own trust model (Flatpak sandboxing, Windows SmartScreen), not macOS's.
