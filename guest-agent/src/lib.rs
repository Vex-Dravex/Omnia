pub mod mount;
pub mod pty;
pub mod service;
#[cfg(target_os = "linux")]
pub mod vsock_transport;

pub mod proto {
    tonic::include_proto!("omnia.agent.v1");
}
