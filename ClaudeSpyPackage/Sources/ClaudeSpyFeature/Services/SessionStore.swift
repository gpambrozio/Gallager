import ClaudeSpyCommon
import Foundation
import os

/// Manages local session state received from the Mac app.
///
/// This store maintains a synchronized view of Claude Code sessions and hook events
/// that are relayed from the Mac through the external server.
@Observable
@MainActor
final public class SessionStore {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.claudespy.ios", category: "SessionStore")

    /// Active Claude sessions by pane ID
    public private(set) var sessions: [String: ClaudeSession] = [:]

    /// List of active pane IDs
    public private(set) var activePanes: [String] = []

    /// All tmux panes (including those without Claude sessions)
    public private(set) var panes: [PaneInfoMessage] = []

    /// User responses to events, keyed by event ID
    /// This persists across navigation so responses aren't lost
    private var eventResponses: [UUID: ResponseType] = [:]

    /// Claude sessions sorted by most recent event timestamp
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

    /// Panes that have Claude sessions (for section 1)
    public var claudeSessionPanes: [(paneId: String, session: ClaudeSession)] {
        sortedSessions
    }

    /// Panes without Claude sessions (plain terminals, for section 2)
    public var plainTerminalPanes: [PaneInfoMessage] {
        let sessionPaneIds = Set(sessions.keys)
        return panes.filter { !sessionPaneIds.contains($0.id) }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !sessions.isEmpty || !panes.isEmpty
    }

    /// Total number of sessions
    public var sessionCount: Int {
        sessions.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        sessions.count + plainTerminalPanes.count
    }

    // MARK: - Initialization

    public init() { }

    // MARK: - State Management

    /// Handle a hook event from the Mac
    public func handleEvent(_ eventMessage: HookEventMessage) {
        let event = eventMessage.event
        let paneId = event.tmuxPane ?? event.action.sessionId

        logger.info("Handling hook event: \(event.action.eventName) for pane: \(paneId)")

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
            logger.info("Session ended for pane: \(paneId)")

        default:
            break
        }
    }

    /// Handle a full session state update from the Mac
    public func handleStateUpdate(_ state: SessionStateMessage) {
        logger.info(
            "Received full session state: \(state.sessions.count) sessions, \(state.panes?.count ?? 0) panes"
        )

        sessions = state.sessions
        activePanes = state.activePanes
        panes = state.panes ?? []
    }

    /// Clear all session data (e.g., on disconnect)
    public func clearOnDisconnect() {
        logger.info("Clearing session data on disconnect")
        sessions.removeAll()
        activePanes.removeAll()
        panes.removeAll()
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
