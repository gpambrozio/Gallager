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

    /// Current list of available panes (updated by refreshPanes)
    public private(set) var panes: [PaneInfo] = []

    /// Error from the last refresh attempt, if any
    public private(set) var lastError: String?

    /// Whether a refresh is currently in progress
    public private(set) var isRefreshing = false

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

    /// Refreshes the list of available panes across all sessions
    /// Updates the internal `panes` array and returns the result
    /// - Returns: The refreshed list of panes
    @discardableResult
    public func refreshPanes() async -> [PaneInfo] {
        guard !isRefreshing else { return panes }

        isRefreshing = true
        lastError = nil

        defer { isRefreshing = false }

        do {
            try await checkAvailability()

            // Format: #{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}
            let format = "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}"

            let result = try await runTmuxCommand([
                "list-panes",
                "-a",
                "-F", format,
            ])

            guard result.isSuccess else {
                lastError = result.stderrString
                return panes
            }

            let lines = result.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .map(String.init)

            // Parse panes and deduplicate by paneId (filters out grouped session duplicates)
            let allPanes = lines.compactMap { PaneInfo(fromTmuxOutput: $0) }
            var seen = Set<String>()
            panes = allPanes.filter { pane in
                if seen.contains(pane.paneId) {
                    return false
                }
                seen.insert(pane.paneId)
                return true
            }
        } catch {
            lastError = error.localizedDescription
            panes = []
        }

        return panes
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

    /// Captures a pane with specified scrollback for snapshot display
    /// - Parameters:
    ///   - target: The pane target
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback
    /// - Returns: Tuple containing the captured data and total line count
    public func capturePaneWithScrollback(
        _ target: String,
        scrollbackMultiplier: Int = 3
    ) async throws -> (content: Data, totalLines: Int) {
        // Get pane dimensions
        let (_, height) = try await getPaneDimensions(target)

        // Capture with scrollback using -S flag (negative = lines before visible area)
        var args = ["capture-pane", "-t", target, "-p", "-e"]

        // Only add -S flag if we want scrollback (multiplier > 0)
        // Without -S, tmux captures just the visible area
        if scrollbackMultiplier > 0 {
            let scrollbackLines = height * scrollbackMultiplier
            args.append("-S")
            args.append("-\(scrollbackLines)")
        }

        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        // Count actual lines captured
        let content = result.stdout
        let lineCount = content.withUnsafeBytes { buffer in
            buffer.reduce(0) { count, byte in
                byte == UInt8(ascii: "\n") ? count + 1 : count
            }
        }

        return (content: content, totalLines: max(lineCount, height))
    }

    /// Captures the visible pane content with cursor positioning for each line
    /// This ensures content is rendered at the correct position in the terminal
    public func capturePaneWithPositioning(_ target: String) async throws -> Data {
        // Capture just the visible content (no scrollback)
        let captureArgs = ["capture-pane", "-t", target, "-p", "-e"]
        let captureResult = try await runTmuxCommand(captureArgs)

        guard captureResult.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        // Get the current cursor position
        let cursorArgs = ["display-message", "-t", target, "-p", "#{cursor_x},#{cursor_y}"]
        let cursorResult = try await runTmuxCommand(cursorArgs)
        let cursorPos = cursorResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursorParts = cursorPos.split(separator: ",")
        let cursorX = Int(cursorParts.first ?? "0") ?? 0
        let cursorY = Int(cursorParts.last ?? "0") ?? 0

        // Split into lines and add cursor positioning for each
        let content = captureResult.stdoutString
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var positionedContent = ""

        // Start with cursor home
        positionedContent += "\u{1b}[H"  // Cursor to home position (1,1)

        for (index, line) in lines.enumerated() {
            // Move cursor to row (index+1), column 1
            positionedContent += "\u{1b}[\(index + 1);1H"
            // Clear the line first to avoid artifacts
            positionedContent += "\u{1b}[2K"
            // Add the line content
            positionedContent += line
        }

        // Position cursor where it actually is in the source pane
        // tmux cursor_x and cursor_y are 0-based, ANSI escape is 1-based
        positionedContent += "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"

        return positionedContent.data(using: .utf8) ?? Data()
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

    /// Forces a pane to redraw by sending Ctrl+L
    public func forceRedraw(_ target: String) async throws {
        _ = try await runTmuxCommand([
            "send-keys",
            "-t", target,
            "C-l",
        ])
    }

    /// Sends keys to a pane
    /// - Parameters:
    ///   - target: The pane target
    ///   - keys: The keys to send (can be literal text or tmux key names like "Enter", "C-c")
    ///   - literal: If true, sends keys literally without interpreting special names
    public func sendKeys(_ target: String, keys: String, literal: Bool = false) async throws {
        var args = ["send-keys", "-t", target]
        if literal {
            args.append("-l")  // Disable key name lookup
        }
        args.append(keys)

        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Sends Ctrl+C to cancel the current operation in a pane
    public func sendInterrupt(_ target: String) async throws {
        _ = try await runTmuxCommand([
            "send-keys",
            "-t", target,
            "C-c",
        ])
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
