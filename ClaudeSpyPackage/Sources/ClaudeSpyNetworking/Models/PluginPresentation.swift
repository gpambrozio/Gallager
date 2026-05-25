import Foundation

// MARK: - Plugin Presentation

/// Per-plugin presentation bundle sent from the Mac to each newly-connected
/// iOS viewer (and re-sent when a plugin is enabled/disabled or upgrades).
/// iOS caches by `(id, version)`. Sessions and projects refer to plugins by
/// `id`; iOS looks up icon/name/color from the cache.
///
/// On the wire (with `keyEncodingStrategy = .convertToSnakeCase`):
/// ```json
/// {
///   "id": "claude-code",
///   "version": "1.0.0",
///   "display_name": "Claude Code",
///   "short_name": "Claude",
///   "color": "#cb6f3a",
///   "icon_b64": "<base64 PNG>"
/// }
/// ```
public struct PluginPresentation: Codable, Sendable, Equatable {
    /// Plugin ID (e.g. "claude-code").
    public let id: String

    /// Plugin version (semver-like string, e.g. "1.0.0").
    public let version: String

    /// Full human-readable name ("Claude Code").
    public let displayName: String

    /// Short label for compact sidebar rows ("Claude").
    public let shortName: String

    /// Theme color as a CSS hex string (e.g. "#cb6f3a").
    public let color: String

    /// Plugin icon, raw PNG bytes. Serialised as base64 (`icon_b64`) on the
    /// wire. Usually well under 50 KB.
    public let iconPNGData: Data

    public init(
        id: String,
        version: String,
        displayName: String,
        shortName: String,
        color: String,
        iconPNGData: Data
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.shortName = shortName
        self.color = color
        self.iconPNGData = iconPNGData
    }

    // MARK: - Codable

    // `iconPNGData` maps to `iconB64` on the Swift side so that the global
    // `convertToSnakeCase` strategy produces `icon_b64` on the wire. The value
    // is encoded as a base64 string (NOT Data's default base64-encoded blob,
    // which would be a separate representation).
    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case displayName
        case shortName
        case color
        case iconPNGData = "iconB64"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.version = try container.decode(String.self, forKey: .version)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.color = try container.decode(String.self, forKey: .color)
        let iconB64 = try container.decode(String.self, forKey: .iconPNGData)
        guard let data = Data(base64Encoded: iconB64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .iconPNGData,
                in: container,
                debugDescription: "icon_b64 is not a valid base64 string"
            )
        }
        self.iconPNGData = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(shortName, forKey: .shortName)
        try container.encode(color, forKey: .color)
        try container.encode(iconPNGData.base64EncodedString(), forKey: .iconPNGData)
    }
}

// MARK: - Plugin Presentations Message

/// Wire envelope that ships an array of `PluginPresentation`s to iOS.
///
/// On the wire:
/// ```json
/// {
///   "type": "plugin_presentations",
///   "presentations": [ <PluginPresentation>, ... ]
/// }
/// ```
public struct PluginPresentationsMessage: Codable, Sendable, Equatable {
    /// Discriminator. Always `"plugin_presentations"`.
    public let type: String

    /// Presentations for every plugin enabled on the host.
    public let presentations: [PluginPresentation]

    public init(presentations: [PluginPresentation]) {
        self.type = Self.discriminator
        self.presentations = presentations
    }

    /// The constant wire `type` value for this message.
    public static let discriminator = "plugin_presentations"
}
