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

    /// Agent projects grouped by source host's pairId
    public private(set) var agentProjectsByHost: [String: [AgentProject]] = [:]

    /// Plugin presentations keyed by plugin id, full-replaced on each
    /// `plugin_presentations` push (spec §7.3). In-memory only — the host
    /// re-pushes the complete set on every viewer connect. The sidebar reads
    /// the icon/name/color for a session's `pluginID` from here.
    public private(set) var presentationsByPluginID: [String: PluginPresentation] = [:]

    /// Home directory path for each host, keyed by pairId
    public private(set) var homeDirectoryByHost: [String: String] = [:]

    /// Hosts that have sent at least one full state update
    private var hostsWithReceivedState: Set<String> = []

    // MARK: - Computed Properties (All Hosts Combined)

    /// All panes combined from all hosts
    public var panes: [PaneState] {
        Array(paneStates.values)
    }

    /// All agent projects combined from all hosts
    public var agentProjects: [AgentProject] {
        agentProjectsByHost.values.flatMap { $0 }
    }

    /// Panes without agent sessions (plain terminals)
    public var plainTerminalPanes: [PaneState] {
        paneStates.values.filter { $0.agentSession == nil }
    }

    /// Whether there are any sessions or panes to display
    public var hasSessions: Bool {
        !paneStates.isEmpty
    }

    /// Total number of agent sessions
    public var sessionCount: Int {
        paneStates.values.filter { $0.agentSession != nil }.count
    }

    /// Total number of items to display (Claude sessions + plain terminals)
    public var totalItemCount: Int {
        paneStates.count
    }

    // MARK: - Per-Host Computed Properties

    /// Get agent sessions for a specific host, sorted by display name.
    public func agentSessions(for hostId: String) -> [(paneId: String, session: AgentSession)] {
        paneStates
            .filter { $0.key.pairId == hostId }
            .compactMap { key, state -> (paneId: String, session: AgentSession)? in
                guard let session = state.agentSession else { return nil }
                return (paneId: key.paneId, session: session)
            }
            .sorted { lhs, rhs in
                lhs.session.displayName.localizedCaseInsensitiveCompare(rhs.session.displayName) == .orderedAscending
            }
    }

    /// Get plain terminal panes (no agent session) for a specific host
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

    /// Get agent projects for a specific host
    public func projects(for hostId: String) -> [AgentProject] {
        agentProjectsByHost[hostId] ?? []
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

    /// Handle a per-session state update from a host (the agent-blind plugin
    /// status message — replaces the old hook-event path). The `AgentState`
    /// carries the open response form via its `awaiting*` cases, so moving to any
    /// non-awaiting state retracts the form automatically.
    public func handleAgentStatus(_ status: AgentSessionStatusMessage) {
        let hostId = status.pairId
        let paneId = status.sessionId
        let key = PaneKey(pairId: hostId, paneId: paneId)

        // Upsert the agent session within the pane state, setting its state.
        var session = paneStates[key]?.agentSession ?? AgentSession(paneId: paneId, pluginID: status.pluginId)
        session.pluginID = status.pluginId
        session.state = status.state

        if paneStates[key] != nil {
            paneStates[key]?.agentSession = session
        } else {
            paneStates[key] = PaneState(paneId: paneId, agentSession: session)
        }
    }

    /// Handle a full session state update from a host
    public func handleStateUpdate(_ state: SessionStateMessage) {
        let hostId = state.pairId

        logger.info(
            "Received full session state from host \(hostId): \(state.paneStates.count) panes, \(state.agentProjects?.count ?? 0) projects"
        )

        // Build new state atomically to avoid UI flicker from clear-then-repopulate.
        // Drop this host's existing panes first, then add the incoming ones keyed by `(hostId, paneId)`.
        var newPaneStates = paneStates.filter { $0.key.pairId != hostId }

        for (paneId, paneState) in state.paneStates {
            newPaneStates[PaneKey(pairId: hostId, paneId: paneId)] = paneState
        }

        paneStates = newPaneStates
        agentProjectsByHost[hostId] = state.agentProjects ?? []
        homeDirectoryByHost[hostId] = state.homeDirectory
        hostsWithReceivedState.insert(hostId)

        // Open response forms ride `AgentSession.state` inside `paneStates`, so a
        // form that opened while we were disconnected is replayed for free as part
        // of the snapshot above — no separate reconcile needed.
    }

    /// Clear all sessions and panes for a specific host
    public func clearSessions(for hostId: String) {
        paneStates = paneStates.filter { $0.key.pairId != hostId }

        // Clear stored projects
        agentProjectsByHost.removeValue(forKey: hostId)
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

    /// Check if a pane is currently active (has an agent session)
    public func isPaneActive(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.agentSession != nil
    }

    /// Check if yolo mode is enabled for a pane (as reported by the host)
    public func isYoloModeEnabled(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.yoloMode ?? false
    }

    /// Marks a session as handled (user has seen it) locally. Only a finished
    /// session (`doneWorking`) goes idle; an `awaiting*` form is owed an explicit
    /// response so it survives viewing — the guard now lives inside
    /// `AgentSession.markHandled`.
    public func markSessionHandled(paneId: String, hostId: String) {
        let key = PaneKey(pairId: hostId, paneId: paneId)
        paneStates[key]?.agentSession?.markHandled()
    }

    // MARK: - Plugin Presentations

    /// Full-replace the plugin presentation cache from a `plugin_presentations`
    /// push. Always the complete enabled set (spec §7.2/§7.3).
    public func handlePluginPresentations(_ message: PluginPresentationsMessage) {
        presentationsByPluginID = Dictionary(
            message.presentations.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// The presentation for a plugin id, if cached.
    public func presentation(forPluginID pluginID: String) -> PluginPresentation? {
        presentationsByPluginID[pluginID]
    }

    // MARK: - Response Storage (iOS only)

    #if os(iOS)
        /// Stored responses for interactive response requests, keyed by the
        /// request id of the originating `AgentResponseRequest`. iOS-only because
        /// only the iOS app has the interactive response flow.
        private var requestResponses: [String: ResponseType] = [:]

        /// Get the stored response for a request id, if any.
        public func response(forRequestID requestID: String) -> ResponseType? {
            requestResponses[requestID]
        }

        /// Store a response for a request id.
        public func setResponse(_ response: ResponseType?, forRequestID requestID: String) {
            if let response {
                requestResponses[requestID] = response
            } else {
                requestResponses.removeValue(forKey: requestID)
            }
        }
    #endif
}
