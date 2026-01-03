import Foundation

/// Result of a process execution
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    var isSuccess: Bool {
        exitCode == 0
    }
}

/// Errors that can occur during process execution
enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(path: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout

    var errorDescription: String? {
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

/// Runs external processes asynchronously
actor ProcessRunner {
    /// Runs a command and returns the result
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command arguments
    ///   - environment: Additional environment variables (merged with current environment)
    ///   - timeout: Maximum time to wait for completion (nil for no timeout)
    /// - Returns: The process result containing stdout, stderr, and exit code
    func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
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

        // Run the process
        return try await withCheckedThrowingContinuation { continuation in
            // Use a thread-safe wrapper for collecting output
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

            process.terminationHandler = { [outputCollector] _ in
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

            do {
                try process.run()

                // Set up timeout if specified
                if let timeout {
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a command and throws if it fails
    func runOrThrow(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let result = try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )

        if !result.isSuccess {
            throw ProcessRunnerError.executionFailed(
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }

        return result
    }
}

/// Thread-safe output collector for process output
private final class OutputCollector: @unchecked Sendable {
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
