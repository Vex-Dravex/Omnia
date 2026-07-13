use std::io::{Read, Write};
use std::pin::Pin;
use std::sync::Arc;

use futures::Stream;
use tokio::io::unix::AsyncFd;
use tonic::{Request, Response, Status, Streaming};

use crate::mount::{default_mount_point, BlockDeviceOps, RealBlockDeviceOps};
use crate::proto::*;
use crate::pty;

pub struct AgentService {
    block_device_ops: Arc<dyn BlockDeviceOps>,
}

impl AgentService {
    pub fn new() -> Self {
        Self {
            block_device_ops: Arc::new(RealBlockDeviceOps),
        }
    }

    #[cfg(test)]
    pub fn with_block_device_ops(ops: Arc<dyn BlockDeviceOps>) -> Self {
        Self {
            block_device_ops: ops,
        }
    }
}

impl Default for AgentService {
    fn default() -> Self {
        Self::new()
    }
}

type BoxStream<T> = Pin<Box<dyn Stream<Item = Result<T, Status>> + Send + 'static>>;

#[tonic::async_trait]
impl omnia_agent_server::OmniaAgent for AgentService {
    // --- Implemented in M1 (see milestones/M1-linux-runtime.md) ---

    async fn hello(
        &self,
        _request: Request<HelloRequest>,
    ) -> Result<Response<HelloResponse>, Status> {
        Ok(Response::new(HelloResponse {
            agent_version: env!("CARGO_PKG_VERSION").to_string(),
            guest_os: GuestOs::Linux as i32,
            ready: true,
        }))
    }

    type OpenShellStream = BoxStream<ShellOutput>;

    async fn open_shell(
        &self,
        request: Request<Streaming<ShellInput>>,
    ) -> Result<Response<Self::OpenShellStream>, Status> {
        let mut inbound = request.into_inner();

        let open = match inbound.message().await {
            Ok(Some(ShellInput {
                payload: Some(shell_input::Payload::Open(open)),
            })) => open,
            Ok(_) => {
                return Err(Status::invalid_argument(
                    "first OpenShell message must be a ShellOpen",
                ))
            }
            Err(e) => return Err(e),
        };

        let program = if open.command.is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
        } else {
            open.command[0].clone()
        };
        let args: Vec<String> = if open.command.is_empty() {
            Vec::new()
        } else {
            open.command[1..].to_vec()
        };

        let proc = pty::spawn(
            &program,
            &args,
            open.initial_cols.clamp(1, u16::MAX as u32) as u16,
            open.initial_rows.clamp(1, u16::MAX as u32) as u16,
        )
        .map_err(|e| Status::internal(format!("failed to spawn shell: {e}")))?;

        pty::set_nonblocking(&proc.master)
            .map_err(|e| Status::internal(format!("set_nonblocking failed: {e}")))?;
        let master_for_read = proc
            .master
            .try_clone()
            .map_err(|e| Status::internal(format!("clone master fd failed: {e}")))?;
        let master_for_write = proc.master;
        let mut child = proc.child;

        let read_fd = Arc::new(
            AsyncFd::new(master_for_read)
                .map_err(|e| Status::internal(format!("AsyncFd::new failed: {e}")))?,
        );
        let write_fd = Arc::new(
            AsyncFd::new(master_for_write)
                .map_err(|e| Status::internal(format!("AsyncFd::new failed: {e}")))?,
        );

        let (tx, rx) = tokio::sync::mpsc::channel::<Result<ShellOutput, Status>>(64);

        // Writer task: relay stdin_chunk / resize messages from the client
        // into the PTY master until the client half of the stream closes.
        let writer_write_fd = write_fd.clone();
        tokio::spawn(async move {
            while let Ok(Some(msg)) = inbound.message().await {
                match msg.payload {
                    Some(shell_input::Payload::StdinChunk(chunk)) => {
                        let mut guard = match writer_write_fd.writable().await {
                            Ok(g) => g,
                            Err(_) => break,
                        };
                        let _ = guard.try_io(|inner| {
                            inner
                                .get_ref()
                                .try_clone()?
                                .write_all(&chunk)
                                .map(|_| chunk.len())
                        });
                    }
                    Some(shell_input::Payload::Resize(resize)) => {
                        let _ = pty::resize(
                            writer_write_fd.get_ref(),
                            resize.cols.clamp(1, u16::MAX as u32) as u16,
                            resize.rows.clamp(1, u16::MAX as u32) as u16,
                        );
                    }
                    Some(shell_input::Payload::Open(_)) | None => {
                        // Open only valid as the first message; ignore stray
                        // duplicates rather than tearing down the session.
                    }
                }
            }
        });

