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
final class LinuxRuntime: NSObject, GuestRuntime, @unchecked Sendable {
    /// agent.proto's fixed control-channel vsock port (see
    /// guest-agent/src/main.rs's --vsock-port default).
    static let controlPort: UInt32 = 5151

    /// Fired (on the VM's queue) when the VM stops outside our own
    /// suspend flow — guest poweroff/crash or a VZ runtime error. Wired by
    /// VMDService to reset the lifecycle state machine.
    var onUnexpectedStop: (@Sendable () -> Void)?

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
        super.init()
    }

    /// Whether the running VM has a vsock device to bridge — used by
    /// VMDService before wiring up a `VsockControlProxy`.
    func hasVsockDevice() -> Bool {
        queue.sync {
            virtualMachine?.socketDevices.first is VZVirtioSocketDevice
        }
    }

    /// Opens a guest vsock connection on `port`, hopping to the VM's queue
    /// first — VZ device calls must happen on the queue the VM is bound to.
    /// Used by `VsockControlProxy` to bridge the agent.proto control channel
    /// out to a local UDS the CLI/app can connect to (see
    /// VMDService.controlSocketPath).
    func connectControlChannel(
        port: UInt32,
        completion: @escaping @Sendable (Result<VZVirtioSocketConnection, any Error>) -> Void
    ) {
        queue.async {
            guard let device = self.virtualMachine?.socketDevices.first as? VZVirtioSocketDevice else {
                completion(.failure(LinuxRuntimeError.notRunning))
                return
            }
            device.connect(toPort: port, completionHandler: completion)
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
        // vm.start returning only means the vCPUs are executing — the guest
        // still has a full kernel+userspace boot ahead of it. "Running"
        // must mean "the agent answers on vsock" (milestone M1 task #4's
        // handshake), or every caller immediately races the boot.
        do {
            try await waitForAgentReady(timeout: .seconds(90))
        } catch {
            // Don't leave a half-booted zombie VM behind a `.stopped`
            // state — tear it down before failing the boot.
            await forceStop()
            throw error
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
        // The agent (and its vsock listener) come back as part of the
        // restored memory image, so this normally succeeds on the first
        // probe — it's a cheap correctness check, not a boot wait.
        try await waitForAgentReady(timeout: .seconds(15))
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

        // A stable machine identity, persisted on first boot. Without this
        // every VZVirtualMachineConfiguration gets a fresh random
        // VZGenericMachineIdentifier — and restoring a snapshot into a VM
        // whose identifier differs from the one it was saved with fails
        // with VZErrorDomain code 12 ("invalid argument").
        let platform = VZGenericPlatformConfiguration()
        let machineIDPath = imagePath.appendingPathComponent("machine-id")
        if let data = try? Data(contentsOf: machineIDPath),
            let persisted = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = persisted
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: machineIDPath)
        }
        config.platform = platform

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
        // Same story as the machine identifier above: the default MAC is
        // random per configuration, and snapshot restore rejects a config
        // whose devices don't match the saved ones ("invalid argument").
        // Persist the first boot's MAC and reuse it forever.
        let macPath = imagePath.appendingPathComponent("mac-address")
        if let persisted = try? String(contentsOf: macPath, encoding: .utf8),
            let mac = VZMACAddress(string: persisted.trimmingCharacters(in: .whitespacesAndNewlines)) {
            networkConfig.macAddress = mac
        } else {
            try networkConfig.macAddress.string.write(to: macPath, atomically: true, encoding: .utf8)
        }
        config.networkDevices = [networkConfig]

        // console=hvc0 on the kernel cmdline is the virtio console serial
        // port; capture it to a file — the guest's boot log is the primary
        // debugging tool for image problems. (A bare
        // VZVirtioConsoleDeviceConfiguration fails validation: it requires
        // at least one attached port.)
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = try VZFileSerialPortAttachment(
            url: imagePath.appendingPathComponent("console.log"),
            append: false
        )
        config.serialPorts = [serialPort]

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
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        vm.delegate = self
        return vm
    }

    /// Repeatedly probes the agent's vsock control port until a connection
    /// succeeds. A successful connect proves the agent's listener is up —
    /// a full gRPC `Hello` round trip would be an even stronger check, but
    /// vmd has no gRPC client dependency (the CLI/app talk to the agent
    /// directly, by design) and listener-up is sufficient for M1.
    private func waitForAgentReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                try await probeAgent()
                return
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw LinuxRuntimeError.agentNeverBecameReady
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func probeAgent() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let device = self.virtualMachine?.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: LinuxRuntimeError.notRunning)
                    return
                }
                device.connect(toPort: Self.controlPort) { result in
                    switch result {
                    case .success(let connection):
                        connection.close()
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func forceStop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let vm = self.virtualMachine else {
                    continuation.resume()
                    return
                }
                vm.stop { _ in
                    self.virtualMachine = nil
                    continuation.resume()
                }
            }
        }
    }
}

extension LinuxRuntime: VZVirtualMachineDelegate {
    // Both callbacks arrive on the VM's queue. They fire for
    // guest-initiated stops (poweroff, panic) and runtime failures — NOT
    // for our own programmatic vm.stop() calls in suspend()/forceStop().
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        self.virtualMachine = nil
        onUnexpectedStop?()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        self.virtualMachine = nil
        onUnexpectedStop?()
    }
}

enum LinuxRuntimeError: Error {
    case missingSnapshot
    case notRunning
    case agentNeverBecameReady
}
