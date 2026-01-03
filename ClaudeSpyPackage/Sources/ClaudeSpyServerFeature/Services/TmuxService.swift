import Foundation

/// Errors that can occur when interacting with tmux
enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case noServerRunning
    case invalidPane(target: String)
    case commandFailed(message: String)
    case permissionDenied
    case pipeError(message: String)

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux is not installed or not in PATH"
        case .noServerRunning:
            return "No tmux server running. Start tmux first."
        case let .invalidPane(target):
            return "Pane '\(target)' not found"
        case let .commandFailed(message):
            return "tmux command failed: \(message)"
        case .permissionDenied:
            return "Permission denied accessing tmux"
        case let .pipeError(message):
            return "Connection lost to pane: \(message)"
        }
    }
}

/// Service for interacting with tmux via CLI
@Observable
@MainActor
public final class TmuxService {
    private let processRunner = ProcessRunner()
    private var tmuxPath: String
    private var socketPath: String?

    /// Active pipe-pane processes keyed by pane target
    private var activePipes: [String: String] = [:]

    public init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    /// Updates the tmux configuration
    public func configure(tmuxPath: String, socketPath: String?) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath?.isEmpty == true ? nil : socketPath
    }

    // MARK: - tmux Commands

    /// Checks if tmux is available and a server is running
    public func checkAvailability() async throws {
        // Check if tmux exists
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else {
            throw TmuxError.tmuxNotFound
        }

        // Check if server is running
        let result = try await runTmuxCommand(["list-sessions"])
        if !result.isSuccess {
            let stderr = result.stderrString.lowercased()
            if stderr.contains("no server running") || stderr.contains("no sessions") {
                throw TmuxError.noServerRunning
            }
            if stderr.contains("permission denied") {
                throw TmuxError.permissionDenied
            }
        }
    }

    /// Lists all available panes across all sessions
    public func listPanes() async throws -> [PaneInfo] {
        // Format: #{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}
        let format = "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}"

        let result = try await runTmuxCommand([
            "list-panes",
            "-a",
            "-F", format,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        let lines = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)

        return lines.compactMap { PaneInfo(fromTmuxOutput: $0) }
    }

    /// Validates that a pane target exists
    public func validatePane(_ target: String) async throws -> Bool {
        let result = try await runTmuxCommand([
            "display-message",
            "-t", target,
            "-p", "#{pane_id}",
        ])

        return result.isSuccess && !result.stdoutString.isEmpty
    }

    /// Gets the dimensions of a pane
    public func getPaneDimensions(_ target: String) async throws -> (width: Int, height: Int) {
        let result = try await runTmuxCommand([
            "display-message",
            "-t", target,
            "-p", "#{pane_width} #{pane_height}",
        ])

        guard result.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        let parts = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1])
        else {
            throw TmuxError.invalidPane(target: target)
        }

        return (width, height)
    }

    /// Captures the current pane content with escape sequences
    /// - Parameters:
    ///   - target: The pane target
    ///   - scrollback: Whether to include scrollback history
    /// - Returns: The captured content as raw data with ANSI escape sequences
    public func capturePane(_ target: String, scrollback: Bool = true) async throws -> Data {
        var args = ["capture-pane", "-t", target, "-p", "-e"]

        if scrollback {
            args.append("-S")
            args.append("-") // From start of scrollback
        }

        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        return result.stdout
    }

    /// Starts pipe-pane to stream output to a named pipe
    /// - Parameter target: The pane target
    /// - Returns: The path to the created FIFO
    public func startPipePipe(_ target: String) async throws -> String {
        // Generate unique FIFO path
        let fifoPath = "/tmp/tmux-mirror-\(UUID().uuidString).fifo"

        // Create the FIFO
        let fifoReader = FIFOReader(path: fifoPath)
        try await fifoReader.createFIFO()

        // Start pipe-pane
        let result = try await runTmuxCommand([
            "pipe-pane",
            "-t", target,
            "cat > \(fifoPath)",
        ])

        guard result.isSuccess else {
            // Clean up FIFO on failure
            await fifoReader.stop()
            throw TmuxError.pipeError(message: result.stderrString)
        }

        activePipes[target] = fifoPath
        return fifoPath
    }

    /// Stops pipe-pane for a target
    public func stopPipePipe(_ target: String) async throws {
        // Stop pipe-pane by running it with no command
        _ = try await runTmuxCommand([
            "pipe-pane",
            "-t", target,
        ])

        // Clean up FIFO if we know about it
        if let fifoPath = activePipes[target] {
            try? FileManager.default.removeItem(atPath: fifoPath)
            activePipes.removeValue(forKey: target)
        }
    }

    /// Gets the pane ID for a target
    public func getPaneId(_ target: String) async throws -> String {
        let result = try await runTmuxCommand([
            "display-message",
            "-t", target,
            "-p", "#{pane_id}",
        ])

        guard result.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    private func runTmuxCommand(_ arguments: [String]) async throws -> ProcessResult {
        var args = arguments

        // Add socket path if configured
        if let socket = socketPath {
            args = ["-S", socket] + args
        }

        return try await processRunner.run(
            executable: tmuxPath,
            arguments: args
        )
    }
}
