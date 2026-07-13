//! Real client-server round trip: starts the actual `AgentService` behind a
//! real tonic `Server` on a Unix domain socket (standing in for vsock, which
//! this dev sandbox has no device for — see src/main.rs's `--unix-socket`
//! flag, which exists for exactly this reason) and drives it with the real
//! generated gRPC client, not by calling service methods directly in-process.
//! This is the closest this environment can get to the M1 acceptance
//! criteria in milestones/M1-linux-runtime.md without a booted VM guest.

use futures::StreamExt;
use hyper_util::rt::TokioIo;
use omnia_agent::proto::omnia_agent_client::OmniaAgentClient;
use omnia_agent::proto::omnia_agent_server::OmniaAgentServer;
use omnia_agent::proto::{shell_input, shell_output, GuestOs, HelloRequest, ShellInput, ShellOpen};
use omnia_agent::service::AgentService;
use tokio::net::UnixStream;
use tonic::transport::{Endpoint, Server, Uri};

async fn start_test_server() -> (tonic::transport::Channel, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket_path = dir.path().join("omnia-agent-test.sock");

    let listener = tokio::net::UnixListener::bind(&socket_path).expect("bind uds");
    let incoming = tokio_stream::wrappers::UnixListenerStream::new(listener);

    tokio::spawn(async move {
        Server::builder()
            .add_service(OmniaAgentServer::new(AgentService::new()))
            .serve_with_incoming(incoming)
            .await
            .expect("server should run cleanly");
    });

    // Give the listener a moment to be ready to accept.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    let socket_path_for_connector = socket_path.clone();
    let channel = Endpoint::from_static("http://[::]:50051")
        .connect_with_connector(tower::service_fn(move |_: Uri| {
            let socket_path = socket_path_for_connector.clone();
            async move {
                let stream = UnixStream::connect(socket_path).await?;
                Ok::<_, std::io::Error>(TokioIo::new(stream))
            }
        }))
        .await
        .expect("client should connect over uds");

    (channel, dir)
}

#[tokio::test]
async fn hello_round_trips_over_a_real_grpc_connection() {
    let (channel, _dir) = start_test_server().await;
    let mut client = OmniaAgentClient::new(channel);

    let resp = client
        .hello(HelloRequest {
            host_protocol_version: "0.1.0".to_string(),
        })
        .await
        .expect("hello RPC should succeed")
        .into_inner();

    assert_eq!(resp.guest_os, GuestOs::Linux as i32);
    assert!(resp.ready);
}

#[tokio::test]
async fn open_shell_runs_a_one_shot_command_and_streams_real_output() {
    let (channel, _dir) = start_test_server().await;
    let mut client = OmniaAgentClient::new(channel);

    let (tx, rx) = tokio::sync::mpsc::channel::<ShellInput>(4);
    tx.send(ShellInput {
        payload: Some(shell_input::Payload::Open(ShellOpen {
            target_shell: GuestOs::Linux as i32,
            command: vec!["/bin/echo".to_string(), "integration-test-ok".to_string()],
            initial_cols: 80,
            initial_rows: 24,
        })),
    })
    .await
    .expect("send ShellOpen");
    drop(tx); // no stdin needed for a one-shot `echo`

    let request_stream = tokio_stream::wrappers::ReceiverStream::new(rx);
    let mut response_stream = client
        .open_shell(request_stream)
        .await
        .expect("open_shell RPC should succeed")
        .into_inner();

    let mut stdout = Vec::new();
    let mut exit_code = None;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);

    while tokio::time::Instant::now() < deadline {
        let next =
            tokio::time::timeout(std::time::Duration::from_secs(2), response_stream.next()).await;
        let Ok(Some(msg)) = next else { break };
        let msg = msg.expect("shell output message should not be an error");
        match msg.payload {
            Some(shell_output::Payload::StdoutChunk(chunk)) => stdout.extend_from_slice(&chunk),
            Some(shell_output::Payload::StderrChunk(chunk)) => {
                panic!(
                    "unexpected stderr from `echo`: {}",
                    String::from_utf8_lossy(&chunk)
                )
            }
            Some(shell_output::Payload::ExitCode(code)) => {
                exit_code = Some(code);
                break;
            }
            None => {}
        }
    }

    let stdout_text = String::from_utf8_lossy(&stdout);
    assert!(
        stdout_text.contains("integration-test-ok"),
        "expected echoed output over the real PTY+gRPC round trip, got: {stdout_text:?}"
    );
    assert_eq!(
        exit_code,
        Some(0),
        "expected the real guest process's exit code to propagate to the host"
    );
}
