import Foundation

/// Errors that can occur when interacting with tmux
enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case noServerRunning
    case invalidPane(target: String)
    case commandFailed(message: String)
    case permissionDenied

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
        }
    }
}

/// Service for interacting with tmux via CLI
@Observable
@MainActor
final public class TmuxService {
    private let processRunner = ProcessRunner()
    private var tmuxPath: String
    private var socketPath: String?

    /// Current list of available panes (updated by refreshPanes)
    public private(set) var panes: [PaneInfo] = []

    /// Handler called when the pane list changes (after refreshPanes detects a change)
    private var onPanesChanged: (@Sendable () async -> Void)?

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

    /// Sets a handler to be called when the pane list changes.
    /// This is useful for pushing updates to remote clients (e.g., iOS).
    public func setPanesChangedHandler(_ handler: @escaping @Sendable () async -> Void) {
        onPanesChanged = handler
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
        let oldPanes = panes

        defer {
            isRefreshing = false

            // Notify if panes changed (compare sets to ignore order)
            if Set(panes) != Set(oldPanes), let handler = onPanesChanged {
                Task {
                    await handler()
                }
            }
        }

        do {
            try await checkAvailability()

            // Get sessions with attached clients to prefer them during deduplication
            let attachedSessions = await getAttachedSessionNames()

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

            // Parse panes and sort so attached sessions come first
            let allPanes = lines.compactMap { PaneInfo(fromTmuxOutput: $0) }
            let sortedPanes = allPanes.sorted { pane1, pane2 in
                let pane1Attached = attachedSessions.contains(pane1.sessionName)
                let pane2Attached = attachedSessions.contains(pane2.sessionName)
                // Attached sessions come first
                if pane1Attached != pane2Attached {
                    return pane1Attached
                }
                return false // Preserve original order otherwise
            }

            // Deduplicate by paneId - attached session versions will be kept
            var seen = Set<String>()
            panes = sortedPanes.filter { pane in
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

    /// Gets the names of sessions that have clients attached
    private func getAttachedSessionNames() async -> Set<String> {
        guard
            let result = try? await runTmuxCommand(["list-clients", "-F", "#{session_name}"]),
            result.isSuccess
        else {
            return []
        }

        let sessions = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)

        return Set(sessions)
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
        guard
            parts.count == 2,
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

    /// Captures pane content with scrollback for streaming initialization.
    /// Scrollback lines have problematic escape codes filtered (keeping only colors),
    /// while the visible area uses full ANSI codes with explicit cursor positioning.
    /// - Parameters:
    ///   - target: The pane target
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback (default: 3)
    /// - Returns: Terminal data that will populate both scrollback and visible area
    public func capturePaneWithScrollbackForStreaming(
        _ target: String,
        scrollbackMultiplier: Int = 3
    ) async throws -> Data {
        // Get pane height for scrollback calculation
        let (_, height) = try await getPaneDimensions(target)
        let scrollbackLines = height * scrollbackMultiplier

        // Capture scrollback + visible area together (no -E flag means capture through visible end)
        // This ensures that when we output with \r\n and content scrolls, the scrollback buffer
        // gets fully populated before Part 2 overwrites the visible area.
        // Without this, the tail of scrollback output ends up in visible and gets lost.
        let scrollbackArgs = ["capture-pane", "-t", target, "-p", "-e", "-S", "-\(scrollbackLines)"]
        let scrollbackResult = try await runTmuxCommand(scrollbackArgs)

        // Capture visible area WITH escape codes for colors
        let visibleArgs = ["capture-pane", "-t", target, "-p", "-e"]
        let visibleResult = try await runTmuxCommand(visibleArgs)

        guard visibleResult.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        // Get cursor position
        let cursorArgs = ["display-message", "-t", target, "-p", "#{cursor_x},#{cursor_y}"]
        let cursorResult = try await runTmuxCommand(cursorArgs)
        let cursorPos = cursorResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursorParts = cursorPos.split(separator: ",")
        let cursorX = Int(cursorParts.first ?? "0") ?? 0
        let cursorY = Int(cursorParts.last ?? "0") ?? 0

        var output = ""

        // Part 1: Output scrollback with filtered escape codes (keep only SGR/colors)
        if scrollbackResult.isSuccess {
            let scrollbackContent = scrollbackResult.stdoutString
            let scrollbackLinesList = scrollbackContent.split(separator: "\n", omittingEmptySubsequences: false)

            for line in scrollbackLinesList {
                // Strip any trailing CR (tmux may output \r\n line endings)
                var lineStr = String(line)
                if lineStr.hasSuffix("\r") {
                    lineStr.removeLast()
                }
                // Filter to colors only, reset attributes, output content with newline
                let filtered = filterToColorCodesOnly(lineStr)
                output += "\u{1b}[0m" // Reset at start
                output += filtered
                output += "\u{1b}[0m\r\n" // Reset, carriage return, newline
            }
        }

        // Part 2: Render visible area with explicit positioning and colors
        let visibleLines = visibleResult.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        output += "\u{1b}[H" // Cursor to home

        for (index, line) in visibleLines.enumerated() {
            // Move cursor to row (index+1), column 1
            output += "\u{1b}[\(index + 1);1H"
            // Clear the line first to avoid artifacts
            output += "\u{1b}[2K"
            // Add the line content
            output += line
        }

        // Position cursor where it actually is
        output += "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"

        return Data(output.utf8)
    }

    /// Filters ANSI escape codes, keeping only SGR (color/style) codes.
    /// Removes cursor positioning, screen clearing, and other control sequences.
    private func filterToColorCodesOnly(_ input: String) -> String {
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            if input[i] == "\u{1b}", input.index(after: i) < input.endIndex {
                let nextIndex = input.index(after: i)
                if input[nextIndex] == "[" {
                    // CSI sequence - find the end
                    var endIndex = input.index(after: nextIndex)
                    while endIndex < input.endIndex {
                        let char = input[endIndex]
                        if char >= "@" && char <= "~" {
                            // Found terminating character
                            let sequence = String(input[i...endIndex])
                            // Keep only SGR sequences (ending with 'm')
                            if char == "m" {
                                result += sequence
                            }
                            // Skip other sequences (cursor positioning, etc.)
                            i = input.index(after: endIndex)
                            break
                        }
                        endIndex = input.index(after: endIndex)
                    }
                    if endIndex >= input.endIndex {
                        // Incomplete sequence, skip the escape
                        i = input.index(after: i)
                    }
                } else {
                    // Non-CSI escape sequence, skip
                    i = input.index(after: i)
                }
            } else {
                result.append(input[i])
                i = input.index(after: i)
            }
        }

        return result
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
            args.append("-l") // Disable key name lookup
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

    // MARK: - Session Creation

    /// Creates a new tmux session with the specified name and dimensions.
    /// If a session with the given name already exists, appends a number suffix.
    /// - Parameters:
    ///   - baseName: The desired base name for the session
    ///   - width: Terminal width in columns
    ///   - height: Terminal height in rows
    /// - Returns: Tuple containing the actual session name and the pane ID of the first pane
    public func createSession(
        baseName: String,
        width: Int,
        height: Int
    ) async throws -> (sessionName: String, paneId: String) {
        // Get existing session names
        let existingNames = await getExistingSessionNames()

        // Find a unique name
        let sessionName = findUniqueSessionName(baseName: baseName, existingNames: existingNames)

        // Create the session with specified dimensions
        // -d: detached, -x: width, -y: height
        let result = try await runTmuxCommand([
            "new-session",
            "-d",
            "-s", sessionName,
            "-x", String(width),
            "-y", String(height),
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        // Get the pane ID of the first pane in the new session
        // Target format: session:window.pane (first window, first pane)
        let windowIndex = 0
        let paneIndex = 0
        let firstPaneTarget = "\(sessionName):\(windowIndex).\(paneIndex)"
        let paneIdResult = try await runTmuxCommand([
            "display-message",
            "-t", firstPaneTarget,
            "-p", "#{pane_id}",
        ])

        guard paneIdResult.isSuccess else {
            throw TmuxError.commandFailed(message: "Session created but could not get pane ID")
        }

        let paneId = paneIdResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Refresh panes to include the new session
        await refreshPanes()

        return (sessionName: sessionName, paneId: paneId)
    }

    /// Gets all existing session names
    private func getExistingSessionNames() async -> Set<String> {
        guard
            let result = try? await runTmuxCommand(["list-sessions", "-F", "#{session_name}"]),
            result.isSuccess
        else {
            return []
        }

        let names = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)

        return Set(names)
    }

    /// Finds a unique session name by appending numbers if needed
    private func findUniqueSessionName(baseName: String, existingNames: Set<String>) -> String {
        // Sanitize base name: tmux session names can't contain colons or periods
        let sanitized = baseName
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        if !existingNames.contains(sanitized) {
            return sanitized
        }

        // Find the next available number
        var counter = 2
        while existingNames.contains("\(sanitized)-\(counter)") {
            counter += 1
        }

        return "\(sanitized)-\(counter)"
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
