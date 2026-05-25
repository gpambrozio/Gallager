import Foundation

// MARK: - PluginRegistryEntry

/// One entry in `~/.gallager/registry.json` (Spec §9.1, §9.2).
///
/// Bundled plugins ship inside the app and have `source = .bundled`,
/// `manifest_url = "bundle://<id>/plugin.json"`, and `bundle_sha256 = nil`
/// (no integrity check needed; they came from the signed app bundle).
///
/// User-installed plugins fetch from a remote URL and require a non-nil
/// `bundle_sha256` matching the downloaded zip.
///
/// Wire-format requirement: serialization MUST use a `JSONEncoder` with
/// `keyEncodingStrategy = .convertToSnakeCase` (and decoder with
/// `keyDecodingStrategy = .convertFromSnakeCase`).
public struct PluginRegistryEntry: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let source: Source
    public let manifestURL: URL
    public let bundleSHA256: String?
    public var enabled: Bool
    public let installedAt: Date

    public init(
        id: String,
        version: String,
        source: Source,
        manifestURL: URL,
        bundleSHA256: String?,
        enabled: Bool,
        installedAt: Date
    ) {
        self.id = id
        self.version = version
        self.source = source
        self.manifestURL = manifestURL
        self.bundleSHA256 = bundleSHA256
        self.enabled = enabled
        self.installedAt = installedAt
    }

    // `manifestURL` / `bundleSHA256` would round-trip through
    // `convertFromSnakeCase` as `manifestUrl` / `bundleSha256` — the strategy
    // doesn't preserve multi-letter acronyms. We patch the keys so the wire
    // name (`manifest_url`, `bundle_sha256`) matches what the strategy
    // produces for our raw value.
    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case source
        case manifestURL = "manifestUrl"
        case bundleSHA256 = "bundleSha256"
        case enabled
        case installedAt
    }

    /// How the plugin entered the registry.
    public enum Source: String, Codable, Sendable, Equatable {
        /// Bundled inside the app — cannot be uninstalled, only disabled.
        case bundled

        /// Installed by the user from an https URL.
        case url
    }
}
