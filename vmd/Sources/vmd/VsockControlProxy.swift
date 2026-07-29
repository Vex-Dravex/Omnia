import Foundation
import Virtualization

/// Bridges a running guest's vsock control channel (agent.proto, port 5151
/// per guest-agent's default) to a local Unix domain socket, so the CLI and
/// app-wrapper processes — which don't have access to the `VZVirtualMachine`
/// instance living inside vmd — can connect a normal gRPC-over-UDS client
/// and speak agent.proto directly, without every byte being relayed through
/// XPC. See VMDXPCProtocol.swift's doc comment for the rationale.
///
/// FIRST DRAFT: the byte-relay loop below is written for correctness of
/// shape (accept -> vsock connect -> bidirectional pump) but its
/// backpressure/error-recovery behavior has not been exercised against a
/// real vsock connection (no Swift toolchain in the environment that wrote
/// this — see BUILDING.md). Treat the `pump` function as the first thing to
/// stress-test once this builds on a real Mac against a real guest.
final class VsockControlProxy {
    /// Opens a vsock connection to the guest on the given port. Injected by
    /// the runtime (see LinuxRuntime.connectControlChannel) so the hop onto
    /// the VM's queue — required for VZ device calls — happens there, not
    /// here.
    typealias VsockConnector = @Sendable (
        _ port: UInt32,
        _ completion: @escaping @Sendable (Result<VZVirtioSocketConnection, any Error>) -> Void
    ) -> Void

    private let connectVsock: VsockConnector
    private let port: UInt32
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Session-activity callbacks, driving M1's idle-suspend policy
    /// (milestones/M1 task #8): every relayed connection counts as an
    /// active session; `onAllSessionsClosed` fires when the count returns
    /// to zero (start the idle countdown), `onSessionActive` on 0 -> 1
    /// (cancel it).
    var onSessionActive: (@Sendable () -> Void)?
    var onAllSessionsClosed: (@Sendable () -> Void)?

    private let sessionLock = NSLock()
    private var activeSessions = 0

    private func sessionOpened() {
        sessionLock.lock()
        activeSessions += 1
        let becameActive = activeSessions == 1
        sessionLock.unlock()
        if becameActive { onSessionActive?() }
    }

    private func sessionClosed() {
        sessionLock.lock()
        activeSessions -= 1
        let becameIdle = activeSessions == 0
        sessionLock.unlock()
        if becameIdle { onAllSessionsClosed?() }
    }

    init(port: UInt32, socketPath: String, connectVsock: @escaping VsockConnector) {
        self.connectVsock = connectVsock
        self.port = port
        self.socketPath = socketPath
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                for (i, byte) in pathBytes.prefix(103).enumerated() {
                    cptr[i] = CChar(bitPattern: byte)
                }
                cptr[min(pathBytes.count, 103)] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        listenerFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenerFD = -1
        unlink(socketPath)
    }

    private func acceptOne() {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }

        connectVsock(port) { result in
            switch result {
            case .success(let connection):
                // Take ownership via dup: VZVirtioSocketConnection closes
                // its fd when it goes away, and nothing retains it beyond
                // this closure — a relay running on the connection's own fd
                // would be cut off at an arbitrary point.
                let vsockFD = dup(connection.fileDescriptor)
                connection.close()
                guard vsockFD >= 0 else {
                    close(clientFD)
                    return
                }
                self.sessionOpened()
                Self.relay(clientFD, vsockFD) { [weak self] in
                    self?.sessionClosed()
                }
            case .failure:
                close(clientFD)
            }
        }
    }

    /// Full-duplex relay for one accepted connection: one pump per
    /// direction. A direction hitting EOF half-closes (shutdown SHUT_WR)
    /// the other side so stream teardown propagates like a real socket
    /// pair; the fds are closed exactly once, after BOTH directions finish
    /// — closing them per-pump would double-close and kill the opposite
    /// direction mid-stream.
    private static func relay(_ a: Int32, _ b: Int32, onFinish: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        pump(from: a, to: b, group: group)
        pump(from: b, to: a, group: group)
        group.notify(queue: .global(qos: .utility)) {
            close(a)
            close(b)
            onFinish()
        }
    }

    /// One-directional byte pump. Two of these (in opposite directions) make
    /// up a full-duplex relay for one accepted connection.
    private static func pump(from source: Int32, to destination: Int32, group: DispatchGroup) {
        let queue = DispatchQueue(label: "com.omnia.vmd.vsockproxy.pump")
        group.enter()
        queue.async {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            outer: while true {
                let n = buffer.withUnsafeMutableBytes { ptr in
                    read(source, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                var written = 0
                while written < n {
                    let w = buffer.withUnsafeBytes { ptr in
                        write(destination, ptr.baseAddress!.advanced(by: written), n - written)
                    }
                    if w <= 0 { break outer }
                    written += w
                }
            }
            shutdown(destination, SHUT_WR)
            group.leave()
        }
    }
}
