import Foundation

// MARK: - AgentProject

/// An agent-blind project entry surfaced in the sidebar. Replaces the
/// agent-specific `ClaudeProjectInfo` (spec §16): the `pluginID` string tags
/// which plugin discovered the project, and iOS looks up the icon/name from the
/// presentation cache by that id.
///
/// Pushed to the host via `PluginHost.setProjects` and forwarded to iOS on the
/// existing session-state message (spec §7.2).
public struct AgentProject: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (plugin id + path; two plugins can share a directory).
    public var id: String {
        "\(pluginID):\(path)"
    }

    /// Project name (last component of path).
    public let name: String

    /// Full path to the project directory.
    public let path: String

    /// Timestamp of last activity in this project (for sorting by recency).
    public let lastUsed: Date?

    /// Optional per-project config directory (e.g. a non-default `.claude`
    /// folder). `nil` when the project lives in the plugin's default location.
    public let configDir: String?

    /// Id of the plugin that discovered this project.
    public let pluginID: String

    public init(
        name: String,
        path: String,
        lastUsed: Date? = nil,
        configDir: String? = nil,
        pluginID: String
    ) {
        self.name = name
        self.path = path
        self.lastUsed = lastUsed
        self.configDir = configDir
        self.pluginID = pluginID
    }

    /// Tolerant decode so incidental field additions across host/viewer version
    /// skew don't break decoding (spec §3 wire-compat rule).
    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case lastUsed
        case configDir
        case pluginID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.path = try container.decode(String.self, forKey: .path)
        self.lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        self.configDir = try container.decodeIfPresent(String.self, forKey: .configDir)
        self.pluginID = try container.decode(String.self, forKey: .pluginID)
    }
}

public extension [AgentProject] {
    /// Most-recently-used first; entries without a timestamp sort last.
    func sortedByLastUsed() -> [AgentProject] {
        sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
