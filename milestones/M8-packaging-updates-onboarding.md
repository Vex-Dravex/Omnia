# M8 — Packaging, Updates, Onboarding

**Goal:** turn the working system from M1–M7 into something a real user can install and set up without reading any of these docs. This is the "ship it" milestone: signing/notarization, the first-run wizard, auto-updates, and a coherent Settings surface pulling together every configurable knob introduced along the way (idle-suspend duration from M4, memory ceiling override from M4/M6, etc.).

**Read first:** [docs/10-security-distribution.md](../docs/10-security-distribution.md) in full. Assumes M1–M7 complete — this milestone touches every prior subsystem's user-facing edges but adds no new runtime capability.

## Scope

In scope:
- Code signing (Developer ID) and notarization pipeline for `Omnia.app`, `com.omnia.vmd`, `OmniaFileProvider.appex`, the privileged helper, and the app-wrapper template.
- Sparkle integration for `Omnia.app` auto-updates, plus the separate "update Linux base image" flow noted in [docs/10](../docs/10-security-distribution.md) (distinct from app updates since it resets the guest overlay).
- First-run onboarding wizard: guest setup choice (Linux only / Windows only / both), Linux path (download base image, zero-config), Windows path (point at user's ISO, run the unattended pipeline from M3 with visible progress).
- Consolidated Settings UI: idle-suspend duration (M4), memory ceiling advanced override (M4, optional/hidden by default per [docs/06](../docs/06-lifecycle-memory.md)'s "no slider by default" principle — this is an advanced/power-user escape hatch, not the primary control), shared-folder location (M5), marketplace catalog refresh (M6).
- `omnia` CLI installer step (placing the binary in `/opt/homebrew/bin` or `/usr/local/bin` as determined in M1, now actually wired into the app's first-run/install flow rather than a manual dev step).
- Crash reporting/diagnostics bundle generation (for user bug reports) — lightweight, no telemetry collection by default per [docs/10](../docs/10-security-distribution.md).

Out of scope: Mac App Store distribution (explicitly ruled out in [docs/10](../docs/10-security-distribution.md) — Developer ID direct distribution only), any new product feature.

## Tasks

1. Set up Developer ID signing + `notarytool` pipeline (CI-integrated, documented in `docs/10` if not already sufficiently detailed — extend that doc if implementation reveals gaps).
2. Integrate Sparkle for `Omnia.app`; build the appcast generation as part of the release process.
3. Build the base-image-update flow: check `omnia-linux-base.img.zst`'s published version against the installed one, prompt the user, perform the update as a distinct, clearly-labeled action (not silent, since it resets the overlay).
4. Build the onboarding wizard UI, wiring together M1's Linux setup and M3's Windows unattended-install pipeline behind a guided flow with real progress feedback (not just a spinner — surface the actual stage, per [docs/03](../docs/03-windows-runtime.md)'s note about reading `omnia-agent` heartbeats for progress once it's installed).
5. Build the consolidated Settings UI, pulling in each prior milestone's config knob.
6. Wire CLI binary installation into the app's setup flow.
7. Build a "Diagnostics" action (Settings or Help menu) that bundles relevant logs (vmd, guest agent connection logs, recent state transitions) into a shareable file for bug reports — no automatic/background collection.

## Acceptance criteria

- A notarized, signed build installs and runs on a clean Mac with Gatekeeper enabled, no warnings beyond the standard first-launch "downloaded from the internet" prompt.
- First-run wizard takes a user with zero prior context from "just installed Omnia" to "has at least the Linux guest set up and one app exported" with no need to consult documentation or a terminal.
- Windows setup via the wizard correctly surfaces the unattended-install pipeline's progress and completes to a working, debloated, exported-app-ready guest.
- Sparkle update check works (test against a staged appcast pointing at a newer dummy version).
- Base-image update is a distinct, explicit action from app updates and clearly communicates the overlay-reset consequence before proceeding.
- Settings UI exposes every knob introduced in M1–M7 that was designed to be user-configurable, and none that weren't (audit against each doc's "no user-facing X" statements — e.g. confirm there is still no RAM-size input in the default Settings view).

## Test strategy

Signing/notarization: verified via `spctl --assess` and a real Gatekeeper check on a clean test machine/VM, not just CI logs. Onboarding wizard: scripted UI test where feasible (XCTest UI testing) covering the happy path for both guest types, plus a manual first-run checklist for the parts that need a truly clean machine (base image download, ISO-driven Windows install) to validate realistically. Settings: unit tests for each setting's persistence/round-trip; the "audit against no user-facing X" check should be a documented manual review step in this milestone's PR description, not skipped.
