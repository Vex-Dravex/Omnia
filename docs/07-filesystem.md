# 07 — Filesystem Integration

Covers two distinct features that are easy to conflate: (1) plugging in a Linux/Windows-formatted **external drive** and having it open in Finder, and (2) a **shared folder** between host and guest for everyday file exchange. Both ultimately surface through a single macOS **File Provider extension**, but the data path into that extension differs.

## Feature 1: External drive with a foreign filesystem (ext4, btrfs, and NTFS-beyond-macOS's-read-only-support)

macOS cannot mount ext4/btrfs at all, and only reads NTFS natively (no write). The goal: plug in such a drive and it appears as a normal, read/write volume in Finder — backed by the *real* filesystem driver running inside a guest, not a reimplementation on the host.

Flow:
1. **DiskArbitration claim.** `vmd`'s privileged helper registers a `DADiskClaim` callback (via `DiskArbitration.framework`) that recognizes unmountable/unknown filesystem probes (macOS fails to identify ext4/btrfs, which is the signal to intercept) and claims the disk before macOS shows an "insert a readable disk" prompt.
2. **Raw block passthrough.** The claimed disk's BSD device (`/dev/diskN`) is passed into the Linux runtime as an additional `VZVirtioBlockDeviceConfiguration` (attached dynamically — Linux guest is resumed if suspended, matching the on-demand model in [06](06-lifecycle-memory.md)) or, for a Windows-only-relevant NTFS-write case, into the Windows runtime.
3. **Guest-side mount.** `omnia-agent` mounts the new block device inside the guest (`mount /dev/vdX /mnt/omnia-drive-<uuid>`) using the guest's real driver.
4. **Finder exposure.** The **File Provider extension** (a separate, macOS-managed process, `OmniaFileProvider.appex`) presents that mounted path as a Finder volume/domain. Reads/writes from Finder are relayed to the extension, which relays them to `omnia-agent` over vsock, which performs them against the real mount inside the guest. This mirrors the approach used by tools like OrbStack for container filesystem access — the File Provider API is designed exactly for "a Finder-visible filesystem backed by something that isn't a local disk."
5. **Unmount/eject.** Standard Finder eject triggers unclaim → guest unmount → block device detached. If the guest is suspended when the drive is unplugged, `vmd` treats it the same as an unmount request (resume briefly to unmount cleanly, then proceed).

**Constraint to flag in M5, not resolve prematurely:** File Provider performance for large sequential transfers (e.g. copying a 20GB file) needs early benchmarking — if vsock-relayed I/O is too slow, virtio-fs-based exposure (see Feature 2) of the mounted path may be substituted as the transport instead of the File Provider's typical per-item I/O calls. Decide with data during M5, don't assume either path up front.

## Feature 2: Shared folder (everyday host↔guest file exchange)

Simpler and lower-risk: a **virtio-fs** share (already part of the VM configuration in [02](02-linux-runtime.md)/[03](03-windows-runtime.md)) exposing a host directory (default `~/Omnia Shared/`) directly into the guest at a fixed mount point. This is the "drop a file in and both sides see it" mechanism and needs no File Provider extension — the guest mounts virtio-fs natively (Linux: `virtiofs` kernel driver; Windows: `virtio-fs` driver from `virtio-win`, included in the debloated image build per [03](03-windows-runtime.md)).

## Explicitly not in scope for v1 (documented, not built)

- Full bidirectional live-sync of the guest's entire home directory into Finder (only the explicit shared folder and explicitly-mounted external drives are exposed — not the whole guest filesystem, to avoid surprising the user with guest-internal clutter, consistent with the "only what I choose" principle applied elsewhere).
