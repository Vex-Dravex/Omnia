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
    private let vsockDevice: VZVirtioSocketDevice
    private let port: UInt32
    private let socketPath: String
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(vsockDevice: VZVirtioSocketDevice, port: UInt32, socketPath: String) {
        self.vsockDevice = vsockDevice
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

        vsockDevice.connect(toPort: port) { result in
            switch result {
            case .success(let connection):
                let vsockFD = connection.fileDescriptor
                Self.pump(from: clientFD, to: vsockFD)
                Self.pump(from: vsockFD, to: clientFD)
            case .failure:
                close(clientFD)
            }
        }
    }

    /// One-directional byte pump. Two of these (in opposite directions) make
    /// up a full-duplex relay for one accepted connection.
    private static func pump(from source: Int32, to destination: Int32) {
        let queue = DispatchQueue(label: "com.omnia.vmd.vsockproxy.pump")
        queue.async {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { ptr in
                    read(source, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                var written = 0
                while written < n {
                    let w = buffer.withUnsafeBytes { ptr in
                        write(destination, ptr.baseAddress!.advanced(by: written), n - written)
                    }
                    if w <= 0 { break }
                    written += w
                }
            }
            close(source)
            close(destination)
        }
    }
}
