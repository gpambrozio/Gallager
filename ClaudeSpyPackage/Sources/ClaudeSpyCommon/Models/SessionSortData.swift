import ClaudeSpyNetworking
import Foundation

// MARK: - Session Sort Data

/// Data needed to sort a session, extracted uniformly from local or remote
/// sessions. Lives in ClaudeSpyCommon so the macOS sidebar/menu AND the iOS
/// session list all order sessions with the same algorithm — iOS mirrors the
/// host's sorting via the `sidebarSortMode` the host pushes with its session
/// state. The `LocalTmuxSession` builders live in ClaudeSpyServerFeature
/// (`SessionFieldsView.swift`); the remote builders are here.
public struct SessionSortData {
    public let sessionName: String
    public let primaryLabel: String
    public let hasClaude: Bool
    public let statusPriority: Int // displayed-state bucket: 0 = attention, 1 = working, 2 = idle, 3 = plain terminal (no agent, no pin)
    public let statusPriorityIdleFirst: Int // displayed-state bucket: 0 = attention, 1 = idle, 2 = working, 3 = plain terminal (no agent, no pin)
    public let latestEventTimestamp: Date?

    public init(
        sessionName: String,
        primaryLabel: String,
        hasClaude: Bool,
        statusPriority: Int,
        statusPriorityIdleFirst: Int,
        latestEventTimestamp: Date?
    ) {
        self.sessionName = sessionName
        self.primaryLabel = primaryLabel
        self.hasClaude = hasClaude
        self.statusPriority = statusPriority
        self.statusPriorityIdleFirst = statusPriorityIdleFirst
        self.latestEventTimestamp = latestEventTimestamp
    }

    /// Status priority: lower = higher priority (attention > working > idle).
    /// Derived from the DISPLAYED state bucket — the manual "Set State"
    /// override wins over the agent's own state — so a session sorts where
    /// its status icon says it belongs (a pinned-to-Waiting session rises to
    /// the attention group; pre-#702 the sort read the raw agent state and a
    /// pinned session's position contradicted its bell). `nil` is the plain
    /// terminal glyph: no agent, no pin.
    public static func statusPriority(displayed: CLISessionState?) -> Int {
        switch displayed {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        case nil: 3
        }
    }

    /// Status priority with idle before working (attention > idle > working);
    /// same displayed-state derivation as `statusPriority(displayed:)`.
    public static func statusPriorityIdleFirst(displayed: CLISessionState?) -> Int {
        switch displayed {
        case .waiting: 0
        case .idle: 1
        case .working: 2
        case nil: 3
        }
    }

    /// Resolves the primary label from configured fields and session values.
    /// Returns the first non-empty field value, falling back to sessionName.
    public static func primaryLabel(
        fields: [SidebarField],
        customDescription: String?,
        projectName: String?,
        sessionName: String,
        terminalTitle: String?,
        command: String?,
        currentPath: String?,
        gitBranch: String? = nil,
        homeDirectory: String? = nil
    ) -> String {
        for field in fields {
            let value: String? = switch field {
            case .customDescription: customDescription
            case .projectName: projectName
            case .sessionName: sessionName
            case .terminalTitle: terminalTitle
            case .command: command
            case .currentPath: currentPath?.abbreviatedPath(home: homeDirectory)
            case .gitBranch: gitBranch
            case .latestEvent: nil // excluded from primary label computation
            case .tokenUsage: nil // rich field, no text value to sort by
            }
            if let value, !value.isEmpty {
                return value
            }
        }
        return sessionName
    }

    /// Builds sort data for a remote `TmuxSession` using the relay-provided pane state.
    public static func forRemoteSession(
        _ session: TmuxSession,
        sidebarFields: [SidebarField],
        sidebarTerminalFields: [SidebarField],
        homeDirectory: String?
    ) -> SessionSortData {
        let claudeSession = session.windows.flatMap(\.panes).compactMap(\.agentSession).first
        let activePane = session.activeWindow?.activePane
        let terminalTitle = session.windows.flatMap(\.panes).compactMap(\.terminalTitle).first { !$0.isEmpty }
        let fields = claudeSession != nil ? sidebarFields : sidebarTerminalFields
        let label = primaryLabel(
            fields: fields,
            customDescription: session.customDescription,
            projectName: claudeSession?.displayName,
            sessionName: session.sessionName,
            terminalTitle: terminalTitle,
            command: activePane?.command,
            currentPath: activePane?.currentPath,
            gitBranch: activePane?.gitBranch,
            homeDirectory: homeDirectory
        )
        return SessionSortData(
            sessionName: session.sessionName,
            primaryLabel: label,
            hasClaude: claudeSession != nil,
            statusPriority: statusPriority(displayed: session.displayedState),
            statusPriorityIdleFirst: statusPriorityIdleFirst(displayed: session.displayedState),
            // The plugin model dropped the per-event timestamp buffer (spec §16);
            // recency sort by last event is no longer available.
            latestEventTimestamp: nil
        )
    }

    /// THE remote per-host session ordering — shared by the Mac viewer's
    /// `RemoteHostSidebarSection`, the menu bar dropdown, and the iOS session
    /// list, so every viewer surface orders a host's sessions identically.
    public static func sortedRemoteSessions(
        _ sessions: [TmuxSession],
        mode: SidebarSortMode,
        sidebarFields: [SidebarField],
        sidebarTerminalFields: [SidebarField],
        homeDirectory: String?
    ) -> [TmuxSession] {
        mode.sorted(sessions) { session in
            forRemoteSession(
                session,
                sidebarFields: sidebarFields,
                sidebarTerminalFields: sidebarTerminalFields,
                homeDirectory: homeDirectory
            )
        }
    }
}

public extension SidebarSortMode {
    /// Sort an array of items using the given sort mode and a closure to extract sort data.
    func sorted<T>(_ items: [T], by data: (T) -> SessionSortData) -> [T] {
        items.sorted { lhs, rhs in
            let a = data(lhs)
            let b = data(rhs)
            switch self {
            case .alphabetical:
                return a.primaryLabel.localizedCaseInsensitiveCompare(b.primaryLabel) == .orderedAscending
            case .claudeFirst:
                if a.hasClaude != b.hasClaude { return a.hasClaude }
                return a.sessionName.localizedCaseInsensitiveCompare(b.sessionName) == .orderedAscending
            case .statusPriority:
                if a.statusPriority != b.statusPriority { return a.statusPriority < b.statusPriority }
                return a.sessionName.localizedCaseInsensitiveCompare(b.sessionName) == .orderedAscending
            case .statusPriorityIdleFirst:
                if a.statusPriorityIdleFirst != b.statusPriorityIdleFirst { return a.statusPriorityIdleFirst < b.statusPriorityIdleFirst }
                return a.sessionName.localizedCaseInsensitiveCompare(b.sessionName) == .orderedAscending
            case .recentActivity:
                let aTime = a.latestEventTimestamp ?? .distantPast
                let bTime = b.latestEventTimestamp ?? .distantPast
                if aTime != bTime { return aTime > bTime }
                return a.sessionName.localizedCaseInsensitiveCompare(b.sessionName) == .orderedAscending
            case .sessionName:
                return a.sessionName.localizedCaseInsensitiveCompare(b.sessionName) == .orderedAscending
            }
        }
    }
}
