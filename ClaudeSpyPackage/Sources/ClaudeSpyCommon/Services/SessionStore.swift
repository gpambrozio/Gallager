import ClaudeSpyNetworking
import Foundation

/// Composite identity for a pane originating from a specific host.
///
/// A viewer can be connected to several hosts at once, and tmux assigns
/// pane IDs independently on each host (both `%0`, `%1`, etc. are reused).
/// Keying only by `paneId` across hosts makes them collide, so the viewer
/// stores panes under `(pairId, paneId)` — the `pairId` uniquely identifies
/// both the host and the user account on that host via the pairing flow.
public struct PaneKey: Hashable, Sendable {
    public let pairId: String
    public let paneId: String

    public init(pairId: String, paneId: String) {
        self.pairId = pairId
        self.paneId = paneId
    }
}

/// One outstanding plugin-driven response request, keyed by its `requestId`.
///
/// Wraps the wire `AgentResponseRequest` alongside the routing fields the iOS
/// UI needs to render it (which host pushed it, which session it belongs to,
/// which plugin owns the session). Used by `SessionStore.responseRequests`;
/// Task 19 reads this state into a sheet.
public struct ResponseRequestEntry: Sendable, Equatable {
    public let hostId: String
    public let sessionId: String
    public let pluginId: String
    public let requestId: String
    public let request: AgentResponseRequest
    /// When this request arrived locally. Used to select the most recent
    /// request when several are open on the same session simultaneously.
    public let receivedAt: Date

    public init(
        hostId: String,
        sessionId: String,
        pluginId: String,
        requestId: String,
        request: AgentResponseRequest,
        receivedAt: Date = Date()
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.request = request
        self.receivedAt = receivedAt
    }
}

/// Manages local session state received from multiple host servers.
///
/// This store maintains a synchronized view of Claude Code sessions and hook events
/// that are relayed from hosts through the external server, grouped by source host.
@Observable
@MainActor
final public class SessionStore {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.sessionstore")

    /// Per-pane state keyed by `(pairId, paneId)` to disambiguate panes
    /// whose IDs collide across hosts.
    public private(set) var paneStates: [PaneKey: PaneState] = [:]

    /// Claude projects grouped by source host's pairId
    public private(set) var claudeProjectsByHost: [String: [AgentProject]] = [:]

    /// Home directory path for each host, keyed by pairId
    public private(set) var homeDirectoryByHost: [String: String] = [:]

    /// Hosts that have sent at least one full state update
    private var hostsWithReceivedState: Set<String> = []

    /// Outstanding plugin-driven response requests, keyed by `requestId`.
    ///
    /// Plugin sidecars push `agent_response_request` messages when a session
    /// needs the user to answer something (permission prompt, free-text reply,
    /// menu pick, plan approval, ...). `SessionDetailService` picks the entry
    /// matching its `(hostId, sessionId, pluginId)` and the response views
    /// render it. A subsequent `agent_response_request` carrying
    /// `request == nil` for the same `requestId` removes the entry — the
    /// sidecar's way of saying "the user no longer needs to answer this".
    public private(set) var responseRequests: [String: ResponseRequestEntry] = [:]

    // MARK: - Computed Properties (All Hosts Combined)

    /// All panes combined from all hosts
    public var panes: [PaneState] {
        Array(paneStates.values)
    }

    /// All Claude projects combined from all hosts
    public var claudeProjects: [AgentProject] {
        claudeProjectsByHost.values.flatMap { $0 }
    }

    /// Panes without Claude sessions (plain terminals)
    public var plainTerminalPanes: [PaneState] {
        paneStates.values.filter { $0.agentSession == nil }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !paneStates.isEmpty
    }

    /// Total number of Claude sessions
    public var sessionCount: Int {
        paneStates.values.filter { $0.agentSession != nil }.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        paneStates.count
    }

    // MARK: - Per-Host Computed Properties

