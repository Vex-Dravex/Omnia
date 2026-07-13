import XCTest
@testable import OmniaVMDCore

/// Exercises the state machine from docs/06-lifecycle-memory.md against a
/// fake runtime — no real VM involved, so these are expected to be able to
/// run on any Swift toolchain (unlike LinuxRuntime's tests, which need a
/// real macOS host). NOTE: not yet run — this repo's writing environment has
/// no Swift toolchain at all (see BUILDING.md). Run `swift test` on a Mac as
/// the first verification step for this file.
final class GuestLifecycleControllerTests: XCTestCase {
    actor FakeRuntime: GuestRuntime {
        private(set) var coldBootCount = 0
        private(set) var resumeCount = 0
        private(set) var suspendCount = 0
        var coldBootError: Error?
        var resumeError: Error?
        var suspendDelay: Duration = .zero

        func coldBoot() async throws {
            coldBootCount += 1
            if let coldBootError { throw coldBootError }
        }

        func resume() async throws {
            resumeCount += 1
            if let resumeError { throw resumeError }
        }

        func suspend() async throws {
            if suspendDelay > .zero {
                try await Task.sleep(for: suspendDelay)
            }
            suspendCount += 1
        }
    }

    func testEnsureRunningFromStoppedPerformsColdBoot() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(kind: .linux, runtime: runtime, idleTimeout: .seconds(90))

        try await controller.ensureRunning()

        let state = await controller.state
        XCTAssertEqual(state, .running)
        let count = await runtime.coldBootCount
        XCTAssertEqual(count, 1)
    }

    func testEnsureRunningWhenAlreadyRunningIsANoOp() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(kind: .linux, runtime: runtime, idleTimeout: .seconds(90))
        try await controller.ensureRunning()

        try await controller.ensureRunning()

        let count = await runtime.coldBootCount
        XCTAssertEqual(count, 1, "a second ensureRunning() while already running must not re-boot")
    }

    func testEnsureRunningFromSuspendedResumes() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(kind: .linux, runtime: runtime, idleTimeout: .seconds(90))
        try await controller.ensureRunning() // -> running
        try await controller.forceSuspend() // -> suspended

        try await controller.ensureRunning()

        let state = await controller.state
        XCTAssertEqual(state, .running)
        let resumeCount = await runtime.resumeCount
        XCTAssertEqual(resumeCount, 1)
        let coldBootCount = await runtime.coldBootCount
        XCTAssertEqual(coldBootCount, 1, "resuming from suspended must not cold boot again")
    }

    func testIdleTimerSuspendsAfterLastWindowCloses() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(
            kind: .linux, runtime: runtime, idleTimeout: .milliseconds(50)
        )
        try await controller.ensureRunning()

        await controller.onLastWindowClosed()
        try await Task.sleep(for: .milliseconds(200))

        let state = await controller.state
        XCTAssertEqual(state, .suspended)
        let suspendCount = await runtime.suspendCount
        XCTAssertEqual(suspendCount, 1)
    }

    func testActivityCancelsPendingIdleTimer() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(
            kind: .linux, runtime: runtime, idleTimeout: .milliseconds(50)
        )
        try await controller.ensureRunning()
        await controller.onLastWindowClosed()

        await controller.onActivity()
        try await Task.sleep(for: .milliseconds(200))

        let state = await controller.state
        XCTAssertEqual(state, .running, "activity before the countdown elapses must cancel the suspend")
    }

    func testForceSuspendBypassesIdleTimer() async throws {
        let runtime = FakeRuntime()
        let controller = GuestLifecycleController(kind: .linux, runtime: runtime, idleTimeout: .seconds(90))
        try await controller.ensureRunning()

        try await controller.forceSuspend()

        let state = await controller.state
        XCTAssertEqual(state, .suspended)
    }

    func testFailedColdBootRollsBackToStopped() async throws {
        struct BootFailed: Error {}
        let runtime = FakeRuntime()
        await runtime.setColdBootError(BootFailed())
        let controller = GuestLifecycleController(kind: .linux, runtime: runtime, idleTimeout: .seconds(90))

        do {
            try await controller.ensureRunning()
            XCTFail("expected coldBoot failure to propagate")
        } catch {
            // expected
        }

        let state = await controller.state
        XCTAssertEqual(state, .stopped, "a failed first boot must not strand the guest in a running-ish state")
    }
}

private extension GuestLifecycleControllerTests.FakeRuntime {
    func setColdBootError(_ error: Error) {
        coldBootError = error
    }
}
