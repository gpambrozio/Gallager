import Foundation
import GallagerPluginProtocol
import Logging

// Narrowed import: `ClaudeSpyNetworking` also declares `JSONRPCRequest` /
// `JSONRPCResponse` / `JSONRPCError`. We only need `JSONValue` from it, so
// scope the symbol import to that one type to avoid name collisions with
// the sidecar-protocol types from `GallagerPluginProtocol`.
import enum ClaudeSpyNetworking.JSONValue

// MARK: - SidecarSupervisor

/// Owns the lifecycle of one sidecar process (Spec §12).
///
/// - Spawns the child with stdin/stdout piped (JSON-RPC) and stderr piped to
///   a `SidecarLogFile`.
/// - Runs the `initialize` handshake with a 10s deadline.
/// - Heartbeats every 30 s; three consecutive `health` misses → forced restart.
/// - Tracks crashes in a 60 s sliding window; 1/2/3 backoff 1/2/4 s; 4th flips
///   the plugin into `.disabled` with the last 50 stderr lines attached.
/// - On `stop()`, sends `shutdown`, waits 3 s, then SIGTERM, then SIGKILL after
///   another 5 s.
///
/// The abstract `Clock` is injected so tests can swap in a `TestClock` and
/// drive the backoff timing deterministically.
public actor SidecarSupervisor {
    // MARK: - State

    /// Public state surface — the UI maps this onto plugin tiles.
    public enum State: Sendable, Equatable {
        case notStarted
        case starting
        case running
        /// `initialize` RPC failed; no auto-restart until user takes action.
        case failedInit(String)
        /// Process exited unexpectedly; `restartCountInWindow` tracks how
        /// many times this has happened in the current 60s window.
        case crashed(restartCountInWindow: Int)
        /// Crashed too many times — auto-disabled with last stderr context.
        case disabled(reason: String, lastStderr: [String])
    }

    // MARK: - Delegate

    /// Inbound traffic from the sidecar (notifications + requests). The
    /// supervisor wraps the connection's delegate and forwards through, so
    /// `PluginManager` (Task 7) only deals with supervisors.
    public protocol Delegate: AnyObject, Sendable {
        func received(
            notification: JSONRPCNotification,
            from supervisor: SidecarSupervisor
        ) async

        func received(
            request: JSONRPCRequest,
            from supervisor: SidecarSupervisor
        ) async -> JSONRPCResponse

        /// Called whenever the supervisor's `State` transitions. Always
        /// dispatched on the supervisor's actor so observers see consistent
        /// ordering with `state`.
        func stateChanged(
            _ state: State,
            for supervisor: SidecarSupervisor
        ) async
    }

    // MARK: - Tunables

    /// Initial handshake timeout (Spec §12 step 2).
    public static let initializeTimeout: Duration = .seconds(10)
    /// Heartbeat cadence (Spec §12 step 3).
    public static let heartbeatInterval: Duration = .seconds(30)
    /// Per-heartbeat reply timeout. Misses count against the consecutive
    /// strikeout counter.
    public static let heartbeatRPCTimeout: Duration = .seconds(5)
    /// Consecutive heartbeat misses before declaring the sidecar crashed.
    public static let maxHeartbeatMisses = 3
    /// Crash-counting window for backoff decisions (Spec §12).
    public static let crashWindow: Duration = .seconds(60)
    /// SIGTERM grace period after `shutdown` returns or times out.
    public static let stopGracePeriod: Duration = .seconds(3)
    /// Final SIGKILL deadline after SIGTERM is issued.
    public static let stopHardDeadline: Duration = .seconds(5)

    // MARK: - Configuration

    public let pluginID: String
    public let executableURL: URL

    private let env: [String: String]
    private let stateDir: URL
    private let logFile: SidecarLogFile
    private weak var delegate: (any Delegate)?
    private let clock: any Clock<Duration>
    private let logger: Logger

    /// Params passed to the `initialize` RPC during `start()`. Defaults to
    /// an empty `{}` object (used by the EchoSidecar tests, which don't
    /// care about the handshake payload). `PluginManager` overrides this
    /// with `{plugin_root, state_dir, app_version}` per Spec §6.1.
    private let initializeParams: JSONValue

    // MARK: - Mutable state

    public private(set) var state: State = .notStarted
    public private(set) var connection: JSONRPCConnection?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var heartbeatTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var crashTimestamps: [Date] = []
    /// Callers parked inside `waitForProcessExit`. Resumed when the
    /// terminationHandler fires (or `stop()` decides to give up).
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set during `stop()` so the termination handler doesn't trigger a
    /// restart for an intentional exit.
    private var isShuttingDown = false

    /// Bridge object passed to the JSONRPCConnection — kept strongly here so
    /// the connection (which holds it weakly) doesn't drop it mid-run.
    private var bridge: ConnectionBridge?

    // MARK: - Init

    public init(
        pluginID: String,
        executableURL: URL,
        env: [String: String],
        stateDir: URL,
        logFile: SidecarLogFile,
        delegate: any Delegate,
        initializeParams: JSONValue = .object([:]),
        clock: any Clock<Duration> = ContinuousClock(),
        logger: Logger? = nil
    ) {
        self.pluginID = pluginID
        self.executableURL = executableURL
        self.env = env
        self.stateDir = stateDir
        self.logFile = logFile
        self.delegate = delegate
        self.initializeParams = initializeParams
        self.clock = clock
        self.logger = logger ?? Logger(label: "gallager.plugin.supervisor.\(pluginID)")
    }

    // MARK: - Lifecycle

    /// Spawn the child, build the connection, run `initialize`.
    public func start() async throws {
        // From `.disabled` we don't auto-start. Caller must `restart()`
        // explicitly (which resets the crash window) to re-enable.
        switch state {
        case .running,
             .starting:
            return
        case .disabled:
            throw SidecarSupervisorError.disabled
        default:
            break
        }

        await transition(to: .starting)
        isShuttingDown = false

        do {
            try await spawnAndInitialize()
            await transition(to: .running)
            startHeartbeat()
        } catch {
            // Initialize failed — clean up partial state, surface a
            // failed-init state to the delegate, and don't auto-retry.
            await teardownProcess()
            let message = String(describing: error)
            await transition(to: .failedInit(message))
            throw error
        }
    }

    /// Force a fresh start regardless of current state. Resets the crash
    /// counter so a manually-triggered restart isn't penalised.
    public func restart() async throws {
        crashTimestamps.removeAll()
        await stopInternal(reason: .manualRestart)
        try await start()
    }

    /// Send `shutdown`, wait, then SIGTERM, then SIGKILL.
    public func stop() async {
        await stopInternal(reason: .userStop)
    }

    // MARK: - Send (convenience)

    public func send<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        timeout: Duration = .seconds(30)
    ) async throws -> R {
        guard let connection else {
            throw JSONRPCConnectionError.connectionClosed
        }
        return try await connection.send(method: method, params: params, timeout: timeout)
    }

    public func send<P: Encodable & Sendable>(
        method: String,
        params: P,
        timeout: Duration = .seconds(30)
    ) async throws {
        guard let connection else {
            throw JSONRPCConnectionError.connectionClosed
        }
        try await connection.send(method: method, params: params, timeout: timeout)
    }

    // MARK: - Spawn

    private func spawnAndInitialize() async throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let proc = Process()
        proc.executableURL = executableURL
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        var processEnv = ProcessInfo.processInfo.environment
        for (key, value) in env {
            processEnv[key] = value
        }
        proc.environment = processEnv

        // Wire stderr into the rotating log before launch — first bytes
        // arrive as soon as the child writes anything.
        await logFile.attachStderrPipe(stderr)

        // Terminate handler can fire on any thread. Hop onto the actor to
        // mutate state. Capture a weak self so the handler doesn't keep the
        // supervisor alive after callers drop it.
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.processDidExit() }
        }

        try proc.run()

        // Drop parent's copies of child-inherited ends so the reader EOFs when
        // the child exits — otherwise attachStderrPipe's read() wedges forever.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let bridge = ConnectionBridge()
        let connection = JSONRPCConnection(
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading,
            delegate: bridge,
            logger: logger
        )
        bridge.bind(supervisor: self, delegate: delegate)
        await connection.start()

        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        self.connection = connection
        self.bridge = bridge

        // Per Spec §12 step 2: `initialize` with 10s timeout. `PluginManager`
        // passes `{plugin_root, state_dir, app_version}` via `initializeParams`;
        // the supervisor's own unit tests (with the EchoSidecar fixture) leave
        // it at the default `{}` since the echo just round-trips whatever it
        // gets.
        do {
            try await connection.send(
                method: PluginRPCMethod.AppToSidecar.initialize.rawValue,
                params: initializeParams,
                timeout: SidecarSupervisor.initializeTimeout
            )
        } catch {
            throw error
        }
    }

    // MARK: - Termination

    /// Called on the actor when `Process.terminationHandler` fires.
    private func handleTermination() async {
        // Intentional shutdown — just clean up and don't restart.
        if isShuttingDown {
            return
        }
        // We treat any unexpected exit from `.running` or `.starting` as a
        // crash (the latter covers the race where the child dies before
        // `initialize` returns). Other states already finished teardown.
        switch state {
        case .running,
             .starting:
            break
        default:
            return
        }

        await teardownConnectionOnly()

        let count = recordCrashInWindow()
        if count > 3 {
            await disableAfterTooManyCrashes()
            return
        }

        await transition(to: .crashed(restartCountInWindow: count))

        // Backoff per crash count in window: 1s, 2s, 4s.
        let backoffSeconds = max(1, 1 << (count - 1))
        let backoff = Duration.seconds(backoffSeconds)

        backoffTask?.cancel()
        backoffTask = Task { [weak self, clock] in
            try? await clock.sleep(for: backoff)
            guard !Task.isCancelled else { return }
            await self?.restartAfterBackoff()
        }
    }

    private func restartAfterBackoff() async {
        do {
            try await spawnAndInitialize()
            await transition(to: .running)
            startHeartbeat()
        } catch {
            await teardownProcess()
            await transition(to: .failedInit(String(describing: error)))
        }
    }

    private func recordCrashInWindow() -> Int {
        let now = Date()
        let windowStart = now.addingTimeInterval(
            -Double(SidecarSupervisor.crashWindow.components.seconds)
        )
        crashTimestamps.removeAll { $0 < windowStart }
        crashTimestamps.append(now)
        return crashTimestamps.count
    }

    private func disableAfterTooManyCrashes() async {
        let lastLines = (try? await logFile.lastLines(50)) ?? []
        await transition(to: .disabled(
            reason: "crashed too many times",
            lastStderr: lastLines
        ))
    }

    // MARK: - Shutdown plumbing

    private enum StopReason { case userStop, manualRestart }

    private func stopInternal(reason: StopReason) async {
        // Already disabled / not started — just clean up any partial state.
        switch state {
        case .notStarted:
            return
        default:
            break
        }

        isShuttingDown = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        backoffTask?.cancel()
        backoffTask = nil

        // Try a graceful `shutdown` RPC if we still have a live connection.
        if let connection {
            do {
                try await connection.send(
                    method: PluginRPCMethod.AppToSidecar.shutdown.rawValue,
                    params: [String: String](),
                    timeout: SidecarSupervisor.stopGracePeriod
                )
            } catch {
                // No-op: best-effort shutdown.
                logger.debug("shutdown RPC failed (continuing teardown): \(error)")
            }
        }

        if let process, process.isRunning {
            // Give the sidecar a moment to exit on its own after `shutdown`.
            let exited = await waitForProcessExit(
                process,
                deadline: SidecarSupervisor.stopGracePeriod
            )
            if !exited {
                process.terminate() // SIGTERM
                let exitedAfterTerm = await waitForProcessExit(
                    process,
                    deadline: SidecarSupervisor.stopHardDeadline
                )
                if !exitedAfterTerm {
                    // Foundation's Process exposes SIGKILL only via the
                    // underlying processIdentifier. Falling back to kill(2)
                    // ensures we don't leak a hung child.
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        await teardownProcess()

        if reason == .userStop {
            await transition(to: .notStarted)
        }
    }

    /// Wait for `process` to exit, up to `deadline`. Driven by the
    /// `terminationHandler` (see `processDidExit`) rather than polling, so
    /// the actor wakes the instant the child exits.
    private func waitForProcessExit(_ process: Process, deadline: Duration) async -> Bool {
        if !process.isRunning { return true }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                await self.awaitExit()
                return true
            }
            group.addTask { [clock] in
                try? await clock.sleep(for: deadline)
                return false
            }
            let exited = await group.next() ?? false
            group.cancelAll()
            return exited
        }
    }

    /// Park on `exitWaiters` until the terminationHandler resumes us. If the
    /// process is already gone by the time we get here, resolve immediately.
    private func awaitExit() async {
        if let process, !process.isRunning { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if let process, !process.isRunning {
                    continuation.resume()
                    return
                }
                exitWaiters.append(continuation)
            }
        } onCancel: {
            // Hop back to the actor and resume any parked waiters; with a
            // single in-flight `waitForProcessExit` call per stop attempt
            // this just resumes our own continuation.
            Task { [weak self] in
                await self?.cancelExitWaiters()
            }
        }
    }

    private func cancelExitWaiters() {
        let parked = exitWaiters
        exitWaiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Called on the actor when the child's `terminationHandler` fires. Wakes
    /// any parked `waitForProcessExit` callers, then runs the existing crash
    /// / restart bookkeeping.
    private func processDidExit() async {
        let parked = exitWaiters
        exitWaiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
        await handleTermination()
    }

    // MARK: - Teardown

    private func teardownConnectionOnly() async {
        if let connection {
            await connection.stop()
        }
        connection = nil
        bridge = nil
    }

    private func teardownProcess() async {
        await teardownConnectionOnly()
        await logFile.close()

        // Close pipe handles so the kernel reaps the file descriptors. We
        // ignore close errors (already-closed FDs are common during forced
        // shutdown).
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, clock] in
            var consecutiveMisses = 0
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: SidecarSupervisor.heartbeatInterval)
                } catch { return }
                guard let self else { return }
                do {
                    try await self.sendHeartbeat()
                    consecutiveMisses = 0
                } catch {
                    consecutiveMisses += 1
                    if consecutiveMisses >= SidecarSupervisor.maxHeartbeatMisses {
                        await self.forceRestartAfterHeartbeatLoss()
                        return
                    }
                }
            }
        }
    }

    private func sendHeartbeat() async throws {
        guard let connection else { throw JSONRPCConnectionError.connectionClosed }
        try await connection.send(
            method: PluginRPCMethod.AppToSidecar.health.rawValue,
            params: [String: String](),
            timeout: SidecarSupervisor.heartbeatRPCTimeout
        )
    }

    private func forceRestartAfterHeartbeatLoss() async {
        guard let process, process.isRunning else { return }
        // Terminate the child; `terminationHandler` will catch the exit and
        // route it through the crash-counter machinery.
        process.terminate()
    }

    // MARK: - State transitions

    private func transition(to newState: State) async {
        guard newState != state else { return }
        state = newState
        await delegate?.stateChanged(newState, for: self)
    }
}

