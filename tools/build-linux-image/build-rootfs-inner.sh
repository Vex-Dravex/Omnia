#!/usr/bin/env bash
#
# Inner half of the macOS image-build path (see build-in-vm.sh): runs as
# root INSIDE the throwaway aarch64 Ubuntu builder VM, where loop-device-free
# rootfs construction is possible with native-arch chroots.
#
# Inputs (all expected in $BUILD, default /build):
#   ArchLinuxARM-aarch64-latest.tar.gz   Arch Linux ARM base rootfs tarball
#   omnia-agent                          aarch64-musl agent binary
#   omnia-agent.service                  systemd unit (guest-agent/packaging/)
#
# Outputs in $BUILD/out:
#   rootfs.img      whole-disk ext4 (NO partition table — LinuxRuntime boots
#                   with root=/dev/vda, so the disk itself is the filesystem;
#                   the original build.sh's GPT+p1 layout contradicted that
#                   cmdline and is corrected here)
#   vmlinuz         uncompressed arm64 kernel Image (VZLinuxBootLoader)
#   initramfs.img   mkinitcpio fallback image (no host-specific autodetect)

set -euo pipefail

BUILD="${BUILD:-/build}"
ROOTFS="$BUILD/rootfs"
OUT="$BUILD/out"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-4096}"

log() { echo "[build-rootfs-inner] $*" >&2; }

log "Installing build tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zstd e2fsprogs >/dev/null

log "Extracting Arch Linux ARM base rootfs"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS" "$OUT"
tar -xpf "$BUILD/ArchLinuxARM-aarch64-latest.tar.gz" -C "$ROOTFS"

log "Installing omnia-agent"
install -Dm755 "$BUILD/omnia-agent" "$ROOTFS/usr/local/bin/omnia-agent"
install -Dm644 "$BUILD/omnia-agent.service" "$ROOTFS/etc/systemd/system/omnia-agent.service"
# systemctl enable without systemd running = create the wants symlink.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/omnia-agent.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/omnia-agent.service"

log "Guest configuration"
echo "omnia-linux" > "$ROOTFS/etc/hostname"
# DHCP on the NAT interface via systemd-networkd (in the base tarball —
# no extra packages needed). Without this the guest has no networking.
mkdir -p "$ROOTFS/etc/systemd/network"
printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' \
  > "$ROOTFS/etc/systemd/network/20-wired.network"
for svc in systemd-networkd systemd-resolved; do
  mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
  ln -sf "/usr/lib/systemd/system/$svc.service" \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/$svc.service"
done
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
# The guest side of AF_VSOCK needs the virtio transport loaded before the
# agent can bind its vsock port.
echo "vmw_vsock_virtio_transport" > "$ROOTFS/etc/modules-load.d/omnia-vsock.conf"
# Root password is a placeholder for local `omnia linux` shell testing
# during M1 development only (same note as build.sh).
chroot "$ROOTFS" /bin/bash -c "echo 'root:omnia' | chpasswd"

log "Kernel and initramfs"
ls -la "$ROOTFS/boot" >&2
if [[ ! -e "$ROOTFS/boot/Image" ]]; then
  log "No /boot/Image in the tarball — kernel package layout changed?"
  exit 1
fi
# Build our own initramfs with autodetect skipped: the ALARM preset only
# ships/regenerates the 'default' image, and mkinitcpio's autodetect hook
# would whitelist modules for THIS builder VM's hardware, not the
# Virtualization.framework guest's. -S autodetect = fallback-style image
# with the full module set (virtio_blk et al guaranteed present).
KVER="$(ls "$ROOTFS/usr/lib/modules" | head -1)"
log "Generating initramfs for kernel $KVER (autodetect skipped)"
for d in proc sys dev; do mount --bind "/$d" "$ROOTFS/$d"; done
chroot "$ROOTFS" mkinitcpio -k "$KVER" -S autodetect -g /boot/initramfs-omnia.img
for d in proc sys dev; do umount "$ROOTFS/$d"; done
cp "$ROOTFS/boot/Image" "$OUT/vmlinuz"
cp "$ROOTFS/boot/initramfs-omnia.img" "$OUT/initramfs.img"

log "Building whole-disk ext4 rootfs.img (${IMAGE_SIZE_MB}MB)"
rm -f "$OUT/rootfs.img"
truncate -s "${IMAGE_SIZE_MB}M" "$OUT/rootfs.img"
mkfs.ext4 -q -d "$ROOTFS" "$OUT/rootfs.img"

chmod 644 "$OUT"/*

log "Done:"
ls -lh "$OUT" >&2
