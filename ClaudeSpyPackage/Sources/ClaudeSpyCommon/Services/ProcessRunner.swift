import Dependencies
import DependenciesMacros
import Foundation

/// Result of a process execution
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public var isSuccess: Bool {
        exitCode == 0
    }

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Errors that can occur during process execution
public enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(path: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Executable not found at path: \(path)"
        case let .executionFailed(exitCode, stderr):
            return "Process exited with code \(exitCode): \(stderr)"
        case .timeout:
            return "Process execution timed out"
        }
    }
}

/// A dependency for running external processes asynchronously.
///
/// Wraps `Process` execution so it can be controlled in tests.
/// Use `@Dependency(ProcessRunner.self)` to access it.
@DependencyClient
public struct ProcessRunner: Sendable {
    /// Runs a command and returns the result.
    public var run: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval?
    ) async throws -> ProcessResult
}

// MARK: - Convenience

public extension ProcessRunner {
    /// Runs a command and throws if it fails.
    func runOrThrow(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, environment, timeout)

        if !result.isSuccess {
            throw ProcessRunnerError.executionFailed(
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }

        return result
    }
}

// MARK: - DependencyKey

extension ProcessRunner: DependencyKey {
    public static var previewValue: ProcessRunner {
        ProcessRunner(
            run: { _, _, _, _ in
                ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        )
    }

    public static var liveValue: ProcessRunner {
        #if os(macOS)
            return ProcessRunner(
                run: { executable, arguments, environment, timeout in
                    // Verify executable exists
                    guard FileManager.default.isExecutableFile(atPath: executable) else {
                        throw ProcessRunnerError.executableNotFound(path: executable)
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    // Set up environment
                    var env = ProcessInfo.processInfo.environment
                    if let additionalEnv = environment {
                        for (key, value) in additionalEnv {
                            env[key] = value
                        }
                    }
                    process.environment = env

                    // Set up pipes for stdout and stderr
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    // Launch before entering the continuation so that ObjC exceptions
                    // from NSTask (e.g. invalid launch path, already-launched task) are
                    // caught by Swift's do/try/catch instead of crashing with SIGABRT.
                    let outputCollector = OutputCollector()

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            outputCollector.appendStdout(data)
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            outputCollector.appendStderr(data)
                        }
                    }

                    try process.run()

                    // Set up timeout if specified.
                    // Reads `\.continuousClock` from the surrounding dependency context
                    // so a `TestClock` injected via `withDependencies` can drive timeout
                    // behaviour deterministically without burning wall-clock seconds.
                    // Read-and-capture must happen here, OUTSIDE the `Task`. Unstructured
                    // tasks don't propagate `DependencyValues` task-locals, so reading
                    // `@Dependency` inside the `Task` body would silently fall back to
                    // the live clock. Any future dependency this closure needs must be
                    // captured the same way (or routed through `withEscapedDependencies`).
                    let timeoutTask: Task<Void, Never>?
                    if let timeout {
                        @Dependency(\.continuousClock) var clock
                        timeoutTask = Task { [clock] in
                            try? await clock.sleep(for: .seconds(timeout))
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                    } else {
                        timeoutTask = nil
                    }

                    return await withCheckedContinuation { continuation in
                        process.terminationHandler = { [outputCollector, timeoutTask] _ in
                            // Cancel the timeout sleep eagerly so it doesn't sit on a
                            // virtual deadline after the process has already exited.
                            timeoutTask?.cancel()

                            // Clean up handlers
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            stderrPipe.fileHandleForReading.readabilityHandler = nil

                            // Read any remaining data
                            let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                            let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                            if !remainingStdout.isEmpty {
                                outputCollector.appendStdout(remainingStdout)
                            }
                            if !remainingStderr.isEmpty {
                                outputCollector.appendStderr(remainingStderr)
                            }

                            let result = ProcessResult(
                                exitCode: process.terminationStatus,
                                stdout: outputCollector.stdout,
                                stderr: outputCollector.stderr
                            )
                            continuation.resume(returning: result)
                        }
                    }
                }
            )
        #else
            // `Process` (NSTask) is macOS-only. `ProcessRunner` is only invoked on
            // macOS (plugin cores, tmux, installers); it is never used on iOS, so the
            // live value fails loudly if (unexpectedly) called there.
            return ProcessRunner(
                run: { executable, _, _, _ in
                    throw ProcessRunnerError.executableNotFound(path: executable)
                }
            )
        #endif
    }
}

#if os(macOS)
    /// Thread-safe output collector for process output
    final private class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()

        var stdout: Data {
            lock.withLock { _stdout }
        }

        var stderr: Data {
            lock.withLock { _stderr }
        }

        func appendStdout(_ data: Data) {
            lock.withLock { _stdout.append(data) }
        }

        func appendStderr(_ data: Data) {
            lock.withLock { _stderr.append(data) }
        }
    }
#endif
