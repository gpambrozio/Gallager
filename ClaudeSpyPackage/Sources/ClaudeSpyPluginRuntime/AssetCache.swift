import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - AssetCache

/// Caches per-plugin presentation bundles (icon PNG + display name + theme
/// color) keyed by `(pluginID, version)`. Loads icon PNG bytes from disk on
/// cache miss.
///
/// Per Spec §7.3, the presentation bundle is the only metadata iOS sees about
/// a plugin — sessions/projects reference plugins by `id` and iOS looks up
/// icon/name/color here. The actor is the single place that owns the PNG
/// bytes so we never re-read the file system on each iOS reconnect.
public actor AssetCache {
    // MARK: - Cache key

    private struct Key: Hashable {
        let pluginID: String
        let version: String
    }

    // MARK: - State

    private var cache: [Key: PluginPresentation] = [:]

    // MARK: - Init

    public init() { }

    // MARK: - Public API

    /// Build a presentation for the given manifest, loading the icon PNG
    /// from `pluginDir/<manifest.ui.icon>` and caching the result.
    ///
    /// `color` defaults to `"#888888"` (Spec §7.3 example uses a per-plugin
    /// color, but the manifest doesn't currently carry one; we pick a
    /// deterministic neutral default so iOS rendering remains stable).
    /// Future task can extend `PluginManifest.UI` to carry a color hint.
    public func presentation(
        for manifest: PluginManifest,
        pluginDir: URL
    ) async throws -> PluginPresentation {
        let key = Key(pluginID: manifest.id, version: manifest.version)
        if let cached = cache[key] {
            return cached
        }

        let iconURL = pluginDir.appendingPathComponent(manifest.ui.icon)
        let iconData: Data
        do {
            iconData = try Data(contentsOf: iconURL)
        } catch {
            throw AssetCacheError.iconLoadFailed(
                path: iconURL.path,
                underlying: String(describing: error)
            )
        }

        let presentation = PluginPresentation(
            id: manifest.id,
            version: manifest.version,
            displayName: manifest.displayName,
            shortName: manifest.shortName,
            color: AssetCache.defaultColor,
            iconPNGData: iconData
        )
        cache[key] = presentation
        return presentation
    }

    /// Drop every cached presentation. Used by `PluginManager.stop()` so a
    /// subsequent restart picks up freshly-discovered manifests.
    public func clear() async {
        cache.removeAll()
    }

    /// Drop a specific plugin's cached presentation (e.g. on uninstall).
    public func remove(pluginID: String) async {
        cache = cache.filter { $0.key.pluginID != pluginID }
    }

    // MARK: - Defaults

    /// Neutral default theme color used when the manifest provides no
    /// per-plugin color hint. CSS-style `#RRGGBB`.
    public static let defaultColor = "#888888"
}

// MARK: - AssetCacheError

public enum AssetCacheError: Error, Equatable, CustomStringConvertible {
    case iconLoadFailed(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .iconLoadFailed(path, underlying):
            return "AssetCache could not load icon at \(path): \(underlying)"
        }
    }
}
