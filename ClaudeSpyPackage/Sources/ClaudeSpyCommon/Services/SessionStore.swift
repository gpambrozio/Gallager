import Foundation

/// Manages local session state received from multiple Mac servers.
///
/// This store maintains a synchronized view of Claude Code sessions and hook events
/// that are relayed from Macs through the external server, grouped by source Mac.
@Observable
@MainActor
final public class SessionStore {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.sessionstore")

    /// Active Claude sessions by pane ID
    public private(set) var sessions: [String: ClaudeSession] = [:]

    /// Maps pane ID to source Mac's pairId
    private var paneToMacMap: [String: String] = [:]

    /// List of active pane IDs
    public private(set) var activePanes: [String] = []

    /// All tmux panes grouped by source Mac's pairId
    public private(set) var panesByMac: [String: [PaneInfoMessage]] = [:]

    /// Claude projects grouped by source Mac's pairId
    public private(set) var claudeProjectsByMac: [String: [ClaudeProjectInfo]] = [:]

    /// Macs that have sent at least one full state update
    private var macsWithReceivedState: Set<String> = []

    /// User responses to events, keyed by event ID
    /// This persists across navigation so responses aren't lost
    private var eventResponses: [UUID: ResponseType] = [:]

    // MARK: - Computed Properties (All Macs Combined)