// MARK: - SidecarSupervisorError

public enum SidecarSupervisorError: Error, Equatable, Sendable {
    /// `start()` called while the supervisor is in `.disabled`. The caller
    /// must `restart()` (which resets the crash window) to override.
    case disabled
}

// MARK: - ConnectionBridge

/// Forwards JSONRPCConnection inbound traffic onto the supervisor's delegate.
///
/// Lives as its own class because `JSONRPCConnection.Delegate` is an
/// `AnyObject`-bound protocol and `SidecarSupervisor` is an `actor` (which
/// can't satisfy `AnyObject`). The bridge holds the delegate weakly to
/// match the connection's contract.
final private class ConnectionBridge: JSONRPCConnection.Delegate, @unchecked Sendable {
    private weak var supervisor: SidecarSupervisor?
    private weak var delegate: (any SidecarSupervisor.Delegate)?
    private let lock = NSLock()

    func bind(supervisor: SidecarSupervisor, delegate: (any SidecarSupervisor.Delegate)?) {
        lock.lock()
        defer { lock.unlock() }
        self.supervisor = supervisor
        self.delegate = delegate
    }

    func received(notification: JSONRPCNotification) async {
        let (supervisor, delegate) = snapshot()
        guard let supervisor, let delegate else { return }
        await delegate.received(notification: notification, from: supervisor)
    }

    func received(request: JSONRPCRequest) async -> JSONRPCResponse {
        let (supervisor, delegate) = snapshot()
        guard let supervisor, let delegate else {
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: JSONRPCError(
                    code: -32_603,
                    message: "Supervisor or delegate gone"
                )
            )
        }
        return await delegate.received(request: request, from: supervisor)
    }

    private func snapshot() -> (SidecarSupervisor?, (any SidecarSupervisor.Delegate)?) {
        lock.lock()
        defer { lock.unlock() }
        return (supervisor, delegate)
    }
}
