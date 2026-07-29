import Foundation
import Virtualization
import OmniaVMDCore

/// Implements `VMDXPCProtocol`, owning one `GuestLifecycleController` +
/// `LinuxRuntime` pair for the Linux guest (M1 scope — a `windows` case is
/// added to `guests` in M3 once `WinRuntime` exists, per
/// docs/06-lifecycle-memory.md's "state machine is per-guest" design; the
/// dictionary-keyed-by-GuestKind shape here is deliberately already generic
/// so that addition is a one-line change, not a rewrite).
final class VMDService: NSObject, VMDXPCProtocol {
    private struct GuestEntry {
        let controller: GuestLifecycleController
        let runtime: LinuxRuntime
        var proxy: VsockControlProxy?
    }

    private var guests: [GuestKind: GuestEntry] = [:]
    private let supportDirectory: URL

    override init() {
        self.supportDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Omnia", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let linuxRuntime = LinuxRuntime(
            imagePath: supportDirectory.appendingPathComponent("linux", isDirectory: true),
            snapshotPath: supportDirectory.appendingPathComponent("linux/snapshot.vzstate"),
            auxiliaryStoragePath: supportDirectory.appendingPathComponent("linux/aux")
        )
        let controller = GuestLifecycleController(kind: .linux, runtime: linuxRuntime)
        // Guest poweroff/crash/VZ failure -> reset the state machine so the
        // next ensureRunning() cold-boots instead of serving a dead guest.
        linuxRuntime.onUnexpectedStop = {
            Task { await controller.noteGuestStopped() }
        }
        guests[.linux] = GuestEntry(controller: controller, runtime: linuxRuntime, proxy: nil)

        // .windows added in M3 (milestones/M3-windows-runtime.md) once
        // WinRuntime exists — see the type comment above.
    }

    // MARK: - VMDXPCProtocol

    func ensureRunning(guest: String, reply: @escaping (Bool, String?) -> Void) {
        guard let kind = GuestKind(rawValue: guest), let entry = guests[kind] else {
            reply(false, "unknown guest: \(guest)")
            return
        }
        Task {
            do {
                try await entry.controller.ensureRunning()
                reply(true, nil)
            } catch {
                reply(false, "\(error)")
            }
        }
    }

    func controlSocketPath(guest: String, reply: @escaping (String?, String?) -> Void) {
        guard let kind = GuestKind(rawValue: guest), var entry = guests[kind] else {
            reply(nil, "unknown guest: \(guest)")
            return
        }
        Task {
            let state = await entry.controller.state
            guard state == .running else {
                reply(nil, "guest \(guest) is not running (state: \(state))")
                return
            }

            let socketsDirectory = supportDirectory.appendingPathComponent("sockets", isDirectory: true)
            try? FileManager.default.createDirectory(at: socketsDirectory, withIntermediateDirectories: true)
            let socketPath = socketsDirectory.appendingPathComponent("\(guest)-control.sock").path

            if entry.proxy == nil {
                guard entry.runtime.hasVsockDevice() else {
                    reply(nil, "guest \(guest) has no vsock device available")
                    return
                }
                let runtime = entry.runtime
                let proxy = VsockControlProxy(port: LinuxRuntime.controlPort, socketPath: socketPath) { port, completion in
                    runtime.connectControlChannel(port: port, completion: completion)
                }
                // M1 idle-suspend policy (milestone task #8): a closed shell
                // session starts the 90s countdown, a new one cancels it.
                // onLastWindowClosed is window-centric naming from docs/06;
                // until RAIL exists (M2), "no active control sessions" is
                // the equivalent signal.
                let controller = entry.controller
                proxy.onSessionActive = {
                    Task { await controller.onActivity() }
                }
                proxy.onAllSessionsClosed = {
                    Task { await controller.onLastWindowClosed() }
                }
                do {
                    try proxy.start()
                    entry.proxy = proxy
                    guests[kind] = entry
                } catch {
                    reply(nil, "failed to start control proxy: \(error)")
                    return
                }
            }

            reply(socketPath, nil)
        }
    }

    func status(reply: @escaping ([String: String]) -> Void) {
        Task {
            var result: [String: String] = [:]
            for (kind, entry) in guests {
                let state = await entry.controller.state
                result[kind.rawValue] = "\(state)"
            }
            reply(result)
        }
    }

    func forceSuspend(guest: String, reply: @escaping (Bool, String?) -> Void) {
        guard let kind = GuestKind(rawValue: guest), let entry = guests[kind] else {
            reply(false, "unknown guest: \(guest)")
            return
        }
        Task {
            do {
                try await entry.controller.forceSuspend()
                reply(true, nil)
            } catch {
                reply(false, "\(error)")
            }
        }
    }
}
