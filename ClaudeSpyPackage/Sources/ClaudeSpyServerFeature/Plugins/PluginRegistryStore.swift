import Foundation
import GallagerPluginProtocol

/// A single registry entry describing a plugin and its deployment state.
public struct PluginRegistryEntry: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let source: Source
    public let runtime: Runtime
    public var enabled: Bool
    public let manifestURL: URL?
    public let bundleURL: URL?
    public let bundleSHA256: String?
    /// Host-side preference: include this plugin in automatic update checks.
    /// Only meaningful for `.url` entries; defaults to true.
    public var autoUpdate: Bool
    /// Set when an update installed while the plugin had active sessions, so
    /// agent-side bridge files still need re-installing (done at next launch).
    public var needsBridgeRefresh: Bool

    /// The origin of the plugin: bundled with the app, fetched from a URL, or a local folder.
    public enum Source: String, Codable, Sendable {
        case bundled
        case url
        case folder
    }

    public init(
        id: String,
        version: String,
        source: Source,
        runtime: Runtime,
        enabled: Bool,
        manifestURL: URL?,
        bundleURL: URL?,
        bundleSHA256: String?,
        autoUpdate: Bool = true,
        needsBridgeRefresh: Bool = false
    ) {
        self.id = id
        self.version = version
        self.source = source
        self.runtime = runtime
        self.enabled = enabled
        self.manifestURL = manifestURL
        self.bundleURL = bundleURL
        self.bundleSHA256 = bundleSHA256
        self.autoUpdate = autoUpdate
        self.needsBridgeRefresh = needsBridgeRefresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.version = try c.decode(String.self, forKey: .version)
        self.source = try c.decode(Source.self, forKey: .source)
        self.runtime = try c.decode(Runtime.self, forKey: .runtime)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.manifestURL = try c.decodeIfPresent(URL.self, forKey: .manifestURL)
        self.bundleURL = try c.decodeIfPresent(URL.self, forKey: .bundleURL)
        self.bundleSHA256 = try c.decodeIfPresent(String.self, forKey: .bundleSHA256)
        self.autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        self.needsBridgeRefresh = try c.decodeIfPresent(Bool.self, forKey: .needsBridgeRefresh) ?? false
    }
}

/// The persisted format of the registry on disk.
public struct PluginRegistryFile: Codable, Sendable {
    public var schemaVersion: Int
    public var plugins: [PluginRegistryEntry]

    public init(schemaVersion: Int, plugins: [PluginRegistryEntry]) {
        self.schemaVersion = schemaVersion
        self.plugins = plugins
    }
}

/// Stateless operations for loading and saving the plugin registry to disk.
public enum PluginRegistryStore {
    /// Load the plugin registry from disk, returning an empty registry if the file
    /// does not exist or cannot be decoded. Never throws.
    public static func load(_ url: URL) -> PluginRegistryFile {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PluginRegistryFile.self, from: data)
        } catch {
            // Any read or decode failure returns an empty registry.
            return PluginRegistryFile(schemaVersion: 1, plugins: [])
        }
    }

    /// Save the plugin registry to disk, writing to a temporary file then atomically
    /// replacing the destination. Throws on I/O failure.
    public static func save(_ file: PluginRegistryFile, to url: URL) throws {
        let tmpURL = url.appendingPathExtension("tmp")

        // Encode to JSON and write to the temp file.
        let data = try JSONEncoder().encode(file)
        try data.write(to: tmpURL, options: .atomic)

        // Atomically replace the destination.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }
}
