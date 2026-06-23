import Foundation
import GallagerPluginProtocol
import Logging

public actor SidecarSupervisor {
    public enum State: Sendable, Equatable {
        case stopped
        case running
        case crashed
        case failedInit
        case disabled
    }

    private let manifest: PluginManifest
    private let layout: PluginRootLayout
    private let logger = Logger(label: "com.claudespy.sidecar.supervisor")
    private let stderrLog: SidecarStderrLog
    private let backoffSchedule: [Duration]

    private var process: Process?
    private var transport: SidecarTransport?
    private var _state: State = .stopped
    private var stopping = false

    // Crash policy: per-plugin crash counter over a 60 s sliding window.
    private var crashTimes: [Date] = []
    private var backoffTask: Task<Void, Never>?
    private var onAutoDisabledCallback: (@Sendable ([String]) -> Void)?

    public init(
        manifest: PluginManifest,
        layout: PluginRootLayout,
        backoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    ) {
        self.manifest = manifest
        self.layout = layout
        self.backoffSchedule = backoffSchedule
        self.stderrLog = SidecarStderrLog(logDir: layout.logDir)
    }

    public func state() -> State {
        _state
    }

    public func setOnAutoDisabled(_ cb: @escaping @Sendable ([String]) -> Void) {
        onAutoDisabledCallback = cb
    }

    /// Spawn the child, wire stdio to a transport, and return it ready to drive.
    public func startTransport(delegate: any SidecarTransportDelegate) async throws -> SidecarTransport {
        guard !stopping else { throw SupervisorError.stopping }
        guard let sidecar = manifest.sidecar else {
            _state = .failedInit
            throw SupervisorError.missingSidecarConfig
        }
        let exe = layout.pluginRoot.appendingPathComponent(sidecar.executable)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            _state = .failedInit
            throw SupervisorError.notExecutable(exe.path)
        }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = sidecar.args
        proc.currentDirectoryURL = layout.pluginRoot

        // Inherit parent environment and add plugin-specific vars (spec §3/§5/§6).
        var env = ProcessInfo.processInfo.environment
        env["GALLAGER_PLUGIN_ROOT"] = layout.pluginRoot.path
        env["GALLAGER_STATE_DIR"] = layout.stateDir.path
        env["GALLAGER_APP_VERSION"] = layout.appVersion
        env["GALLAGER_INGRESS_SOCK"] = layout.ingressSocketPath
        env["GALLAGER_PLUGIN_ID"] = manifest.id
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Mirror stderr to the rotated log (off-actor handler → actor append).
        stderr.fileHandleForReading.readabilityHandler = { [stderrLog] h in
            let d = h.availableData
            if !d.isEmpty { Task { await stderrLog.append(d) } }
        }

        let delegateBox = delegate
        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(status: p.terminationStatus, delegate: delegateBox) }
        }

        try proc.run()

        // Close the parent's copies of the child-inherited pipe ends (spec §3).
        // Keep: stdin.fileHandleForWriting, stdout.fileHandleForReading, stderr.fileHandleForReading.
        // Close: stdin.fileHandleForReading, stdout.fileHandleForWriting, stderr.fileHandleForWriting.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let transport = SidecarTransport(writeHandle: stdin.fileHandleForWriting, delegate: delegate)
        let stdoutBytes = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { continuation.finish() } else { continuation.yield(d) }
            }
            continuation.onTermination = { _ in stdout.fileHandleForReading.readabilityHandler = nil }
        }
        await transport.start(reading: stdoutBytes)

        process = proc
        self.transport = transport
        _state = .running
        return transport
    }

    private func handleTermination(status: Int32, delegate: any SidecarTransportDelegate) async {
        await transport?.close()
        transport = nil
        process = nil

        // An expected exit (explicit stop() or already disabled) is not a crash.
        if _state == .stopped || _state == .disabled { return }

        _state = .crashed
        let now = Date()
        crashTimes.append(now)
        // Slide the 60 s window.
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) <= 60 }
        let n = crashTimes.count
        logger.warning("sidecar '\(manifest.id)' crashed (status \(status)); count=\(n) in window")

        if n >= 4 {
            _state = .disabled
            let lines = await stderrLog.lastLines()
            onAutoDisabledCallback?(lines)
            return
        }

        // Pick the backoff duration: crash #1 → index 0, #2 → index 1, #3+ → last index.
        let backoffIndex = min(n - 1, backoffSchedule.count - 1)
        let backoff = backoffSchedule[backoffIndex]

        backoffTask = Task { [weak self] in
            try? await Task.sleep(for: backoff)
            guard let self, await self.state() == .crashed else { return } // guard against double-spawn
            _ = try? await self.startTransport(delegate: delegate)
        }
    }

    /// Graceful shutdown: SIGTERM, then SIGKILL after 5 s. Resume via terminationHandler.
    public func stop() async {
        stopping = true
        defer { stopping = false }
        backoffTask?.cancel()
        _state = .stopped
        guard let proc = process else { return }
        proc.terminate() // SIGTERM

        // SIGKILL safety net after 5 s.
        let killer = Task {
            try? await Task.sleep(for: .seconds(5))
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }

        // Wait for termination using a bounded poll (50 ms intervals).
        // Prefer a stored continuation wired to terminationHandler, but the
        // handler is already set at spawn time; a bounded poll avoids a second
        // handler assignment and is deterministic enough for a graceful stop.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task {
                while proc.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                cont.resume()
            }
        }
        killer.cancel()
        process = nil
        // I1: close and nil the transport on the graceful path so handleTermination's
        // early-return (for _state == .stopped) doesn't leave it open.
        await transport?.close()
        transport = nil
    }

    /// Re-enable after auto-disable: clear crash history and re-spawn.
    public func reEnable(delegate: any SidecarTransportDelegate) async throws -> SidecarTransport {
        backoffTask?.cancel()
        crashTimes.removeAll()
        _state = .stopped
        return try await startTransport(delegate: delegate)
    }
}

public enum SupervisorError: Error, Equatable {
    case notExecutable(String)
    case missingSidecarConfig
    case stopping
}
