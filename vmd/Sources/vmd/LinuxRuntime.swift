import Foundation
import Virtualization
import OmniaVMDCore

/// Wraps a `VZVirtualMachine` running the Linux guest image, per
/// docs/02-linux-runtime.md's configuration table. Conforms to
/// `GuestRuntime` (OmniaVMDCore) so `GuestLifecycleController` drives it
/// through the same state machine used for the Windows runtime (M3).
///
/// NOT YET BUILD-VERIFIED — see this repo's top-level BUILDING.md. The
/// biggest open question for whoever picks this up in Xcode: confirm the
/// exact `VZLinuxBootLoader` vs `VZEFIBootLoader` choice against the actual
/// image produced by tools/build-linux-image (M1's task #3 notes this same
/// open decision).
final class LinuxRuntime: GuestRuntime, @unchecked Sendable {
    private let imagePath: URL
    private let snapshotPath: URL
    private let auxiliaryStoragePath: URL

    /// `VZVirtualMachine` is queue-bound: every call on it (and on its
    /// devices) must happen on the serial queue it was created with. All
    /// access to `virtualMachine` is confined to `queue` — VZ completion
    /// handlers already arrive on it — which is what justifies the
    /// @unchecked Sendable above despite the mutable stored property.
    private var virtualMachine: VZVirtualMachine?
    private let queue = DispatchQueue(label: "com.omnia.vmd.linuxruntime")

    init(imagePath: URL, snapshotPath: URL, auxiliaryStoragePath: URL) {
        self.imagePath = imagePath
        self.snapshotPath = snapshotPath
        self.auxiliaryStoragePath = auxiliaryStoragePath
    }

    /// The running VM's vsock device, used by `VsockControlProxy` to bridge
    /// the agent.proto control channel out to a local UDS the CLI/app can
    /// connect to (see VMDService.controlSocketPath). nil whenever the
    /// guest isn't `.running`.
    func currentVsockDevice() -> VZVirtioSocketDevice? {
        queue.sync {
            virtualMachine?.socketDevices.first as? VZVirtioSocketDevice
        }
    }

    // MARK: - GuestRuntime

    func coldBoot() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let vm: VZVirtualMachine
                do {
                    vm = try self.makeVirtualMachine()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                vm.start { result in
                    switch result {
                    case .success:
                        self.virtualMachine = vm
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func resume() async throws {
        guard FileManager.default.fileExists(atPath: snapshotPath.path) else {
            // No snapshot on disk yet (shouldn't happen if the state
            // machine only calls resume() from `.suspended`, but fail
            // loudly rather than silently cold-booting and masking a bug
            // in the caller).
            throw LinuxRuntimeError.missingSnapshot
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let vm: VZVirtualMachine
                do {
                    vm = try self.makeVirtualMachine()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                vm.restoreMachineStateFrom(url: self.snapshotPath) { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    vm.resume { result in
                        switch result {
                        case .success:
                            self.virtualMachine = vm
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    func suspend() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let vm = self.virtualMachine else {
                    continuation.resume(throwing: LinuxRuntimeError.notRunning)
                    return
                }
                // saveMachineStateTo requires the VM to be paused first —
                // saving a running VM is rejected by the framework.
                vm.pause { result in
                    switch result {
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .success:
                        vm.saveMachineStateTo(url: self.snapshotPath) { error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            vm.stop { error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    self.virtualMachine = nil
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Configuration (docs/02-linux-runtime.md's table)

    private func makeVirtualMachine() throws -> VZVirtualMachine {
        let config = VZVirtualMachineConfiguration()

        // TODO(M1): finalize kernel/initrd extraction from the built image
        // vs. VZEFIBootLoader — tracked as an open decision in
        // milestones/M1-linux-runtime.md task #3.
        let bootLoader = VZLinuxBootLoader(kernelURL: imagePath.appendingPathComponent("vmlinuz"))
        bootLoader.initialRamdiskURL = imagePath.appendingPathComponent("initramfs.img")
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw"
        config.bootLoader = bootLoader

        let physicalCores = ProcessInfo.processInfo.processorCount
        config.cpuCount = min(4, max(1, physicalCores))

        // Ceiling only — actual usage governed by the balloon controller
        // (docs/06-lifecycle-memory.md, implemented in M4). M1 sets a fixed
        // ceiling and configures the balloon device but does not yet run
        // the inflate/deflate policy loop.
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        config.memorySize = min(16 * 1024 * 1024 * 1024, totalMemory * 3 / 4)

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: imagePath.appendingPathComponent("rootfs.img"), readOnly: false)
        let diskConfig = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        config.storageDevices = [diskConfig]

        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        networkConfig.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkConfig]

        let consoleConfig = VZVirtioConsoleDeviceConfiguration()
        config.consoleDevices = [consoleConfig]

        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Carries the agent.proto control channel (docs/protocols/agent.proto).
        let vsockConfig = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsockConfig]

        // Headless per docs/02 — Weston composites offscreen; nothing here
        // is shown to the user unless desktop mode (M7) attaches a
        // VZVirtualMachineView explicitly.

        try config.validate()
        // Bind the VM to our serial queue — the queue-less initializer
        // binds to the main queue, which is not where we drive it from.
        return VZVirtualMachine(configuration: config, queue: queue)
    }
}

enum LinuxRuntimeError: Error {
    case missingSnapshot
    case notRunning
}
