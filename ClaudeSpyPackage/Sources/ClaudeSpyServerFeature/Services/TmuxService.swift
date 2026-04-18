import Dependencies
import Foundation
import Logging

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

/// Whether a tmux stderr message definitively indicates no server is running (or no sessions exist).
///
/// This intentionally excludes transient connection errors ("error connecting to",
/// "no such file or directory") which can occur when tmux is busy under load. Those
/// are disambiguated by checking whether the tmux socket file still exists — if
/// the socket is gone, the server genuinely exited (e.g. last session was closed).
private func isNoServerError(_ stderr: String) -> Bool {
    let lower = stderr.lowercased()
    return lower.contains("no server running")
        || lower.contains("no sessions")
        || lower.contains("no current target")
        // "server exited unexpectedly" is tmux's crash message (vs clean shutdown's "no server running")
        || lower.contains("server exited unexpectedly")
}

/// Whether the stderr indicates a connection-level failure (socket gone or unreachable).
/// These errors are ambiguous: they can mean the server genuinely exited (last session closed,
/// socket deleted) or that the server is momentarily unreachable under load.
/// Callers should follow up with a socket-existence check to disambiguate.
private func isConnectionError(_ stderr: String) -> Bool {
    let lower = stderr.lowercased()
    return lower.contains("error connecting to")
        || lower.contains("no such file or directory")
}

/// Service for interacting with tmux via CLI
@Observable
@MainActor
final public class TmuxService {
    /// Base environment variables set on all sessions/windows/panes created by the app.
    /// Includes Claude Code rendering config and oh-my-zsh update suppression.
    private static let baseEnvironmentVars = [
        "CLAUDE_CODE_NO_FLICKER=1",
        "DISABLE_AUTO_UPDATE=true",
        "DISABLE_UPDATE_PROMPT=true",
    ]

    /// Path to the Gallager CLI for the `$VISUAL` environment variable.
    /// When set, Ctrl-G in Claude Code opens the in-app prompt editor via `Gallager edit`.
    public var editorCLIPath: String?

    /// Socket path for the API server. The CLI reads this from `$GALLAGER_SOCKET`.
    public var apiSocketPath: String?

    /// Full environment variables list including VISUAL when editor CLI is available.
    private var terminalEnvironmentVars: [String] {
        var vars = Self.baseEnvironmentVars
        if let editorCLIPath {
            vars.append("VISUAL=\(editorCLIPath) edit")
        }
        if let apiSocketPath {
            vars.append("GALLAGER_SOCKET=\(apiSocketPath)")
        }
        return vars
    }

    @ObservationIgnored
    @Dependency(ProcessRunner.self) private var processRunner
    private let logger = Logger(label: "com.claudespy.tmuxservice")
    private var tmuxPath: String
    private var socketPath: String?

    /// Current list of available panes (updated by refreshPanes)
    public private(set) var panes: [PaneInfo] = []

    /// Panes grouped by tmux window (derived from panes)
    public var windows: [LocalTmuxWindow] {
        LocalTmuxWindow.groupPanes(panes)
    }

    /// Windows grouped by tmux session (derived from windows)
    public var sessions: [LocalTmuxSession] {
        LocalTmuxSession.groupWindows(windows)
    }

    /// Handler called when the pane list changes (after refreshPanes detects a change)
    private var onPanesChanged: (@Sendable () async -> Void)?

    /// Error from the last refresh attempt, if any
    public private(set) var lastError: String?

    /// Whether a refresh is currently in progress
    public private(set) var isRefreshing = false

    /// Sessions that currently have terminal clients attached (resize is controlled by the client)
    public private(set) var attachedSessionNames: Set<String> = []

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

