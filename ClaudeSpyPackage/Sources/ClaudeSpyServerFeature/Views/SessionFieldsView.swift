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

// MARK: - Local Session Sort Data

/// The `LocalTmuxSession` builders for `SessionSortData` (the shared core —
/// struct, priorities, remote builders — lives in ClaudeSpyCommon so iOS can
/// sort with the same algorithm).
extension SessionSortData {
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

    /// THE local session ordering: the sidebar and the menu bar dropdown both
    /// call this, so "same order as the sidebar" is enforced by the shared
    /// function rather than by convention at each call site.
    static func sortedLocalSessions(
        _ sessions: [LocalTmuxSession],
        mode: SidebarSortMode,
        paneStates: [String: PaneState],
        lastActivity: (String) -> Date?,
        sidebarFields: [SidebarField],
        sidebarTerminalFields: [SidebarField]
    ) -> [LocalTmuxSession] {
        mode.sorted(sessions) { session in
            forLocalSession(
                session,
                paneStates: paneStates,
                lastActivity: lastActivity,
                sidebarFields: sidebarFields,
                sidebarTerminalFields: sidebarTerminalFields
            )
        }
    }

}