    /// Get Claude sessions for a specific host, sorted by most recent event
    public func agentSessions(for hostId: String) -> [(paneId: String, session: AgentSession)] {
        paneStates
            .filter { $0.key.pairId == hostId }
            .compactMap { key, state -> (paneId: String, session: AgentSession)? in
                guard let session = state.agentSession else { return nil }
                return (paneId: key.paneId, session: session)
            }
            .sorted { lhs, rhs in
                let lhsTime = lhs.session.lastEventTimestamp ?? .distantPast
                let rhsTime = rhs.session.lastEventTimestamp ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    /// Get plain terminal panes (no Claude session) for a specific host
    public func panes(for hostId: String) -> [PaneState] {
        paneStates
            .filter { $0.key.pairId == hostId && $0.value.agentSession == nil }
            .map(\.value)
    }

    /// Get all pane states for a specific host grouped by tmux window
    public func windows(for hostId: String) -> [TmuxWindow] {
        let hostPanes = paneStates
            .filter { $0.key.pairId == hostId }
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
            .filter { $0.key.pairId == hostId && $0.value.windowId == windowId }
            .map(\.value)
            .sorted { $0.paneIndex < $1.paneIndex }
        guard let first = windowPanes.first else { return nil }
        return TmuxWindow(
            id: windowId,
            sessionName: first.sessionName,
            windowIndex: first.windowIndex,
            windowName: first.windowName,
            windowLayout: first.windowLayout,
            isWindowActive: first.isWindowActive,
            panes: windowPanes
        )
    }

    /// Get Claude projects for a specific host
    public func projects(for hostId: String) -> [AgentProject] {
        claudeProjectsByHost[hostId] ?? []
    }

    /// Check if a host has any sessions or panes
    public func hasSessions(for hostId: String) -> Bool {
        paneStates.keys.contains { $0.pairId == hostId }
    }

    /// Whether a full session state has been received from the given host
    public func hasReceivedState(for hostId: String) -> Bool {
        hostsWithReceivedState.contains(hostId)
    }

    // MARK: - Initialization

    public init() { }

    // MARK: - State Management

    /// Handle a full session state update from a host
    public func handleStateUpdate(_ state: SessionStateMessage) {
        let hostId = state.pairId

        logger.info(
            "Received full session state from host \(hostId): \(state.paneStates.count) panes, \(state.claudeProjects?.count ?? 0) projects"
        )

        // Build new state atomically to avoid UI flicker from clear-then-repopulate.
        // Drop this host's existing panes first, then add the incoming ones keyed by `(hostId, paneId)`.
        var newPaneStates = paneStates.filter { $0.key.pairId != hostId }

        for (paneId, paneState) in state.paneStates {
            newPaneStates[PaneKey(pairId: hostId, paneId: paneId)] = paneState
        }

        paneStates = newPaneStates
        claudeProjectsByHost[hostId] = state.claudeProjects ?? []
        homeDirectoryByHost[hostId] = state.homeDirectory
        hostsWithReceivedState.insert(hostId)
    }

    /// Apply an `agent_session_status` update pushed by a plugin sidecar.
    ///
    /// Finds the matching session by `(hostId, pluginId, sessionId)` and
    /// updates its `working` / `attention` / `lastEventTimestamp`. The wire
    /// envelope's `sessionId` is the agent's own session id (e.g. a Claude
    /// UUID), so we walk panes for the host and pick the one whose
    /// `agentSession` matches both the id and the plugin id.
    ///
    /// If no matching session is found the update is dropped — the session
    /// state push that introduces the session may simply not have arrived
    /// yet, and the next full state update will overwrite the stale flags.
    public func applyStatus(_ update: AgentSessionStatusUpdate, hostId: String) {
        let matchingKey = paneStates.first { key, state in
            key.pairId == hostId
                && state.agentSession?.id == update.sessionId
                && state.agentSession?.pluginID == update.pluginId
        }?.key

        guard let matchingKey else {
            logger.debug(
                "applyStatus: no session matching pluginId=\(update.pluginId) sessionId=\(update.sessionId) on host \(hostId)"
            )
            return
        }

        paneStates[matchingKey]?.agentSession?.working = update.working
        paneStates[matchingKey]?.agentSession?.attention = update.attention
        paneStates[matchingKey]?.agentSession?.lastEventTimestamp = update.timestamp
    }

    /// Present a plugin-driven response request. Stores the request keyed by
    /// `requestId`; a later `dismissResponseRequest(requestID:)` call (or an
    /// inbound `agent_response_request` with `request == nil`) removes it.
    public func presentResponseRequest(_ entry: ResponseRequestEntry) {
        responseRequests[entry.requestId] = entry
    }

    /// Dismiss the response request matching `requestID`. No-op if no such
    /// request is open.
    public func dismissResponseRequest(requestID: String) {
        responseRequests.removeValue(forKey: requestID)
    }

    /// Clear all sessions and panes for a specific host
    public func clearSessions(for hostId: String) {
        paneStates = paneStates.filter { $0.key.pairId != hostId }
        responseRequests = responseRequests.filter { $0.value.hostId != hostId }

        // Clear stored projects
        claudeProjectsByHost.removeValue(forKey: hostId)
        homeDirectoryByHost.removeValue(forKey: hostId)
        hostsWithReceivedState.remove(hostId)

        logger.info("Cleared all sessions for host: \(hostId)")
    }

    /// Get a session by host and pane ID
    public func session(for paneId: String, hostId: String) -> AgentSession? {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.agentSession
    }

    /// Get the pane state by host and pane ID
    public func paneState(for paneId: String, hostId: String) -> PaneState? {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]
    }

    /// Check if a pane is currently active (has a Claude session)
    public func isPaneActive(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.agentSession != nil
    }

    /// Check if yolo mode is enabled for a pane (as reported by the host)
    public func isYoloModeEnabled(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.yoloMode ?? false
    }

    /// Marks a session as handled (user has seen it), clearing the `attention` flag locally.
    public func markSessionHandled(paneId: String, hostId: String) {
        let key = PaneKey(pairId: hostId, paneId: paneId)
        guard paneStates[key]?.agentSession?.attention == true else { return }
        paneStates[key]?.agentSession?.markHandled()
    }
}
