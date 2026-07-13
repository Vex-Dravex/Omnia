# M4 — Lifecycle & Dynamic Memory Polish

**Goal:** replace M1/M2/M3's minimal fixed-timer suspend behavior with the full policy from [docs/06-lifecycle-memory.md](../docs/06-lifecycle-memory.md): tuned idle-suspend, and — the centerpiece — the dynamic memory balloon controller that removes any need for a user-assigned RAM value. This milestone is where "reactive and smooth like Parallels, but with no RAM slider" actually gets proven with numbers.

**Read first:** [docs/06-lifecycle-memory.md](../docs/06-lifecycle-memory.md) in full. Assumes M1–M3 complete (both guest runtimes exist and the state machine is generic across them).

## Scope

In scope:
- `vmd`'s balloon controller: the inflate/deflate loop reacting to `MemoryPressure` events (already defined in [agent.proto](../docs/protocols/agent.proto), stubbed/unused until now) from both guest agents.
- Guest-side memory pressure reporting in `omnia-agent` (Linux: read `/proc/meminfo`/`MemAvailable` or use `PSI` if available; Windows: query `GlobalMemoryStatusEx` or performance counters) — implement in both agent codebases.
- Idle-suspend countdown made user-configurable (Settings UI: a single duration control, default 90s, per [docs/06](../docs/06-lifecycle-memory.md) — this is the only user-facing timing knob; do not add a RAM-related setting).
- Proactive balloon deflation ahead of a new app launch (the "about to need memory" signal from `EnsureRunning` firing before the guest is fully resumed, so the guest doesn't stall reclaiming pages under load).
- Measurement/benchmarking harness: scripted scenarios (idle guest, guest running a memory-heavy app, guest transitioning between the two) with recorded host `vm_stat` numbers, checked into `tests/m4_memory_benchmarks/` as both the test and its own documentation of real behavior.

Out of scope: any new user-facing feature — this milestone is entirely about tuning existing mechanisms to meet [docs/06](../docs/06-lifecycle-memory.md)'s acceptance criteria with real measurements.

## Tasks

1. Implement `MemoryPressure` reporting in both `omnia-agent` builds; wire into the existing `WatchEvents` stream (already defined in the proto — this is the first milestone to actually populate it).
2. Implement `vmd`'s balloon controller: on `LEVEL_WARNING`/`LEVEL_CRITICAL`, deflate (give memory back to guest); on sustained `LEVEL_NORMAL` with low guest-reported usage, inflate (reclaim to host). Avoid oscillation — add hysteresis (e.g. don't reverse direction within N seconds of the last adjustment); document the chosen constants and why.
3. Add the proactive pre-launch deflation hook to `EnsureRunning`.
4. Build the idle-suspend duration Settings control (SwiftUI, simple), reading/writing to `vmd`'s config store.
5. Write the benchmark harness: script scenarios, capture before/after host memory stats, produce a readable report (`tests/m4_memory_benchmarks/report.md` template, filled in with real run output, committed as evidence — not just a passing/failing assertion).
6. Re-benchmark suspend/resume latency (both guests) under the now-ballooned-down conditions and update the numbers recorded in M1/M3 if they've changed materially.

## Acceptance criteria

All of [docs/06-lifecycle-memory.md](../docs/06-lifecycle-memory.md)'s "Acceptance criteria (M4)" section, verbatim:
- Cold-start-from-suspend timing holds under real (ballooned) conditions.
- 90s (default) after last window closes → guest process fully exited, verified via `ps`.
- Memory-heavy app followed by 5+ idle minutes → host memory measurably reclaimed, numbers recorded.
- No RAM-size input anywhere in default-path UI.

Additionally:
- Balloon controller doesn't oscillate/thrash under a sustained borderline-pressure workload (documented test scenario).
- Changing the idle-suspend duration in Settings takes effect on the next timer start without requiring an app restart.

## Test strategy

Scripted benchmark scenarios (see Tasks §5) run against real VMs (both guest types) — this milestone is inherently about measured real-world numbers, not mocked unit tests. Balloon-controller *decision logic* (given a sequence of pressure events, does it choose to inflate/deflate/hold) can and should be unit-tested in isolation from the real VM by injecting synthetic `MemoryPressure` events through `vmd`'s controller component directly.
