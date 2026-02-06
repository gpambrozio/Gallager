import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Manages session state received from remote Mac hosts.
///
/// This store maintains a synchronized view of Claude Code sessions and panes
/// that are relayed from Mac hosts through the external server.
@Observable
@MainActor
final public class RemoteSessionStore {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.remotesessionstore")

    /// Active Claude sessions by pane ID
    public private(set) var sessions: [String: ClaudeSession] = [:]

    /// Maps pane ID to source Mac host's pairId
    private var paneToHostMap: [String: String] = [:]

    /// List of active pane IDs
    public private(set) var activePanes: [String] = []

    /// All tmux panes grouped by source Mac host's pairId
    public private(set) var panesByHost: [String: [PaneInfoMessage]] = [:]

    /// Claude projects grouped by source Mac host's pairId
    public private(set) var claudeProjectsByHost: [String: [ClaudeProjectInfo]] = [:]

    /// Mac hosts that have sent at least one full state update
    private var hostsWithReceivedState: Set<String> = []

    // MARK: - Computed Properties (All Hosts Combined)

    /// Claude sessions sorted by most recent event timestamp (all hosts combined)
    public var sortedSessions: [(paneId: String, session: ClaudeSession)] {
        sessions
            .map { (paneId: $0.key, session: $0.value) }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// All panes combined from all Mac hosts
    public var panes: [PaneInfoMessage] {
        panesByHost.values.flatMap { $0 }
    }

    /// All Claude projects combined from all Mac hosts
    public var claudeProjects: [ClaudeProjectInfo] {
        claudeProjectsByHost.values.flatMap { $0 }
    }

    /// Panes without Claude sessions (plain terminals)
    public var plainTerminalPanes: [PaneInfoMessage] {
        let sessionPaneIds = Set(sessions.keys)
        return panes.filter { !sessionPaneIds.contains($0.id) }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !sessions.isEmpty || !panesByHost.isEmpty
    }

    /// Total number of sessions
    public var sessionCount: Int {
        sessions.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        sessions.count + plainTerminalPanes.count
    }

    // MARK: - Per-Host Computed Properties

    /// Get Claude sessions for a specific Mac host, sorted by most recent event
    public func sessions(for hostId: String) -> [(paneId: String, session: ClaudeSession)] {
        sessions
            .filter { paneToHostMap[$0.key] == hostId }
            .map { (paneId: $0.key, session: $0.value) }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.latestEvent?.timestamp ?? .distantPast
                let rhsTime = rhs.session.latestEvent?.timestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Get plain terminal panes (no Claude session) for a specific Mac host
    public func panes(for hostId: String) -> [PaneInfoMessage] {
        let hostPanes = panesByHost[hostId] ?? []
        let sessionPaneIds = Set(sessions.keys.filter { paneToHostMap[$0] == hostId })
        return hostPanes.filter { !sessionPaneIds.contains($0.id) }
    }

    /// Get Claude projects for a specific Mac host
    public func projects(for hostId: String) -> [ClaudeProjectInfo] {
        claudeProjectsByHost[hostId] ?? []
    }

    /// Get the source Mac host ID for a pane
    public func hostId(for paneId: String) -> String? {
        paneToHostMap[paneId]
    }

    /// Check if a Mac host has any sessions or panes
    public func hasSessions(for hostId: String) -> Bool {
        let hasHostSessions = sessions.keys.contains { paneToHostMap[$0] == hostId }
        let hasHostPanes = !(panesByHost[hostId]?.isEmpty ?? true)
        return hasHostSessions || hasHostPanes
    }

    /// Whether a full session state has been received from the given Mac host
    public func hasReceivedState(for hostId: String) -> Bool {
        hostsWithReceivedState.contains(hostId)
    }

    // MARK: - Initialization

    public init() { }

    // MARK: - State Management

    /// Handle a hook event from a Mac host
    public func handleEvent(_ eventMessage: HookEventMessage) {
        let event = eventMessage.event
        let hostId = eventMessage.pairId
        let paneId = event.tmuxPane ?? event.action.sessionId

        logger.info("Handling hook event: \(event.action.eventName) for pane: \(paneId) from host: \(hostId)")

        // Track host source for this pane
        paneToHostMap[paneId] = hostId

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
            paneToHostMap.removeValue(forKey: paneId)
            logger.info("Session ended for pane: \(paneId)")

        default:
            break
        }
    }

    /// Handle a full session state update from a Mac host
    public func handleStateUpdate(_ state: SessionStateMessage) {
        let hostId = state.pairId

        logger.info(
            "Received full session state from host \(hostId): \(state.sessions.count) sessions, \(state.panes?.count ?? 0) panes, \(state.claudeProjects?.count ?? 0) projects"
        )

        // Build new state atomically to avoid UI flicker
        var newSessions = sessions.filter { paneToHostMap[$0.key] != hostId }
        var newPaneToHostMap = paneToHostMap.filter { $0.value != hostId }
        var newActivePanes = activePanes.filter { paneToHostMap[$0] != hostId }

        // Add sessions with host tracking
        for (paneId, session) in state.sessions {
            newSessions[paneId] = session
            newPaneToHostMap[paneId] = hostId
        }

        // Update active panes
        let hostActivePanes = state.activePanes
        newActivePanes.append(contentsOf: hostActivePanes)
        for paneId in hostActivePanes {
            newPaneToHostMap[paneId] = hostId
        }

        // Atomically swap all state
        sessions = newSessions
        paneToHostMap = newPaneToHostMap
        activePanes = newActivePanes
        panesByHost[hostId] = state.panes ?? []
        claudeProjectsByHost[hostId] = state.claudeProjects ?? []
        hostsWithReceivedState.insert(hostId)
    }

    /// Clear all sessions and panes for a specific Mac host
    public func clearSessions(for hostId: String) {
        let panesToRemove = paneToHostMap.filter { $0.value == hostId }.keys

        for paneId in panesToRemove {
            sessions.removeValue(forKey: paneId)
            paneToHostMap.removeValue(forKey: paneId)
            activePanes.removeAll { $0 == paneId }
        }

        panesByHost.removeValue(forKey: hostId)
        claudeProjectsByHost.removeValue(forKey: hostId)
        hostsWithReceivedState.remove(hostId)

        logger.info("Cleared all sessions for Mac host: \(hostId)")
    }

    /// Get a session by pane ID
    public func session(for paneId: String) -> ClaudeSession? {
        sessions[paneId]
    }

    /// Check if a pane is currently active
    public func isPaneActive(_ paneId: String) -> Bool {
        activePanes.contains(paneId)
    }
}
