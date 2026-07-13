# M5 — Finder Drive Integration

**Goal:** plugging in an ext4/btrfs-formatted external drive results in it mounting in Finder, read/write, backed by the real guest filesystem driver. This is [docs/07-filesystem.md](../docs/07-filesystem.md) Feature 1; Feature 2 (the always-on shared folder) should already exist as a side effect of the VM configuration from M1/M3 (virtio-fs share) — verify it works, and if it was never actually surfaced/tested, this milestone also closes that gap.

**Read first:** [docs/07-filesystem.md](../docs/07-filesystem.md) in full. Assumes M1–M4 complete.

## Scope

In scope:
- Root helper process (`tools/privileged-helper/` or similar) implementing the narrowly-scoped DiskArbitration disk-claim, installed/authorized per [docs/10-security-distribution.md](../docs/10-security-distribution.md)'s "smallest possible piece runs elevated" principle.
- `vmd` logic to detect an unrecognized-filesystem disk claim event, attach it as an additional block device to the Linux runtime (resuming it if suspended), and request a mount via `omnia-agent`'s existing `MountBlockDevice` RPC (already implemented in M1 — this milestone is largely about wiring the DiskArbitration trigger to it, not building new agent-side mount logic).
- `OmniaFileProvider.appex` (new target): a File Provider extension presenting the guest-mounted path as a Finder volume, relaying file operations to `omnia-agent` over vsock.
- Eject/unmount flow, including the case where the guest is suspended when the user ejects (resume briefly, unmount cleanly, allow suspend to proceed).
- Verify (and fix if broken) the virtio-fs shared-folder path (`~/Omnia Shared/`) from both guests — this doesn't need a File Provider extension since virtio-fs already gives the guest a native mount; the "Finder integration" here is just confirming the host-side directory behaves normally (it should, since it's a real host directory shared *into* the guest, not the reverse).

Out of scope: NTFS write support is included only insofar as it reuses this same pipeline (routed through whichever guest — likely Windows — has the best NTFS write driver situation; do not build a separate NTFS-specific path). Bidirectional full-home-directory sync is explicitly out of scope per [docs/07](../docs/07-filesystem.md).

## Tasks

1. Implement the root helper with the modern Apple-recommended privileged-helper mechanism (verify current guidance at implementation time per [docs/10](../docs/10-security-distribution.md) — do not assume SMJobBless is still current without checking).
2. Implement DiskArbitration claim logic: register a callback, detect probe failures for ext4/btrfs specifically (don't intercept disks macOS can already mount — only unrecognized filesystems), claim before macOS shows its "insert a readable disk" prompt.
3. Wire the claimed disk's BSD device into `vmd`, attach as a `VZVirtioBlockDeviceConfiguration` to the (possibly-resumed) Linux runtime.
4. Call `MountBlockDevice` via `omnia-agent`, confirm the guest mounts successfully and reports back the mount point/filesystem type.
5. Build `OmniaFileProvider.appex`: implement the File Provider protocol's required methods (item enumeration, fetch contents, create/modify/delete) by relaying each to `omnia-agent` over vsock, operating against the guest's real mount.
6. Build eject handling: Finder eject → extension/vmd triggers `UnmountBlockDevice` → DiskArbitration release → (if the countdown was already running) allow normal idle-suspend to proceed.
7. **Benchmark large-file transfer** (per [docs/07](../docs/07-filesystem.md)'s flagged constraint): copy a multi-GB file both directions through the File Provider path, measure throughput. If unacceptably slow, evaluate switching the transport for this feature to a virtio-fs-based exposure instead of per-item File Provider I/O — document the decision and data either way.
8. Verify the shared-folder (Feature 2) path on both guests; fix if not already working from earlier milestones.

## Acceptance criteria

- Plugging in a real ext4-formatted USB drive results in it appearing as a normal (non-greyed-out, no "insert a readable disk" prompt) volume in Finder within a few seconds, with the Linux guest resuming on-demand if it was suspended.
- Creating, editing, deleting, and renaming files on that volume via Finder works correctly and is reflected when inspecting the same mount from inside the guest directly (`omnia linux ls /mnt/omnia-drive-...`).
- Ejecting via Finder cleanly unmounts guest-side and macOS-side with no errors, and the drive can be re-plugged and remounted without a reboot of anything.
- Large-file transfer throughput is measured and documented, with a stated pass/fail against a reasonable "usable for everyday file copying" bar (define the bar explicitly in the benchmark report, e.g. sustained >20MB/s, rather than leaving it implicit).
- btrfs drive (in addition to ext4) mounts and behaves the same way.

## Test strategy

Requires real physical or virtual (image-file-backed, `hdiutil`-attached where feasible for CI) ext4/btrfs volumes — build a test fixture that creates a small ext4 disk image on the host for repeatable automated testing of the claim→mount→Finder→unmount cycle, reserving actual USB hardware for a manual pre-release checklist item. File Provider extension correctness (item enumeration/CRUD) should have unit tests against a mocked `omnia-agent` connection in addition to the end-to-end fixture test.