    /// Claude sessions sorted by most recent event timestamp (all Macs combined)
    public var sortedSessions: [(paneId: String, session: ClaudeSession)] {
        sessions
            .map { (paneId: $0.key, session: $0.value) }
            .sorted { lhs, rhs in
                // Sort by most recent event timestamp
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Panes that have Claude sessions (for legacy compatibility)
    public var claudeSessionPanes: [(paneId: String, session: ClaudeSession)] {
        sortedSessions
    }

    /// All panes combined from all Macs
    public var panes: [PaneInfoMessage] {
        panesByMac.values.flatMap { $0 }
    }

    /// All Claude projects combined from all Macs
    public var claudeProjects: [ClaudeProjectInfo] {
        claudeProjectsByMac.values.flatMap { $0 }
    }

    /// Panes without Claude sessions (plain terminals, for legacy compatibility)
    public var plainTerminalPanes: [PaneInfoMessage] {
        let sessionPaneIds = Set(sessions.keys)
        return panes.filter { !sessionPaneIds.contains($0.id) }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !sessions.isEmpty || !panesByMac.isEmpty
    }

    /// Total number of sessions
    public var sessionCount: Int {
        sessions.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        sessions.count + plainTerminalPanes.count
    }

    // MARK: - Per-Mac Computed Properties

    /// Get Claude sessions for a specific Mac, sorted by most recent event
    public func sessions(for macId: String) -> [(paneId: String, session: ClaudeSession)] {
        sessions
            .filter { paneToMacMap[$0.key] == macId }
            .map { (paneId: $0.key, session: $0.value) }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Get plain terminal panes (no Claude session) for a specific Mac
    public func panes(for macId: String) -> [PaneInfoMessage] {
        let macPanes = panesByMac[macId] ?? []
        let sessionPaneIds = Set(sessions.keys.filter { paneToMacMap[$0] == macId })
        return macPanes.filter { !sessionPaneIds.contains($0.id) }
    }

    /// Get Claude projects for a specific Mac
    public func projects(for macId: String) -> [ClaudeProjectInfo] {
        claudeProjectsByMac[macId] ?? []
    }

    /// Get the source Mac ID for a pane
    public func macId(for paneId: String) -> String? {
        paneToMacMap[paneId]
    }

    /// Check if a Mac has any sessions or panes
    public func hasSessions(for macId: String) -> Bool {
        let hasMacSessions = sessions.keys.contains { paneToMacMap[$0] == macId }
        let hasMacPanes = !(panesByMac[macId]?.isEmpty ?? true)
        return hasMacSessions || hasMacPanes
    }

    /// Whether a full session state has been received from the given Mac
    public func hasReceivedState(for macId: String) -> Bool {
        macsWithReceivedState.contains(macId)
    }

    // MARK: - Initialization

    public init() { }

    // MARK: - State Management

    /// Handle a hook event from a Mac
    public func handleEvent(_ eventMessage: HookEventMessage) {
        let event = eventMessage.event
        let macId = eventMessage.pairId
        let paneId = event.tmuxPane ?? event.action.sessionId

        logger.info("Handling hook event: \(event.action.eventName) for pane: \(paneId) from Mac: \(macId)")

        // Track Mac source for this pane
        paneToMacMap[paneId] = macId

        // Get or create session
        var session = sessions[paneId] ?? ClaudeSession(paneId: paneId)
        session.addEvent(event)
        sessions[paneId] = session

        // Handle session lifecycle
        switch event.action {
        case .sessionStart:
            if !activePanes.contains(paneId) {
                activePanes.append(paneId)
            }
            logger.info("Session started for pane: \(paneId)")

        case .sessionEnd:
            activePanes.removeAll { $0 == paneId }
            sessions.removeValue(forKey: paneId)
            paneToMacMap.removeValue(forKey: paneId)
            logger.info("Session ended for pane: \(paneId)")

        default:
            break
        }
    }

    /// Handle a full session state update from a Mac
    public func handleStateUpdate(_ state: SessionStateMessage) {
        let macId = state.pairId

        logger.info(
            "Received full session state from Mac \(macId): \(state.sessions.count) sessions, \(state.panes?.count ?? 0) panes, \(state.claudeProjects?.count ?? 0) projects"
        )

        // Build new state atomically to avoid UI flicker from clear-then-repopulate
        // First, filter out old data for this Mac
        var newSessions = sessions.filter { paneToMacMap[$0.key] != macId }
        var newPaneToMacMap = paneToMacMap.filter { $0.value != macId }
        var newActivePanes = activePanes.filter { paneToMacMap[$0] != macId }

        // Add sessions with Mac tracking
        for (paneId, session) in state.sessions {
            newSessions[paneId] = session
            newPaneToMacMap[paneId] = macId
        }

        // Update active panes
        let macActivePanes = state.activePanes
        newActivePanes.append(contentsOf: macActivePanes)
        for paneId in macActivePanes {
            newPaneToMacMap[paneId] = macId
        }

        // Atomically swap all state
        sessions = newSessions
        paneToMacMap = newPaneToMacMap
        activePanes = newActivePanes
        panesByMac[macId] = state.panes ?? []
        claudeProjectsByMac[macId] = state.claudeProjects ?? []
        macsWithReceivedState.insert(macId)
    }

    /// Clear all sessions and panes for a specific Mac
    public func clearSessions(for macId: String) {
        // Collect panes to remove first
        let panesToRemove = paneToMacMap.filter { $0.value == macId }.keys

        // Remove sessions, tracking, and active panes together
        for paneId in panesToRemove {
            sessions.removeValue(forKey: paneId)
            paneToMacMap.removeValue(forKey: paneId)
            activePanes.removeAll { $0 == paneId }
        }

        // Clear stored panes and projects
        panesByMac.removeValue(forKey: macId)
        claudeProjectsByMac.removeValue(forKey: macId)
        macsWithReceivedState.remove(macId)

        logger.info("Cleared all sessions for Mac: \(macId)")
    }

    /// Get a session by pane ID
    public func session(for paneId: String) -> ClaudeSession? {
        sessions[paneId]
    }

    /// Check if a pane is currently active
    public func isPaneActive(_ paneId: String) -> Bool {
        activePanes.contains(paneId)
    }

    // MARK: - Event Responses

    /// Get the stored response for an event, if any
    public func response(for eventId: UUID) -> ResponseType? {
        eventResponses[eventId]
    }

    /// Store a response for an event
    public func setResponse(_ response: ResponseType?, for eventId: UUID) {
        if let response {
            eventResponses[eventId] = response
            logger.debug("Stored response for event \(eventId): \(response.feedbackMessage)")
        } else {
            eventResponses.removeValue(forKey: eventId)
        }
    }
}
