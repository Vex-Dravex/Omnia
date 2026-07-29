import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Drives an `OpenShell` session (agent.proto) against a guest's control
/// socket — the implementation behind `omnia shell` / `omnia linux [cmd...]`
/// / `omnia win [cmd...]` (docs/08-cli.md).
///
/// Written against gRPC Swift 2 (GRPCCore + NIO HTTP/2 transport over a
/// Unix domain socket). The generated client surface this uses lives in
/// Generated/agent.grpc.swift — regenerate via scripts/generate-swift-proto.sh
/// whenever docs/protocols/agent.proto changes.
enum ShellSession {
    /// Runs `command` (or an interactive shell if empty) over the guest's
    /// control socket at `socketPath`, relaying the terminal's stdin/stdout
    /// and propagating the guest process's real exit code as this process's
    /// own exit code, per docs/08-cli.md's "composable in Mac shell
    /// scripts/pipelines" requirement.
    static func run(socketPath: String, command: [String], guestOS: Omnia_Agent_V1_GuestOS) async throws -> Int32 {
        let isInteractive = command.isEmpty
        let (cols, rows) = currentTerminalSize()
        if isInteractive {
            enableRawMode()
        }
        defer {
            if isInteractive { restoreTerminalMode() }
        }

        return try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        ) { client in
            let agent = Omnia_Agent_V1_OmniaAgent.Client(wrapping: client)
            return try await agent.openShell { writer in
                try await writer.write(.with {
                    $0.open = .with {
                        $0.targetShell = guestOS
                        $0.command = command
                        $0.initialCols = UInt32(cols)
                        $0.initialRows = UInt32(rows)
                    }
                })
                // Forward local stdin to the guest process. Only meaningful
                // for an interactive session — a one-shot `omnia linux <cmd>`
                // normally has no piped stdin and this loop just waits until
                // the RPC completes and cancels it.
                for await chunk in stdinChunks() {
                    try await writer.write(.with { $0.stdinChunk = chunk })
                }
            } onResponse: { response in
                var exitCode: Int32 = -1
                for try await output in response.messages {
                    switch output.payload {
                    case .stdoutChunk(let chunk):
                        FileHandle.standardOutput.write(chunk)
                    case .stderrChunk(let chunk):
                        FileHandle.standardError.write(chunk)
                    case .exitCode(let code):
                        exitCode = code
                    case .none:
                        break
                    }
                }
                return exitCode
            }
        }
    }

    /// Blocking stdin reads bridged into an AsyncStream on a dedicated
    /// thread, so the request producer above can `for await` chunks without
    /// tying up a cooperative-pool thread on a blocking read. The thread
    /// stays parked on read(2) until EOF or process exit; when the RPC ends
    /// first the stream's consumer is simply cancelled.
    private static func stdinChunks() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let thread = Thread {
                let stdin = FileHandle.standardInput
                while true {
                    let data = stdin.availableData
                    if data.isEmpty { break }
                    continuation.yield(data)
                }
                continuation.finish()
            }
            thread.name = "omnia-stdin-relay"
            thread.start()
        }
    }

    private static func currentTerminalSize() -> (cols: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private static var savedTermios = termios()

    /// Puts the local terminal into raw mode for the duration of an
    /// interactive session so keystrokes (including control characters)
    /// pass through to the guest shell unmodified, matching `ssh`'s
    /// behavior. Restored by `restoreTerminalMode()`.
    private static func enableRawMode() {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    private static func restoreTerminalMode() {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    }
}
