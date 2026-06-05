import Foundation

// MARK: - PluginPresentation

/// The per-plugin presentation bundle iOS uses to render sidebar icons/names
/// and badges, without knowing anything about the plugin itself. Sourced from
/// each plugin's manifest and pushed to iOS via `plugin_presentations` (spec §7.2).
///
/// iOS holds these in an in-memory dictionary keyed by `id` and full-replaces on
/// every push; it never persists to disk (the Mac re-pushes the complete set on
/// every viewer connect — spec §7.3).
public struct PluginPresentation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let version: String
    public let displayName: String
    public let shortName: String
    /// Accent color as a hex string (e.g. "#cb6f3a").
    public let color: String
    /// Base64-encoded PNG icon bytes, if the plugin ships one.
    public let iconB64: String?

    public init(
        id: String,
        version: String,
        displayName: String,
        shortName: String,
        color: String,
        iconB64: String? = nil
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.shortName = shortName
        self.color = color
        self.iconB64 = iconB64
    }
}