    /// Whether the tmux server socket file is missing from disk.
    /// When the last session is closed, tmux removes the socket. A missing socket
    /// definitively means no server is running, disambiguating connection errors
    /// from transient failures (where the socket still exists).
    private var isServerSocketMissing: Bool {
        let path: String
        if let socket = socketPath {
            path = socket
        } else {
            // tmux default: $TMUX_TMPDIR/tmux-<uid>/default or /tmp/tmux-<uid>/default
            let tmpDir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
            path = "\(tmpDir)/tmux-\(getuid())/default"
        }
        return !FileManager.default.fileExists(atPath: path)
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
            if isNoServerError(result.stderrString) {
                throw TmuxError.noServerRunning
            }
            // Connection errors with a missing socket mean the server genuinely exited
            if isConnectionError(result.stderrString) && isServerSocketMissing {
                throw TmuxError.noServerRunning
            }
            if result.stderrString.lowercased().contains("permission denied") {
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
            attachedSessionNames = attachedSessions

            let format = "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}|#{pane_title}|#{window_layout}|#{window_name}|#{window_active}|#{@gallager-description}"

            let result = try await runTmuxCommand([
                "list-panes",
                "-a",
                "-F", format,
            ])

            guard result.isSuccess else {
                if isNoServerError(result.stderrString) {
                    panes = []
                    return panes
                }
                // Connection errors are ambiguous: check if the socket is actually gone
                // (server genuinely exited, e.g. last session closed) vs. transient
                if isConnectionError(result.stderrString) && isServerSocketMissing {
                    logger.info("tmux socket missing after connection error — server exited, clearing panes")
                    panes = []
                    return panes
                }
                logger.warning("tmux list-panes failed (keeping old panes)", metadata: [
                    "stderr": "\(result.stderrString)",
                    "exitCode": "\(result.exitCode)",
                    "oldPaneCount": "\(panes.count)",
                ])
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
        } catch TmuxError.noServerRunning {
            // Tmux has no sessions - this is legitimate, not an error
            lastError = nil
            panes = []
        } catch {
            // Check if the socket is gone — if so, the server genuinely exited
            if isServerSocketMissing {
                logger.info("tmux socket missing after error — server exited, clearing panes")
                lastError = nil
                panes = []
            } else {
                // Socket still exists — transient failure, keep old panes
                logger.warning("tmux refresh failed transiently (keeping old panes)", metadata: [
                    "error": "\(error.localizedDescription)",
                    "oldPaneCount": "\(panes.count)",
                ])
                lastError = error.localizedDescription
            }
        }

        return panes
    }

    /// Detects tmux panes that have a running Claude Code process as a descendant.
    ///
    /// Gets each pane's shell PID and current path via tmux, then walks the process tree
    /// from `ps` output to find any descendant process named `claude`. This handles cases
    /// where Claude Code is launched through shell wrappers or scripts (not a direct child
    /// of the pane shell).
    ///
    /// Returns a mapping of pane ID (e.g., `%0`) to the pane's current working directory
    /// for each pane where Claude Code is running.
    public func detectClaudePanes() async -> [String: String] {
        do {
            // Get pane IDs, shell PIDs, and current paths in one tmux call
            let result = try await runTmuxCommand([
                "list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}|#{pane_current_path}",
            ])
            guard result.isSuccess else { return [:] }

            // Build paneId -> (panePid, currentPath) mapping
            var paneInfo: [String: (pid: String, path: String)] = [:]
            for line in result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 2)
                guard parts.count == 3 else { continue }
                paneInfo[String(parts[0])] = (pid: String(parts[1]), path: String(parts[2]))
            }

            guard !paneInfo.isEmpty else { return [:] }

            let tree = try await processTree()
            guard let tree else { return [:] }

            // Walk the subtree of each pane shell, looking for a "claude" descendant
            var claudePanes: [String: String] = [:]
            for (paneId, info) in paneInfo {
                let descendants = tree.descendants(of: info.pid)
                if descendants.contains(where: { tree.processName(for: $0) == "claude" }) {
                    claudePanes[paneId] = info.path
                }
            }

            return claudePanes
        } catch {
            logger.warning("detectClaudePanes failed: \(error)")
            return [:]
        }
    }

    /// Gets the names of sessions that have real terminal clients attached (excludes control-mode clients used by this app)
    private func getAttachedSessionNames() async -> Set<String> {
        guard
            let result = try? await runTmuxCommand(["list-clients", "-F", "#{client_control_mode}|#{session_name}"]),
            result.isSuccess
        else {
            return []
        }

        // Filter out control-mode clients (created by this app for mirroring) — only real terminal clients constrain pane size
        let sessions = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, parts[0] == "0" else { return nil }
                return String(parts[1])
            }

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

    /// The mouse tracking mode active in a tmux pane.
    public enum PaneMouseMode {
        case off
        case standard
        case button
        case any
    }

    /// Queries the mouse tracking mode of a tmux pane.
    public func getPaneMouseMode(_ target: String) async throws -> PaneMouseMode {
        let result = try await runTmuxCommand([
            "display-message",
            "-t", target,
            "-p", "#{mouse_any_flag} #{mouse_button_flag} #{mouse_standard_flag}",
        ])

        guard result.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }

        let parts = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3 else { return .off }

        if parts[0] == "1" { return .any }
        if parts[1] == "1" { return .button }
        if parts[2] == "1" { return .standard }
        return .off
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

    /// Captures pane content with scrollback for streaming initialization via subprocess.
    /// Used for re-captures (existing stream path) and fallback scenarios.
    /// For new stream initialization, prefer `capturePaneViaControlMode` which eliminates
    /// the timing gap between capture and stream registration.
    /// - Parameters:
    ///   - target: The pane target
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback (default: 3)
    /// - Returns: Terminal data that will populate both scrollback and visible area
    public func capturePaneWithScrollbackForStreaming(
        _ target: String,
        scrollbackMultiplier: Int = 3
    ) async throws -> Data {
        let (_, height) = try await getPaneDimensions(target)
        let scrollbackLines = height * scrollbackMultiplier

        let scrollbackResult = try await runTmuxCommand(
            ["capture-pane", "-t", target, "-p", "-e", "-S", "-\(scrollbackLines)", "-E", "-1"]
        )
        let visibleResult = try await runTmuxCommand(
            ["capture-pane", "-t", target, "-p", "-e"]
        )
        guard visibleResult.isSuccess else {
            throw TmuxError.invalidPane(target: target)
        }
        let cursorResult = try await runTmuxCommand(
            ["display-message", "-t", target, "-p", "#{cursor_x},#{cursor_y},#{cursor_flag}"]
        )

        return processCapturePaneForStreaming(
            scrollbackOutput: scrollbackResult.isSuccess ? scrollbackResult.stdoutString : nil,
            visibleOutput: visibleResult.stdoutString,
            cursorOutput: cursorResult.stdoutString,
            height: height
        )
    }

    /// Captures pane content for streaming using control mode commands.
    ///
    /// Unlike `capturePaneWithScrollbackForStreaming` (which uses subprocesses), this sends
    /// capture commands through the control client's `sendCommand()`. Since commands and
    /// `%output` events are serialized in the same control mode stream, the capture results
    /// are precisely ordered relative to live data — eliminating the H5 timing gap.
    ///
    /// - Parameters:
    ///   - target: The pane target
    ///   - height: Known pane height (from previous query)
    ///   - controlClientManager: The manager to send commands through
    ///   - sessionName: The session name for the control client
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback
    /// - Returns: Terminal data for scrollback + visible area
    public func capturePaneViaControlMode(
        _ target: String,
        height: Int,
        controlClientManager: TmuxControlClientManager,
        sessionName: String,
        scrollbackMultiplier: Int = 3
    ) async throws -> Data {
        let scrollbackLines = height * scrollbackMultiplier

        let scrollbackResponse = try await controlClientManager.sendCommand(
            "capture-pane -t '\(target)' -p -e -S -\(scrollbackLines) -E -1",
            sessionName: sessionName
        )

        let visibleResponse = try await controlClientManager.sendCommand(
            "capture-pane -t '\(target)' -p -e",
            sessionName: sessionName
        )

        guard !visibleResponse.isError else {
            throw TmuxError.invalidPane(target: target)
        }
        let cursorResponse = try await controlClientManager.sendCommand(
            "display-message -t '\(target)' -p '#{cursor_x},#{cursor_y},#{cursor_flag}'",
            sessionName: sessionName
        )

        return processCapturePaneForStreaming(
            scrollbackOutput: scrollbackResponse.isError ? nil : scrollbackResponse.output,
            visibleOutput: visibleResponse.output,
            cursorOutput: cursorResponse.output,
            height: height
        )
    }

    /// Processes raw capture results into streaming terminal data.
    ///
    /// Shared processing logic used by both subprocess-based and control-mode-based
    /// capture paths. Scrollback lines have escape codes filtered to SGR only,
    /// while the visible area uses filtered ANSI codes with cursor positioning.
    /// Internal for testing.
    func processCapturePaneForStreaming(
        scrollbackOutput: String?,
        visibleOutput: String,
        cursorOutput: String,
        height: Int
    ) -> Data {
        // Parse cursor position and visibility flag
        // Format: "x,y,flag" where flag is 1 (visible) or 0 (hidden via DECTCEM)
        let cursorPos = cursorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursorParts = cursorPos.split(separator: ",")
        let cursorX = Int(cursorParts.first ?? "0") ?? 0
        let cursorY = cursorParts.count >= 2 ? (Int(cursorParts[1]) ?? 0) : 0
        let cursorVisible = cursorParts.count >= 3 ? (Int(cursorParts[2]) ?? 1) != 0 : true

        var output = ""

        // Parse visible lines early — needed by both Part 1 (to exclude visible area
        // from scrollback) and Part 2 (to render the visible area).
        var visibleContent = visibleOutput
        if visibleContent.hasSuffix("\n") {
            visibleContent.removeLast()
        }
        let visibleLines = visibleContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Part 1: Output scrollback with filtered escape codes (keep only SGR/colors)
        // The scrollback capture (`-S -N -E -1`) contains only scrollback lines
        // (lines above the visible area). We output them here; they get pushed
        // into SwiftTerm's scrollback buffer when Part 2 writes the visible area.
        //
        // Scrollback is suppressed in two cases:
        // 1. The visible area is mostly empty (screenWasCleared) — indicates
        //    `clear` was just run and the scrollback is stale pre-clear history.
        // 2. The scrollback has fewer lines than the terminal height — indicates
        //    `clear` was run and the screen has since been re-filled. After
        //    clear, tmux trims the pushed blank lines, leaving only a small
        //    number of stale lines in the scrollback capture.
        let nonEmptyVisibleCount = visibleLines.count { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let screenWasCleared = nonEmptyVisibleCount < max(1, height / 4)

        var hasScrollback = false
        if !screenWasCleared, let scrollbackContent = scrollbackOutput {
            var trimmed = scrollbackContent
            if trimmed.hasSuffix("\n") {
                trimmed.removeLast()
            }
            let scrollbackLinesList = trimmed.split(separator: "\n", omittingEmptySubsequences: false)

            // Skip scrollback when it has fewer lines than the terminal
            // height. This catches the case where `clear` (or \e[2J) was run
            // and the screen has since been re-filled — the screenWasCleared
            // heuristic above only detects clears when the visible area is
            // still mostly empty. After clear + fill, the scrollback contains
            // only a small number of stale pre-clear lines (tmux trims the
            // blank pushed lines), while genuine scrollback from continuous
            // output (e.g., `seq 1 200`) produces many more lines than height.
            let hasEnoughScrollback = scrollbackLinesList.count >= height

            if !scrollbackLinesList.isEmpty, hasEnoughScrollback {
                hasScrollback = true
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
        }

        // Part 2: Render visible area from the top of the screen.

        // When scrollback was output (Part 1), push it into the terminal's
        // scrollback buffer using line feeds. Each LF at the bottom of the
        // screen triggers natural scrolling that moves the top visible line
        // into the scrollback buffer. We use `height - 1` LFs to push all
        // content rows without pushing the trailing blank line (from Part 1's
        // last \r\n) into scrollback.
        //
        // Note: SU (CSI n S) cannot be used here — SwiftTerm's cmdScrollUp
        // deletes lines via splice instead of pushing them to scrollback,
        // which destroys Part 1 content and creates a gap when scrolling up.
        if hasScrollback {
            // When height == 1, count is 0 — intentional no-op since a
            // single-row pane has no scrollback worth preserving.
            output += String(repeating: "\n", count: height - 1)
        }

        // Determine how many lines to output. We must output at least:
        // - cursorY + 1: so the cursor can be positioned on the correct row
        // - visibleLines.count: to render all captured visible content
        // - height (when scrollback exists): to fully cover the visible area,
        //   clearing any stale content from previous captures.
        let minForScrollback = hasScrollback ? height : 0
        let linesToOutput = max(cursorY + 1, visibleLines.count, minForScrollback)

        // Always position cursor at the top for Part 2. After the LF scroll
        // above (when scrollback exists), the visible area is clear and ready
        // for the visible content to be drawn from the top.
        output += "\u{1b}[H" // Cursor to home (row 1, col 1)

        // Output visible lines sequentially, clearing each line before writing.
        // After the LF scroll above, Part 1 is in the scrollback buffer, so the
        // visible area is empty — we clear each line defensively and draw Part 2.
        // Filter each line to keep only color codes (remove cursor positioning that could interfere)
        for index in 0..<linesToOutput {
            output += "\u{1b}[2K" // Clear current line
            if index < visibleLines.count {
                output += filterToColorCodesOnly(visibleLines[index])
            }
            // Add newline after each line except the last
            if index < linesToOutput - 1 {
                output += "\r\n"
            }
        }

        // Clear any remaining lines below the visible content
        // (in case terminal has more rows than visible lines)
        output += "\u{1b}[J" // Clear from cursor to end of screen

        // Position cursor using relative movement from the last drawn line.
        // After drawing `linesToOutput` lines, the cursor is on the last line.
        // We need to move UP by (linesToOutput - 1 - cursorY) lines, then to
        // the correct column. Using relative movement instead of absolute
        // positioning ensures correctness even when the mirror terminal has
        // fewer rows than tmux — absolute \e[Y;XH would reference tmux row
        // numbers that don't exist in a smaller mirror.
        let effectiveCursorY = min(cursorY, linesToOutput - 1)
        let linesUp = linesToOutput - 1 - effectiveCursorY
        if linesUp > 0 {
            output += "\u{1b}[\(linesUp)A" // Move cursor up
        }
        output += "\u{1b}[\(cursorX + 1)G" // Move to column (absolute column positioning)

        // Reset SGR to a known default, then restore the active SGR state at
        // the cursor position so live-stream data inherits the correct colors.
        // The explicit reset is load-bearing: mid-capture rendering can leave
        // SwiftTerm in a non-default SGR state when tmux's `capture-pane -p`
        // emits a lone `\e[4m` (or similar set-code) on a row whose trailing
        // cells were trimmed. Without the reset, that state would persist past
        // the capture and bleed into live-streamed writes (issue #352).
        output += "\u{1b}[0m"
        let activeSGR = extractActiveSGR(from: visibleLines, cursorX: cursorX, cursorY: effectiveCursorY)
        if !activeSGR.isEmpty {
            output += activeSGR
        }

        // Apply cursor visibility state (DECTCEM). When the remote pane has hidden
        // the cursor (e.g., Claude Code, vim), emit ?25l so the mirror hides it too.
        if !cursorVisible {
            output += "\u{1b}[?25l"
        }

        return Data(output.utf8)
    }

    /// Filters ANSI escape codes, keeping only SGR (color/style) codes.
    /// Removes cursor positioning, screen clearing, and other control sequences.
    ///
    /// Also translates DEC Special Graphics characters to their UTF-8 equivalents.
    /// `tmux capture-pane -e` uses SO (0x0E) / SI (0x0F) to wrap characters that
    /// were originally drawn using the DEC line drawing charset. Since the charset
    /// designation sequences (e.g. `ESC ) 0`) are stripped by this filter, we must
    /// convert those characters here — otherwise SwiftTerm would render them as
    /// plain ASCII (e.g. 'q' instead of '─').
    ///
    /// Internal for testing
    func filterToColorCodesOnly(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        // Resets per call — callers must invoke per-line (as processCapturePaneForStreaming does)
        var inACS = false // Tracking SO/SI (Alternate Character Set) state

        while i < input.endIndex {
            let char = input[i]

            if char == "\u{0e}" {
                // SO (Shift Out): activate G1 charset (DEC Special Graphics in capture-pane output)
                inACS = true
                i = input.index(after: i)
            } else if char == "\u{0f}" {
                // SI (Shift In): activate G0 charset (standard ASCII)
                inACS = false
                i = input.index(after: i)
            } else if char == "\u{1b}", input.index(after: i) < input.endIndex {
                let nextIndex = input.index(after: i)
                if input[nextIndex] == "[" {
                    // CSI sequence - find the end
                    var endIndex = input.index(after: nextIndex)
                    while endIndex < input.endIndex {
                        let csiChar = input[endIndex]
                        if csiChar >= "@" && csiChar <= "~" {
                            // Found terminating character
                            let sequence = String(input[i...endIndex])
                            // Keep only SGR sequences (ending with 'm')
                            if csiChar == "m" {
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
                } else if input[nextIndex] == "]" {
                    // OSC sequence: ESC ] ... BEL or ESC ] ... ESC backslash (ST)
                    // Find the terminator first, then decide whether to keep the sequence
                    var oscIndex = input.index(after: nextIndex)
                    var terminatorEnd: String.Index?
                    while oscIndex < input.endIndex {
                        if input[oscIndex] == "\u{07}" {
                            // BEL terminator
                            terminatorEnd = input.index(after: oscIndex)
                            break
                        } else if input[oscIndex] == "\u{1b}" {
                            // Check for ST (ESC \)
                            let afterEsc = input.index(after: oscIndex)
                            if afterEsc < input.endIndex, input[afterEsc] == "\\" {
                                terminatorEnd = input.index(after: afterEsc)
                                break
                            }
                        }
                        oscIndex = input.index(after: oscIndex)
                    }
                    if let terminatorEnd {
                        // Check if this is OSC 8 (hyperlink) — preserve it
                        let oscContent = input[input.index(after: nextIndex)..<oscIndex]
                        if oscContent.hasPrefix("8;") {
                            result += String(input[i..<terminatorEnd])
                        }
                        i = terminatorEnd
                    } else {
                        // Unterminated OSC, skip past it all
                        i = input.endIndex
                    }
                } else if input[nextIndex] == "(" || input[nextIndex] == ")" || input[nextIndex] == "*" || input[nextIndex] == "+" {
                    // Charset selection: ESC + designator + charset = 3 bytes total
                    let charsetIndex = input.index(after: nextIndex)
                    if charsetIndex < input.endIndex {
                        i = input.index(after: charsetIndex)
                    } else {
                        // Incomplete sequence, skip what we have
                        i = input.endIndex
                    }
                } else {
                    // Standard 2-byte non-CSI escape (ESC + type byte)
                    i = input.index(after: nextIndex)
                }
            } else if inACS {
                // Translate DEC Special Graphics character to UTF-8 equivalent
                result.append(Self.translateDECGraphics(char))
                i = input.index(after: i)
            } else {
                result.append(char)
                i = input.index(after: i)
            }
        }

        return result
    }

    /// DEC Special Graphics character mapping.
    /// Maps ASCII characters to their UTF-8 box-drawing equivalents when the terminal
    /// is in the DEC Special Graphics charset (activated via SO after `ESC ) 0`).
    /// Reference: VT100 User Guide, Table 5-13
    private static func translateDECGraphics(_ char: Character) -> Character {
        switch char {
        case "`": return "\u{25c6}" // ◆
        case "a": return "\u{2592}" // ▒
        case "b": return "\u{2409}" // ␉ (HT symbol)
        case "c": return "\u{240c}" // ␌ (FF symbol)
        case "d": return "\u{240d}" // ␍ (CR symbol)
        case "e": return "\u{240a}" // ␊ (LF symbol)
        case "f": return "\u{00b0}" // °
        case "g": return "\u{00b1}" // ±
        case "h": return "\u{2424}" // ␤ (NL symbol)
        case "i": return "\u{240b}" // ␋ (VT symbol)
        case "j": return "\u{2518}" // ┘
        case "k": return "\u{2510}" // ┐
        case "l": return "\u{250c}" // ┌
        case "m": return "\u{2514}" // └
        case "n": return "\u{253c}" // ┼
        case "o": return "\u{23ba}" // ⎺
        case "p": return "\u{23bb}" // ⎻
        case "q": return "\u{2500}" // ─
        case "r": return "\u{23bc}" // ⎼
        case "s": return "\u{23bd}" // ⎽
        case "t": return "\u{251c}" // ├
        case "u": return "\u{2524}" // ┤
        case "v": return "\u{2534}" // ┴
        case "w": return "\u{252c}" // ┬
        case "x": return "\u{2502}" // │
        case "y": return "\u{2264}" // ≤
        case "z": return "\u{2265}" // ≥
        case "{": return "\u{03c0}" // π
        case "|": return "\u{2260}" // ≠
        case "}": return "\u{00a3}" // £
        case "~": return "\u{00b7}" // ·
        default: return char
        }
    }

    /// Extracts the active SGR (color/style) escape sequences at the given cursor position
    /// by walking through visible lines and tracking SGR state changes.
    /// Returns accumulated non-reset SGR codes, or empty string if the state is default.
    ///
    /// SGR attributes are cumulative in terminals — `\e[1m` (bold) followed by `\e[31m` (red)
    /// means "bold red". This function accumulates all active SGR sequences so that the full
    /// styling state is restored. A reset (`\e[0m` or `\e[m`) clears all accumulated state.
    ///
    /// Limitations:
    /// - Only recognizes CSI (`ESC [`) sequences; 8-bit C1 codes and non-CSI escapes are not parsed.
    /// - Column counting treats every character as single-width; CJK/emoji (2-column) characters
    ///   may cause the cursor column check to be off, since tmux reports `cursor_x` in column units.
    ///
    /// Internal for testing
    func extractActiveSGR(from lines: [String], cursorX: Int, cursorY: Int) -> String {
        var activeSGRs: [String] = []

        for lineIndex in 0...min(cursorY, lines.count - 1) {
            let line = lines[lineIndex]

            // If the cursor line is completely empty in the capture, the cell
            // at the cursor was never written (tmux emits nothing for a row
            // with no content transitions from its left margin). Its attributes
            // are the pane default — ignore any SGR state accumulated from
            // earlier rows that the capture failed to pair with an explicit
            // reset (e.g. a row of fully-underlined spaces that `capture-pane
            // -p` trimmed, leaving just `\e[4m` with no matching `\e[0m` when
            // every row below is also empty). Without this guard the accumulated
            // `\e[4m` would be emitted and the mirror's SwiftTerm would stay
            // stuck in underline mode, causing subsequent live-streamed writes
            // to render underlined even though the real pane has default
            // attributes at the cursor cell. See issue #352.
            if lineIndex == cursorY, line.isEmpty {
                return ""
            }

            var i = line.startIndex
            var col = 0

            while i < line.endIndex {
                // On the cursor line, stop before processing escapes at/beyond cursor column.
                // Escape sequences after the cursor position (like tmux's trailing \e[0m)
                // are not part of the active SGR state at the cursor.
                if lineIndex == cursorY, col >= cursorX {
                    return activeSGRs.joined()
                }

                if line[i] == "\u{1b}", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "[" {
                    // Parse CSI sequence
                    var endIdx = line.index(line.index(after: i), offsetBy: 1)
                    while endIdx < line.endIndex {
                        let ch = line[endIdx]
                        if ch >= "@", ch <= "~" {
                            if ch == "m" {
                                let sgr = String(line[i...endIdx])
                                if sgr == "\u{1b}[0m" || sgr == "\u{1b}[m" {
                                    activeSGRs.removeAll()
                                } else {
                                    activeSGRs.append(sgr)
                                }
                            }
                            i = line.index(after: endIdx)
                            break
                        }
                        endIdx = line.index(after: endIdx)
                    }
                    if endIdx >= line.endIndex {
                        i = line.endIndex
                    }
                } else {
                    // Visible character — count display columns toward cursor position.
                    // Wide characters (CJK, emoji) occupy 2 terminal columns.
                    if lineIndex == cursorY {
                        col += Self.displayWidth(of: line[i])
                    }
                    i = line.index(after: i)
                }
            }
        }

        return activeSGRs.joined()
    }

    /// Returns the terminal display width of a character (1 or 2 columns).
    ///
    /// This must match SwiftTerm's `UnicodeUtil.columnWidth(rune:)` so that
    /// our cursor-position tracking agrees with the actual rendered output.
    /// The width table is derived from SwiftTerm's `UnicodeWidthData.eastAsianWide`.
    ///
    /// For multi-scalar characters (ZWJ sequences, flags), only the first
    /// scalar is inspected — terminals render them as 2 columns regardless.
    nonisolated static func displayWidth(of char: Character) -> Int {
        guard let scalar = char.unicodeScalars.first else { return 1 }
        let value = scalar.value

        // ASCII fast path
        if value < 0x7F {
            return value < 0x20 ? 0 : 1
        }

        // Zero-width categories (must match SwiftTerm's checks)
        let props = scalar.properties
        switch props.generalCategory {
        case .nonspacingMark,
             .spacingMark,
             .enclosingMark:
            return 0
        case .format:
            return value == 0x00AD ? 1 : 0
        default:
            break
        }

        // East Asian Wide — matches SwiftTerm's UnicodeWidthData.eastAsianWide
        if Self.isEastAsianWide(value) {
            return 2
        }

        return 1
    }

    /// Matches SwiftTerm's `UnicodeWidthData.eastAsianWide` table exactly.
    /// Characters in this table are always rendered as 2 columns wide.
    /// Characters that only become wide with VS16 (U+FE0F) are NOT included.
    private nonisolated static func isEastAsianWide(_ value: UInt32) -> Bool {
        // Below 0x1100 nothing is wide
        guard value >= 0x1100 else { return false }

        switch value {
        // Hangul Jamo
        case 0x1100...0x115F: return true
        // Horologicals
        case 0x231A...0x231B: return true
        // Angle brackets
        case 0x2329...0x232A: return true
        // Media controls
        case 0x23E9...0x23EC: return true
        case 0x23F0: return true
        case 0x23F3: return true
        // Geometric shapes
        case 0x25FD...0x25FE: return true
        // Misc Symbols — only specific emoji
        case 0x2614...0x2615: return true
        case 0x2630...0x2637: return true
        case 0x2648...0x2653: return true
        case 0x267F: return true
        case 0x268A...0x268F: return true
        case 0x2693: return true
        case 0x26A1: return true
        case 0x26AA...0x26AB: return true
        case 0x26BD...0x26BE: return true
        case 0x26C4...0x26C5: return true
        case 0x26CE: return true
        case 0x26D4: return true
        case 0x26EA: return true
        case 0x26F2...0x26F3: return true
        case 0x26F5: return true
        case 0x26FA: return true
        case 0x26FD: return true
        // Dingbats — only specific emoji
        case 0x2705: return true
        case 0x270A...0x270B: return true
        case 0x2728: return true
        case 0x274C: return true
        case 0x274E: return true
        case 0x2753...0x2755: return true
        case 0x2757: return true
        case 0x2795...0x2797: return true
        case 0x27B0: return true
        case 0x27BF: return true
        // Arrows + geometric shapes
        case 0x2B1B...0x2B1C: return true
        case 0x2B50: return true
        case 0x2B55: return true
        // CJK Radicals, Ideographs, Kana, etc.
        case 0x2E80...0x2E99: return true
        case 0x2E9B...0x2EF3: return true
        case 0x2F00...0x2FD5: return true
        case 0x2FF0...0x303E: return true
        case 0x3041...0x3096: return true
        case 0x3099...0x30FF: return true
        case 0x3105...0x312F: return true
        case 0x3131...0x318E: return true
        case 0x3190...0x31E5: return true
        case 0x31EF...0x321E: return true
        case 0x3220...0x3247: return true
        case 0x3250...0xA48C: return true
        case 0xA490...0xA4C6: return true
        case 0xA960...0xA97C: return true
        case 0xAC00...0xD7A3: return true
        case 0xF900...0xFAFF: return true
        case 0xFE10...0xFE19: return true
        case 0xFE30...0xFE52: return true
        case 0xFE54...0xFE66: return true
        case 0xFE68...0xFE6B: return true
        case 0xFF01...0xFF60: return true
        case 0xFFE0...0xFFE6: return true
        // Supplementary planes
        case 0x16FE0...0x16FE4: return true
        case 0x16FF0...0x16FF6: return true
        case 0x17000...0x18CD5: return true
        case 0x18CFF...0x18D1E: return true
        case 0x18D80...0x18DF2: return true
        case 0x1AFF0...0x1AFF3: return true
        case 0x1AFF5...0x1AFFB: return true
        case 0x1AFFD...0x1AFFE: return true
        case 0x1B000...0x1B122: return true
        case 0x1B132: return true
        case 0x1B150...0x1B152: return true
        case 0x1B155: return true
        case 0x1B164...0x1B167: return true
        case 0x1B170...0x1B2FB: return true
        case 0x1D300...0x1D356: return true
        case 0x1D360...0x1D376: return true
        // Emoji (U+1F000+)
        case 0x1F004: return true
        case 0x1F0CF: return true
        case 0x1F18E: return true
        case 0x1F191...0x1F19A: return true
        case 0x1F200...0x1F202: return true
        case 0x1F210...0x1F23B: return true
        case 0x1F240...0x1F248: return true
        case 0x1F250...0x1F251: return true
        case 0x1F260...0x1F265: return true
        case 0x1F300...0x1F320: return true
        case 0x1F32D...0x1F335: return true
        case 0x1F337...0x1F37C: return true
        case 0x1F37E...0x1F393: return true
        case 0x1F3A0...0x1F3CA: return true
        case 0x1F3CF...0x1F3D3: return true
        case 0x1F3E0...0x1F3F0: return true
        case 0x1F3F4: return true
        case 0x1F3F8...0x1F43E: return true
        case 0x1F440: return true
        case 0x1F442...0x1F4FC: return true
        case 0x1F4FF...0x1F53D: return true
        case 0x1F54B...0x1F54E: return true
        case 0x1F550...0x1F567: return true
        case 0x1F57A: return true
        case 0x1F595...0x1F596: return true
        case 0x1F5A4: return true
        case 0x1F5FB...0x1F64F: return true
        case 0x1F680...0x1F6C5: return true
        case 0x1F6CC: return true
        case 0x1F6D0...0x1F6D2: return true
        case 0x1F6D5...0x1F6D8: return true
        case 0x1F6DC...0x1F6DF: return true
        case 0x1F6EB...0x1F6EC: return true
        case 0x1F6F4...0x1F6FC: return true
        case 0x1F7E0...0x1F7EB: return true
        case 0x1F7F0: return true
        case 0x1F90C...0x1F93A: return true
        case 0x1F93C...0x1F945: return true
        case 0x1F947...0x1F9FF: return true
        case 0x1FA70...0x1FA7C: return true
        case 0x1FA80...0x1FA8A: return true
        case 0x1FA8E...0x1FAC6: return true
        case 0x1FAC8: return true
        case 0x1FACD...0x1FADC: return true
        case 0x1FADF...0x1FAEA: return true
        case 0x1FAEF...0x1FAF8: return true
        case 0x20000...0x2FFFD: return true
        case 0x30000...0x3FFFD: return true
        default: return false
        }
    }

    /// Forces a pane to redraw by sending Ctrl+L
    public func forceRedraw(_ target: String) async throws {
        _ = try await runTmuxCommand([
            "send-keys",
            "-t", target,
            "C-l",
        ])
    }

    /// Sends raw bytes to a pane using hex encoding.
    ///
    /// Used for escape sequences (e.g., mouse events) that can't be represented
    /// as TmuxKey values and must be forwarded to the terminal application as-is.
    public func sendRawBytes(_ target: String, data: Data) async throws {
        var args = ["send-keys", "-t", target, "-H"]
        args.append(contentsOf: data.map { String(format: "%02x", $0) })
        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
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
        args.append(escapeTmuxSemicolon(keys))

        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Sends multiple non-literal key names to a pane in a single tmux command.
    ///
    /// This batches keys like `Enter`, `Up`, `C-c` into one `send-keys` invocation
    /// instead of spawning a separate process per keystroke.
    /// - Parameters:
    ///   - target: The pane target
    ///   - keys: Array of tmux key names (e.g., ["Enter", "Up", "C-c"])
    public func sendBatchKeys(_ target: String, keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        var args = ["send-keys", "-t", target]
        for key in keys {
            args.append(escapeTmuxSemicolon(key))
        }
        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Tmux strips a trailing ";" from the last argv entry, treating it
    /// as a command separator. Escaping it as "\;" prevents this.
    /// This affects standalone ";" and any string ending in ";" (e.g. ";;;;;").
    private func escapeTmuxSemicolon(_ key: String) -> String {
        key.hasSuffix(";") ? String(key.dropLast()) + "\\;" : key
    }

    /// Resizes a tmux pane to the specified dimensions
    /// - Parameters:
    ///   - target: The pane target (e.g., "%5" or "session:0.1")
    ///   - width: New width in columns
    ///   - height: New height in rows
    public func resizePane(_ target: String, width: Int, height: Int) async throws {
        // Use resize-window instead of resize-pane: pane resize is constrained by the window
        // dimensions, and control-mode clients (used by this app) set the window size.
        // resize-window changes the window itself, and the pane follows.
        let result = try await runTmuxCommand([
            "resize-window",
            "-t", target,
            "-x", String(width),
            "-y", String(height),
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Splits a tmux pane in the given direction
    /// - Parameters:
    ///   - target: The pane target to split (e.g., "%5")
    ///   - horizontal: If true, splits left-right (-h); if false, splits top-bottom (-v)
    ///   - workingDirectory: Optional starting directory for the new pane
    /// - Returns: The pane ID of the newly created pane
    public func splitPane(
        _ target: String,
        horizontal: Bool,
        workingDirectory: String? = nil
    ) async throws -> String {
        let flag = horizontal ? "-h" : "-v"
        var args = [
            "split-window",
            flag,
            "-t", target,
            "-P", "-F", "#{pane_id}", // Print new pane ID
        ] + terminalEnvironmentVars.flatMap { ["-e", $0] }

        if let workingDirectory, !workingDirectory.isEmpty {
            args.append(contentsOf: ["-c", workingDirectory])
        }

        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Selects (focuses) a tmux pane
    /// - Parameter target: The pane target to select (e.g., "%5")
    public func selectPane(_ target: String) async throws {
        let result = try await runTmuxCommand([
            "select-pane",
            "-t", target,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Selects (switches to) a tmux window
    /// - Parameter target: The window target to select (e.g., "session:0")
    public func selectWindow(_ target: String) async throws {
        let result = try await runTmuxCommand([
            "select-window",
            "-t", target,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Creates a new tmux window in an existing session
    /// - Parameters:
    ///   - sessionName: The session to create the window in
    ///   - workingDirectory: Optional working directory for the new window
    /// - Returns: The pane ID of the new window's first pane
    public func newWindow(sessionName: String, workingDirectory: String? = nil) async throws -> String {
        var args = [
            "new-window",
            "-t", sessionName,
            "-P", "-F", "#{pane_id}",
        ] + terminalEnvironmentVars.flatMap { ["-e", $0] }

        if let workingDirectory {
            args += ["-c", workingDirectory]
        }

        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        let paneId = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Refresh to pick up the new window
        await refreshPanes()

        return paneId
    }

    /// Sends Ctrl+C to cancel the current operation in a pane
    public func sendInterrupt(_ target: String) async throws {
        _ = try await runTmuxCommand([
            "send-keys",
            "-t", target,
            "C-c",
        ])
    }

    /// Kills a tmux session by name
    /// - Parameter sessionName: The name of the session to kill
    public func killSession(_ sessionName: String) async throws {
        let result = try await runTmuxCommand([
            "kill-session",
            "-t", sessionName,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        // Refresh panes to reflect the killed session
        await refreshPanes()
    }

    /// Kills a single tmux pane by its pane ID.
    /// If the pane is the last one in its window/session, tmux will close the window/session automatically.
    /// - Parameter paneId: The pane ID to kill (e.g. "%0")
    public func killPane(_ paneId: String) async throws {
        let result = try await runTmuxCommand([
            "kill-pane",
            "-t", paneId,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        // Refresh panes to reflect the killed pane
        await refreshPanes()
    }

    /// Kills a single tmux window by its target (e.g., "session:0").
    /// If the window is the last one in its session, tmux will close the session automatically.
    /// - Parameter windowTarget: The window target to kill (e.g., "mysession:0")
    public func killWindow(_ windowTarget: String) async throws {
        let result = try await runTmuxCommand([
            "kill-window",
            "-t", windowTarget,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        // Refresh panes to reflect the killed window
        await refreshPanes()
    }

    // MARK: - Custom Descriptions

    /// The tmux user option key used to persist Gallager custom descriptions.
    /// User options must be prefixed with `@`; tmux stores them at the scope
    /// they are set (session or window) and resolves lookups with window-over-session
    /// inheritance when formatted from a pane.
    private static let descriptionOptionKey = "@gallager-description"

    /// Persists the custom description for a session as a tmux user option.
    ///
    /// Writes `@gallager-description` at session scope so it survives app restarts
    /// (the tmux server keeps the option for the session's lifetime). Any existing
    /// window-level overrides inside the session are cleared first so the new value
    /// applies uniformly across every window — doing the sweep up front also means a
    /// stray override from a previous version or manual tmux tweak gets cleaned up
    /// even if the session-level write ends up being a no-op.
    /// - Parameters:
    ///   - description: The description text, or `nil` to clear the option.
    ///   - sessionName: The tmux session name.
    public func setSessionDescription(_ description: String?, for sessionName: String) async throws {
        // Sweep window-level overrides first so the session value wins everywhere.
        // Running this before the session-level write also means the cleanup still
        // happens if `set-option -u` exits non-zero (e.g. option already unset).
        if
            let windows = try? await runTmuxCommand([
                "list-windows", "-t", sessionName, "-F", "#{window_index}",
            ]), windows.isSuccess {
            let indexes = windows.stdoutString
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for index in indexes {
                _ = try? await runTmuxCommand([
                    "set-option", "-wu", "-t", "\(sessionName):\(index)",
                    Self.descriptionOptionKey,
                ])
            }
        }

        if let description {
            let result = try await runTmuxCommand([
                "set-option", "-t", sessionName,
                Self.descriptionOptionKey, description,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        } else {
            let result = try await runTmuxCommand([
                "set-option", "-u", "-t", sessionName,
                Self.descriptionOptionKey,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
    }

    /// Describes a process running in a tmux pane (foreground or background).
    public struct RunningProcess: Sendable {
        /// The pane index within its window (e.g., 0, 1)
        public let paneIndex: Int
        /// The process name (e.g., "python", "node", "make")
        public let name: String
        /// Whether this is the foreground process (vs a background child)
        public let isForeground: Bool
    }

    /// Known shell executables that indicate an idle pane.
    private static let knownShells: Set = [
        "bash", "zsh", "sh", "fish", "dash", "csh", "tcsh", "ksh",
    ]

    /// Snapshot of the system process tree, built from `ps` output.
    /// Shared by `detectClaudePanes` and `runningProcesses`.
    private struct ProcessTree {
        private let childrenOf: [String: [String]]
        private let names: [String: String]

        init(psOutput: String) {
            var children: [String: [String]] = [:]
            var processNames: [String: String] = [:]

            for line in psOutput.split(separator: "\n") {
                let cols = line.split(whereSeparator: \.isWhitespace)
                guard cols.count >= 3 else { continue }
                let pid = String(cols[0])
                let ppid = String(cols[1])
                // comm may contain path separators — take just the basename
                let comm = String(cols[cols.count - 1])
                let basename = comm.split(separator: "/").last.map(String.init) ?? comm
                children[ppid, default: []].append(pid)
                processNames[pid] = basename
            }

            self.childrenOf = children
            self.names = processNames
        }

        func processName(for pid: String) -> String? {
            names[pid]
        }

        /// Returns all descendant PIDs of the given root (excluding the root itself).
        func descendants(of rootPid: String) -> [String] {
            var result: [String] = []
            var seen: Set<String> = [rootPid]
            var stack = childrenOf[rootPid, default: []]
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                result.append(pid)
                stack.append(contentsOf: childrenOf[pid, default: []])
            }
            return result
        }
    }

    /// Builds a `ProcessTree` from the current system state.
    private func processTree() async throws -> ProcessTree? {
        let psResult = try await processRunner.run(
            executable: "/bin/ps",
            arguments: ["-eo", "pid,ppid,comm"],
            environment: nil,
            timeout: 5
        )
        guard psResult.isSuccess else { return nil }
        return ProcessTree(psOutput: psResult.stdoutString)
    }

    /// Detects running processes across all panes of a tmux session.
    ///
    /// Checks both the foreground command (`pane_current_command`) and background
    /// child processes (via `ps` process tree walk from `pane_pid`). A pane whose
    /// foreground command is a known shell and has no child processes is considered idle.
    ///
    /// - Parameter sessionName: The tmux session name to inspect
    /// - Returns: Array of running processes found across the session's panes
    public func runningProcesses(inSession sessionName: String) async -> [RunningProcess] {
        // list-panes -s lists all panes in the session (across all windows)
        await runningProcesses(listPanesArgs: ["-s", "-t", sessionName])
    }

    /// Detects running processes across all panes of a specific tmux window.
    ///
    /// Same detection as `runningProcesses(inSession:)` but scoped to a single window.
    ///
    /// - Parameter windowTarget: The tmux window target (e.g., "session:0")
    /// - Returns: Array of running processes found across the window's panes
    public func runningProcesses(inWindow windowTarget: String) async -> [RunningProcess] {
        // list-panes without -s lists panes only in the specified window
        await runningProcesses(listPanesArgs: ["-t", windowTarget])
    }

    /// Shared implementation for detecting running processes in tmux panes.
    private func runningProcesses(listPanesArgs: [String]) async -> [RunningProcess] {
        do {
            let format = "#{pane_index}|#{pane_current_command}|#{pane_pid}"
            let result = try await runTmuxCommand(
                ["list-panes"] + listPanesArgs + ["-F", format]
            )
            guard result.isSuccess else { return [] }

            struct PaneEntry {
                let paneIndex: Int
                let command: String
                let pid: String
            }

            var entries: [PaneEntry] = []
            for line in result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 2)
                guard parts.count == 3, let index = Int(parts[0]) else { continue }
                entries.append(PaneEntry(paneIndex: index, command: String(parts[1]), pid: String(parts[2])))
            }

            guard !entries.isEmpty else { return [] }

            let tree = try await processTree()
            guard let tree else { return [] }

            var running: [RunningProcess] = []

            for entry in entries {
                let isShell = Self.knownShells.contains(entry.command)

                // If foreground process is not a shell, it's a running process
                if !isShell {
                    running.append(RunningProcess(
                        paneIndex: entry.paneIndex,
                        name: entry.command,
                        isForeground: true
                    ))
                }

                // Walk the process tree from the pane's shell PID to find background children.
                let descendants = tree.descendants(of: entry.pid)
                for pid in descendants {
                    if let name = tree.processName(for: pid), !Self.knownShells.contains(name) {
                        // Skip the foreground process — already counted above
                        if !isShell && name == entry.command { continue }
                        running.append(RunningProcess(
                            paneIndex: entry.paneIndex,
                            name: name,
                            isForeground: false
                        ))
                    }
                }
            }

            return running
        } catch {
            logger.warning("runningProcesses failed: \(error)")
            return []
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
        height: Int,
        workingDirectory: String? = nil,
        runCommand: String? = nil
    ) async throws -> (sessionName: String, paneId: String) {
        // Get existing session names
        let existingNames = await getExistingSessionNames()

        // Find a unique name
        let sessionName = findUniqueSessionName(baseName: baseName, existingNames: existingNames)

        // Build command arguments
        // -d: detached, -x: width, -y: height, -c: working directory
        // -e: set environment variables (suppress oh-my-zsh update prompts)
        var args = [
            "new-session",
            "-d",
            "-s", sessionName,
            "-x", String(width),
            "-y", String(height),
        ] + terminalEnvironmentVars.flatMap { ["-e", $0] }

        // Add working directory if specified
        if let workingDirectory, !workingDirectory.isEmpty {
            args.append(contentsOf: ["-c", workingDirectory])
        }

        // Create the session with specified dimensions
        let result = try await runTmuxCommand(args)

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

        // Run initial command if specified
        if let runCommand, !runCommand.isEmpty {
            _ = try await runTmuxCommand([
                "send-keys",
                "-t", paneId,
                runCommand,
                "Enter",
            ])
        }

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
            arguments: args,
            environment: nil,
            timeout: nil
        )
    }
}
