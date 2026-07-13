import Foundation
import GRPC
import NIOCore
import NIOPosix

/// Drives an `OpenShell` session (agent.proto) against a guest's control
/// socket — the implementation behind `omnia shell` / `omnia linux [cmd...]`
/// / `omnia win [cmd...]` (docs/08-cli.md).
///
/// VERIFY-ON-BUILD: this is the single riskiest file in the CLI. It's
/// written against grpc-swift 1.x's async/await client API from memory —
/// exact generated symbol names (`Omnia_Agent_V1_OmniaAgentAsyncClient`,
/// `makeOpenShellCall`, etc.) depend on what `protoc-gen-grpc-swift`
/// actually emits (see scripts/generate-swift-proto.sh) and on the
/// grpc-swift version resolved by SwiftPM. Run `scripts/generate-swift-proto.sh`
/// then `swift build` and reconcile this file against the real generated
/// signatures before trusting it further — treat every grpc-swift call
/// below as a best-effort sketch, not a verified contract.
enum ShellSession {
    /// Runs `command` (or an interactive shell if empty) over the guest's
    /// control socket at `socketPath`, relaying the terminal's stdin/stdout
    /// and propagating the guest process's real exit code as this process's
    /// own exit code, per docs/08-cli.md's "composable in Mac shell
    /// scripts/pipelines" requirement.
    static func run(socketPath: String, command: [String], guestOS: Omnia_Agent_V1_GuestOs) async throws -> Int32 {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let channel = try GRPCChannelPool.with(
            target: .unixDomainSocket(socketPath),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )
        defer { try? channel.close().wait() }

        let client = Omnia_Agent_V1_OmniaAgentAsyncClient(channel: channel)

        let isInteractive = command.isEmpty
        let (cols, rows) = currentTerminalSize()
        if isInteractive {
            enableRawMode()
        }
        defer {
            if isInteractive { restoreTerminalMode() }
        }

        let call = client.makeOpenShellCall()

        try await call.requestStream.send(.with {
            $0.open = .with {
                $0.targetShell = guestOS
                $0.command = command
                $0.initialCols = UInt32(cols)
                $0.initialRows = UInt32(rows)
            }
        })

        // Forward local stdin to the guest process. Only meaningful for an
        // interactive session — a one-shot `omnia linux <cmd>` has no stdin
        // to relay and this task simply sees EOF immediately.
        let stdinTask = Task {
            let stdin = FileHandle.standardInput
            while true {
                let data = stdin.availableData
                if data.isEmpty { break }
                try? await call.requestStream.send(.with { $0.stdinChunk = data })
            }
            try? await call.requestStream.finish()
        }

        var exitCode: Int32 = -1
        for try await output in call.responseStream {
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

        stdinTask.cancel()
        return exitCode
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
