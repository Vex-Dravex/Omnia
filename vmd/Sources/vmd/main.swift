import Foundation
import OmniaVMDCore

/// Entry point for `com.omnia.vmd`, run as a per-user LaunchAgent (see
/// docs/01-architecture.md's process table and docs/10-security-distribution.md
/// for the eventual launchd plist / signing requirements — not yet written;
/// this file assumes it's being run directly during development).
final class VMDXPCDelegate: NSObject, NSXPCListenerDelegate {
    private let service = VMDService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: VMDXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

// The vsock<->UDS relay writes into sockets that peers can reset at any
// moment (a gRPC client aborting, a guest going away). Without this, the
// resulting SIGPIPE kills the whole daemon — which in dev testing showed
// up as vmd silently vanishing mid-session.
signal(SIGPIPE, SIG_IGN)

let delegate = VMDXPCDelegate()
let listener = NSXPCListener(machServiceName: VMDXPCServiceName.value)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
