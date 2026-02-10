import Foundation
import Logging

/// Result of running a process
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var isSuccess: Bool { exitCode == 0 }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Errors from process execution
public enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(path: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            "Executable not found: \(path)"
        case let .executionFailed(exitCode, stderr):
            "Process exited with code \(exitCode): \(stderr)"
        case .timeout:
            "Process timed out"
        }
    }
}

/// Runs external processes asynchronously
public actor ProcessRunner {
    private let logger = Logger(label: "e2e.process-runner")

    public init() { }

    /// Run a process and return the result
    public func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = 30
    ) async throws -> ProcessResult {
        let executablePath: String
        if executable.hasPrefix("/") {
            executablePath = executable
        } else {
            // Resolve from PATH
            let whichResult = try await runDirect("/usr/bin/which", arguments: [executable])
            guard whichResult.isSuccess else {
                throw ProcessRunnerError.executableNotFound(path: executable)
            }
            executablePath = whichResult.stdoutString
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ProcessRunnerError.executableNotFound(path: executablePath)
        }

        return try await runDirect(executablePath, arguments: arguments, environment: environment, timeout: timeout)
    }

    /// Run a process and throw if it fails
    public func runOrThrow(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = 30
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments: arguments, environment: environment, timeout: timeout)
        guard result.isSuccess else {
            throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result
    }

    // MARK: - Private

    private func runDirect(
        _ executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.appendStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.appendStderr(data)
            }
        }

        try process.run()

        if let timeout {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while process.isRunning {
                if ContinuousClock.now > deadline {
                    process.terminate()
                    throw ProcessRunnerError.timeout
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } else {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        // Give pipes a moment to flush
        try await Task.sleep(for: .milliseconds(50))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Read any remaining data
        let remainingStdout = stdoutPipe.fileHandleForReading.availableData
        if !remainingStdout.isEmpty {
            collector.appendStdout(remainingStdout)
        }
        let remainingStderr = stderrPipe.fileHandleForReading.availableData
        if !remainingStderr.isEmpty {
            collector.appendStderr(remainingStderr)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr
        )
    }
}

// MARK: - Thread-safe output collector

final private class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()

    var stdout: Data {
        lock.lock()
        defer { lock.unlock() }
        return _stdout
    }

    var stderr: Data {
        lock.lock()
        defer { lock.unlock() }
        return _stderr
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stdout.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stderr.append(data)
    }
}
