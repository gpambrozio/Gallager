import ClaudeSpyNetworking
import Foundation

/// Manages local session state received from multiple host servers.
///
/// This store maintains a synchronized view of Claude Code sessions and hook events
/// that are relayed from hosts through the external server, grouped by source host.
@Observable
@MainActor
final public class SessionStore {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.sessionstore")

    /// Unified per-pane state keyed by pane ID (all hosts combined)
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Maps pane ID to source host's pairId
    private var paneToHostMap: [String: String] = [:]

    /// Claude projects grouped by source host's pairId
    public private(set) var claudeProjectsByHost: [String: [ClaudeProjectInfo]] = [:]

    /// Hosts that have sent at least one full state update
    private var hostsWithReceivedState: Set<String> = []

    // MARK: - Computed Properties (All Hosts Combined)

    /// Claude sessions sorted by most recent event timestamp (all hosts combined)
    public var sortedSessions: [(paneId: String, session: ClaudeSession)] {
        paneStates
            .compactMap { key, state -> (paneId: String, session: ClaudeSession)? in
                guard let session = state.claudeSession else { return nil }
                return (paneId: key, session: session)
            }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Panes that have Claude sessions (for legacy compatibility)
    public var claudeSessionPanes: [(paneId: String, session: ClaudeSession)] {
        sortedSessions
    }

    /// All panes combined from all hosts
    public var panes: [PaneState] {
        Array(paneStates.values)
    }

    /// All Claude projects combined from all hosts
    public var claudeProjects: [ClaudeProjectInfo] {
        claudeProjectsByHost.values.flatMap { $0 }
    }

    /// Panes without Claude sessions (plain terminals)
    public var plainTerminalPanes: [PaneState] {
        paneStates.values.filter { $0.claudeSession == nil }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !paneStates.isEmpty
    }

    /// Total number of Claude sessions
    public var sessionCount: Int {
        paneStates.values.filter { $0.claudeSession != nil }.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        paneStates.count
    }

    // MARK: - Per-Host Computed Properties

    /// Get Claude sessions for a specific host, sorted by most recent event
    public func sessions(for hostId: String) -> [(paneId: String, session: ClaudeSession)] {
        paneStates
            .filter { paneToHostMap[$0.key] == hostId }
            .compactMap { key, state -> (paneId: String, session: ClaudeSession)? in
                guard let session = state.claudeSession else { return nil }
                return (paneId: key, session: session)
            }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Get plain terminal panes (no Claude session) for a specific host
    public func panes(for hostId: String) -> [PaneState] {
        paneStates
            .filter { paneToHostMap[$0.key] == hostId && $0.value.claudeSession == nil }
            .map(\.value)
    }

    /// Get all pane states for a specific host grouped by tmux window
    public func windows(for hostId: String) -> [TmuxWindow] {
        let hostPanes = paneStates
            .filter { paneToHostMap[$0.key] == hostId }
            .map(\.value)
        return TmuxWindow.groupPanes(hostPanes)
    }

    /// Get all pane states for a specific host grouped by tmux session
    public func sessions(for hostId: String) -> [TmuxSession] {
        TmuxSession.groupWindows(windows(for: hostId))
    }

    /// Get a single window by ID for a specific host, without grouping all panes
    public func window(id windowId: String, hostId: String) -> TmuxWindow? {
        let windowPanes = paneStates
            .filter { paneToHostMap[$0.key] == hostId && $0.value.windowId == windowId }
            .map(\.value)
            .sorted { $0.paneIndex < $1.paneIndex }
        guard let first = windowPanes.first else { return nil }
        return TmuxWindow(
            id: windowId,
            sessionName: first.sessionName,
            windowIndex: first.windowIndex,
            windowName: first.windowName,
            windowLayout: first.windowLayout,
            panes: windowPanes
        )
    }

    /// Get Claude projects for a specific host
    public func projects(for hostId: String) -> [ClaudeProjectInfo] {
        claudeProjectsByHost[hostId] ?? []
    }

    /// Get the source host ID for a pane
    public func hostId(for paneId: String) -> String? {
        paneToHostMap[paneId]
    }

    /// Check if a host has any sessions or panes
    public func hasSessions(for hostId: String) -> Bool {
        paneStates.keys.contains { paneToHostMap[$0] == hostId }
    }

    /// Whether a full session state has been received from the given host
    public func hasReceivedState(for hostId: String) -> Bool {
        hostsWithReceivedState.contains(hostId)
    }

    // MARK: - Initialization

    public init() { }

    // MARK: - State Management

    /// Handle a hook event from a host
    public func handleEvent(_ eventMessage: HookEventMessage) {
        let event = eventMessage.event
        let hostId = eventMessage.pairId
        let paneId = event.tmuxPane ?? event.action.sessionId

        logger.info("Handling hook event: \(event.action.eventName) for pane: \(paneId) from host: \(hostId)")

        // Track host source for this pane
        paneToHostMap[paneId] = hostId

        // Get or create session within pane state
        var session = paneStates[paneId]?.claudeSession ?? ClaudeSession(paneId: paneId)
        session.addEvent(event)

        if paneStates[paneId] != nil {
            paneStates[paneId]?.claudeSession = session
        } else {
            paneStates[paneId] = PaneState(paneId: paneId, claudeSession: session)
        }

        // Handle session lifecycle
        switch event.action {
        case .sessionStart:
            logger.info("Session started for pane: \(paneId)")

        case .sessionEnd:
            paneStates[paneId]?.claudeSession = nil
            paneStates[paneId]?.yoloMode = false
            // Remove pane state entirely if it has no meaningful data
            if paneStates[paneId]?.target.isEmpty == true {
                paneStates.removeValue(forKey: paneId)
                paneToHostMap.removeValue(forKey: paneId)
            }
            logger.info("Session ended for pane: \(paneId)")

        default:
            break
        }
    }

    /// Handle a full session state update from a host
    public func handleStateUpdate(_ state: SessionStateMessage) {
        let hostId = state.pairId

        logger.info(
            "Received full session state from host \(hostId): \(state.paneStates.count) panes, \(state.claudeProjects?.count ?? 0) projects"
        )

        // Build new state atomically to avoid UI flicker from clear-then-repopulate
        // First, filter out old data for this host
        var newPaneStates = paneStates.filter { paneToHostMap[$0.key] != hostId }
        var newPaneToHostMap = paneToHostMap.filter { $0.value != hostId }

        // Add pane states with host tracking
        for (paneId, paneState) in state.paneStates {
            newPaneStates[paneId] = paneState
            newPaneToHostMap[paneId] = hostId
        }

        // Atomically swap all state
        paneStates = newPaneStates
        paneToHostMap = newPaneToHostMap
        claudeProjectsByHost[hostId] = state.claudeProjects ?? []
        hostsWithReceivedState.insert(hostId)
    }

    /// Clear all sessions and panes for a specific host
    public func clearSessions(for hostId: String) {
        // Collect panes to remove first
        let panesToRemove = paneToHostMap.filter { $0.value == hostId }.keys

        // Remove pane states and tracking
        for paneId in panesToRemove {
            paneStates.removeValue(forKey: paneId)
            paneToHostMap.removeValue(forKey: paneId)
        }

        // Clear stored projects
        claudeProjectsByHost.removeValue(forKey: hostId)
        hostsWithReceivedState.remove(hostId)

        logger.info("Cleared all sessions for host: \(hostId)")
    }

    /// Get a session by pane ID
    public func session(for paneId: String) -> ClaudeSession? {
        paneStates[paneId]?.claudeSession
    }

    /// Get the pane state by pane ID
    public func paneState(for paneId: String) -> PaneState? {
        paneStates[paneId]
    }

    /// Check if a pane is currently active (has a Claude session)
    public func isPaneActive(_ paneId: String) -> Bool {
        paneStates[paneId]?.claudeSession != nil
    }

    /// Check if yolo mode is enabled for a pane (as reported by the host)
    public func isYoloModeEnabled(for paneId: String) -> Bool {
        paneStates[paneId]?.yoloMode ?? false
    }

    /// Marks a session as handled (user has seen it), clearing the `needsAttention` flag locally.
    /// - Parameter paneId: The pane ID whose session should be marked handled
    public func markSessionHandled(paneId: String) {
        guard paneStates[paneId]?.claudeSession?.needsAttention == true else { return }
        paneStates[paneId]?.claudeSession?.markHandled()
    }

    // MARK: - Event Response Storage (iOS only)

    #if os(iOS)
        /// Stored responses for interactive events (permission requests, prompts, etc.)
        /// This is iOS-only because only the iOS app has the interactive response flow.
        private var eventResponses: [UUID: ResponseType] = [:]

        /// Get the stored response for an event, if any
        public func response(for eventId: UUID) -> ResponseType? {
            eventResponses[eventId]
        }

        /// Store a response for an event
        public func setResponse(_ response: ResponseType?, for eventId: UUID) {
            if let response {
                eventResponses[eventId] = response
            } else {
                eventResponses.removeValue(forKey: eventId)
            }
        }
    #endif
}
