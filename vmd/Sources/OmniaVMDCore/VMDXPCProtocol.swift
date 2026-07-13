import Foundation

/// The XPC surface vmd exposes to Omnia.app, the `omnia` CLI, and (from M5)
/// the File Provider extension — see docs/01-architecture.md's process
/// table and docs/08-cli.md. Kept deliberately small for M1: guest lifecycle
/// control plus a socket handoff for talking directly to omnia-agent.
///
/// Why a socket handoff instead of proxying every RPC byte through XPC:
/// `agent.proto`'s RPCs (especially the bidirectional-streaming `OpenShell`)
/// are already a well-defined gRPC contract — reimplementing that same
/// traffic shape again as a second XPC-specific protocol would be pure
/// duplication. Instead, vmd bridges the guest's vsock control channel to a
/// local Unix domain socket per running guest (`VsockControlProxy`) once
/// it's up, and hands the CLI/app-wrapper that socket path so they can speak
/// agent.proto's real generated gRPC client directly against it.
@objc public protocol VMDXPCProtocol {
    /// Ensures the given guest is running (cold boot from `.stopped`, resume
    /// from `.suspended`, or a no-op if already `.running`) — see
    /// docs/06-lifecycle-memory.md. Blocks (from the caller's perspective)
    /// until the guest is actually `.running` or the attempt has failed.
    func ensureRunning(guest: String, reply: @escaping (Bool, String?) -> Void)

    /// Path to the local UDS currently bridging to `guest`'s vsock control
    /// channel, or nil (with an error string) if the guest isn't running.
    /// Callers should call `ensureRunning` first.
    func controlSocketPath(guest: String, reply: @escaping (String?, String?) -> Void)

    /// `omnia status` (docs/08-cli.md) — guest identifier -> state string
    /// (one of "stopped"/"running"/"suspending"/"suspended"/"resuming").
    func status(reply: @escaping ([String: String]) -> Void)

    /// Power-user override (`omnia suspend`, docs/08-cli.md).
    func forceSuspend(guest: String, reply: @escaping (Bool, String?) -> Void)
}

/// Mach service name vmd registers under as a LaunchAgent. Shared with the
/// CLI/app so both sides name the same service without hardcoding the
/// string twice.
public enum VMDXPCServiceName {
    public static let value = "com.omnia.vmd"
}
