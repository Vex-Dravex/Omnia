# 06 — Lifecycle & Dynamic Memory

This doc specifies the state machine that makes Windows/Linux "open and close like an app" — the mechanism behind "no boot/shutdown wait" and "no background VM" — and the dynamic memory policy that removes the RAM slider entirely. Owned by `vmd`; one instance of this state machine per guest (Linux, Windows).

## Guest state machine

```
        first-ever setup
              │
              ▼
        ┌───────────┐
        │  stopped   │◄────────────────────────────┐
        └─────┬─────┘                               │
              │ cold boot (setup wizard              │ user: "Reset guest"
              │  or first EnsureRunning)              │  (discards overlay)
              ▼                                       │
        ┌───────────┐   idle timer expires    ┌──────┴────┐
        │  running   │────────────────────────►│ suspending │
        │            │◄────────────────────────┤            │
        └─────┬─────┘   EnsureRunning during   └──────┬────┘
              │          suspend → cancel timer         │ saveMachineStateTo
   EnsureRunning                                        │ completes, process exits
   while running:                                       ▼
   no-op, return                                  ┌───────────┐
   immediately                                     │ suspended │
                                                    └─────┬─────┘
                                                          │ EnsureRunning
                                                          ▼
                                                    ┌───────────┐
                                                    │ resuming   │──► running
                                                    └───────────┘
```

- **`stopped`**: no snapshot exists yet, or the guest was reset. Only reachable from initial setup or an explicit user "Reset" action — not part of normal day-to-day cycling.
- **`running`**: VM process alive, actively serving at least one RAIL session or a desktop-mode session.
- **`suspending`**: idle timer fired; `vmd` is calling `saveMachineStateTo` (Linux, [02](02-linux-runtime.md)) or the QEMU snapshot equivalent (Windows, [03](03-windows-runtime.md)). If an `EnsureRunning` request arrives during this window, it queues and is served once the in-flight suspend completes and immediately reverses to resume — no dropped requests, but no interrupt-mid-save either (interrupting a state save risks a corrupt snapshot).
- **`suspended`**: VM process has exited. Zero host RAM/CPU attributable to this guest (verify via `vmd` reporting the runtime process's RSS as its own dedicated per-guest state, since a truly exited process has no RSS to report at all — the metric is "no `vzlinux`/`omnia-qemu` process exists").
- **`resuming`**: fresh runtime process spawned, loading the snapshot.

## Idle-suspend trigger

`omnia-agent` in each guest reports to `vmd` (over the vsock control channel) whenever the count of user-visible app windows (RAIL sessions + desktop-mode session) transitions to zero. `vmd` starts a countdown (default **90 seconds**, user-configurable in Settings, not a required decision during onboarding) before moving `running → suspending`. Any new `EnsureRunning` call cancels the countdown.

Rationale for a delay rather than instant suspend: closing one app and immediately opening another (or a save dialog briefly closing the window) shouldn't force a resume cycle. The countdown is the tunable that trades "resource-free sooner" against "avoids resume thrash" — ship a sensible default, expose it, don't over-engineer adaptive logic for v1.

## Dynamic memory (no user-assigned RAM)

**Ceiling, not allocation.** Each `VZVirtualMachineConfiguration`/QEMU invocation is given a generous memory *ceiling* (e.g., `min(16GB, 75% of host physical RAM)` — exact formula finalized in M4, must leave adequate host headroom) but that ceiling is never the guest's actual footprint. Actual usage is governed continuously by:

1. **virtio-balloon** (`VZVirtioTraditionalMemoryBalloonDeviceConfiguration` on Linux, `virtio-balloon-pci` on Windows/QEMU) with **free-page-reporting** enabled where the guest kernel supports it (modern Linux kernels and Windows' virtio-balloon driver both do) — this lets the guest proactively tell the host about freed pages without `vmd` having to poll and guess.
2. **`vmd`'s balloon controller**: a lightweight loop that requests the guest inflate the balloon (reclaiming pages back to the host) when `omnia-agent` reports low guest memory pressure, and deflates it (giving pages back) when the guest reports pressure or is about to launch a new app (a `EnsureRunning`/app-launch-imminent signal can proactively deflate slightly ahead of need, avoiding a stall).
3. **No user-facing RAM setting** anywhere in the UI — this is the explicit fix for the Parallels annoyance. Settings may expose the *ceiling* as an advanced/optional cap for power users worried about worst-case host memory pressure, but the default experience has no slider to touch.

## Suspend-time interaction with memory

Because the balloon keeps resident guest memory low during normal use, `saveMachineStateTo`/QEMU-snapshot calls at suspend time serialize far less data than a "fully loaded" guest would — this is *why* the 1–3s resume target in [02](02-linux-runtime.md)/[03](03-windows-runtime.md) is achievable rather than aspirational. The balloon controller and the suspend path are therefore coupled: M4's acceptance criteria must measure snapshot save time under realistic (ballooned-down) conditions, not a freshly-booted, unballooned VM.

## Acceptance criteria (M4)

- Launching an exported app when its guest is `suspended` results in `running` + first RAIL frame in line with the [04](04-presentation-rail.md) cold-start target, snapshot-resume overhead included.
- 90 seconds (default) after the last tracked app window closes, `vmd`'s guest state is `suspended` and no `vzlinux`/`omnia-qemu` process exists (`ps` verification).
- With a guest idle for 5+ minutes after running a memory-heavy app (e.g., a browser), the balloon controller has reclaimed host memory back down near baseline — measured via host `vm_stat`/Activity Monitor comparison, documented with actual numbers, not asserted.
- No RAM-size input exists anywhere in default-path Settings or onboarding UI.
