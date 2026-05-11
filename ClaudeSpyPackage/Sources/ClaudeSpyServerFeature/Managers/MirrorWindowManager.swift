import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import Foundation
import Logging

/// Manages pane state, hook events, and session tracking.
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Unified per-pane state keyed by pane ID.
    /// Contains tmux metadata, Claude session, terminal title, and yolo mode.
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Task for periodic session validation
    private var sessionValidationTask: Task<Void, Never>?

    /// Task observing NSMenu tracking notifications so the validation loop
    /// can stand down while the user has a menu open.
    private var menuTrackingObservationTask: Task<Void, Never>?

    /// Number of NSMenus currently in tracking mode (context menus, menu bar
    /// menus, etc.). Bumped by `NSMenu.didBeginTrackingNotification` and
    /// decremented by `NSMenu.didEndTrackingNotification` — both fire on
    /// every menu open/close globally within the app.
    ///
    /// While this is > 0, `startPeriodicSessionValidation` skips its
    /// `updatePaneStates` / `refreshGitBranches` cycle: mutating `paneStates`
    /// or other `@Observable` state ripples through SwiftUI reconciliation
    /// and AppKit interprets that as a reason to dismiss the open popup,
    /// which is exactly what was killing the "Open in Editor" submenu
    /// mid-hover every 5 seconds.
    private var menuTrackingCount = 0

    /// Called when session metadata (description, color, or emoji) changes,
    /// to push updated state to viewers.
    public var onSessionMetadataChanged: (@MainActor @Sendable () async -> Void)?

    /// Interval between session validation checks (in seconds)
    private let validationInterval: TimeInterval = 5

    @ObservationIgnored
    @Dependency(ProcessRunner.self) private var processRunner

    private let logger = Logger(label: "com.claudespy.mirrorwindowmanager")
    private let settings: AppSettings
    private let tmuxService: TmuxService

    /// Pane stream manager for sharing streams
    public var paneStreamManager: PaneStreamManager

    /// Editor session manager for prompt editing
    public let editorSessionManager: EditorSessionManager

    public init(
        settings: AppSettings,
        tmuxService: TmuxService,
        paneStreamManager: PaneStreamManager,
        editorSessionManager: EditorSessionManager
    ) {
        self.settings = settings
        self.tmuxService = tmuxService
        self.paneStreamManager = paneStreamManager
        self.editorSessionManager = editorSessionManager
    }

    // MARK: - Pane State Management

    /// Updates the pane states dictionary from tmux pane metadata.
    /// Creates new entries for newly discovered panes, updates metadata for existing panes,
    /// and removes entries for panes that no longer exist (cleaning up associated state).
    ///
    /// An empty `panes` argument is a legitimate signal that the tmux server has
    /// no panes (e.g. the user just closed the last session and the server
    /// exited). When that happens we must clear `paneStates` so the UI stops
    /// showing stale sessions; refusing to clear leaves the just-closed session
    /// pinned in the session list and tab bars indefinitely. The producer-side
    /// guards in `TmuxService.refreshPanes()` only set `panes = []` on
    /// confident server-down paths, so we trust them here. Surprising wipes
    /// are still observable via the warnings below and the producer-side logs.
    public func updatePaneStates(from panes: [PaneInfo]) {
        if panes.isEmpty && !paneStates.isEmpty {
            logger.warning("updatePaneStates clearing non-empty state from empty panes", metadata: [
                "existingPaneCount": "\(paneStates.count)",
                "existingClaudeSessionCount": "\(paneStates.values.filter { $0.claudeSession != nil }.count)",
            ])
        }

        let currentPaneIds = Set(panes.map(\.paneId))

        // Update or create entries for current panes
        for pane in panes {
            if var state = paneStates[pane.paneId] {
                pane.updateMetadata(of: &state)
                paneStates[pane.paneId] = state
            } else {
                paneStates[pane.paneId] = pane.makePaneState()
            }
        }

        // Remove stale entries — but skip hook-only minimal states. `handleHookEvent`
        // creates a `PaneState(paneId:claudeSession:)` with default-empty `sessionName`
        // when a hook arrives for a pane the windowManager hasn't yet observed; the
        // first refresh that sees the pane fills in metadata. A refresh whose
        // `list-panes` snapshot was taken BEFORE the hook arrived (the subprocess
        // ran while MainActor was suspended) won't include that pane, and removing
        // the entry here would silently drop the SessionStart and lose the project
        // decoration. Empty `sessionName` is a reliable signal that no refresh has
        // confirmed the pane yet — refresh-derived entries always carry the tmux
        // session name. The next refresh that does see the pane confirms it; if the
        // pane truly never appears in tmux a follow-up hook with the same paneId
        // updates in place rather than accumulating.
        let stalePaneIds = paneStates.keys.filter { paneId in
            guard !currentPaneIds.contains(paneId) else { return false }
            return paneStates[paneId]?.sessionName.isEmpty == false
        }
        for paneId in stalePaneIds {
            removeStaleState(paneId: paneId)
        }
    }

    // MARK: - Periodic Session Validation

    /// Starts a background task that periodically validates sessions against actual tmux panes.
    /// Sessions for panes that no longer exist are automatically removed.
    public func startPeriodicSessionValidation() {
        // Cancel any existing task
        sessionValidationTask?.cancel()
        startMenuTrackingObservation()

        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.validationInterval ?? 5))

                guard !Task.isCancelled, let self else { break }

                // While a menu is open, leave state alone — paneStates
                // mutations dismiss the popup mid-hover. The next cycle
                // (5 s later) will catch up once the user closes the menu.
                guard menuTrackingCount == 0 else { continue }

                // Refresh panes and update state
                let panes = await self.tmuxService.refreshPanes()
                self.updatePaneStates(from: panes)
                await self.refreshGitBranches()
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
        menuTrackingObservationTask?.cancel()
        menuTrackingObservationTask = nil
    }

    /// Watches for NSMenu tracking notifications so the validation loop can
    /// pause itself while the user has a popup open. `didBeginTracking` and
    /// `didEndTracking` post on every menu open/close globally — both
    /// menu-bar drop-downs and SwiftUI `.contextMenu` / `Menu` popups.
    private func startMenuTrackingObservation() {
        guard menuTrackingObservationTask == nil else { return }
        let center = NotificationCenter.default
        menuTrackingObservationTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in center.notifications(named: NSMenu.didBeginTrackingNotification) {
                        await self?.incrementMenuTrackingCount()
                    }
                }
                group.addTask { [weak self] in
                    for await _ in center.notifications(named: NSMenu.didEndTrackingNotification) {
                        await self?.decrementMenuTrackingCount()
                    }
                }
            }
        }
    }

    private func incrementMenuTrackingCount() {
        menuTrackingCount += 1
    }

    private func decrementMenuTrackingCount() {
        menuTrackingCount = max(0, menuTrackingCount - 1)
    }

    // MARK: - Session Management

    /// Updates the Claude session for the given pane ID, creating pane state if needed.
    /// Encapsulates the copy-mutate-reassign pattern for struct values in dictionaries.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - update: A closure that mutates the session
    private func updateSession(paneId: String, _ update: (inout ClaudeSession) -> Void) {
        var session = paneStates[paneId]?.claudeSession ?? ClaudeSession(paneId: paneId)
        update(&session)
        if paneStates[paneId] != nil {
            paneStates[paneId]?.claudeSession = session
        } else {
            // Pane not yet known from tmux refresh — create minimal state
            paneStates[paneId] = PaneState(paneId: paneId, claudeSession: session)
        }
    }

    /// Marks panes as Claude sessions based on process detection at startup.
    /// Only creates sessions for panes that don't already have one (hook-based
    /// detection takes precedence).
    /// - Parameter panes: Mapping of pane ID to the pane's current working directory
    public func markDetectedClaudeSessions(_ panes: [String: String]) {
        for (paneId, path) in panes where paneStates[paneId] != nil && paneStates[paneId]?.claudeSession == nil {
            updateSession(paneId: paneId) { session in
                session.detectedProjectPath = path
            }
        }
    }

    // MARK: - Hook Event Handling

    /// Handles incoming hook events - tracks active sessions
    /// - Parameter event: The hook event to process
    public func handleHookEvent(_ event: HookEvent) async {
        guard let paneId = event.tmuxPane else { return }

        // A hook event that updates working/notification state wins over any
        // CLI-driven override so subsequent hook activity is reflected. The
        // sidebar aggregates state across every pane in the session, so clear
        // the override on every sibling pane — not just the one this event
        // targeted — otherwise the row keeps reading from a stale sibling.
        if event.isWorking != nil || event.wouldTriggerNotification {
            let sessionName = paneStates[paneId]?.sessionName
            if let sessionName, !sessionName.isEmpty {
                for (otherId, state) in paneStates where state.sessionName == sessionName {
                    paneStates[otherId]?.cliSessionState = nil
                }
            } else {
                paneStates[paneId]?.cliSessionState = nil
            }
        }

        // Track active session based on event type
        switch event.action {
        case let .sessionEnd(body):
            // Add the final event before removing the session
            updateSession(paneId: paneId) { $0.addEvent(event) }
            paneStates[paneId]?.claudeSession = nil
            paneStates[paneId]?.yoloMode = false
            // Drop the CLI override too — the session it was decorating is gone.
            // Mirror the working/notification path above and clear every sibling
            // pane in the same tmux session, since `session.set_state --session`
            // can stamp the override across all of them. Otherwise siblings keep
            // a stale override after Claude exits in one pane and no further
            // hook events arrive to clear them.
            let sessionName = paneStates[paneId]?.sessionName
            if let sessionName, !sessionName.isEmpty {
                for (otherId, state) in paneStates where state.sessionName == sessionName {
                    paneStates[otherId]?.cliSessionState = nil
                }
            } else {
                paneStates[paneId]?.cliSessionState = nil
            }

            // Close the pane when Claude exits normally (user quit at prompt)
            if settings.closePaneOnSessionEnd && body.reason == .promptInputExit {
                closePaneWhenClaudeExits(paneId: paneId)
            }

        case .sessionStart:
            // Yolo mode is NOT reset here — context compaction restarts
            // send sessionStart without a preceding sessionEnd, so yolo
            // must carry over. Normal session endings already clear yolo
            // via the sessionEnd handler above.
            updateSession(paneId: paneId) { $0.addEvent(event) }

        case let .permissionRequest(body) where isYoloModeEnabled(for: paneId) && body.isYoloAutoApprovable:
            // Yolo mode: auto-approve by sending Enter after a short delay
            updateSession(paneId: paneId) {
                $0.addEvent(event)
                $0.markAutoApproved()
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try await tmuxService.sendKeys(paneId, keys: "Enter")
            } catch {
                // If auto-approve fails, fall through to normal flow
            }

        case .setup,
             .permissionRequest,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .postToolBatch,
             .permissionDenied,
             .notification,
             .userPromptSubmit,
             .userPromptExpansion,
             .stop,
             .stopFailure,
             .subagentStart,
             .subagentStop,
             .teammateIdle,
             .taskCreated,
             .taskCompleted,
             .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitation,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .unknown:
            updateSession(paneId: paneId) { $0.addEvent(event) }
        }
    }

    /// Updates the terminal title for a pane.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - title: The new terminal title
    public func updateTerminalTitle(paneId: String, title: String) {
        paneStates[paneId]?.terminalTitle = title
    }

    /// Updates the `OSC 9;4` progress signal for a pane. `.removed` clears it.
    /// Returns `true` if the stored value actually changed; the caller can use
    /// that to decide whether to push session state to viewers.
    @discardableResult
    public func setPaneProgress(_ progress: TerminalProgressState, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        let normalized: TerminalProgressState? = progress == .removed ? nil : progress
        if paneStates[paneId]?.progress == normalized {
            return false
        }
        paneStates[paneId]?.progress = normalized
        return true
    }

    /// Set of pane IDs that have active Claude sessions
    public var activeSessionPaneIds: Set<String> {
        Set(paneStates.filter { $0.value.claudeSession != nil }.keys)
    }

    /// Number of sessions that need user attention
    public var pendingSessionCount: Int {
        paneStates.values.filter { $0.claudeSession?.needsAttention == true }.count
    }

    /// All sessions sorted with attention-needing sessions first
    public var sortedSessions: [ClaudeSession] {
        paneStates.values
            .compactMap(\.claudeSession)
            .sorted {
                if $0.needsAttention != $1.needsAttention {
                    return $0.needsAttention
                }
                return $0.paneId < $1.paneId
            }
    }

    // MARK: - Mark Handled

    /// Marks a session as handled (user has seen it), clearing the `needsAttention` flag.
    /// - Parameter paneId: The pane ID whose session should be marked handled
    public func markSessionHandled(paneId: String) {
        guard paneStates[paneId]?.claudeSession?.needsAttention == true else { return }
        paneStates[paneId]?.claudeSession?.markHandled()
    }

    // MARK: - CLI Session State Override

    /// Sets the CLI-driven session state override for a pane. Pass `nil` to
    /// clear the override and revert to whatever the underlying Claude session
    /// (or absence of one) reports. No-op if the pane isn't tracked yet —
    /// callers should refresh tmux state first so `sessionName` is populated;
    /// otherwise the session-wide hook clearing in `handleHookEvent` can't
    /// match siblings.
    /// - Parameters:
    ///   - state: The override to apply, or `nil` to clear.
    ///   - paneId: The pane to apply the override to.
    /// - Returns: `true` when an existing pane was updated.
    @discardableResult
    public func setCLISessionState(_ state: CLISessionState?, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        paneStates[paneId]?.cliSessionState = state
        return true
    }

    // MARK: - Yolo Mode

    /// Sets yolo mode for a pane's Claude session.
    /// When enabled, permission requests are auto-approved by sending Enter keystroke.
    /// If there's already a pending auto-approvable permission request, it is approved immediately.
    /// - Parameters:
    ///   - enabled: Whether to enable or disable yolo mode
    ///   - paneId: The pane ID to set yolo mode for
    public func setYoloMode(enabled: Bool, for paneId: String) {
        if paneStates[paneId] != nil {
            paneStates[paneId]?.yoloMode = enabled
        } else {
            // Create minimal state if needed
            paneStates[paneId] = PaneState(paneId: paneId, yoloMode: enabled)
        }

        // When enabling, auto-approve any pending permission request
        if
            enabled,
            let latestEvent = paneStates[paneId]?.claudeSession?.latestEvent,
            case let .permissionRequest(body) = latestEvent.action,
            body.isYoloAutoApprovable {
            paneStates[paneId]?.claudeSession?.markAutoApproved()
            let eventId = latestEvent.id
            Task { [tmuxService] in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    // Verify the event hasn't been superseded to avoid a double-Enter
                    guard self.paneStates[paneId]?.claudeSession?.latestEvent?.id == eventId else { return }
                    try await tmuxService.sendKeys(paneId, keys: "Enter")
                } catch {
                    // If auto-approve fails, the user can still approve manually
                }
            }
        }
    }

    /// Whether yolo mode is enabled for the given pane
    public func isYoloModeEnabled(for paneId: String) -> Bool {
        paneStates[paneId]?.yoloMode ?? false
    }

    // MARK: - Session Descriptions

    /// Sets a custom description for a session, updating every pane in every window
    /// of that session so the description survives switching windows/tabs.
    /// The description is persisted as a tmux user option so it survives app restarts.
    /// - Parameters:
    ///   - description: The description text, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionDescription(_ description: String?, for sessionName: String) {
        let normalizedDescription = description?.isEmpty == true ? nil : description
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customDescription = normalizedDescription
        }
        Task { [tmuxService] in
            try? await tmuxService.setSessionDescription(normalizedDescription, for: sessionName)
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Colors

    /// Sets a custom color for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - color: The color, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionColor(_ color: SessionColor?, for sessionName: String) {
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customColor = color
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionColor(color, for: sessionName)
            } catch {
                logger.warning("Failed to persist session color", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Emoji

    /// Sets a custom emoji for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - emoji: The emoji string, or nil/empty to clear
    ///   - sessionName: The tmux session name
    public func setSessionEmoji(_ emoji: String?, for sessionName: String) {
        let normalizedEmoji = emoji?.isEmpty == true ? nil : emoji
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customEmoji = normalizedEmoji
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionEmoji(normalizedEmoji, for: sessionName)
            } catch {
                logger.warning("Failed to persist session emoji", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Auto-Close Pane

    /// Polls until the Claude process exits from the pane, then closes the pane after a short delay.
    private func closePaneWhenClaudeExits(paneId: String) {
        Task { [tmuxService] in
            // Poll until Claude is no longer running in this pane (up to 30 seconds)
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                let claudePanes = await tmuxService.detectClaudePanes()
                if claudePanes[paneId] == nil {
                    // Claude process has exited — wait 1 second then close the pane
                    try? await Task.sleep(for: .seconds(1))
                    try? await tmuxService.killPane(paneId)
                    return
                }
            }
        }
    }

    // MARK: - Git Branch Detection

    private static let gitPath = "/usr/bin/git"

    /// Refreshes git branch info for all panes that have a current path.
    func refreshGitBranches() async {
        var panesForPath: [String: [String]] = [:]
        for (paneId, state) in paneStates {
            guard let path = state.currentPath, !path.isEmpty else { continue }
            panesForPath[path, default: []].append(paneId)
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for path in panesForPath.keys {
                group.addTask { [processRunner] in
                    let branch = await Self.detectGitBranch(at: path, processRunner: processRunner)
                    return (path, branch)
                }
            }

            for await (path, branch) in group {
                for paneId in panesForPath[path] ?? [] {
                    paneStates[paneId]?.gitBranch = branch
                }
            }
        }
    }

    /// Detects the git branch for a given directory path.
    /// Returns nil if the path is not inside a git repository.
    private static func detectGitBranch(
        at path: String,
        processRunner: ProcessRunner
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard
            let result = try? await processRunner.run(
                gitPath,
                ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                nil,
                5
            ) else { return nil }

        guard result.isSuccess else { return nil }
        let branch = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty { return nil }
        // `git rev-parse --abbrev-ref HEAD` returns the literal "HEAD" when the
        // working copy is in a detached-HEAD state. Surface that explicitly
        // rather than showing "HEAD" in the sidebar.
        if branch == "HEAD" { return "(detached)" }
        return branch
    }

    // MARK: - State Cleanup

    /// Removes state for a pane that no longer exists.
    private func removeStaleState(paneId: String) {
        paneStates.removeValue(forKey: paneId)
    }
}
