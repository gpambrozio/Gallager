import Foundation

/// How sessions are sorted in the sidebar.
public enum SidebarSortMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case alphabetical
    case claudeFirst
    case statusPriority
    case statusPriorityIdleFirst
    case recentActivity
    case sessionName

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alphabetical: "Alphabetical (by primary label)"
        case .claudeFirst: "Claude sessions first"
        case .statusPriority: "Status priority (attention > working > idle)"
        case .statusPriorityIdleFirst: "Status priority (attention > idle > working)"
        case .recentActivity: "Most recent activity"
        case .sessionName: "Session name"
        }
    }
}

/// Fields that can be displayed in sidebar session rows.
///
/// Users configure which fields appear and in what order via Preferences > Sidebar.
/// The first visible field renders with primary styling; subsequent fields use caption styling.
public enum SidebarField: String, Codable, Sendable, CaseIterable, Identifiable {
    case customDescription
    case projectName
    case sessionName
    case terminalTitle
    case command
    case currentPath
    case gitBranch
    case latestEvent

    public var id: String { rawValue }

    /// Human-readable label for the preferences UI
    public var displayName: String {
        switch self {
        case .customDescription: "Custom Description"
        case .projectName: "Project Name"
        case .sessionName: "Tmux Session Name"
        case .terminalTitle: "Terminal Title"
        case .command: "Current Command"
        case .currentPath: "Current Path"
        case .gitBranch: "Git Branch"
        case .latestEvent: "Latest Event"
        }
    }

    /// Whether this field is available for plain terminal sessions (no Claude session)
    public var availableForTerminals: Bool {
        switch self {
        case .projectName,
             .latestEvent: false
        case .customDescription,
             .sessionName,
             .terminalTitle,
             .command,
             .currentPath,
             .gitBranch: true
        }
    }

    /// All fields available for terminal sessions
    public static let terminalFields: [SidebarField] = allCases.filter(\.availableForTerminals)

    /// Default field order for Claude sessions
    public static let defaultFields: [SidebarField] = [
        .customDescription,
        .projectName,
        .currentPath,
        .latestEvent,
    ]

    /// Default field order for plain terminal sessions
    public static let defaultTerminalFields: [SidebarField] = [
        .customDescription,
        .terminalTitle,
        .currentPath,
        .command,
    ]
}