        // Reader task: relay PTY output to the client until the child exits,
        // then send the final exit-code message.
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                let mut guard = match read_fd.readable().await {
                    Ok(g) => g,
                    Err(_) => break,
                };
                match guard.try_io(|inner| inner.get_ref().try_clone()?.read(&mut buf)) {
                    Ok(Ok(0)) => break,
                    Ok(Ok(n)) => {
                        if tx
                            .send(Ok(ShellOutput {
                                payload: Some(shell_output::Payload::StdoutChunk(
                                    buf[..n].to_vec(),
                                )),
                            }))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                    Ok(Err(e)) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                    Ok(Err(_)) => break,
                    Err(_would_block) => continue,
                }
            }

            let exit_code = child
                .wait()
                .await
                .ok()
                .and_then(|status| status.code())
                .unwrap_or(-1);
            let _ = tx
                .send(Ok(ShellOutput {
                    payload: Some(shell_output::Payload::ExitCode(exit_code)),
                }))
                .await;
        });

        let out_stream = tokio_stream::wrappers::ReceiverStream::new(rx);
        Ok(Response::new(Box::pin(out_stream)))
    }

    async fn mount_block_device(
        &self,
        request: Request<MountBlockDeviceRequest>,
    ) -> Result<Response<MountBlockDeviceResponse>, Status> {
        let req = request.into_inner();
        let ops = self.block_device_ops.clone();
        let device_path = req.device_path.clone();
        let mount_point = default_mount_point(&req.requested_mount_point);

        let result = tokio::task::spawn_blocking(move || -> anyhow::Result<String> {
            let fs_type = ops.detect_filesystem(&device_path)?;
            ops.mount(&device_path, &mount_point, &fs_type)?;
            Ok(fs_type)
        })
        .await
        .map_err(|e| Status::internal(format!("mount task panicked: {e}")))?;

        match result {
            Ok(fs_type) => Ok(Response::new(MountBlockDeviceResponse {
                mounted: true,
                mount_point: default_mount_point(&req.requested_mount_point),
                filesystem_type: fs_type,
                error: String::new(),
            })),
            Err(e) => Ok(Response::new(MountBlockDeviceResponse {
                mounted: false,
                mount_point: String::new(),
                filesystem_type: String::new(),
                error: e.to_string(),
            })),
        }
    }

    async fn unmount_block_device(
        &self,
        request: Request<UnmountBlockDeviceRequest>,
    ) -> Result<Response<UnmountBlockDeviceResponse>, Status> {
        let req = request.into_inner();
        let ops = self.block_device_ops.clone();

        let result = tokio::task::spawn_blocking(move || ops.unmount(&req.mount_point))
            .await
            .map_err(|e| Status::internal(format!("unmount task panicked: {e}")))?;

        Ok(Response::new(UnmountBlockDeviceResponse {
            unmounted: result.is_ok(),
        }))
    }

    type WatchEventsStream = BoxStream<AgentEvent>;

    async fn watch_events(
        &self,
        _request: Request<WatchEventsRequest>,
    ) -> Result<Response<Self::WatchEventsStream>, Status> {
        // M1 scope stub (see milestones/M1-linux-runtime.md): the interface
        // exists and is wired end-to-end, but no events are produced yet.
        // Weston window-count events (M2) and memory-pressure events (M4)
        // populate this stream in later milestones — this must become a
        // real broadcaster then, not remain `stream::pending`.
        let empty: BoxStream<AgentEvent> = Box::pin(futures::stream::pending());
        Ok(Response::new(empty))
    }

    // --- Out of scope for M1; implemented in later milestones ---

    async fn list_apps(
        &self,
        _request: Request<ListAppsRequest>,
    ) -> Result<Response<ListAppsResponse>, Status> {
        Err(Status::unimplemented(
            "ListApps ships in M2 (docs/05-app-integration.md)",
        ))
    }

    async fn launch_app(
        &self,
        _request: Request<LaunchAppRequest>,
    ) -> Result<Response<LaunchAppResponse>, Status> {
        Err(Status::unimplemented(
            "LaunchApp ships in M2 (docs/04-presentation-rail.md)",
        ))
    }

    async fn terminate_app(
        &self,
        _request: Request<TerminateAppRequest>,
    ) -> Result<Response<TerminateAppResponse>, Status> {
        Err(Status::unimplemented(
            "TerminateApp ships in M2 (docs/04-presentation-rail.md)",
        ))
    }

    type InstallAppStream = BoxStream<InstallProgress>;

    async fn install_app(
        &self,
        _request: Request<InstallAppRequest>,
    ) -> Result<Response<Self::InstallAppStream>, Status> {
        Err(Status::unimplemented(
            "InstallApp ships in M6 (docs/09-marketplace.md)",
        ))
    }

    async fn uninstall_app(
        &self,
        _request: Request<UninstallAppRequest>,
    ) -> Result<Response<UninstallAppResponse>, Status> {
        Err(Status::unimplemented(
            "UninstallApp ships in M6 (docs/09-marketplace.md)",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use omnia_agent_server::OmniaAgent;
    use std::sync::Mutex;

    #[tokio::test]
    async fn hello_reports_linux_and_ready() {
        let svc = AgentService::new();
        let resp = svc
            .hello(Request::new(HelloRequest::default()))
            .await
            .unwrap();
        let body = resp.into_inner();
        assert_eq!(body.guest_os, GuestOs::Linux as i32);
        assert!(body.ready);
        assert!(!body.agent_version.is_empty());
    }

    #[tokio::test]
    async fn watch_events_stream_never_yields_in_m1() {
        use futures::StreamExt;

        let svc = AgentService::new();
        let resp = svc
            .watch_events(Request::new(WatchEventsRequest::default()))
            .await
            .unwrap();
        let mut stream = resp.into_inner();
        let next = tokio::time::timeout(std::time::Duration::from_millis(200), stream.next()).await;
        assert!(next.is_err(), "M1's WatchEvents stub must never yield");
    }

    struct FakeBlockDeviceOps {
        detected_fs: &'static str,
        mount_calls: Mutex<Vec<(String, String, String)>>,
        unmount_calls: Mutex<Vec<String>>,
    }

    impl BlockDeviceOps for FakeBlockDeviceOps {
        fn detect_filesystem(&self, _device_path: &str) -> anyhow::Result<String> {
            Ok(self.detected_fs.to_string())
        }
        fn mount(&self, device_path: &str, mount_point: &str, fs_type: &str) -> anyhow::Result<()> {
            self.mount_calls.lock().unwrap().push((
                device_path.to_string(),
                mount_point.to_string(),
                fs_type.to_string(),
            ));
            Ok(())
        }
        fn unmount(&self, mount_point: &str) -> anyhow::Result<()> {
            self.unmount_calls
                .lock()
                .unwrap()
                .push(mount_point.to_string());
            Ok(())
        }
    }

    #[tokio::test]
    async fn mount_block_device_uses_detected_fs_type_and_requested_mount_point() {
        let fake = Arc::new(FakeBlockDeviceOps {
            detected_fs: "ext4",
            mount_calls: Mutex::new(Vec::new()),
            unmount_calls: Mutex::new(Vec::new()),
        });
        let svc = AgentService::with_block_device_ops(fake.clone());

        let resp = svc
            .mount_block_device(Request::new(MountBlockDeviceRequest {
                device_path: "/dev/vdb".to_string(),
                requested_mount_point: "/mnt/my-drive".to_string(),
            }))
            .await
            .unwrap()
            .into_inner();

        assert!(resp.mounted);
        assert_eq!(resp.filesystem_type, "ext4");
        assert_eq!(resp.mount_point, "/mnt/my-drive");
        assert_eq!(
            fake.mount_calls.lock().unwrap()[0],
            (
                "/dev/vdb".to_string(),
                "/mnt/my-drive".to_string(),
                "ext4".to_string()
            )
        );
    }

    #[tokio::test]
    async fn unmount_block_device_delegates_to_ops() {
        let fake = Arc::new(FakeBlockDeviceOps {
            detected_fs: "ext4",
            mount_calls: Mutex::new(Vec::new()),
            unmount_calls: Mutex::new(Vec::new()),
        });
        let svc = AgentService::with_block_device_ops(fake.clone());

        let resp = svc
            .unmount_block_device(Request::new(UnmountBlockDeviceRequest {
                mount_point: "/mnt/my-drive".to_string(),
            }))
            .await
            .unwrap()
            .into_inner();

        assert!(resp.unmounted);
        assert_eq!(fake.unmount_calls.lock().unwrap()[0], "/mnt/my-drive");
    }
}
