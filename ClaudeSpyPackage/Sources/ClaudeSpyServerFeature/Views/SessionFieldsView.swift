import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Renders sidebar session fields in the order configured by the user.
///
/// The first field with a non-empty value gets primary styling (`.body.weight(.medium)`).
/// Subsequent fields use caption styling. Fields whose value is nil or empty are skipped.
struct SessionFieldsView: View {
    let fields: [SidebarField]
    let customDescription: String?
    let projectName: String?
    let sessionName: String
    let terminalTitle: String?
    let command: String?
    let currentPath: String?
    let gitBranch: String?
    let latestEvent: String?
    /// Remote host's home directory for proper path abbreviation (nil for local sessions)
    var homeDirectory: String?

    var body: some View {
        let visibleFields = fields.compactMap { field -> (SidebarField, String)? in
            guard let value = value(for: field), !value.isEmpty else { return nil }
            return (field, value)
        }

        VStack(alignment: .leading, spacing: 2) {
            if visibleFields.isEmpty {
                // Fallback: always show session name when no configured fields have values
                Text(sessionName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                ForEach(Array(visibleFields.enumerated()), id: \.element.0) { index, entry in
                    if index == 0 {
                        Text(entry.1)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(entry.1)
                            .font(entry.0 == .latestEvent ? .caption2 : .caption)
                            .foregroundStyle(entry.0 == .latestEvent ? .tertiary : .secondary)
                            .lineLimit(entry.0 == .latestEvent ? 2 : 1)
                    }
                }
            }
        }
    }

    /// The first non-empty field value, used for alphabetical sorting
    var primaryLabel: String {
        SessionSortData.primaryLabel(
            fields: fields,
            customDescription: customDescription,
            projectName: projectName,
            sessionName: sessionName,
            terminalTitle: terminalTitle,
            command: command,
            currentPath: currentPath,
            gitBranch: gitBranch,
            homeDirectory: homeDirectory
        )
    }

    private func value(for field: SidebarField) -> String? {
        switch field {
        case .customDescription: customDescription
        case .projectName: projectName
        case .sessionName: sessionName
        case .terminalTitle: terminalTitle
        case .command: command
        case .currentPath: currentPath?.abbreviatedPath(home: homeDirectory)
        case .gitBranch: gitBranch
        case .latestEvent: latestEvent
        // Rich field: drawn by the row as a telemetry meter, not a text value.
        case .tokenUsage: nil
        }
    }
}

// MARK: - Session Sort Data

/// Data needed to sort a session, extracted uniformly from local or remote sessions.
struct SessionSortData {
    let sessionName: String
    let primaryLabel: String
    let hasClaude: Bool
    let statusPriority: Int // 0 = attention, 1 = working, 2 = idle, 3 = no claude
    let statusPriorityIdleFirst: Int // 0 = attention, 1 = idle, 2 = working, 3 = no claude
    let latestEventTimestamp: Date?

    /// Status priority: lower = higher priority (attention > working > idle).
    /// Derived from the DISPLAYED state bucket — the manual "Set State"
    /// override wins over the agent's own state — so a session sorts where
    /// its status icon says it belongs (a pinned-to-Waiting session rises to
    /// the attention group; pre-#702 the sort read the raw agent state and a
    /// pinned session's position contradicted its bell). `nil` is the plain
    /// terminal glyph: no agent, no pin.
    static func statusPriority(displayed: CLISessionState?) -> Int {
        switch displayed {
        case .waiting: 0
        case .working: 1
        case .idle: 2
        case nil: 3
        }
    }

    /// Status priority with idle before working (attention > idle > working);
    /// same displayed-state derivation as `statusPriority(displayed:)`.
    static func statusPriorityIdleFirst(displayed: CLISessionState?) -> Int {
        switch displayed {
        case .waiting: 0
        case .idle: 1
        case .working: 2
        case nil: 3
        }
    }

    /// Resolves the primary label from configured fields and session values.
    /// Returns the first non-empty field value, falling back to sessionName.
    static func primaryLabel(
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
    static func forRemoteSession(
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

    /// Builds sort data for a local `LocalTmuxSession` from the tracked pane
    /// states. Shared by the sidebar (`MainView`) and the menu bar dropdown so
    /// both surfaces order sessions identically — the menu's "same order as
    /// the sidebar" guarantee is this single builder plus the shared
    /// `SidebarSortMode.sorted`. Scans the full session (all windows) to match
    /// the session-level sidebar row, not the selected window.
    static func forLocalSession(
        _ session: LocalTmuxSession,
        paneStates: [String: PaneState],
        lastActivity: (String) -> Date?,
        sidebarFields: [SidebarField],
        sidebarTerminalFields: [SidebarField]
    ) -> SessionSortData {
        let claudeSession: AgentSession? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { paneStates[$0.paneId]?.agentSession }
            .first

        // The displayed bucket the sidebar's status icon shows: the manual
        // "Set State" override (any pane, window/pane order) wins over the
        // agent state — the same scan the sidebar row itself performs.
        let stateOverride: CLISessionState? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { paneStates[$0.paneId]?.cliSessionState }
            .first
        let displayed = CLISessionState.displayed(override: stateOverride, agentState: claudeSession?.state)

        let primaryPane = session.activeWindow?.activePane
        let paneState = primaryPane.flatMap { paneStates[$0.paneId] }

        // Scan all windows for terminal title (matches SessionSidebarRow.terminalTitle)
        let terminalTitle: String? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { paneStates[$0.paneId]?.terminalTitle }
            .first { !$0.isEmpty }

        let fields = claudeSession != nil ? sidebarFields : sidebarTerminalFields

        let label = primaryLabel(
            fields: fields,
            customDescription: paneState?.customDescription,
            projectName: claudeSession?.displayName,
            sessionName: session.sessionName,
            terminalTitle: terminalTitle,
            command: primaryPane?.command,
            currentPath: primaryPane?.currentPath,
            gitBranch: paneState?.gitBranch
        )

        // Recency = the latest plugin-status arrival across the session's panes.
        // The per-event timestamp buffer was dropped (spec §16); status-arrival
        // order is the agent-blind stand-in and matches event-receipt order.
        // Not `.lazy`: max() consumes every element anyway, and a lazy chain
        // would escape the non-escaping `lastActivity` closure.
        let latestActivity = session.windows
            .flatMap(\.panes)
            .compactMap { lastActivity($0.paneId) }
            .max()

        return SessionSortData(
            sessionName: session.sessionName,
            primaryLabel: label,
            hasClaude: claudeSession != nil,
            statusPriority: statusPriority(displayed: displayed),
            statusPriorityIdleFirst: statusPriorityIdleFirst(displayed: displayed),
            latestEventTimestamp: latestActivity
        )
    }
}

extension SidebarSortMode {
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
