import Foundation
import OmniaVMDCore

/// Thin async wrapper around the XPC connection to `com.omnia.vmd` — see
/// vmd/Sources/OmniaVMDCore/VMDXPCProtocol.swift for the protocol this talks
/// to. Every `omnia` subcommand that touches a guest goes through this.
struct VMDClientError: Error, CustomStringConvertible {
    let description: String
}

final class VMDClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: VMDXPCServiceName.value, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: VMDXPCProtocol.self)
        connection.invalidationHandler = {
            FileHandle.standardError.write(
                Data("omnia: lost connection to vmd — is Omnia.app running?\n".utf8))
        }
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    private var proxy: VMDXPCProtocol {
        get throws {
            guard let proxy = connection.remoteObjectProxy as? VMDXPCProtocol else {
                throw VMDClientError(description: "could not reach vmd (is it running?)")
            }
            return proxy
        }
    }

    /// Resumes/cold-boots `guest` as needed and waits until it's actually
    /// running. Shows a one-line status message while waiting, per
    /// docs/08-cli.md's "Resuming Linux…" UX note.
    func ensureRunning(guest: GuestKind) async throws {
        let proxy = try proxy
        FileHandle.standardError.write(Data("Resuming \(guest.rawValue)...\n".utf8))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.ensureRunning(guest: guest.rawValue) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VMDClientError(description: error ?? "unknown error"))
                }
            }
        }
    }

    func controlSocketPath(guest: GuestKind) async throws -> String {
        let proxy = try proxy
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            proxy.controlSocketPath(guest: guest.rawValue) { path, error in
                if let path {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(throwing: VMDClientError(description: error ?? "unknown error"))
                }
            }
        }
    }

    func status() async throws -> [GuestKind: String] {
        let proxy = try proxy
        let raw: [String: String] = await withCheckedContinuation { continuation in
            proxy.status { result in
                continuation.resume(returning: result)
            }
        }
        var result: [GuestKind: String] = [:]
        for (key, value) in raw {
            if let kind = GuestKind(rawValue: key) {
                result[kind] = value
            }
        }
        return result
    }
}
