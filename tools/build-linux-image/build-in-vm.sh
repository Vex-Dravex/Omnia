#!/usr/bin/env bash
#
# macOS-runnable path to build the Linux guest image (the original build.sh
# assumes native Arch-on-loop-device infra that a Mac doesn't have; this is
# the adaptation BUILDING.md/HANDOFF.md predicted would be needed).
#
# Strategy: boot a throwaway aarch64 Ubuntu cloud VM under qemu+HVF, run
# build-rootfs-inner.sh inside it (native-arch chroot, no loop devices —
# whole-disk ext4 via mkfs.ext4 -d), and scp the artifacts back out.
#
# Requirements (host): qemu (brew install qemu), curl, ssh/scp, hdiutil.
# Inputs downloaded to .work/ on first run (checksums verified):
#   - Ubuntu noble arm64 cloud image (builder VM)
#   - Arch Linux ARM aarch64 rootfs tarball (guest base)
# Plus the cross-compiled agent:
#   guest-agent/target/aarch64-unknown-linux-musl/release/omnia-agent
#
# Outputs in .output/: rootfs.img, vmlinuz, initramfs.img
# (matching the filenames LinuxRuntime.swift expects under
#  ~/Library/Application Support/Omnia/linux/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/.output}"
AGENT_BINARY="${AGENT_BINARY:-$REPO_ROOT/guest-agent/target/aarch64-unknown-linux-musl/release/omnia-agent}"
AGENT_UNIT="$REPO_ROOT/guest-agent/packaging/omnia-agent.service"

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
ALARM_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
SSH_PORT="${SSH_PORT:-2222}"
QEMU_FIRMWARE="${QEMU_FIRMWARE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

log() { echo "[build-in-vm] $*" >&2; }

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR"

[[ -x "$AGENT_BINARY" ]] || {
  log "omnia-agent aarch64-musl binary missing — build it first:"
  log "  cd guest-agent && cargo build --release --target aarch64-unknown-linux-musl"
  exit 1
}

# --- Fetch inputs -----------------------------------------------------------
if [[ ! -f noble-server-cloudimg-arm64.img ]]; then
  log "Downloading Ubuntu builder image"
  curl -sLO "$UBUNTU_IMG_URL"
  curl -sLO "${UBUNTU_IMG_URL%/*}/SHA256SUMS"
  shasum -a 256 -c <(grep 'noble-server-cloudimg-arm64.img$' SHA256SUMS)
fi
if [[ ! -f ArchLinuxARM-aarch64-latest.tar.gz ]]; then
  log "Downloading Arch Linux ARM rootfs tarball"
  curl -sLO "$ALARM_URL"
  curl -sLO "$ALARM_URL.md5"
  [[ "$(md5 -q ArchLinuxARM-aarch64-latest.tar.gz)" == "$(awk '{print $1}' ArchLinuxARM-aarch64-latest.tar.gz.md5)" ]] \
    || { log "ALARM tarball md5 mismatch"; exit 1; }
fi

# --- Builder VM disk + cloud-init seed -------------------------------------
if [[ ! -f builder.qcow2 ]]; then
  log "Preparing builder VM disk"
  cp noble-server-cloudimg-arm64.img builder.qcow2
  qemu-img resize builder.qcow2 24G >/dev/null
fi

if [[ ! -f builder_ssh_key ]]; then
  ssh-keygen -t ed25519 -N "" -f builder_ssh_key -C omnia-builder >/dev/null
fi

if [[ ! -f seed.iso ]]; then
  log "Creating cloud-init seed"
  rm -rf seed && mkdir seed
  cat > seed/meta-data <<EOF
instance-id: omnia-builder
local-hostname: omnia-builder
EOF
  cat > seed/user-data <<EOF
#cloud-config
users:
  - name: builder
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat builder_ssh_key.pub)
EOF
  hdiutil makehybrid -iso -joliet -default-volume-name cidata -o seed.iso seed >/dev/null
fi

# --- Boot builder VM --------------------------------------------------------
SSH_OPTS=(-p "$SSH_PORT" -i builder_ssh_key -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

if ! ssh "${SSH_OPTS[@]}" builder@127.0.0.1 true 2>/dev/null; then
  log "Booting builder VM (qemu + HVF)"
  qemu-system-aarch64 \
    -M virt -accel hvf -cpu host -smp 4 -m 4096 \
    -bios "$QEMU_FIRMWARE" \
    -drive if=virtio,file=builder.qcow2,format=qcow2 \
    -drive if=virtio,file=seed.iso,format=raw,readonly=on \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -device virtio-net-pci,netdev=n0 \
    -display none -daemonize -pidfile qemu.pid \
    -serial "file:$WORK_DIR/builder-console.log"

  log "Waiting for SSH"
  for _ in $(seq 1 60); do
    ssh "${SSH_OPTS[@]}" builder@127.0.0.1 true 2>/dev/null && break
    sleep 5
  done
  ssh "${SSH_OPTS[@]}" builder@127.0.0.1 true \
    || { log "builder VM never became reachable (see builder-console.log)"; exit 1; }
fi

# --- Run the inner build ----------------------------------------------------
log "Copying inputs into builder"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 "sudo mkdir -p /build && sudo chown builder /build"
scp "${SSH_OPTS[@]/#-p/-P}" \
  ArchLinuxARM-aarch64-latest.tar.gz \
  "$AGENT_BINARY" \
  "$AGENT_UNIT" \
  "$SCRIPT_DIR/build-rootfs-inner.sh" \
  builder@127.0.0.1:/build/ >/dev/null

log "Running build-rootfs-inner.sh in builder"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 "sudo bash /build/build-rootfs-inner.sh"

log "Fetching artifacts"
scp "${SSH_OPTS[@]/#-p/-P}" \
  builder@127.0.0.1:/build/out/rootfs.img \
  builder@127.0.0.1:/build/out/vmlinuz \
  builder@127.0.0.1:/build/out/initramfs.img \
  "$OUTPUT_DIR/" >/dev/null

log "Shutting down builder VM"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 "sudo poweroff" 2>/dev/null || true

log "Done:"
ls -lh "$OUTPUT_DIR" >&2
