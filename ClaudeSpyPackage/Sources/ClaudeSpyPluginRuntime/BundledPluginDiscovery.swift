import Foundation
import GallagerPluginProtocol

// MARK: - BundledPluginRecord

/// One discovered bundled plugin: its decoded manifest, the on-disk directory
/// (so callers can resolve relative paths like the icon and the sidecar
/// executable), and the matching registry entry used to seed
/// `PluginRegistry.mergeBundled`.
public struct BundledPluginRecord: Sendable, Equatable {
    public let manifest: PluginManifest
    public let pluginDir: URL
    public let registryEntry: PluginRegistryEntry

    public init(
        manifest: PluginManifest,
        pluginDir: URL,
        registryEntry: PluginRegistryEntry
    ) {
        self.manifest = manifest
        self.pluginDir = pluginDir
        self.registryEntry = registryEntry
    }
}

// MARK: - BundledPluginDiscovery

/// Scans the bundled `plugins/<id>/plugin.json` files inside a directory and
/// turns each into a `BundledPluginRecord`. Defaults to using
/// `Bundle.main.resourceURL/plugins`; tests can pass an arbitrary directory.
///
/// Per Spec §5 every bundled manifest must declare `schema_version == 1`;
/// mismatches throw rather than silently skipping the plugin so a packaging
/// bug surfaces loudly during development.
public struct BundledPluginDiscovery: Sendable {
    public init() { }

    /// Iterate `dir`'s immediate subdirectories, load `plugin.json` from each,
    /// validate it, and build a record. Missing `plugin.json` files are
    /// skipped (the subdirectory may contain support files for another
    /// plugin); decode failures and schema mismatches throw.
    public func discover(in dir: URL) throws -> [BundledPluginRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Sort by directory name so the output order is deterministic
        // (callers might display the list and we don't want test flake).
        let subdirs = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [BundledPluginRecord] = []
        let installedAt = Date()
        for subdir in subdirs {
            let manifestURL = subdir.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            let data = try Data(contentsOf: manifestURL)
            let manifest: PluginManifest
            do {
                manifest = try decoder.decode(PluginManifest.self, from: data)
            } catch {
                throw BundledPluginDiscoveryError.decodeFailed(
                    pluginDir: subdir,
                    underlying: String(describing: error)
                )
            }

            guard manifest.schemaVersion == 1 else {
                throw BundledPluginDiscoveryError.unsupportedSchemaVersion(
                    pluginDir: subdir,
                    schemaVersion: manifest.schemaVersion
                )
            }

            // Bundled plugins always use the `bundle://` manifest URL and
            // carry no integrity hash (they came from the signed app
            // bundle). User-installed plugins flow through
            // `PluginRegistry.addUserInstall` instead.
            let registryEntry = PluginRegistryEntry(
                id: manifest.id,
                version: manifest.version,
                source: .bundled,
                manifestURL: URL(string: "bundle://\(manifest.id)/plugin.json")!,
                bundleSHA256: nil,
                enabled: true,
                installedAt: installedAt
            )

            records.append(
                BundledPluginRecord(
                    manifest: manifest,
                    pluginDir: subdir,
                    registryEntry: registryEntry
                )
            )
        }

        return records
    }
}

// MARK: - BundledPluginDiscoveryError

public enum BundledPluginDiscoveryError: Error, Equatable, CustomStringConvertible {
    case decodeFailed(pluginDir: URL, underlying: String)
    case unsupportedSchemaVersion(pluginDir: URL, schemaVersion: Int)

    public var description: String {
        switch self {
        case let .decodeFailed(pluginDir, underlying):
            return "BundledPluginDiscovery decode failed at \(pluginDir.path): \(underlying)"
        case let .unsupportedSchemaVersion(pluginDir, schemaVersion):
            return "BundledPluginDiscovery rejected schema version \(schemaVersion) at \(pluginDir.path) (expected 1)"
        }
    }
}
