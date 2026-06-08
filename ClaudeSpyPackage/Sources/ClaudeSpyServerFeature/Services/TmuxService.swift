import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import Foundation
import Logging

/// Errors that can occur when interacting with tmux
enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case invalidPane(target: String)
    case commandFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux is not installed or not in PATH"
        case let .invalidPane(target):
            return "Pane '\(target)' not found"
        case let .commandFailed(message):
            return "tmux command failed: \(message)"
        }
    }
}

/// Outcome of a single refresh attempt against tmux. Encapsulates the decision
/// of whether to assign new panes, clear stored state, or preserve the current
/// state — keeping the mutation point in `refreshPanes` to a single switch so
/// `panes` is never written to an intermediate `[]` value mid-refresh.
private enum RefreshOutcome {
    /// list-panes succeeded with parseable output. Use these panes verbatim.
    case assign([PaneInfo])
    /// Tmux server confirmed to have no panes/sessions. Clear stored state.
    case empty(reason: String)
    /// Couldn't confidently determine state. Preserve current panes.
    case keep(reason: String, lastError: String?)
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
    private static let baseEnvironmentVars: [String] = {
        var vars = [
            "CLAUDE_CODE_NO_FLICKER=1",
            "DISABLE_AUTO_UPDATE=true",
            "DISABLE_UPDATE_PROMPT=true",
        ]
        // Pin spawned panes to the app's own TMPDIR so tooling that resolves
        // `$TMPDIR/<file>` sees the same temp dir the app does. In production this
        // equals the value panes already inherit from the app-owned tmux server (a
        // no-op); under the E2E harness the app's TMPDIR is pinned to the test
        // runner's temp dir, so injected `$TMPDIR/<script>` invocations resolve.
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            vars.append("TMPDIR=\(tmp)")
        }
        return vars
    }()

    /// Absolute path to the user's login shell. Mirrors tmux's own resolution
    /// chain: `$SHELL` → passwd entry's `pw_shell` → POSIX-guaranteed `/bin/sh`.
    /// Resolved once at first access and baked into `defaultCommandWrapper`
    /// rather than relying on `${SHELL}` indirection inside `/bin/sh -c`, so
    /// the spawned pane runs the exact shell we logged.
    private static let userShellPath: String = {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let pw = getpwuid(geteuid())?.pointee, let cstr = pw.pw_shell {
            let resolved = String(cString: cstr)
            if !resolved.isEmpty { return resolved }
        }
        return "/bin/sh"
    }()

    /// POSIX single-quote a string for safe substitution into a `/bin/sh -c` command.
    /// Handles paths with spaces or quotes (rare for shell paths, but cheap to be correct).
    private static func posixSingleQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Wrapper command installed as tmux's `default-command` so every spawned shell
    /// reports as iTerm. Required for OSC 9;4 progress sequences: Claude Code only
    /// emits them when it believes it's running under iTerm.
    ///
    /// `-e TERM_PROGRAM=iTerm.app` on `new-session` doesn't work — tmux 3.2+
    /// unconditionally overwrites `TERM_PROGRAM=tmux` and
    /// `TERM_PROGRAM_VERSION=<tmux-version>` at shell-spawn time (see tmux's
    /// `spawn.c`), after the session env has been applied. The override happens
    /// before `exec(shell)`, so we re-export here — the prefix runs *after*
    /// tmux's hardcoded set and wins.
    ///
    /// `<userShellPath> -l` mirrors what tmux does when `default-command` is
    /// empty (login shell from `default-shell`). Honors any `$SHELL` that
    /// accepts `-l` as the login-shell flag (zsh/bash/fish/xonsh) — nushell
    /// would error and would need the `exec -a "-name"` argv[0] convention
    /// instead (works because tmux runs `default-command` via `/bin/sh -c`,
    /// which on macOS is bash and supports `exec -a`).
    ///
    /// The leading `printf` emits OSC 10 (default foreground) and OSC 11
    /// (default background) *setter* sequences before the shell starts.
    /// tmux's display parser intercepts them and caches the pane's fg/bg —
    /// so later OSC-10/11 *queries* from inside-pane apps (e.g. Codex CLI's
    /// startup probe) get answered from tmux's cache rather than timing out
    /// against tmux 3.6a's broken outer-terminal forwarding (see tmux/tmux
    /// #4846, openai/codex #22761 / #23489). Without this, Codex falls back
    /// to hardcoded colors — including bold + RGB(0,0,0) for the "● Working"
    /// status, invisible on dark mirror themes.
    ///
    /// The fg/bg values match the actual colors the mirror's renderer
    /// applies for the user's currently-selected theme (see
    /// `TerminalContainerView.applyDarkTheme` / `applyLightTheme`), so the
    /// cached value and the rendered bg can't drift if the user toggles
    /// between dark and light themes.
    private var defaultCommandWrapper: String {
        let shell = Self.posixSingleQuote(Self.userShellPath)
        let (fgHex, bgHex) = Self.oscColors(for: themeProvider())
        let oscPreamble = "printf '\\033]10;rgb:\(fgHex)\\007\\033]11;rgb:\(bgHex)\\007'"
        return "\(oscPreamble); TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.6.6 exec \(shell) -l"
    }

    /// Returns the `RRRR/GGGG/BBBB` strings tmux expects in an OSC 10/11
    /// setter for the given mirror theme. Values mirror exactly what
    /// `TerminalContainerView.applyDarkTheme` and `applyLightTheme` push
    /// into SwiftTerm so the cached value in tmux matches what the user
    /// actually sees rendered.
    private static func oscColors(for theme: TerminalTheme) -> (fg: String, bg: String) {
        switch theme {
        case .defaultDark,
             .solarizedDark:
            // applyDarkTheme: fg = NSColor(0.9), bg = NSColor(0.1)
            return ("e6e6/e6e6/e6e6", "1a1a/1a1a/1a1a")
        case .defaultLight,
             .solarizedLight:
            // applyLightTheme: fg = NSColor(0.1), bg = NSColor(0.95)
            return ("1a1a/1a1a/1a1a", "f2f2/f2f2/f2f2")
        }
    }

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

    /// Closure that returns the user's currently-selected mirror theme.
    /// Read each time `defaultCommandWrapper` is evaluated so the OSC 10/11
    /// setters baked into newly-spawned shells reflect the live preference.
    /// Defaults to dark; `AppCoordinator` overrides this with a real
    /// settings-backed closure during construction.
    private var themeProvider: @MainActor () -> TerminalTheme = { .defaultDark }

    public init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    /// Wire up the source of truth for the mirror theme. The closure is
    /// invoked each time a new tmux session is created, so theme changes
    /// the user makes in Settings take effect for the next-spawned shell
    /// without needing to restart the app.
    public func setThemeProvider(_ provider: @escaping @MainActor () -> TerminalTheme) {
        themeProvider = provider
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

    /// Refreshes the list of available panes across all sessions.
    ///
    /// Internally delegates the "what state is tmux in?" decision to
    /// `queryRefreshOutcome`, which folds every observable signal (process
    /// errors, stderr classification, socket presence, list-sessions
    /// confirmation) into one of three outcomes: assign new panes, clear
    /// stored state, or preserve current state. This function only chooses
    /// what to write — and writes `panes` exactly once — so observers never
    /// see an intermediate empty-list value mid-refresh.
    /// - Returns: The refreshed list of panes.
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

        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else {
            if !oldPanes.isEmpty {
                logger.warning("tmux refresh: clearing panes", metadata: [
                    "reason": "tmux binary not found at \(tmuxPath)",
                    "oldPaneCount": "\(oldPanes.count)",
                ])
            }
            panes = []
            return panes
        }

        // Get sessions with attached clients to prefer them during deduplication
        let attachedSessions = await getAttachedSessionNames()
        attachedSessionNames = attachedSessions

        switch await queryRefreshOutcome(attachedSessions: attachedSessions) {
        case let .assign(newPanes):
            panes = newPanes
        case let .empty(reason):
            if !oldPanes.isEmpty {
                logger.warning("tmux refresh: clearing panes", metadata: [
                    "reason": "\(reason)",
                    "oldPaneCount": "\(oldPanes.count)",
                ])
            }
            panes = []
        case let .keep(reason, err):
            if !oldPanes.isEmpty {
                logger.warning("tmux refresh: keeping old panes", metadata: [
                    "reason": "\(reason)",
                    "oldPaneCount": "\(oldPanes.count)",
                ])
            }
            lastError = err
            // panes intentionally untouched — observers see no change
        }

        return panes
    }

    /// Queries tmux and folds every signal into a single `RefreshOutcome`.
    ///
    /// Decision flow:
    /// 1. Run `list-panes -a`. If it parses to a non-empty list → `.assign`.
    /// 2. Process-level throw or non-success exit:
    ///    - `isNoServerError` stderr → `.empty` (tmux explicitly says so).
    ///    - `isConnectionError` stderr + socket missing → `.empty`.
    ///    - Process throw + socket missing → `.empty`.
    ///    - Anything else → `.keep` (transient — preserve panes).
    /// 3. Success but parsed empty → ask tmux directly via `list-sessions`:
    ///    - Success + zero rows → `.empty` (server confirms no sessions).
    ///    - Anything else → `.keep` (tmux glitched on list-panes; sessions
    ///      always have at least one pane, so non-empty list-sessions means
    ///      list-panes lied).
    private func queryRefreshOutcome(attachedSessions: Set<String>) async -> RefreshOutcome {
        // Fields are joined with ASCII Unit Separator (U+001F) — see
        // `PaneInfo.fieldSeparator`. Using `|` here used to break parsing as
        // soon as `pane_title` contained a `|` (Codex CLI does this when it
        // surfaces "Action Required | <session>" titles).
        let sep = String(PaneInfo.fieldSeparator)
        let format = "#{pane_id}\(sep)#{session_name}\(sep)#{window_index}\(sep)#{pane_index}\(sep)#{pane_current_command}\(sep)#{pane_current_path}\(sep)#{pane_width}\(sep)#{pane_height}\(sep)#{pane_active}\(sep)#{pane_title}\(sep)#{window_layout}\(sep)#{window_name}\(sep)#{window_active}\(sep)#{\(Self.colorOptionKey)}\(sep)#{\(Self.emojiOptionKey)}\(sep)#{\(Self.descriptionOptionKey)}"

        let result: ProcessResult
        do {
            result = try await runTmuxCommand(["list-panes", "-a", "-F", format])
        } catch {
            if isServerSocketMissing {
                return .empty(reason: "list-panes threw + socket missing (\(error.localizedDescription))")
            }
            return .keep(
                reason: "list-panes threw + socket present (\(error.localizedDescription))",
                lastError: error.localizedDescription
            )
        }

        if !result.isSuccess {
            let stderr = result.stderrString
            if isNoServerError(stderr) {
                return .empty(reason: "list-panes: no-server (stderr=\(stderr) exit=\(result.exitCode))")
            }
            if isConnectionError(stderr) && isServerSocketMissing {
                return .empty(reason: "list-panes: connection error + socket missing (stderr=\(stderr))")
            }
            return .keep(
                reason: "list-panes failed (stderr=\(stderr) exit=\(result.exitCode))",
                lastError: stderr
            )
        }

        // Success — parse, sort by attached-first, deduplicate by pane id.
        let lines = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
        let parsed = lines.compactMap { PaneInfo(fromTmuxOutput: $0) }
        let sorted = parsed.sorted { pane1, pane2 in
            let pane1Attached = attachedSessions.contains(pane1.sessionName)
            let pane2Attached = attachedSessions.contains(pane2.sessionName)
            if pane1Attached != pane2Attached {
                return pane1Attached
            }
            return false
        }
        var seen = Set<String>()
        let deduped = sorted.filter { pane in
            if seen.contains(pane.paneId) {
                return false
            }
            seen.insert(pane.paneId)
            return true
        }

        if !deduped.isEmpty {
            return .assign(deduped)
        }

        // list-panes returned success with empty/unparseable stdout. Confirm
        // against list-sessions — every session has at least one pane, so
        // sessions-exist + zero panes is definitionally a tmux glitch.
        let sessionCheck = try? await runTmuxCommand(["list-sessions", "-F", "#{session_id}"])
        let sessionLines = sessionCheck?.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n") ?? []
        let listSessionsSucceeded = sessionCheck?.isSuccess == true

        if listSessionsSucceeded && sessionLines.isEmpty {
            return .empty(reason: "list-panes empty + list-sessions confirms no sessions (rawLines=\(lines.count) parsed=\(parsed.count))")
        }
        // Use `.debugDescription` so any ANSI/control bytes in the glitched
        // stdout are escaped (e.g. `\u{1B}`) instead of leaking into the
        // structured log line raw.
        let stdoutPrefix = String(result.stdoutString.prefix(200)).debugDescription
        return .keep(
            reason: "list-panes empty + list-sessions inconclusive (sessionCount=\(sessionLines.count) sessionsSucceeded=\(listSessionsSucceeded) rawLines=\(lines.count) parsed=\(parsed.count) stdoutPrefix=\(stdoutPrefix))",
            lastError: nil
        )
    }

    /// Detects tmux panes that have a running coding-agent process as a descendant.
    ///
    /// Metadata for an agent process detected in a pane.
    public struct DetectedAgentPane: Sendable {
        public let path: String
        /// Id of the plugin whose `process_names` matched (spec §6).
        public let pluginID: String
    }

    /// Gets each pane's shell PID and current path via tmux, then walks the process tree
    /// from `ps` output to find any descendant process whose name is one of an enabled
    /// plugin's manifest `process_names`. This handles cases where the agent CLI is
    /// launched through shell wrappers or scripts (not a direct child of the pane shell).
    ///
    /// - Parameter processNamesByPlugin: Map of pluginID → its manifest
    ///   `process_names` (from `PluginRegistry.processNamesByPlugin`). Pane
    ///   detection is purely manifest-driven and agent-blind (spec §6).
    /// - Returns: A mapping of pane ID (e.g., `%0`) to the detected plugin and the
    ///   pane's current working directory.
    public func detectAgentPanes(
        processNamesByPlugin: [String: [String]]
    ) async -> [String: DetectedAgentPane] {
        guard !processNamesByPlugin.isEmpty else { return [:] }

        // Invert to processName → pluginID for O(1) lookup while walking the tree.
        // When two plugins claim the same process name, the lexicographically
        // smaller pluginID wins so detection is deterministic.
        var pluginByProcessName: [String: String] = [:]
        for (pluginID, names) in processNamesByPlugin.sorted(by: { $0.key < $1.key }) {
            for name in names where pluginByProcessName[name] == nil {
                pluginByProcessName[name] = pluginID
            }
        }
        guard !pluginByProcessName.isEmpty else { return [:] }

        do {
            // Get pane IDs, shell PIDs, and current paths in one tmux call.
            // Joined with U+001F so a `|` in a working-directory path can't
            // shift fields — see `PaneInfo.fieldSeparator`.
            let sep = String(PaneInfo.fieldSeparator)
            let result = try await runTmuxCommand([
                "list-panes", "-a", "-F", "#{pane_id}\(sep)#{pane_pid}\(sep)#{pane_current_path}",
            ])
            guard result.isSuccess else { return [:] }

            // Build paneId -> (panePid, currentPath) mapping
            var paneInfo: [String: (pid: String, path: String)] = [:]
            for line in result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
                let parts = line.split(separator: PaneInfo.fieldSeparator, maxSplits: 2)
                guard parts.count == 3 else { continue }
                paneInfo[String(parts[0])] = (pid: String(parts[1]), path: String(parts[2]))
            }

            guard !paneInfo.isEmpty else { return [:] }

            let tree = try await processTree()
            guard let tree else { return [:] }

            // Walk the subtree of each pane shell, collecting every descendant
            // whose process name a plugin claims. A pane can match more than one
            // plugin (e.g. one agent launched from inside another's pane), so we
            // can't break on the first hit: `descendants(of:)` order depends on
            // the `ps`/PID snapshot, which would make the winner flip between
            // runs. Pick the lexicographically smallest matching pluginID so
            // attribution is deterministic (this also keeps "claude-code" winning
            // over "codex", matching the previous behavior).
            var detected: [String: DetectedAgentPane] = [:]
            for (paneId, info) in paneInfo {
                let descendants = tree.descendants(of: info.pid)
                var matchedPluginIDs: Set<String> = []
                for pid in descendants {
                    guard let name = tree.processName(for: pid) else { continue }
                    if let pluginID = pluginByProcessName[name] {
                        matchedPluginIDs.insert(pluginID)
                    }
                }
                if let winner = matchedPluginIDs.min() {
                    detected[paneId] = DetectedAgentPane(path: info.path, pluginID: winner)
                }
            }

            return detected
        } catch {
            logger.warning("detectAgentPanes failed: \(error)")
            return [:]
        }
    }

    /// Gets the names of sessions that have real terminal clients attached (excludes control-mode clients used by this app)
    private func getAttachedSessionNames() async -> Set<String> {
        // Joined with U+001F so a `|` in a tmux session name can't shift
        // fields — see `PaneInfo.fieldSeparator`.
        let sep = String(PaneInfo.fieldSeparator)
        guard
            let result = try? await runTmuxCommand(["list-clients", "-F", "#{client_control_mode}\(sep)#{session_name}"]),
            result.isSuccess
        else {
            return []
        }

        // Filter out control-mode clients (created by this app for mirroring) — only real terminal clients constrain pane size
        let sessions = result.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: PaneInfo.fieldSeparator, maxSplits: 1)
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
        let (width, height) = try await getPaneDimensions(target)
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
            width: width,
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
    ///   - paneId: The stable tmux pane id (e.g. `%3`)
    ///   - height: Known pane height (from previous query)
    ///   - controlClientManager: The manager to send commands through
    ///   - sessionName: The session name for the control client
    ///   - scrollbackMultiplier: How many times the visible height to capture as scrollback
    /// - Returns: Terminal data for scrollback + visible area
    public func capturePaneViaControlMode(
        paneId: String,
        width: Int,
        height: Int,
        controlClientManager: TmuxControlClientManager,
        sessionName: String,
        scrollbackMultiplier: Int = 3
    ) async throws -> Data {
        // Address the pane by its stable tmux pane ID rather than a
        // session:window.pane target string. With `renumber-windows on`,
        // window indices are reassigned synchronously when sibling windows
        // are killed, which invalidates a stale target captured before the
        // kill — leading to `%error` from `capture-pane` and a blank mirror
        // until the user navigates away and back.
        let scrollbackLines = height * scrollbackMultiplier

        let scrollbackResponse = try await controlClientManager.sendCommand(
            "capture-pane -t '\(paneId)' -p -e -S -\(scrollbackLines) -E -1",
            sessionName: sessionName
        )

        let visibleResponse = try await controlClientManager.sendCommand(
            "capture-pane -t '\(paneId)' -p -e",
            sessionName: sessionName
        )

        guard !visibleResponse.isError else {
            throw TmuxError.invalidPane(target: paneId)
        }
        let cursorResponse = try await controlClientManager.sendCommand(
            "display-message -t '\(paneId)' -p '#{cursor_x},#{cursor_y},#{cursor_flag}'",
            sessionName: sessionName
        )

        return processCapturePaneForStreaming(
            scrollbackOutput: scrollbackResponse.isError ? nil : scrollbackResponse.output,
            visibleOutput: visibleResponse.output,
            cursorOutput: cursorResponse.output,
            width: width,
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
        width: Int,
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
        // Scrollback is suppressed when the visible area is mostly empty —
        // that's the right-after-clear state where the scrollback is stale
        // pre-clear history that would pollute the mirror.
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

            // Once we have any scrollback at all, push it through. Earlier
            // versions skipped scrollback when its line count was below the
            // pane height, on the assumption that "real" scrollback is always
            // larger than one screen — but small genuine output (e.g.
            // `seq 1 100` in a 61-row mirror, ~39 history lines) was being
            // dropped. Match tmux's own scrollback behavior instead: anything
            // tmux retains, the mirror retains.
            if !scrollbackLinesList.isEmpty {
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
        output += "\u{1b}[0m" // Known default before the visible area so the
        // carried-background tracking below starts from a clean slate (an empty
        // first row must paint default, not inherit a stale bg from prior feeds).

        // Output visible lines sequentially. Filter each line to keep only color
        // codes (remove cursor positioning that could interfere).
        //
        // Trailing-cell strategy: write the line's content, then EITHER pad
        // out to `width - 1` with explicit spaces under the active SGR (when
        // the line's end-of-line SGR state has non-bg attributes that need
        // styling preservation), OR just `\e[K` (BCE-erase to end of line)
        // when the bg band — or no styling at all — is sufficient. Reset SGR
        // before `\r\n`.
        //
        // Why conditional and not always-or-never padding:
        //
        //   - `\e[K` (EL) is BCE: it paints trailing cells with the line's
        //     active bg color (so issue #411 bg bands survive) but uses
        //     `Terminal.eraseAttr()` which strips fg and style — i.e. it
        //     CANNOT preserve underline / italic / fg-color bands from
        //     trimmed-capture rows (the #352 trim shape: a lone `\e[4m` or
        //     similar non-bg setter with no chars after).
        //
        //   - Padding with real spaces under the active SGR preserves any
        //     attribute on the trailing cells, including non-bg ones — but
        //     every padded space is a real cell with `code != 0` in the
        //     buffer. `BufferLine.getTrimmedLength` only trims cells with
        //     `code == 0`, so padded rows have a trimmed length equal to the
        //     pane width. When auto-resize fires after attach and SwiftTerm
        //     reflows narrower, every padded row of `width - 1` chars wraps
        //     into `ceil((width - 1) / newCols)` visual rows. The trailing
        //     visual rows are pure pad spaces — visually blank — producing
        //     the double/triple-spacing reported as issue #429.
        //
        //   So we restrict padding to the rows that actually need it: those
        //   ending with a non-bg SGR setter that hasn't been reset. In
        //   practice these are TUI bands (underlined separators, fg-colored
        //   status lines), not ordinary log content. Ordinary content rows
        //   skip padding → trimmed length stays at the actual content
        //   length → reflow narrower trims trailing NULL cells → no blank
        //   continuation rows. The few padded rows still produce blanks on
        //   reflow, but those rows are also redrawn by the running TUI on
        //   the SIGWINCH that auto-resize triggers, so the blanks are
        //   transient — a much smaller blast radius than padding every row.
        //
        //   Padding stops one column short of `width` (then `\e[K` BCE-clears
        //   the final cell) so the cursor can never land in the pending-wrap
        //   position. The single-cell loss of non-bg styling on the rightmost
        //   column is invisible in practice. This was the original intent of
        //   the `width - 1` cap from PR #353/#413.
        //
        //   The SGR-leak fix from #352 (resetting SGR before extractActiveSGR
        //   and skipping extraction on empty cursor lines) is unchanged and
        //   still prevents the underline-state leak into live-streamed data
        //   regardless of padding strategy.
        // `capture-pane -e -p` emits SGR as DELTAS: for a run of identical
        // full-width background ROWS WITH NO GLYPHS (e.g. the Codex composer's
        // top-padding band) it writes the bg setter on the FIRST row and leaves
        // the rest empty, relying on the terminal carrying the bg across the
        // line breaks (verified against tmux). The per-row `\e[0m` below would
        // otherwise kill that carry, so each trimmed-empty continuation row's
        // `\e[K` would clear to default — the reported "composer band row goes
        // black" bug. We carry the background across those empty band rows and
        // re-emit it at the start of each captured row so `\e[K` keeps painting
        // the band.
        //
        // The carry STOPS at the first row with printable content. tmux also
        // leaves a default empty row trimmed-empty (so it too carries the prior
        // bg in the capture stream), but a CONTENT row's trailing bg is the
        // row's own fill — not a band that should bleed into the blank line
        // below it (e.g. the gap between the composer's input row and the
        // footer). Resetting the carry after any content row keeps those blanks
        // default while still letting a glyph-free band span multiple rows.
        //
        // The per-row `\e[0m` reset stays — it stops a band leaking into a
        // *different*-content next row (#411); re-establishing the carried bg
        // first is what lets a glyph-free band span multiple rows.
        let padTarget = max(0, width - 1)
        var carriedBackground = ""
        for index in 0..<linesToOutput {
            var visibleColumns = 0
            var needsExplicitPadding = false
            if index < visibleLines.count {
                let filtered = filterToColorCodesOnly(visibleLines[index])
                if !carriedBackground.isEmpty {
                    output += carriedBackground
                }
                output += filtered
                visibleColumns = countVisibleColumns(filtered)
                needsExplicitPadding = lineHasNonBgSGRActiveAtEnd(filtered)
                carriedBackground = visibleColumns > 0
                    ? "" // content row: its bg is the row's own fill, don't carry it down
                    : trailingBackgroundSGR(carried: carriedBackground, applying: filtered)
            } else {
                // Beyond the captured content the area below is empty (default).
                carriedBackground = ""
            }
            if needsExplicitPadding, visibleColumns < padTarget {
                output += String(repeating: " ", count: padTarget - visibleColumns)
            }
            output += "\u{1b}[K" // BCE-clear trailing cells (carried/own bg paints the band)
            output += "\u{1b}[0m" // Reset before newline so a band can't leak into a different next row
            if index < linesToOutput - 1 {
                output += "\r\n"
            }
        }

        // Clear any remaining lines below the visible content
        // (in case terminal has more rows than visible lines). SGR was reset
        // after the final line above, so ED clears with default attributes.
        output += "\u{1b}[J"

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

    /// Counts visible (cursor-advancing) columns in a `filterToColorCodesOnly`
    /// result, skipping CSI/OSC escape sequences. Each grapheme is measured
    /// via `displayWidth(of:)` so wide characters (CJK, emoji) count as 2 and
    /// combining marks count as 0 — matching SwiftTerm's column accounting.
    ///
    /// Used by `processCapturePaneForStreaming` when a row needs explicit
    /// padding under the active SGR (see `lineHasNonBgSGRActiveAtEnd`) — the
    /// pad amount is `padTarget - visibleColumns`, so over-counting wraps the
    /// row and silently consumes a row of the rebuilt screen.
    func countVisibleColumns(_ filtered: String) -> Int {
        var count = 0
        var i = filtered.startIndex
        while i < filtered.endIndex {
            let char = filtered[i]
            if char == "\u{1b}", filtered.index(after: i) < filtered.endIndex {
                let next = filtered.index(after: i)
                if filtered[next] == "[" {
                    // CSI: ESC [ ... <terminator @–~>
                    var end = filtered.index(after: next)
                    while end < filtered.endIndex {
                        let c = filtered[end]
                        if c >= "@" && c <= "~" {
                            i = filtered.index(after: end)
                            break
                        }
                        end = filtered.index(after: end)
                    }
                    if end >= filtered.endIndex {
                        i = filtered.endIndex
                    }
                } else if filtered[next] == "]" {
                    // OSC: ESC ] ... BEL or ESC \
                    var end = filtered.index(after: next)
                    while end < filtered.endIndex {
                        if filtered[end] == "\u{07}" {
                            i = filtered.index(after: end)
                            break
                        }
                        if filtered[end] == "\u{1b}" {
                            let after = filtered.index(after: end)
                            if after < filtered.endIndex, filtered[after] == "\\" {
                                i = filtered.index(after: after)
                                break
                            }
                        }
                        end = filtered.index(after: end)
                    }
                    if end >= filtered.endIndex {
                        i = filtered.endIndex
                    }
                } else {
                    // 2-byte non-CSI escape (rare here — filterToColorCodesOnly
                    // mostly strips these, but stay defensive)
                    i = filtered.index(after: next)
                }
            } else {
                count += Self.displayWidth(of: char)
                i = filtered.index(after: i)
            }
        }
        return count
    }

    /// Returns true if the active SGR state at the end of `filtered` includes
    /// any attribute that BCE (`\e[K`) cannot preserve — i.e. a style flag
    /// (bold, dim, italic, underline, blink, reverse, hide, strikethrough,
    /// double-underline, overline) or a non-default fg color.
    ///
    /// Used by `processCapturePaneForStreaming` to decide whether the
    /// trailing cells of a rebuilt row need explicit padding under the active
    /// SGR (preserving the issue #352 trim-shape bands like a lone `\e[4m`)
    /// or whether `\e[K` alone suffices (issue #411 bg bands or default).
    ///
    /// The walker treats partial resets (22-29 style off, 39 default fg) as
    /// no-ops, so it over-pads when a partial reset cancels the only active
    /// attribute. That false positive is acceptable: the cost is reflow
    /// blanks on a rare row, while a false negative would lose visible
    /// styling on the rebuild.
    func lineHasNonBgSGRActiveAtEnd(_ filtered: String) -> Bool {
        var hasNonBgActive = false
        var i = filtered.startIndex
        while i < filtered.endIndex {
            guard
                filtered[i] == "\u{1b}",
                filtered.index(after: i) < filtered.endIndex,
                filtered[filtered.index(after: i)] == "[" else {
                i = filtered.index(after: i)
                continue
            }
            let paramsStart = filtered.index(after: filtered.index(after: i))
            var end = paramsStart
            while end < filtered.endIndex {
                let c = filtered[end]
                if c >= "@", c <= "~" { break }
                end = filtered.index(after: end)
            }
            if end >= filtered.endIndex { break }
            let terminator = filtered[end]
            if terminator == "m" {
                let paramStr = String(filtered[paramsStart..<end])
                // `omittingEmptySubsequences: false` so trailing-empty
                // params (e.g. `\e[1;m`) are treated as `0` per ECMA-48.
                let params: [Int] = paramStr.isEmpty
                    ? [0]
                    : paramStr.split(separator: ";", omittingEmptySubsequences: false)
                    .map { Int($0) ?? 0 }
                var idx = 0
                while idx < params.count {
                    let p = params[idx]
                    switch p {
                    case 0:
                        // Reset all attributes.
                        hasNonBgActive = false
                    case 1...9,
                         21,
                         53:
                        // Style flags: bold, dim, italic, underline, blink,
                        // fast-blink, reverse, hide, strikethrough,
                        // double-underline, overline.
                        hasNonBgActive = true
                    case 30...37,
                         90...97:
                        // 8-color and bright fg.
                        hasNonBgActive = true
                    case 38:
                        // Extended fg: 38;5;N or 38;2;R;G;B. Skip parameters.
                        hasNonBgActive = true
                        if idx + 1 < params.count {
                            switch params[idx + 1] {
                            case 5: idx += 2
                            case 2: idx += 4
                            default: break
                            }
                        }
                    case 48:
                        // Extended bg — doesn't affect non-bg state. Skip params.
                        if idx + 1 < params.count {
                            switch params[idx + 1] {
                            case 5: idx += 2
                            case 2: idx += 4
                            default: break
                            }
                        }
                    default:
                        // 22-29 (style resetters), 39 (default fg), 40-47 / 49 /
                        // 100-107 (bg-related). Conservative: leave the flag
                        // unchanged — partial resets may not clear all non-bg
                        // attributes and we'd rather over-pad than lose styling.
                        break
                    }
                    idx += 1
                }
            }
            i = filtered.index(after: end)
        }
        return hasNonBgActive
    }

    /// Returns the background SGR active at the END of `filtered`, given the
    /// background `carried` into the row (a canonical bg SGR string such as
    /// `"\u{1b}[48;2;53;53;53m"`, or `""` for the default background).
    ///
    /// Used by `processCapturePaneForStreaming` to carry a background band
    /// across the trimmed-empty continuation rows that `capture-pane -e -p`
    /// emits with the setter only on the first row of the run. Only the
    /// background is tracked — empty rows carry nothing else (no glyphs to
    /// style), and `\e[K` cannot render non-bg attributes regardless.
    func trailingBackgroundSGR(carried: String, applying filtered: String) -> String {
        var background = carried
        var i = filtered.startIndex
        while i < filtered.endIndex {
            guard
                filtered[i] == "\u{1b}",
                filtered.index(after: i) < filtered.endIndex,
                filtered[filtered.index(after: i)] == "[" else {
                i = filtered.index(after: i)
                continue
            }
            let paramsStart = filtered.index(after: filtered.index(after: i))
            var end = paramsStart
            while end < filtered.endIndex {
                let c = filtered[end]
                if c >= "@", c <= "~" { break }
                end = filtered.index(after: end)
            }
            if end >= filtered.endIndex { break }
            if filtered[end] == "m" {
                let paramStr = String(filtered[paramsStart..<end])
                let params: [Int] = paramStr.isEmpty
                    ? [0]
                    : paramStr.split(separator: ";", omittingEmptySubsequences: false)
                    .map { Int($0) ?? 0 }
                var idx = 0
                while idx < params.count {
                    let p = params[idx]
                    switch p {
                    case 0,
                         49:
                        // Reset all / default bg — band ends.
                        background = ""
                    case 40...47,
                         100...107:
                        // 8-color and bright bg.
                        background = "\u{1b}[\(p)m"
                    case 48:
                        // Extended bg: 48;5;N or 48;2;R;G;B.
                        if idx + 1 < params.count {
                            switch params[idx + 1] {
                            case 5:
                                if idx + 2 < params.count {
                                    background = "\u{1b}[48;5;\(params[idx + 2])m"
                                }
                                idx += 2
                            case 2:
                                if idx + 4 < params.count {
                                    background = "\u{1b}[48;2;\(params[idx + 2]);\(params[idx + 3]);\(params[idx + 4])m"
                                }
                                idx += 4
                            default:
                                break
                            }
                        }
                    default:
                        // fg / style codes don't affect the background.
                        break
                    }
                    idx += 1
                }
            }
            i = filtered.index(after: end)
        }
        return background
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

    /// Sends a `TmuxKey` sequence to a pane, batching consecutive keys by
    /// literal mode to minimize tmux subprocess spawns: literal text is
    /// concatenated into a single `send-keys -l`, runs of named keys go through
    /// `sendBatchKeys`, and a `.delay` flushes the current batch then sleeps.
    /// Shared by the keystroke-command path and the plugin `sendKeys` sink.
    public func sendKeystrokes(_ target: String, keys: [TmuxKey]) async throws {
        var batch: [TmuxKey] = []
        var batchIsLiteral = false

        for key in keys {
            if case let .delay(milliseconds) = key {
                try await flushKeystrokeBatch(target, keys: &batch, literal: batchIsLiteral)
                batchIsLiteral = false
                try await Task.sleep(for: .milliseconds(milliseconds))
                continue
            }

            let isLiteral = key.requiresLiteralMode
            if !batch.isEmpty, isLiteral != batchIsLiteral {
                try await flushKeystrokeBatch(target, keys: &batch, literal: batchIsLiteral)
            }
            batchIsLiteral = isLiteral
            batch.append(key)
        }

        try await flushKeystrokeBatch(target, keys: &batch, literal: batchIsLiteral)
    }

    private func flushKeystrokeBatch(_ target: String, keys: inout [TmuxKey], literal: Bool) async throws {
        guard !keys.isEmpty else { return }
        if literal {
            try await sendKeys(target, keys: keys.map(\.tmuxKeyName).joined(), literal: true)
        } else {
            try await sendBatchKeys(target, keys: keys.map(\.tmuxKeyName))
        }
        keys.removeAll()
    }

    /// Tmux strips a trailing ";" from the last argv entry, treating it
    /// as a command separator. Escaping it as "\;" prevents this.
    /// This affects standalone ";" and any string ending in ";" (e.g. ";;;;;").
    private func escapeTmuxSemicolon(_ key: String) -> String {
        key.hasSuffix(";") ? String(key.dropLast()) + "\\;" : key
    }

    /// Loads `content` into a named tmux buffer and pastes it into `target`,
    /// preserving bracketed-paste markers so apps that have enabled DEC mode
    /// 2004 see it as a single paste event. Used by the file-drop flow:
    /// `content` is the shell-escaped, space-separated path string from
    /// `DroppedPathFormatter`.
    ///
    /// `bufferName` is fixed per-call so concurrent drops don't trample tmux's
    /// global anonymous buffer. `paste-buffer -d` deletes the named buffer
    /// after pasting so it doesn't accumulate across drops.
    public func loadAndPasteBuffer(
        target: String,
        content: String,
        bufferName: String
    ) async throws {
        // Tmux's `-` form reads from stdin, but our ProcessRunner doesn't
        // expose stdin — write to a tmp file and pass the path instead.
        // Use a `gallager-drop-buf-` prefix so this scratch file shares the
        // top-level `gallager-drop-` namespace AppCoordinator's startup sweep
        // already cleans, but stays distinguishable from the per-drop landing
        // directories created by `handleSendDroppedFiles`.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gallager-drop-buf-\(UUID().uuidString)")
        try Data(content.utf8).write(to: tmpURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let load = try await runTmuxCommand([
            "load-buffer",
            "-b", bufferName,
            tmpURL.path,
        ])
        guard load.isSuccess else {
            throw TmuxError.commandFailed(message: load.stderrString)
        }

        let paste = try await runTmuxCommand([
            "paste-buffer",
            "-p", // honor bracketed-paste mode
            "-d", // delete the named buffer afterwards
            "-b", bufferName,
            "-t", target,
        ])
        guard paste.isSuccess else {
            throw TmuxError.commandFailed(message: paste.stderrString)
        }
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
        workingDirectory: String? = nil,
        shellCommand: String? = nil
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

        // Trailing positional becomes the new pane's command (tmux runs it
        // instead of the user's default-shell). Pass the shell here so the
        // pane comes up running it directly — no transient default-shell
        // window flash, no follow-up `exec` round trip.
        if let shellCommand, !shellCommand.isEmpty {
            args.append(shellCommand)
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

        // Sync the local cache so `pane_active` reflects the change before the
        // 5-second polling timer next fires. Without this, switching sessions
        // and returning to a multi-pane window can render with the previous
        // `activePane`, which echoes a stale `select-pane` back through the
        // auto-focus path.
        await refreshPanes()
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
    public func newWindow(
        sessionName: String,
        workingDirectory: String? = nil,
        windowName: String? = nil,
        windowIndex: Int? = nil
    ) async throws -> String {
        // Trailing colon tells tmux "target session with window unspecified" so it auto-picks
        // the next free index. Without it, tmux fills the target from the best-attached
        // client's current window and new-window then tries that exact index — which fails
        // with "index N in use" whenever a control-mode client is focused on an existing
        // window (i.e. always, for us). When `windowIndex` is supplied (e.g. by
        // `gallager apply` honoring sparse `window_index:` entries) we want
        // exactly that index, so target it directly.
        let target: String
        if let windowIndex {
            target = Self.windowTarget(in: sessionName, windowIndex: "\(windowIndex)")
        } else {
            target = Self.sessionTarget(sessionName)
        }
        var args = [
            "new-window",
            "-t", target,
            "-P", "-F", "#{pane_id}:#{window_index}",
        ] + terminalEnvironmentVars.flatMap { ["-e", $0] }

        if let workingDirectory {
            args += ["-c", workingDirectory]
        }

        if let windowName, !windowName.isEmpty {
            // Set the name at creation so the tab label is correct from the
            // first frame, before any `rename-window` round trip.
            args += ["-n", windowName]
        }

        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = output.split(separator: ":", maxSplits: 1).map(String.init)
        let paneId = components.first ?? output
        let windowIndex = components.count >= 2 ? components[1] : nil

        // Name the new window "terminal N" so the tab shows a stable label
        // instead of the running command. tmux's auto-rename is implicitly
        // disabled once we rename the window. Snapshot *after* new-window
        // returns so concurrent calls see each other's creations and avoid
        // picking the same number. Skip when the caller already supplied a name
        // — overriding it would defeat the point of `--name`.
        if windowName == nil, let windowIndex {
            let existingNames = await listWindowNames(in: sessionName)
            let nextName = Self.nextTerminalWindowName(existingNames: existingNames)
            _ = try? await renameWindow(
                target: Self.windowTarget(in: sessionName, windowIndex: windowIndex),
                name: nextName
            )
        }

        // Refresh to pick up the new window
        await refreshPanes()

        return paneId
    }

    /// Renames an existing tmux window.
    /// - Parameters:
    ///   - target: The window target in the form `sessionName:windowIndex`.
    ///   - name: The new window name.
    public func renameWindow(target: String, name: String) async throws {
        let result = try await runTmuxCommand([
            "rename-window",
            "-t", target,
            name,
        ])

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Reorders a tmux window inside a single session so the windows match the
    /// supplied id list. `windowIds` lists the windows of `sessionName` (each in
    /// the form `sessionName:N`) in the order the caller wants them to appear.
    ///
    /// tmux only supports moving a window to one specific index at a time, so
    /// the implementation rewrites every window index in two steps: first
    /// parking each window at a high temporary index (offset by 1000) to free
    /// up the lower indices, then moving each window into its target slot 0…N-1
    /// in the desired order. After all moves complete a single `refreshPanes`
    /// brings the in-memory model back in sync with tmux.
    public func moveWindows(in sessionName: String, to windowIds: [String]) async throws {
        guard !windowIds.isEmpty else { return }
        // Park every window at a unique high index so the lower indices are
        // free for re-assignment. -k forces tmux to overwrite the destination
        // if it's already in use, which shouldn't happen at +1000 but keeps
        // the call defensive against future renumbering.
        for (offset, id) in windowIds.enumerated() {
            let parkTarget = Self.windowTarget(in: sessionName, windowIndex: "\(1_000 + offset)")
            let result = try await runTmuxCommand([
                "move-window", "-k",
                "-s", id,
                "-t", parkTarget,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
        // Now move each parked window into its final slot. Iterate in the new
        // order so the final tmux indices match the caller's intent.
        for newIndex in windowIds.indices {
            let parkTarget = Self.windowTarget(in: sessionName, windowIndex: "\(1_000 + newIndex)")
            let finalTarget = Self.windowTarget(in: sessionName, windowIndex: "\(newIndex)")
            let result = try await runTmuxCommand([
                "move-window", "-k",
                "-s", parkTarget,
                "-t", finalTarget,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
        await refreshPanes()
    }

    /// Lists window names for a session in window-index order.
    private func listWindowNames(in sessionName: String) async -> [String] {
        guard
            let result = try? await runTmuxCommand([
                "list-windows", "-t", Self.sessionTarget(sessionName), "-F", "#{window_name}",
            ]), result.isSuccess
        else {
            return []
        }
        return result.stdoutString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Computes the next "terminal N" name based on existing window names.
    /// - If any existing name matches `terminal \d+`, returns `"terminal (maxN + 1)"`.
    /// - Otherwise returns `"terminal 1"`.
    static func nextTerminalWindowName(existingNames: [String]) -> String {
        let maxTerminalNumber = existingNames.compactMap { terminalNumber(in: $0) }.max() ?? 0
        return "terminal \(maxTerminalNumber + 1)"
    }

    /// Extracts the integer N from a name of the form "terminal N".
    private static func terminalNumber(in name: String) -> Int? {
        let prefix = "terminal "
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
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
            "-t", Self.sessionTarget(sessionName),
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

    // MARK: - Custom Descriptions and Colors

    /// The tmux user option key used to persist Gallager custom descriptions.
    /// User options must be prefixed with `@`; tmux stores them on the session
    /// and any pane resolves the lookup via the session→window→pane chain.
    private static let descriptionOptionKey = "@gallager-description"

    /// The tmux user option key used to persist Gallager session colors.
    /// Stored at session scope just like `descriptionOptionKey`.
    private static let colorOptionKey = "@gallager-color"

    /// The tmux user option key used to persist Gallager session emoji icons.
    /// Stored at session scope just like `descriptionOptionKey`.
    private static let emojiOptionKey = "@gallager-emoji"

    /// Persists the custom description for a session as a tmux user option.
    ///
    /// Writes `@gallager-description` at session scope so it survives app restarts
    /// (the tmux server keeps the option for the session's lifetime). Any existing
    /// window-level overrides inside the session are cleared first so the new value
    /// applies uniformly across every window — defensive against stray overrides
    /// from older versions of Gallager or manual `tmux set-option -w` tweaks.
    /// - Parameters:
    ///   - description: The description text, or `nil` to clear the option.
    ///   - sessionName: The tmux session name.
    public func setSessionDescription(_ description: String?, for sessionName: String) async throws {
        await sweepWindowOverrides(of: Self.descriptionOptionKey, in: sessionName)

        let target = Self.sessionTarget(sessionName)
        if let description {
            let result = try await runTmuxCommand([
                "set-option", "-t", target,
                Self.descriptionOptionKey, description,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        } else {
            let result = try await runTmuxCommand([
                "set-option", "-u", "-t", target,
                Self.descriptionOptionKey,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
    }

    /// Persists the custom color for a session as a tmux user option.
    ///
    /// Mirrors `setSessionDescription` — writes `@gallager-color` at session
    /// scope after sweeping any window-level overrides.
    /// - Parameters:
    ///   - color: The color, or `nil` to clear the option.
    ///   - sessionName: The tmux session name.
    public func setSessionColor(_ color: SessionColor?, for sessionName: String) async throws {
        await sweepWindowOverrides(of: Self.colorOptionKey, in: sessionName)

        let target = Self.sessionTarget(sessionName)
        if let color {
            let result = try await runTmuxCommand([
                "set-option", "-t", target,
                Self.colorOptionKey, color.rawValue,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        } else {
            let result = try await runTmuxCommand([
                "set-option", "-u", "-t", target,
                Self.colorOptionKey,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
    }

    /// Persists the custom emoji for a session as a tmux user option.
    ///
    /// Mirrors `setSessionDescription` — writes `@gallager-emoji` at session
    /// scope after sweeping any window-level overrides.
    /// - Parameters:
    ///   - emoji: The emoji string, or `nil` to clear the option.
    ///   - sessionName: The tmux session name.
    public func setSessionEmoji(_ emoji: String?, for sessionName: String) async throws {
        await sweepWindowOverrides(of: Self.emojiOptionKey, in: sessionName)

        let target = Self.sessionTarget(sessionName)
        if let emoji, !emoji.isEmpty {
            let result = try await runTmuxCommand([
                "set-option", "-t", target,
                Self.emojiOptionKey, emoji,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        } else {
            let result = try await runTmuxCommand([
                "set-option", "-u", "-t", target,
                Self.emojiOptionKey,
            ])
            guard result.isSuccess else {
                throw TmuxError.commandFailed(message: result.stderrString)
            }
        }
    }

    /// Clears any window-level override for `optionKey` across every window in
    /// `sessionName`. Errors are intentionally swallowed: the override may not
    /// exist (the common case), and this is best-effort defensive cleanup.
    private func sweepWindowOverrides(of optionKey: String, in sessionName: String) async {
        guard
            let windows = try? await runTmuxCommand([
                "list-windows", "-t", Self.sessionTarget(sessionName), "-F", "#{window_index}",
            ]), windows.isSuccess else { return }
        let indexes = windows.stdoutString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for index in indexes {
            _ = try? await runTmuxCommand([
                "set-option", "-wu", "-t", Self.windowTarget(in: sessionName, windowIndex: index),
                optionKey,
            ])
        }
    }

    /// Sets a tmux session-scoped environment variable.
    ///
    /// Used by `gallager apply` to honor the `environment:` block in a layout
    /// config. tmux's `set-environment -t <session>` only affects new shells
    /// spawned inside the session — already-running panes keep their existing
    /// environment.
    /// - Parameters:
    ///   - sessionName: The tmux session whose environment is being modified.
    ///   - name: The environment variable name.
    ///   - value: The value to set, or `nil` to unset (`set-environment -u`).
    public func setSessionEnvironment(
        sessionName: String,
        name: String,
        value: String?
    ) async throws {
        let target = Self.sessionTarget(sessionName)
        let args: [String] = if let value {
            ["set-environment", "-t", target, name, value]
        } else {
            ["set-environment", "-u", "-t", target, name]
        }
        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Applies a tmux layout (preset name or dumped layout string) to a window.
    ///
    /// Accepts the standard presets (`even-horizontal`, `tiled`, etc.) as well
    /// as dumped layout hex strings of the form `select-layout <hex>` exports.
    /// - Parameters:
    ///   - target: The tmux window target (e.g. `session:0`).
    ///   - layout: The layout name or dumped hex string.
    public func selectLayout(target: String, layout: String) async throws {
        let result = try await runTmuxCommand([
            "select-layout",
            "-t", target,
            layout,
        ])
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Sets a tmux option at session, window, or global scope.
    ///
    /// Mirrors `tmux set-option [-g|-w] -t <target> <name> <value>`. Used by
    /// `gallager apply` to pass through the `options:` blocks in a layout
    /// config. We do not validate option names — tmux is the source of truth
    /// and surfaces unknown options as a non-zero exit that we propagate.
    /// - Parameters:
    ///   - target: The tmux target (session or window) the option applies to.
    ///   - name: The option name.
    ///   - value: The option value.
    ///   - scope: The option scope (`session` or `window`). Global scope is
    ///     unsupported — Gallager owns the tmux server.
    public enum TmuxOptionScope: Sendable {
        case session
        case window
    }

    public func setOption(
        target: String,
        name: String,
        value: String,
        scope: TmuxOptionScope
    ) async throws {
        var args = ["set-option"]
        switch scope {
        case .session: break
        case .window: args.append("-w")
        }
        args.append(contentsOf: ["-t", target, name, value])
        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }
    }

    /// Captures the current contents of a pane as plain text (no escape sequences).
    ///
    /// Intended for scripts that need to read pane output (grep a build log,
    /// assert on a test output, wait for a specific line). Unlike `capturePane`,
    /// this omits the `-e` flag so the result is plain text suitable for grep.
    /// - Parameters:
    ///   - target: The pane target (e.g. `%3` or `session:0.0`).
    ///   - scrollback: When `true`, includes the entire scrollback history.
    /// - Returns: The captured plain-text content.
    public func capturePaneText(_ target: String, scrollback: Bool = false) async throws -> String {
        var args = ["capture-pane", "-t", target, "-p"]
        if scrollback {
            args.append("-S")
            args.append("-")
        }
        let result = try await runTmuxCommand(args)
        guard result.isSuccess else {
            // Surface tmux's stderr verbatim so scripts get an actionable message
            // (e.g. "can't find pane: %99", "no server running") instead of a
            // generic "pane not found".
            throw TmuxError.commandFailed(message: result.stderrString)
        }
        return result.stdoutString
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
        await runningProcesses(listPanesArgs: ["-s", "-t", Self.sessionTarget(sessionName)])
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
            // Joined with U+001F so a `|` in a process name (unusual but
            // permitted) can't corrupt the pid field — see
            // `PaneInfo.fieldSeparator`.
            let sep = String(PaneInfo.fieldSeparator)
            let format = "#{pane_index}\(sep)#{pane_current_command}\(sep)#{pane_pid}"
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
                let parts = line.split(separator: PaneInfo.fieldSeparator, maxSplits: 2)
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

    /// Forces the server-wide tmux options needed for modified keys (notably
    /// Shift+Enter) to round-trip cleanly to apps like Claude Code, so users
    /// don't need to add these lines to their `~/.tmux.conf`. `extended-keys`
    /// is a scalar so re-setting it is harmless. `terminal-features` is a
    /// list option and tmux's `-a` appends without deduping, so we read the
    /// current value first and only append `xterm*:extkeys` if it isn't
    /// already present — otherwise the value would grow into
    /// `xterm*:extkeys,xterm*:extkeys,…` over a long-running server.
    private func applyExtendedKeysOptions() async {
        _ = try? await runTmuxCommand(["set-option", "-s", "extended-keys", "on"])

        let current = (try? await runTmuxCommand(["show-options", "-sv", "terminal-features"]))?
            .stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.contains("xterm*:extkeys") else { return }
        _ = try? await runTmuxCommand([
            "set-option", "-sa", "terminal-features", "xterm*:extkeys",
        ])
    }

    /// Creates a new tmux session with the specified name and dimensions.
    /// If a session with the given name already exists, appends a number suffix.
    /// - Parameters:
    ///   - baseName: The desired base name for the session
    ///   - width: Terminal width in columns
    ///   - height: Terminal height in rows
    ///   - extraEnvironment: Additional `KEY=VALUE` strings to set on the session
    ///     via `-e`, on top of `terminalEnvironmentVars`.
    ///   - firstWindowName: Name for the first window. The explicit name also
    ///     disables tmux's automatic-rename so the tab doesn't track the
    ///     running command.
    /// - Returns: Tuple containing the actual session name and the pane ID of the first pane
    public func createSession(
        baseName: String,
        width: Int,
        height: Int,
        workingDirectory: String? = nil,
        runCommand: String? = nil,
        extraEnvironment: [String] = [],
        firstWindowName: String = "terminal 1"
    ) async throws -> (sessionName: String, paneId: String) {
        // Get existing session names
        let existingNames = await getExistingSessionNames()

        // Find a unique name
        let sessionName = findUniqueSessionName(baseName: baseName, existingNames: existingNames)

        // Build command arguments
        // -d: detached, -x: width, -y: height, -c: working directory
        // -e: set environment variables (suppress oh-my-zsh update prompts)
        // -n: name the first window up front so the tab doesn't briefly show
        //     the shell command name before we rename it
        let allEnvironmentVars = terminalEnvironmentVars + extraEnvironment
        // Chain `set-option -g default-command … ; new-session …` in one tmux
        // invocation. `set-option` needs a running server, but we need the
        // wrapper installed *before* `new-session` so the first pane uses it.
        // Within a single tmux call the server is started, then commands run
        // in order — so set-option succeeds and the new session inherits the
        // just-set global default-command. Repeating this on every session
        // create is harmless (idempotent) and avoids tracking server lifetime.
        var args = [
            "set-option", "-g", "default-command", defaultCommandWrapper,
            ";",
            "new-session",
            "-d",
            "-s", sessionName,
            "-n", firstWindowName,
            "-x", String(width),
            "-y", String(height),
        ] + allEnvironmentVars.flatMap { ["-e", $0] }

        // Add working directory if specified
        if let workingDirectory, !workingDirectory.isEmpty {
            args.append(contentsOf: ["-c", workingDirectory])
        }

        // Create the session with specified dimensions
        let result = try await runTmuxCommand(args)

        guard result.isSuccess else {
            throw TmuxError.commandFailed(message: result.stderrString)
        }

        // Apply server-wide options required for extended-key passthrough so
        // Shift+Enter (and other modified keys) reach apps like Claude Code
        // without the user editing ~/.tmux.conf. Server options are global and
        // idempotent — re-running on each session create is harmless and
        // additive (`-a` appends to the terminal-features list).
        await applyExtendedKeysOptions()

        // Get the pane ID of the first pane in the new session
        // Target format: session:window.pane (first window, first pane)
        let windowIndex = 0
        let paneIndex = 0
        let firstPaneTarget = "=\(sessionName):\(windowIndex).\(paneIndex)"
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

    /// Returns `true` when a tmux session with the given name currently exists.
    /// Uses tmux as the source of truth so the answer is correct even when the
    /// in-memory `panes` array hasn't been refreshed yet.
    public func sessionExists(named name: String) async -> Bool {
        await getExistingSessionNames().contains(name)
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

    /// Wraps a session name in tmux's exact-match target syntax (`=<name>:`).
    ///
    /// tmux's `-t <name>` parser falls back to prefix and substring matching
    /// when no exact match is found — and in tmux 3.6 it picks an alphabetic
    /// candidate even when an exact match exists, so `-t terminal` can resolve
    /// to a session named `terminal-2`. The `=` prefix forces an exact
    /// session-name match; the trailing `:` disambiguates the target as a
    /// session (rather than a window or pane) so `set-option`, `list-windows`,
    /// etc. resolve to the right scope.
    private static func sessionTarget(_ sessionName: String) -> String {
        "=\(sessionName):"
    }

    /// Window target inside a specific session, using exact-match session
    /// resolution. See `sessionTarget(_:)` for why this is necessary.
    private static func windowTarget(in sessionName: String, windowIndex: String) -> String {
        "=\(sessionName):\(windowIndex)"
    }

    private func runTmuxCommand(_ arguments: [String]) async throws -> ProcessResult {
        var args = arguments

        // Add socket path if configured
        if let socket = socketPath {
            args = ["-S", socket] + args
        }

        return try await processRunner.run(
            executable: tmuxPath,
            arguments: args,
            // The Mac app process can inherit `TMUX` / `TMUX_PANE` from the
            // launching shell when started by hand from a tmux pane. tmux uses
            // these to bias `-t <name>` target parsing — for session-scoped
            // options it reinterprets the target as a window in the current
            // pane's session, so e.g. `set-option -t terminal @gallager-color
            // red` ends up writing to the *current* session whenever a window
            // there has a name starting with "terminal". Force them empty for
            // every subprocess invocation since the Mac app is not actually
            // running inside a tmux pane.
            environment: ["TMUX": "", "TMUX_PANE": ""],
            timeout: nil
        )
    }
}
