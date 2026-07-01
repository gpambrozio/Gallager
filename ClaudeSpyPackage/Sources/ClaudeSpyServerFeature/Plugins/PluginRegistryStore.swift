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
        bundleSHA256: String?
    ) {
        self.id = id
        self.version = version
        self.source = source
        self.runtime = runtime
        self.enabled = enabled
        self.manifestURL = manifestURL
        self.bundleURL = bundleURL
        self.bundleSHA256 = bundleSHA256
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
