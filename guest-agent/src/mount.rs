//! Block-device mount/unmount for external-drive passthrough
//! (docs/07-filesystem.md, agent.proto's MountBlockDevice/UnmountBlockDevice).
//!
//! `vmd` attaches a claimed disk to the guest as an additional virtio block
//! device and then calls this RPC with the resulting in-guest device path
//! (e.g. `/dev/vdb`). This module detects the filesystem and performs a real
//! mount using the guest's own driver — that's the entire point of routing
//! foreign filesystems through a real Linux guest instead of reimplementing
//! ext4/btrfs support on the host.
//!
//! `BlockDeviceOps` exists so `AgentService`'s RPC-handling logic (path
//! selection, error mapping, response construction) is unit-testable without
//! requiring real block devices / root privileges in CI.

use std::path::PathBuf;
use std::process::Command;

pub trait BlockDeviceOps: Send + Sync {
    fn detect_filesystem(&self, device_path: &str) -> anyhow::Result<String>;
    fn mount(&self, device_path: &str, mount_point: &str, fs_type: &str) -> anyhow::Result<()>;
    fn unmount(&self, mount_point: &str) -> anyhow::Result<()>;
}

pub struct RealBlockDeviceOps;

impl BlockDeviceOps for RealBlockDeviceOps {
    fn detect_filesystem(&self, device_path: &str) -> anyhow::Result<String> {
        let output = Command::new("blkid")
            .args(["-o", "value", "-s", "TYPE", device_path])
            .output()?;
        if !output.status.success() {
            anyhow::bail!(
                "blkid failed for {device_path}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        let fs_type = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if fs_type.is_empty() {
            anyhow::bail!("blkid returned no filesystem type for {device_path}");
        }
        Ok(fs_type)
    }

    // The nix::mount API is Linux-shaped here (5-arg mount(2), umount);
    // macOS's differs. The agent only ever performs real mounts inside the
    // Linux guest — on other hosts (dev-mode via --unix-socket) these RPCs
    // report unsupported instead of compiling against the wrong syscall.
    #[cfg(target_os = "linux")]
    fn mount(&self, device_path: &str, mount_point: &str, fs_type: &str) -> anyhow::Result<()> {
        std::fs::create_dir_all(mount_point)?;
        let source = std::ffi::CString::new(device_path)?;
        let target = std::ffi::CString::new(mount_point)?;
        let fstype = std::ffi::CString::new(fs_type)?;
        // Real mount(2) via the guest kernel's own filesystem driver — this
        // is the whole point of routing ext4/btrfs through a Linux guest
        // rather than a host-side reimplementation. `nix::mount::mount`
        // wraps this syscall; flags/data left default (rw, no special
        // options) for M1 — revisit (e.g. noatime) as a later polish pass.
        nix::mount::mount(
            Some(source.as_c_str()),
            target.as_c_str(),
            Some(fstype.as_c_str()),
            nix::mount::MsFlags::empty(),
            None::<&std::ffi::CStr>,
        )
        .map_err(|errno| anyhow::anyhow!("mount({device_path} -> {mount_point}) failed: {errno}"))
    }

    #[cfg(not(target_os = "linux"))]
    fn mount(&self, device_path: &str, mount_point: &str, _fs_type: &str) -> anyhow::Result<()> {
        anyhow::bail!(
            "mount({device_path} -> {mount_point}) unsupported: block-device mounts only run in the Linux guest"
        )
    }

    #[cfg(target_os = "linux")]
    fn unmount(&self, mount_point: &str) -> anyhow::Result<()> {
        let target = std::ffi::CString::new(mount_point)?;
        nix::mount::umount(target.as_c_str())
            .map_err(|errno| anyhow::anyhow!("umount({mount_point}) failed: {errno}"))
    }

    #[cfg(not(target_os = "linux"))]
    fn unmount(&self, mount_point: &str) -> anyhow::Result<()> {
        anyhow::bail!(
            "umount({mount_point}) unsupported: block-device mounts only run in the Linux guest"
        )
    }
}

pub fn default_mount_point(requested: &str) -> String {
    if !requested.is_empty() {
        return requested.to_string();
    }
    let uuid = uuid::Uuid::new_v4();
    PathBuf::from("/mnt")
        .join(format!("omnia-drive-{uuid}"))
        .to_string_lossy()
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_mount_point_uses_requested_path_when_given() {
        assert_eq!(default_mount_point("/mnt/my-drive"), "/mnt/my-drive");
    }

    #[test]
    fn default_mount_point_generates_uuid_path_when_empty() {
        let path = default_mount_point("");
        assert!(path.starts_with("/mnt/omnia-drive-"));
    }
}
