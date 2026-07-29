/// The guest lifecycle state machine from docs/06-lifecycle-memory.md.
/// Deliberately has zero Virtualization.framework/XPC dependencies so its
/// transition logic can be unit-tested in isolation from a real VM — see
/// `GuestLifecycleControllerTests`. `LinuxRuntime` (M1) and `WinRuntime` (M3)
/// each provide a `GuestRuntime` conformance; this type owns none of the
/// actual VM mechanics, only the state transitions and timing policy.
public enum GuestState: Equatable, Sendable {
    case stopped
    case running
    case suspending
    case suspended
    case resuming
}

public enum GuestKind: String, Sendable {
    case linux
    case windows
}

/// The actual VM mechanics a runtime (LinuxRuntime, WinRuntime) must provide.
/// `coldBoot` is only ever called once per guest lifetime in normal
/// operation (first-ever setup, or after an explicit user "Reset guest") —
/// everyday cycling is entirely resume/suspend, per docs/06.
public protocol GuestRuntime: Sendable {
    func coldBoot() async throws
    func resume() async throws
    func suspend() async throws
}

public enum GuestLifecycleError: Error, Sendable {
    case runtimeFailure(String)
}

/// Owns one guest's state machine end to end: `EnsureRunning` (called by the
/// XPC service on behalf of the CLI/app-wrapper/File Provider extension),
/// the idle-suspend countdown, and serializing concurrent callers so two
/// simultaneous `ensureRunning()` calls don't race into duplicate cold
/// boots. One instance per guest (Linux, Windows) — see docs/01-architecture.md.
public actor GuestLifecycleController {
    public private(set) var state: GuestState = .stopped

    private let kind: GuestKind
    private let runtime: GuestRuntime
    private let idleTimeout: Duration
    private var idleTask: Task<Void, Never>?

    /// Callers blocked on ensureRunning() while a resume/boot/suspend is
    /// already in flight for this guest — resolved once that operation
    /// settles into `.running` (or fails).
    private var runningWaiters: [CheckedContinuation<Void, Error>] = []

    public init(kind: GuestKind, runtime: GuestRuntime, idleTimeout: Duration = .seconds(90)) {
        self.kind = kind
        self.runtime = runtime
        self.idleTimeout = idleTimeout
    }

    /// Entry point for launching any app / opening any shell / mounting any
    /// drive against this guest. Resumes from `.suspended`, cold-boots from
    /// `.stopped`, waits out an in-flight `.resuming`/`.suspending`, and is a
    /// no-op if already `.running`. Cancels the idle-suspend countdown.
    public func ensureRunning() async throws {
        cancelIdleTimer()

        switch state {
        case .running:
            return

        case .resuming:
            try await waitUntilRunning()

        case .suspending:
            // The in-flight suspend must be allowed to finish (interrupting
            // a state save risks a corrupt snapshot, per docs/06) — queue
            // behind it, then immediately resume once it lands in
            // `.suspended`.
            try await waitUntilSuspendedThenResume()

        case .stopped:
            try await performColdBoot()

        case .suspended:
            try await performResume()
        }
    }

    /// Called by the agent-event watcher (WatchEvents' WindowCountChanged,
    /// per agent.proto) when the visible app-window count for this guest
    /// transitions to zero. Starts the idle-suspend countdown.
    public func onLastWindowClosed() {
        guard state == .running else { return }
        scheduleIdleTimer()
    }

    /// Called whenever a new window/session opens — cancels any pending
    /// idle-suspend countdown so a quick app-switch doesn't trigger a
    /// suspend/resume cycle.
    public func onActivity() {
        cancelIdleTimer()
    }

    /// Called by the runtime when the underlying VM stops outside the state
    /// machine's control (guest poweroff/crash, VZ runtime error). Resets to
    /// `.stopped` so the next `ensureRunning()` cold-boots instead of
    /// handing callers a dead guest, and fails any queued waiters.
    public func noteGuestStopped() {
        cancelIdleTimer()
        state = .stopped
        resolveRunningWaiters(.failure(GuestLifecycleError.runtimeFailure("guest stopped unexpectedly")))
    }

    /// Power-user override (`omnia suspend`, docs/08-cli.md) — bypasses the
    /// idle timer and suspends immediately.
    public func forceSuspend() async throws {
        cancelIdleTimer()
        guard state == .running else { return }
        try await performSuspend()
    }

    // MARK: - Private

    private func performColdBoot() async throws {
        state = .running // optimistic: a second concurrent caller sees
        // `.running` and returns immediately rather than racing a second
        // cold boot. If coldBoot() throws below we roll back to `.stopped`
        // and fail every queued waiter, which is the correct outcome for a
        // failed first-ever setup.
        do {
            try await runtime.coldBoot()
            resolveRunningWaiters(.success(()))
        } catch {
            state = .stopped
            resolveRunningWaiters(.failure(error))
            throw error
        }
    }

    private func performResume() async throws {
        state = .resuming
        do {
            try await runtime.resume()
            state = .running
            resolveRunningWaiters(.success(()))
        } catch {
            // Leave state as `.resuming` is unsafe (nothing would ever
            // retry) — fall back to `.suspended` so a subsequent
            // ensureRunning() attempts a fresh resume rather than hanging
            // forever behind a dead state.
            state = .suspended
            resolveRunningWaiters(.failure(error))
            throw error
        }
    }

    private func performSuspend() async throws {
        state = .suspending
        do {
            try await runtime.suspend()
            state = .suspended
        } catch {
            // A failed suspend leaves the guest's real state ambiguous (the
            // runtime may or may not have actually paused/saved). Falling
            // back to `.running` is the safer assumption — it keeps the
            // guest usable rather than stranding it in `.suspending` — but
            // this must be revisited with real failure-mode testing in M4
            // rather than treated as correct-by-construction.
            state = .running
            throw error
        }
    }

    private func scheduleIdleTimer() {
        cancelIdleTimer()
        idleTask = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            try? await self.performSuspend()
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func waitUntilRunning() async throws {
        try await withCheckedThrowingContinuation { continuation in
            runningWaiters.append(continuation)
        }
    }

    private func waitUntilSuspendedThenResume() async throws {
        // Simplification for M1: poll rather than a dedicated suspended-
        // waiter list, since suspend is expected to complete in ~1-3s
        // (docs/02/03) and this keeps the controller's waiter bookkeeping
        // to a single list. Revisit if polling proves too coarse once real
        // suspend-latency numbers are in from M1/M3's acceptance testing.
        while state == .suspending {
            try await Task.sleep(for: .milliseconds(50))
        }
        if state == .suspended {
            try await performResume()
        } else if state == .running {
            return
        }
    }

    private func resolveRunningWaiters(_ result: Result<Void, Error>) {
        let waiters = runningWaiters
        runningWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
