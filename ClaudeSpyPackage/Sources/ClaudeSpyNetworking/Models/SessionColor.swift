import Foundation

/// User-assigned color for a tmux session, shown as a small dot in the sidebar.
///
/// Persisted on the tmux server via the `@gallager-color` user option so the
/// choice survives app restarts. The raw string values double as the wire
/// format for the `session.set_color` API and the storage value tmux holds.
public enum SessionColor: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray

    public var id: String {
        rawValue
    }

    /// Capitalized name shown in menu items and CLI confirmations.
    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Parses a CLI/API string into a color, accepting case-insensitive names
    /// and a small set of aliases. Returns `nil` for unknown values so callers
    /// can surface an error instead of silently mis-coloring a session.
    public static func parse(_ raw: String) -> SessionColor? {
        switch raw.lowercased() {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "blue": .blue
        case "purple",
             "violet": .purple
        case "pink",
             "magenta": .pink
        case "gray",
             "grey": .gray
        default: nil
        }
    }
}
