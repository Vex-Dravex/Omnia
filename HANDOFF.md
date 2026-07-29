# Session Handoff — Omnia M1 Verification

> Paste-able prompt for a new Claude Code session running **locally on the
> user's MacBook** (Apple Silicon). Everything below is also self-verifiable
> from this repo — trust the repo over memory of any prior conversation.

---

## Prompt

You are picking up work on **Omnia** (this repo, `Vex-Dravex/Omnia`), a
macOS app that runs Windows and Linux apps as if they were native Mac apps —
Parallels-class virtualization with the pain points fixed: VMs resume from
snapshots in ~1–3s instead of booting, suspend to zero footprint when idle,
dynamic memory instead of a RAM slider, a debloated Windows install, opt-in
app export, ext4/btrfs drives in Finder, a CLI, and a Flathub/winget
marketplace. Apple Silicon only, macOS 14+.

**Read these before writing any code, in this order:**
1. `BUILDING.md` — the honest status ledger: what has actually been
   compiled/tested vs. what is a written-blind first draft. This is your
   task list; its "What to do next, in order" section is the plan.
2. `docs/00-overview.md` → `docs/01-architecture.md` — the architecture and
   the requirement-to-milestone traceability table.
3. `milestones/M1-linux-runtime.md` — the milestone you are finishing;
   its acceptance criteria define "done."
4. Skim `docs/02-linux-runtime.md`, `docs/06-lifecycle-memory.md`,
   `docs/08-cli.md`, `docs/protocols/agent.proto` as you touch each area.

**Current state (as of commit `e671d7f`):**
- `guest-agent/` (Rust): REAL and verified — 10/10 tests pass, clippy/fmt
  clean. Built and tested on Linux x86_64 only; the vsock transport compiles
  but has never touched a real vsock device, and the
  `aarch64-unknown-linux-musl` production target has never been built.
- `vmd/` and `cli/` (Swift): full source written to the documented design,
  but **never compiled** — the prior session ran in a Linux container with
  no Swift toolchain. Expect compile errors. The riskiest file is
  `cli/Sources/omnia/ShellSession.swift` (grpc-swift client API written from
  memory); the lowest-risk is `vmd/Sources/OmniaVMDCore/GuestState.swift`
  (pure logic, no Apple frameworks).
- `.github/workflows/ci.yml` exists; **CI run #1 failed on the Swift jobs**
  (https://github.com/Vex-Dravex/Omnia/actions/runs/30449617008) — that
  failure is the expected starting point, not a regression. The Rust job
  should be green; check it to confirm the baseline.

**Your job, in order (mirrors BUILDING.md):**
1. `cd guest-agent && cargo test` — confirm the Rust baseline holds on macOS
   (it was only ever run on Linux; some tests use Linux PTY behavior — if any
   fail on macOS for platform reasons, gate them `#[cfg(target_os="linux")]`
   with a comment, since the agent's production target is the Linux guest).
2. `cd vmd && swift build` — fix compile errors until clean. Start with the
   `OmniaVMDCore` target, then the `vmd` executable (Virtualization.framework).
3. `cd vmd && swift test` — make `GuestLifecycleControllerTests` actually
   run and pass.
4. `brew install protobuf swift-protobuf grpc-swift`, run
   `scripts/generate-swift-proto.sh`, then `cd cli && swift build` —
   reconcile `ShellSession.swift` against the real generated gRPC API. This
   is expected to need genuine rework, not just typo fixes.
5. Cross-compile the agent for the guest:
   `rustup target add aarch64-unknown-linux-musl` and get
   `cargo build --release --target aarch64-unknown-linux-musl` working
   (you may need `brew install filosottile/musl-cross/musl-cross` for a
   linker; document whatever you settle on in BUILDING.md).
6. Then attempt the real M1 acceptance flow from
   `milestones/M1-linux-runtime.md`: build a Linux guest image
   (`tools/build-linux-image/build.sh` — written but never executed; it
   assumes Arch-on-loop-device infra and will likely need adaptation, e.g.
   building the rootfs inside a Docker/Lima container instead), boot it
   under `vmd`, and drive `omnia status` / `omnia linux <cmd>` end to end.
7. Keep CI green as you go: push fixes to `main`, watch
   `.github/workflows/ci.yml` results.

**Decisions already made — do not re-litigate without the user asking:**
- Windows engine is hybrid, VM-first (QEMU+HVF Windows 11 ARM64) with
  Wine "instant mode" deferred to M7. Linux uses Virtualization.framework.
- Seamless windows via RDP RemoteApp (RAIL): Windows' native RDP server,
  Weston's RDP backend on Linux, one embedded FreeRDP client (M2/M3 — not
  part of the current task).
- No-background-VM via suspend-to-disk snapshots + auto-suspend on last
  window close; dynamic RAM via virtio-balloon, no user RAM setting ever.
- Rust guest agent, gRPC over vsock, `docs/protocols/agent.proto` is the
  authoritative host↔guest contract.
- Only user-chosen apps are exported to Finder/Launchpad, as real `.app`
  wrapper bundles.

**Working conventions:**
- Commit directly to `main` with clear messages; push when a coherent unit
  of work is done and tests pass.
- Update `BUILDING.md`'s verified/unverified ledger whenever you move
  something from "written" to "proven" — it must stay honest.
- When you change `docs/protocols/agent.proto`, regenerate both the Rust
  side (automatic via `guest-agent/build.rs`) and the Swift side
  (`scripts/generate-swift-proto.sh`) in the same commit.

Start with step 1 and report what you find before making sweeping changes.

---

*This file was written by the prior (remote Linux) session as its handoff.
Once M1 is verified end-to-end on a real Mac, this file's job is done —
delete it and fold anything still relevant into BUILDING.md.*
