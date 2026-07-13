//! PTY-backed process spawning for `OpenShell` (docs/08-cli.md, agent.proto's
//! ShellOpen/ShellInput/ShellOutput). Used for both interactive shells and
//! one-shot commands issued via `omnia linux <cmd>` / `omnia win <cmd>`.

use nix::pty::{openpty, Winsize};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::process::Stdio;
use tokio::process::{Child, Command};
// tokio::process::Command's `pre_exec` comes from its own inherent impl
// (mirroring std::os::unix::process::CommandExt) — no separate trait import
// needed here.

pub struct PtyProcess {
    pub master: File,
    pub child: Child,
}

pub fn spawn(program: &str, args: &[String], cols: u16, rows: u16) -> anyhow::Result<PtyProcess> {
    let ws = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let pty = openpty(Some(&ws), None)?;
    let master: File = pty.master.into();
    let slave: File = pty.slave.into();

    let slave_stdin = slave.try_clone()?;
    let slave_stdout = slave.try_clone()?;
    let slave_stderr = slave.try_clone()?;
    let ctty_fd = slave.as_raw_fd();

    let mut cmd = Command::new(program);
    cmd.args(args);
    cmd.stdin(Stdio::from(slave_stdin));
    cmd.stdout(Stdio::from(slave_stdout));
    cmd.stderr(Stdio::from(slave_stderr));
    cmd.env("TERM", "xterm-256color");

    // Safety: pre_exec runs in the forked child before exec, between fork and
    // exec only async-signal-safe calls are permitted; setsid(2) and
    // ioctl(TIOCSCTTY) both are. This is the standard pattern for attaching a
    // child to a PTY as its controlling terminal (mirrors what `openpty(3)`
    // + `login_tty(3)` do in C, which Rust's std doesn't wrap directly).
    unsafe {
        cmd.pre_exec(move || {
            nix::unistd::setsid().map_err(|e| std::io::Error::from_raw_os_error(e as i32))?;
            let res = libc::ioctl(ctty_fd, libc::TIOCSCTTY as _, 0);
            if res != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    // `slave` must stay open (and `ctty_fd` valid) until *after* spawn():
    // fork() happens inside spawn(), and pre_exec runs in the forked child
    // before exec — if we closed `slave` here first, the fd would already be
    // gone by the time fork() copies the parent's fd table, and TIOCSCTTY
    // would fail with EBADF in the child. Only drop our copy once spawn()
    // has returned (the child has its own independent reference from fork).
    let child = cmd.spawn()?;
    drop(slave);
    Ok(PtyProcess { master, child })
}

/// `std::fs::File` has no `set_nonblocking` (that's only on the net socket
/// types); PTY master fds need O_NONBLOCK set directly via fcntl so the
/// AsyncFd-based read/write loops in `service.rs` don't block the runtime.
pub fn set_nonblocking(file: &File) -> anyhow::Result<()> {
    use nix::fcntl::{fcntl, FcntlArg, OFlag};
    let fd = file.as_raw_fd();
    let current = OFlag::from_bits_truncate(fcntl(fd, FcntlArg::F_GETFL)?);
    fcntl(fd, FcntlArg::F_SETFL(current | OFlag::O_NONBLOCK))?;
    Ok(())
}

pub fn resize(master: &File, cols: u16, rows: u16) -> anyhow::Result<()> {
    let ws = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let res = unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ as _, &ws) };
    if res != 0 {
        anyhow::bail!(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use tokio::io::unix::AsyncFd;

    #[tokio::test]
    async fn spawned_command_output_is_readable_from_master() {
        let mut proc = spawn("/bin/echo", &["hello-from-pty".to_string()], 80, 24)
            .expect("spawn should succeed");

        set_nonblocking(&proc.master).expect("set_nonblocking");
        let async_fd = AsyncFd::new(proc.master).expect("wrap master in AsyncFd");

        let mut collected = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if tokio::time::Instant::now() > deadline {
                break;
            }
            let mut guard = match tokio::time::timeout(
                std::time::Duration::from_millis(500),
                async_fd.readable(),
            )
            .await
            {
                Ok(Ok(g)) => g,
                _ => continue,
            };
            let mut buf = [0u8; 256];
            match guard.try_io(|inner| {
                inner
                    .get_ref()
                    .try_clone()
                    .and_then(|mut f| f.read(&mut buf))
            }) {
                Ok(Ok(0)) => break,
                Ok(Ok(n)) => collected.extend_from_slice(&buf[..n]),
                Ok(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Ok(Err(_)) => break,
                Err(_would_block) => continue,
            }
        }

        let status = proc.child.wait().await.expect("child should exit");
        assert!(status.success());
        let output = String::from_utf8_lossy(&collected);
        assert!(
            output.contains("hello-from-pty"),
            "expected PTY output to contain echoed text, got: {output:?}"
        );
    }

    #[tokio::test]
    async fn resize_does_not_error_on_live_master() {
        // spawn() uses tokio::process::Command (needed elsewhere for async
        // child management), which requires a runtime context even though
        // this particular test doesn't await anything itself.
        let proc = spawn("/bin/sleep", &["1".to_string()], 80, 24).expect("spawn");
        resize(&proc.master, 100, 40).expect("resize should succeed");
    }
}
