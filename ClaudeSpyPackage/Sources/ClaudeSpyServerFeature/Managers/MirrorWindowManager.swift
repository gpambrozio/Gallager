import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Manages pane state, hook events, and session tracking.
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Unified per-pane state keyed by pane ID.
    /// Contains tmux metadata, Claude session, terminal title, and yolo mode.
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Task for periodic session validation
    private var sessionValidationTask: Task<Void, Never>?

    /// Called when window descriptions change, to push updated state to viewers
    public var onDescriptionChanged: (@MainActor @Sendable () async -> Void)?

    /// Interval between session validation checks (in seconds)
    private let validationInterval: TimeInterval = 5

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
    public func updatePaneStates(from panes: [PaneInfo]) {
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

        // Remove stale entries
        let stalePaneIds = paneStates.keys.filter { !currentPaneIds.contains($0) }
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

        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.validationInterval ?? 5))

                guard !Task.isCancelled, let self else { break }

                // Refresh panes and update state
                let panes = await self.tmuxService.refreshPanes()
                self.updatePaneStates(from: panes)
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
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

        // Track active session based on event type
        switch event.action {
        case let .sessionEnd(body):
            // Add the final event before removing the session
            updateSession(paneId: paneId) { $0.addEvent(event) }
            paneStates[paneId]?.claudeSession = nil
            paneStates[paneId]?.yoloMode = false

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
            updateSession(paneId: paneId) { $0.addEvent(event) }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try await tmuxService.sendKeys(paneId, keys: "Enter")
            } catch {
                // If auto-approve fails, fall through to normal flow
            }

        default:
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
        if enabled,
           let latestEvent = paneStates[paneId]?.claudeSession?.latestEvent,
           case let .permissionRequest(body) = latestEvent.action,
           body.isYoloAutoApprovable
        {
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

    // MARK: - Window Descriptions

    /// Sets a custom description for a window, updating all panes that belong to it.
    /// - Parameters:
    ///   - description: The description text, or nil to clear
    ///   - windowId: The window ID (sessionName:windowIndex)
    public func setWindowDescription(_ description: String?, for windowId: String) {
        let normalizedDescription = description?.isEmpty == true ? nil : description
        for (paneId, state) in paneStates where state.windowId == windowId {
            paneStates[paneId]?.customDescription = normalizedDescription
        }
        // Fire-and-forget: avoids blocking the caller while the push completes
        Task { await onDescriptionChanged?() }
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

    // MARK: - State Cleanup

    /// Removes state for a pane that no longer exists.
    private func removeStaleState(paneId: String) {
        paneStates.removeValue(forKey: paneId)
    }
}
