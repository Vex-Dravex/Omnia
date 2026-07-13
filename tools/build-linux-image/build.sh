#!/usr/bin/env bash
#
# Builds omnia-linux-base.img.zst — the Linux guest base image described in
# docs/02-linux-runtime.md and scoped by milestones/M1-linux-runtime.md.
#
# This produces a minimal Arch Linux ARM rootfs with omnia-agent installed
# and enabled as a systemd service, packaged as a compressed disk image ready
# to be downloaded by Omnia.app on first-run Linux setup.
#
# Requirements to actually run this (NOT available in a generic Linux
# container — needs real build infra):
#   - aarch64 cross-bootstrap tooling (pacstrap via an aarch64-capable
#     pacman, or qemu-user-static + binfmt for chrooting into an aarch64
#     rootfs from an x86_64 host)
#   - loop device access (mount/losetup) and root privileges, to partition
#     and format the image file
#   - a pre-built `omnia-agent` binary for aarch64-unknown-linux-musl (see
#     ../../guest-agent — cross-compile that crate first)
#
# This script has NOT been executed end-to-end in the environment that wrote
# it (no aarch64 bootstrap tooling / loop device access there). It is
# structured, parameterized, and step-documented so it can be run and
# iterated on real Linux/ARM build infrastructure without redesigning the
# pipeline — treat a first real run as the point where each step below gets
# verified, not assumed correct.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

IMAGE_NAME="omnia-linux-base"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-4096}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/.output}"
AGENT_BINARY="${AGENT_BINARY:-$REPO_ROOT/guest-agent/target/aarch64-unknown-linux-musl/release/omnia-agent}"

log() { echo "[build-linux-image] $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log "This script needs root (loop devices, mount, chroot). Re-run with sudo."
    exit 1
  fi
}

require_binaries() {
  local missing=()
  for bin in pacstrap arch-chroot losetup mkfs.ext4 parted zstd; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Missing required tools: ${missing[*]}"
    log "On an Arch Linux ARM build host: pacman -S arch-install-scripts parted zstd"
    exit 1
  fi
  if [[ ! -x "$AGENT_BINARY" ]]; then
    log "omnia-agent binary not found at $AGENT_BINARY"
    log "Build it first: cd $REPO_ROOT/guest-agent && cargo build --release --target aarch64-unknown-linux-musl"
    exit 1
  fi
}

# Step 1: create a blank disk image and partition it (single ext4 root
# partition — no separate boot partition needed since VZLinuxBootLoader
# per docs/02-linux-runtime.md points directly at the kernel/initrd
# extracted from this rootfs, not at a partition's own bootloader).
create_image() {
  local img="$WORK_DIR/$IMAGE_NAME.img"
  log "Creating ${IMAGE_SIZE_MB}MB image at $img"
  mkdir -p "$WORK_DIR"
  truncate -s "${IMAGE_SIZE_MB}M" "$img"
  parted -s "$img" mklabel gpt mkpart primary ext4 1MiB 100%
  echo "$img"
}

# Step 2: attach as a loop device, format, mount.
mount_image() {
  local img="$1"
  local loop_dev
  loop_dev="$(losetup --show -fP "$img")"
  mkfs.ext4 -q "${loop_dev}p1"
  local mnt="$WORK_DIR/rootfs"
  mkdir -p "$mnt"
  mount "${loop_dev}p1" "$mnt"
  echo "$loop_dev|$mnt"
}

# Step 3: bootstrap the base rootfs.
bootstrap_rootfs() {
  local mnt="$1"
  log "Bootstrapping base packages into $mnt"
  pacstrap -c "$mnt" base linux linux-firmware openssh flatpak \
    weston xorg-server-xwayland \
    networkmanager
  # weston-backend-rdp lands with M2 (docs/04-presentation-rail.md); M1 only
  # needs enough of a userspace to run omnia-agent and answer shell RPCs.
}

# Step 4: install omnia-agent and its systemd unit.
install_agent() {
  local mnt="$1"
  log "Installing omnia-agent"
  install -Dm755 "$AGENT_BINARY" "$mnt/usr/local/bin/omnia-agent"
  install -Dm644 "$REPO_ROOT/guest-agent/packaging/omnia-agent.service" \
    "$mnt/etc/systemd/system/omnia-agent.service"
  arch-chroot "$mnt" systemctl enable omnia-agent.service
  arch-chroot "$mnt" systemctl enable systemd-networkd.service NetworkManager.service
}

# Step 5: minimal guest config (locale, auto-login prep for the future
# Weston session in M2 — no desktop environment exists to log into yet in M1).
configure_guest() {
  local mnt="$1"
  log "Applying base guest configuration"
  echo "omnia-linux" > "$mnt/etc/hostname"
  arch-chroot "$mnt" bash -c "echo 'root:omnia' | chpasswd"
  # Root password is a placeholder for local `omnia linux` shell testing
  # during M1 development only — replaced by proper agent-mediated auth
  # once the CLI's OpenShell path is the only supported entry point.
}

# Step 6: unmount, detach, compress.
finalize_image() {
  local loop_dev="$1" mnt="$2" img="$3"
  log "Unmounting and detaching"
  umount "$mnt"
  losetup -d "$loop_dev"
  mkdir -p "$OUTPUT_DIR"
  local out="$OUTPUT_DIR/$IMAGE_NAME.img.zst"
  log "Compressing to $out"
  zstd -T0 -19 -f "$img" -o "$out"
  log "Done: $out"
}

main() {
  require_root
  require_binaries
  local img mount_info loop_dev mnt
  img="$(create_image)"
  mount_info="$(mount_image "$img")"
  loop_dev="${mount_info%%|*}"
  mnt="${mount_info##*|}"
  bootstrap_rootfs "$mnt"
  install_agent "$mnt"
  configure_guest "$mnt"
  finalize_image "$loop_dev" "$mnt" "$img"
}

main "$@"
