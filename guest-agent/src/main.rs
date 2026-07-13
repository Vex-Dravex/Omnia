use clap::Parser;
use std::path::PathBuf;
use tonic::transport::Server;
use tracing_subscriber::EnvFilter;

use omnia_agent::proto::omnia_agent_server::OmniaAgentServer;
use omnia_agent::service::AgentService;

/// omnia-agent: guest-side control daemon.
///
/// Production transport is vsock (see docs/02-linux-runtime.md /
/// docs/03-windows-runtime.md), reached at a fixed, well-known port so `vmd`
/// doesn't need guest-side discovery. A Unix-domain-socket transport is also
/// supported purely for local development/testing on a host that has no
/// vsock device (e.g. this repo's CI, or iterating outside a real guest).
#[derive(Parser, Debug)]
#[command(name = "omnia-agent")]
struct Args {
    /// vsock port to listen on (production default per agent.proto's fixed
    /// control-channel port convention).
    #[arg(long, default_value_t = 5151)]
    vsock_port: u32,

    /// Listen on a Unix domain socket instead of vsock. Overrides
    /// --vsock-port. Intended for local development only.
    #[arg(long)]
    unix_socket: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let args = Args::parse();
    let service = AgentService::new();
    let server = Server::builder().add_service(OmniaAgentServer::new(service));

    if let Some(path) = args.unix_socket {
        tracing::info!(path = %path.display(), "listening on unix socket");
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        let uds = tokio::net::UnixListener::bind(&path)?;
        let incoming = tokio_stream::wrappers::UnixListenerStream::new(uds);
        server.serve_with_incoming(incoming).await?;
    } else {
        #[cfg(target_os = "linux")]
        {
            tracing::info!(port = args.vsock_port, "listening on vsock");
            serve_vsock(server, args.vsock_port).await?;
        }
        #[cfg(not(target_os = "linux"))]
        {
            anyhow::bail!(
                "vsock transport is only implemented for Linux guests in M1; \
                 use --unix-socket for local development on this platform"
            );
        }
    }

    Ok(())
}

#[cfg(target_os = "linux")]
async fn serve_vsock(server: tonic::transport::server::Router, port: u32) -> anyhow::Result<()> {
    // NOTE: this requires the `vsock` crate's async listener and a kernel
    // with virtio-vsock support (i.e. running inside a real VM guest, not
    // this dev container). Wired here so the production path is complete;
    // exercised for real in the M1 acceptance test against a booted guest
    // (see milestones/M1-linux-runtime.md's test strategy), not in this
    // sandbox's `cargo test`.
    use omnia_agent::vsock_transport::VsockConn;
    use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

    let addr = VsockAddr::new(VMADDR_CID_ANY, port);
    let mut listener = VsockListener::bind(addr)?;
    let incoming = tokio_stream::wrappers::ReceiverStream::new({
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, _addr)) => {
                        if tx
                            .send(Ok::<_, std::io::Error>(VsockConn(stream)))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "vsock accept error");
                    }
                }
            }
        });
        rx
    });

    server.serve_with_incoming(incoming).await?;
    Ok(())
}
