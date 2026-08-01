import Foundation

/// A tmux session none of whose panes owns an agent session — the system
/// menu's terminal-only rows (issue #702 follow-on). Agent-owning sessions are
/// represented in the menu by their agent panes instead, so a session appears
/// exactly once whichever bucket it falls in.
public struct TerminalOnlySession: Equatable, Sendable, Identifiable {
    /// The tmux session name; also the menu row label.
    public let sessionName: String

    /// The manual "Set State" override, if the session is pinned. With no
    /// agent anywhere in the session this IS the displayed state
    /// (`CLISessionState.displayed(override:agentState:)` with a nil agent);
    /// `nil` renders the plain terminal glyph.
    public let displayedState: CLISessionState?

    /// The pane a menu-row click should select: the active window's active
    /// pane, else the first pane by `(windowIndex, paneIndex)`.
    public let representativePaneId: String

    public var id: String { sessionName }

    public init(sessionName: String, displayedState: CLISessionState?, representativePaneId: String) {
        self.sessionName = sessionName
        self.displayedState = displayedState
        self.representativePaneId = representativePaneId
    }
}

extension Collection where Element == PaneState {
    /// Groups these panes into terminal-only sessions: one entry per session
    /// whose panes ALL lack an agent session, sorted pinned-to-Waiting first,
    /// then by session name. The override is scanned across every pane
    /// in `(windowIndex, paneIndex)` order — a deterministic winner when
    /// siblings disagree, matching the sidebar's `TmuxSession.cliSessionState`
    /// scan — and a partial stamp still surfaces. Panes with an empty session name (agent-only upserts that
    /// haven't been reconciled with a tmux scan yet) never form a row.
    public func terminalOnlySessions() -> [TerminalOnlySession] {
        Dictionary(grouping: self, by: \.sessionName)
            .compactMap { sessionName, panes -> TerminalOnlySession? in
                guard !sessionName.isEmpty,
                      panes.allSatisfy({ $0.agentSession == nil })
                else { return nil }
                let ordered = panes.sorted {
                    ($0.windowIndex, $0.paneIndex) < ($1.windowIndex, $1.paneIndex)
                }
                guard let representative = ordered.first(where: { $0.isWindowActive && $0.isActive })
                    ?? ordered.first
                else { return nil }
                return TerminalOnlySession(
                    sessionName: sessionName,
                    displayedState: ordered.compactMap(\.cliSessionState).first,
                    representativePaneId: representative.paneId
                )
            }
            .sorted {
                if ($0.displayedState == .waiting) != ($1.displayedState == .waiting) {
                    return $0.displayedState == .waiting
                }
                return $0.sessionName.localizedCaseInsensitiveCompare($1.sessionName) == .orderedAscending
            }
    }

    /// The pending badge count over these panes: agent panes whose displayed
    /// state is `.waiting` (per agent pane, honoring the manual override in
    /// both directions — issue #702) PLUS terminal-only sessions pinned to
    /// `.waiting`, counted once per session even though the override stamps
    /// every sibling pane. Equals the number of bell rows the menu dropdown
    /// renders for the same panes. Callers with panes from several hosts must
    /// apply this per host so same-named sessions don't merge.
    public var pendingSessionCount: Int {
        let agentPending = filter { $0.agentSession != nil && $0.displayedState == .waiting }.count
        let terminalPending = terminalOnlySessions().count { $0.displayedState == .waiting }
        return agentPending + terminalPending
    }
}
