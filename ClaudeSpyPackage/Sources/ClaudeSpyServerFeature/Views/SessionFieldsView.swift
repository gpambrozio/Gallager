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

    /// Status priority: lower = higher priority (attention > working > idle)
    static func statusPriority(for agentSession: AgentSession?) -> Int {
        guard let session = agentSession else { return 3 }
        if session.attention { return 0 }
        if session.working { return 1 }
        return 2
    }

    /// Status priority with idle before working (attention > idle > working)
    static func statusPriorityIdleFirst(for agentSession: AgentSession?) -> Int {
        guard let session = agentSession else { return 3 }
        if session.attention { return 0 }
        if !session.working { return 1 }
        return 2
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
        let agentSession = session.windows.flatMap(\.panes).compactMap(\.agentSession).first
        let activePane = session.activeWindow?.activePane
        let terminalTitle = session.windows.flatMap(\.panes).compactMap(\.terminalTitle).first { !$0.isEmpty }
        let fields = agentSession != nil ? sidebarFields : sidebarTerminalFields
        let label = primaryLabel(
            fields: fields,
            customDescription: session.customDescription,
            projectName: agentSession?.displayName,
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
            hasClaude: agentSession != nil,
            statusPriority: statusPriority(for: agentSession),
            statusPriorityIdleFirst: statusPriorityIdleFirst(for: agentSession),
            latestEventTimestamp: agentSession?.lastEventTimestamp
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
