import ArgumentParser
import Foundation
import OmniaVMDCore

@main
struct Omnia: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omnia",
        abstract: "Control and use your Omnia Linux/Windows guests.",
        subcommands: [Status.self, Shell.self, Linux.self],
        // Win.self joins this list in M3 once a Windows guest exists —
        // milestones/M3-windows-runtime.md's task list explicitly calls out
        // wiring Windows into this same CLI surface.
        defaultSubcommand: nil
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the current state of each guest."
    )

    func run() async throws {
        let client = VMDClient()
        let status = try await client.status()
        // M1 only ever has .linux populated (see VMDService.init) — the
        // loop is already written generically so M3 adding .windows to
        // VMDService needs no change here.
        for kind in [GuestKind.linux, GuestKind.windows] {
            let state = status[kind] ?? "not configured"
            print("\(kind.rawValue): \(state)")
        }
    }
}

struct Shell: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open an interactive shell, picking the guest OS if more than one is set up."
    )

    func run() async throws {
        let client = VMDClient()
        let status = try await client.status()
        let available = [GuestKind.linux, GuestKind.windows].filter { status[$0] != nil }

        let guest: GuestKind
        switch available.count {
        case 0:
            throw ValidationError("No guests are set up yet. Run Omnia.app's first-run setup first.")
        case 1:
            guest = available[0]
        default:
            guest = try promptForGuest(choices: available)
        }

        let exitCode = try await runShell(guest: guest, command: [])
        throw ExitCode(exitCode)
    }

    private func promptForGuest(choices: [GuestKind]) throws -> GuestKind {
        print("Which guest?")
        for (index, kind) in choices.enumerated() {
            print("  \(index + 1)) \(kind.rawValue)")
        }
        print("> ", terminator: "")
        guard let line = readLine(), let index = Int(line), choices.indices.contains(index - 1) else {
            throw ValidationError("Invalid selection.")
        }
        return choices[index - 1]
    }
}

struct Linux: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a shell in the Linux guest, or run a command non-interactively."
    )

    @Argument(parsing: .captureForPassthrough, help: "Command to run. Omit for an interactive shell.")
    var command: [String] = []

    func run() async throws {
        let exitCode = try await runShell(guest: .linux, command: command)
        throw ExitCode(exitCode)
    }
}

/// Shared by `Shell`/`Linux` (and `Win` once M3 adds it): ensure the guest
/// is running, fetch its control socket from vmd, and drive the session.
func runShell(guest: GuestKind, command: [String]) async throws -> Int32 {
    let client = VMDClient()
    try await client.ensureRunning(guest: guest)
    let socketPath = try await client.controlSocketPath(guest: guest)
    let protoGuestOS: Omnia_Agent_V1_GuestOs = (guest == .linux) ? .linux : .windows
    return try await ShellSession.run(socketPath: socketPath, command: command, guestOS: protoGuestOS)
}
