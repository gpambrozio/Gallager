import Foundation

// MARK: - PluginManifest (spec §10)

/// The runtime model for a bundled plugin. v1 conformers are always
/// `.inProcess`; the registry switches on `runtime` (v2 adds `.sidecar`).
/// Decoding is tolerant: an absent or `null` `runtime` decodes to `.inProcess`,
/// so v2 introduces no decode-semantics shift at the seam.
public enum Runtime: String, Sendable, Codable {
    case inProcess
    case sidecar
}

/// The minimal v1 manifest. Seeds presentation + pane detection; the remaining
/// reserved fields are v2 forward-compat room the v1 runtime ignores.
public struct PluginManifest: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let shortName: String
    public let version: String
    /// Process names used for pane detection (spec §6).
    public let processNames: [String]
    public let ui: UI
    /// Always `.inProcess` in v1; read (not merely reserved) so v2 needs no
    /// decode change (spec §10).
    public let runtime: Runtime

    public struct UI: Sendable, Codable, Equatable {
        /// Relative path to the icon asset under the plugin root (e.g. "assets/icon.png").
        public let icon: String?
        /// Accent color hex; falls back to `#888888` when absent (spec §10).
        public let color: String?

        public init(icon: String?, color: String?) {
            self.icon = icon
            self.color = color
        }
    }

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        shortName: String,
        version: String,
        processNames: [String],
        ui: UI,
        runtime: Runtime = .inProcess
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.version = version
        self.processNames = processNames
        self.ui = ui
        self.runtime = runtime
    }

    /// Default accent color when `ui.color` is absent (spec §10).
    public static let fallbackColor = "#888888"

    /// The effective accent color (manifest value or fallback).
    public var color: String {
        ui.color ?? Self.fallbackColor
    }

    /// Snake_case JSON keys per the manifest schema (spec §10). Reserved v2 keys
    /// (`sidecar`, `manifest_url`, `bundle_url`, `bundle_sha256`, `publisher`,
    /// `capabilities`, `signature`) are intentionally not decoded.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case displayName = "display_name"
        case shortName = "short_name"
        case version
        case processNames = "process_names"
        case ui
        case runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        self.processNames = try container.decodeIfPresent([String].self, forKey: .processNames) ?? []
        self.ui = try container.decodeIfPresent(UI.self, forKey: .ui) ?? UI(icon: nil, color: nil)
        // Absent or null runtime → inProcess (spec §10).
        self.runtime = try container.decodeIfPresent(Runtime.self, forKey: .runtime) ?? .inProcess
    }

    /// Load and decode a manifest from `<pluginRoot>/plugin.json`.
    public static func load(fromPluginRoot pluginRoot: URL) throws -> PluginManifest {
        let url = pluginRoot.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}
