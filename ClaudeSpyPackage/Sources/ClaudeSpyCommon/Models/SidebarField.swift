import Foundation

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
    case latestEvent

    public var id: String { rawValue }

    /// Human-readable label for the preferences UI
    public var displayName: String {
        switch self {
        case .customDescription: "Custom Description"
        case .projectName: "Project Name"
        case .sessionName: "Session Name"
        case .terminalTitle: "Terminal Title"
        case .command: "Command"
        case .currentPath: "Current Path"
        case .latestEvent: "Latest Event"
        }
    }

    /// Default field order for new installations
    public static let defaultFields: [SidebarField] = [
        .customDescription,
        .projectName,
        .sessionName,
        .currentPath,
        .latestEvent,
    ]
}
