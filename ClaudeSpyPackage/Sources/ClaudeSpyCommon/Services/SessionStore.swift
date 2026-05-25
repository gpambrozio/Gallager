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

    /// Claude projects grouped by source host's pairId
    public private(set) var claudeProjectsByHost: [String: [AgentProject]] = [:]

    /// Home directory path for each host, keyed by pairId
    public private(set) var homeDirectoryByHost: [String: String] = [:]

    /// Hosts that have sent at least one full state update
    private var hostsWithReceivedState: Set<String> = []

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
    public func claudeSessions(for hostId: String) -> [(paneId: String, session: ClaudeSession)] {
        paneStates
            .filter { $0.key.pairId == hostId }
            .compactMap { key, state -> (paneId: String, session: ClaudeSession)? in
                guard let session = state.claudeSession else { return nil }
                return (paneId: key.paneId, session: session)
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
            .filter { $0.key.pairId == hostId && $0.value.claudeSession == nil }
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

    /// Handle a hook event from a host
    public func handleEvent(_ eventMessage: HookEventMessage) {
        let event = eventMessage.event
        let hostId = eventMessage.pairId
        let paneId = event.tmuxPane ?? event.action.sessionId
        let key = PaneKey(pairId: hostId, paneId: paneId)

        logger.info("Handling hook event: \(event.action.eventName) for pane: \(paneId) from host: \(hostId)")

        // Get or create session within pane state
        var session = paneStates[key]?.claudeSession ?? ClaudeSession(paneId: paneId)
        session.addEvent(event)

        if paneStates[key] != nil {
            paneStates[key]?.claudeSession = session
        } else {
            paneStates[key] = PaneState(paneId: paneId, claudeSession: session)
        }

        // Handle session lifecycle
        switch event.action {
        case .sessionStart:
            logger.info("Session started for pane: \(paneId)")

        case .sessionEnd:
            paneStates[key]?.claudeSession = nil
            paneStates[key]?.yoloMode = false
            // Remove pane state entirely if it has no meaningful data
            if paneStates[key]?.target.isEmpty == true {
                paneStates.removeValue(forKey: key)
            }
            logger.info("Session ended for pane: \(paneId)")

        case .setup,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .postToolBatch,
             .permissionRequest,
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
            break
        }
    }

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

    /// Clear all sessions and panes for a specific host
    public func clearSessions(for hostId: String) {
        paneStates = paneStates.filter { $0.key.pairId != hostId }

        // Clear stored projects
        claudeProjectsByHost.removeValue(forKey: hostId)
        homeDirectoryByHost.removeValue(forKey: hostId)
        hostsWithReceivedState.remove(hostId)

        logger.info("Cleared all sessions for host: \(hostId)")
    }

    /// Get a session by host and pane ID
    public func session(for paneId: String, hostId: String) -> ClaudeSession? {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.claudeSession
    }

    /// Get the pane state by host and pane ID
    public func paneState(for paneId: String, hostId: String) -> PaneState? {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]
    }

    /// Check if a pane is currently active (has a Claude session)
    public func isPaneActive(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.claudeSession != nil
    }

    /// Check if yolo mode is enabled for a pane (as reported by the host)
    public func isYoloModeEnabled(paneId: String, hostId: String) -> Bool {
        paneStates[PaneKey(pairId: hostId, paneId: paneId)]?.yoloMode ?? false
    }

    /// Marks a session as handled (user has seen it), clearing the `needsAttention` flag locally.
    public func markSessionHandled(paneId: String, hostId: String) {
        let key = PaneKey(pairId: hostId, paneId: paneId)
        guard paneStates[key]?.claudeSession?.needsAttention == true else { return }
        paneStates[key]?.claudeSession?.markHandled()
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
