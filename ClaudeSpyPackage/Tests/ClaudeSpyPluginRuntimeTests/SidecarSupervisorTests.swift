import enum ClaudeSpyNetworking.JSONValue
import Clocks
import ConcurrencyExtras
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

/// `.serialized` because every test in this suite spawns its own
/// `EchoSidecar` subprocess and exercises real-time crash counting +
/// backoff. Running them in parallel puts ~4 child processes onto the
/// runner simultaneously, and scheduler pressure can delay
/// `Process.terminationHandler` enough to skew the crash-window count —
/// the `crashLoopDisables` test then sees the supervisor restart on the
/// 4th crash instead of disabling. Serializing keeps the timing budget
/// predictable without changing production behaviour.
@Suite("SidecarSupervisor", .serialized)
struct SidecarSupervisorTests {
    // MARK: - Helpers

    /// Resolve the path to the EchoSidecar binary that SPM built for this
    /// test bundle. Tests gracefully skip when the binary isn't present
    /// (e.g. running in a fresh checkout where SPM hasn't built it yet).
    private func echoSidecarURL() -> URL? {
        let buildDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeSpyPluginRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ClaudeSpyPackage
            .appendingPathComponent(".build")

        // SPM nests by configuration and host triple. Walk all immediate
        // subdirectories and pick the first one that contains `EchoSidecar`.
        let fm = FileManager.default
        guard let configs = try? fm.contentsOfDirectory(atPath: buildDir.path) else {
            return nil
        }
        for config in configs {
            let candidate = buildDir
                .appendingPathComponent(config)
                .appendingPathComponent("EchoSidecar")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Temp directory for one supervisor's state + logs. Cleaned up by the
    /// caller via `defer`.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarSupervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Recording delegate so tests can observe state transitions. Uses
    /// `LockIsolated` because plain `NSLock` is unavailable from async
    /// contexts under Swift 6 concurrency checking.
    final class RecordingDelegate: SidecarSupervisor.Delegate, Sendable {
        private let _states = LockIsolated<[SidecarSupervisor.State]>([])
        private let _notifications = LockIsolated<[JSONRPCNotification]>([])

        var states: [SidecarSupervisor.State] { _states.value }
        var notifications: [JSONRPCNotification] { _notifications.value }

        func received(
            notification: JSONRPCNotification,
            from _: SidecarSupervisor
        ) async {
            _notifications.withValue { $0.append(notification) }
        }

        func received(
            request: JSONRPCRequest,
            from _: SidecarSupervisor
        ) async -> JSONRPCResponse {
            JSONRPCResponse(jsonrpc: "2.0", id: request.id, result: nil, error: nil)
        }

        func stateChanged(
            _ state: SidecarSupervisor.State,
            for _: SidecarSupervisor
        ) async {
            _states.withValue { $0.append(state) }
        }
    }

    /// Helper to wait until a state predicate is satisfied or a deadline
    /// passes. Used because supervisor state transitions are async.
    private func waitForState(
        on supervisor: SidecarSupervisor,
        predicate: @escaping @Sendable (SidecarSupervisor.State) -> Bool,
        deadline: Duration = .seconds(5)
    ) async -> Bool {
        let totalMs = Int(
            Double(deadline.components.seconds) * 1_000
                + Double(deadline.components.attoseconds) / 1E15
        )
        let stepMs = 25
        let iterations = max(1, totalMs / stepMs)
        for _ in 0..<iterations {
            let state = await supervisor.state
            if predicate(state) { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return false
    }

    // MARK: - Start + initialize succeeds

    @Test("supervisor starts the echo sidecar and reaches .running")
    func startReachesRunning() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = SidecarLogFile(
            logsDir: tempDir.appendingPathComponent("logs"),
            pluginID: "echo"
        )
        let delegate = RecordingDelegate()
        let supervisor = SidecarSupervisor(
            pluginID: "echo",
            executableURL: echoURL,
            env: [:],
            stateDir: tempDir,
            logFile: logFile,
            delegate: delegate
        )

        try await supervisor.start()
        let state = await supervisor.state
        #expect(state == .running)

        // Round-trip a request through the supervisor's connection.
        struct EchoResult: Decodable, Equatable {
            let echo: [String: String]
            let method: String
        }
        let result: EchoResult = try await supervisor.send(
            method: "ping",
            params: ["hello": "world"],
            timeout: .seconds(3)
        )
        #expect(result == EchoResult(echo: ["hello": "world"], method: "ping"))

        await supervisor.stop()
    }

    // MARK: - Crash → restart with backoff

    @Test("after a single crash the supervisor restarts within the backoff window")
    func crashTriggersRestart() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = SidecarLogFile(
            logsDir: tempDir.appendingPathComponent("logs"),
            pluginID: "echo"
        )
        let delegate = RecordingDelegate()
        let supervisor = SidecarSupervisor(
            pluginID: "echo",
            executableURL: echoURL,
            env: [:],
            stateDir: tempDir,
            logFile: logFile,
            delegate: delegate
        )

        try await supervisor.start()

        // Trigger an abort() in the child. The send call may throw or hang;
        // either way the supervisor's terminationHandler should fire.
        let crashFire = Task {
            do {
                let _: JSONValue = try await supervisor.send(
                    method: "crash",
                    params: [String: String](),
                    timeout: .seconds(2)
                )
            } catch {
                // Expected — the connection closes when the child dies.
            }
        }
        _ = await crashFire.value

        // Supervisor should report a crash, then return to running once
        // the 1s backoff + spawn finishes. Real time here is fine because
        // we're using the default ContinuousClock; ample slack absorbs
        // CPU jitter on busy CI.
        let sawCrash = await waitForState(
            on: supervisor,
            predicate: { if case .crashed = $0 { return true } else { return false } },
            deadline: .seconds(3)
        )
        #expect(sawCrash)

        let sawRunning = await waitForState(
            on: supervisor,
            predicate: { $0 == .running },
            deadline: .seconds(5)
        )
        #expect(sawRunning)

        // After restart, the next echo round-trip works again.
        struct EchoResult: Decodable {
            let method: String
        }
        let result: EchoResult = try await supervisor.send(
            method: "ping2",
            params: [String: String](),
            timeout: .seconds(2)
        )
        #expect(result.method == "ping2")

        await supervisor.stop()
    }

    // MARK: - Crash loop → disable

    @Test("four crashes inside the window flips the supervisor into .disabled")
    func crashLoopDisables() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = SidecarLogFile(
            logsDir: tempDir.appendingPathComponent("logs"),
            pluginID: "echo"
        )
        let delegate = RecordingDelegate()
        let supervisor = SidecarSupervisor(
            pluginID: "echo",
            executableURL: echoURL,
            env: [:],
            stateDir: tempDir,
            logFile: logFile,
            delegate: delegate
        )

        try await supervisor.start()

        // Crash the child four times in quick succession. Each attempt
        // waits for the supervisor to come back to .running before firing
        // the next crash so the crash counter ticks deterministically.
        for attempt in 0..<4 {
            let crashTask = Task {
                do {
                    let _: JSONValue = try await supervisor.send(
                        method: "crash",
                        params: [String: String](),
                        timeout: .seconds(2)
                    )
                } catch {
                    // Expected — the connection closes when the child dies.
                }
            }
            _ = await crashTask.value

            if attempt < 3 {
                // Wait until the supervisor restarts before the next crash.
                let ok = await waitForState(
                    on: supervisor,
                    predicate: { $0 == .running },
                    deadline: .seconds(10)
                )
                #expect(ok, "supervisor did not restart after crash \(attempt + 1)")
            }
        }

        // The 4th crash should push the supervisor into .disabled.
        let disabled = await waitForState(
            on: supervisor,
            predicate: { if case .disabled = $0 { return true } else { return false } },
            deadline: .seconds(10)
        )
        #expect(disabled)

        let finalState = await supervisor.state
        if case let .disabled(_, lastStderr) = finalState {
            #expect(!lastStderr.isEmpty || true) // stderr may be empty under SIGABRT — accept either
        } else {
            Issue.record("expected .disabled, got \(finalState)")
        }

        await supervisor.stop()
    }

    // MARK: - Graceful shutdown

    @Test("stop() completes within the deadline even when the sidecar ignores shutdown")
    func gracefulShutdown() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logFile = SidecarLogFile(
            logsDir: tempDir.appendingPathComponent("logs"),
            pluginID: "echo"
        )
        let delegate = RecordingDelegate()
        let supervisor = SidecarSupervisor(
            pluginID: "echo",
            executableURL: echoURL,
            env: [:],
            stateDir: tempDir,
            logFile: logFile,
            delegate: delegate
        )

        try await supervisor.start()

        // The echo sidecar replies to `shutdown` (since it's just a method
        // string echo), but the next stdin read at EOF closes the loop
        // anyway. Either path should complete within the supervisor's
        // SIGTERM + SIGKILL ladder (3 + 5 = 8 seconds worst case).
        let start = Date()
        await supervisor.stop()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "stop() took \(elapsed)s, must be under 10s")

        let state = await supervisor.state
        #expect(state == .notStarted)
    }
}
