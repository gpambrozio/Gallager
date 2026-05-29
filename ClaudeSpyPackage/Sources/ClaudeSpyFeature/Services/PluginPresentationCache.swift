import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Stores per-plugin presentation bundles received via `plugin_presentations`
/// messages from the Mac. Persisted to disk so reconnects don't blank out the
/// sidebar while the next push is in flight.
///
/// Keyed by plugin id (matching `PluginPresentation.id`). When the Mac upgrades
/// a plugin, the version on `PluginPresentation` changes — the cache replaces
/// the older entry because its key is just the id (so the newest pushed
/// presentation always wins, even when only the icon or short name was
/// updated). The version is still tracked on the value so callers can diff
/// against what they last rendered.
///
/// The class is `@Observable` / `@MainActor` so SwiftUI views can read
/// `presentation(for:)` directly without dispatching back to the main thread.
/// Disk writes happen on a background `Task` so a slow filesystem never blocks
/// the run loop.
@MainActor
@Observable
final public class PluginPresentationCache {
    // MARK: - Storage

    private let logger = Logger(label: "com.claudespy.pluginpresentationcache")

    /// Backing store keyed by plugin id. Order is not preserved — call sites
    /// (`all`) sort by display name for stable enumeration.
    private var byID: [String: PluginPresentation] = [:]

    /// Location of the persisted JSON snapshot.
    private let diskURL: URL

    // MARK: - Public Surface

    /// Snapshot suitable for `ForEach`-style enumeration. Sorted by
    /// `displayName` so the order is stable across renders even though the
    /// underlying dictionary isn't.
    public var all: [PluginPresentation] {
        byID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Initialization

    /// - Parameter diskURL: Where to load and persist the JSON snapshot. The
    ///   default points at the iOS app's `Application Support/ClaudeSpy/
    ///   plugin-presentations.json`. Tests override with a temp file.
    public init(diskURL: URL = PluginPresentationCache.defaultDiskURL) {
        self.diskURL = diskURL
        loadFromDisk()
    }

    // MARK: - Apply / Lookup

    /// Apply an incoming `plugin_presentations` message. Replaces entries
    /// whose `(id, version)` differ from what we have cached; entries with
    /// the same `(id, version)` are skipped to avoid spurious change
    /// notifications.
    ///
    /// Notes:
    /// - Entries that the message omits are NOT removed. The Mac may push a
    ///   subset (e.g. one plugin just toggled enabled) without dropping the
    ///   others. A future task can extend the wire format with an explicit
    ///   "full replace" flag if that becomes a concern.
    /// - The wire format already validates `id` is non-empty during decode;
    ///   we trust that here.
    public func apply(_ message: PluginPresentationsMessage) async {
        var changed = false
        for presentation in message.presentations {
            let existing = byID[presentation.id]
            if existing != presentation {
                byID[presentation.id] = presentation
                changed = true
            }
        }
        guard changed else { return }
        await persistToDisk()
    }

    /// Look up the cached presentation for `pluginID`. Returns nil if no
    /// presentation has been pushed yet (sidebar should fall back to plain
    /// pluginID text + a generic icon).
    public func presentation(for pluginID: String) -> PluginPresentation? {
        byID[pluginID]
    }

    // MARK: - Disk Persistence

    /// Loads the cached presentations from disk synchronously. Missing files,
    /// truncated JSON, or schema mismatches are logged and treated as an
    /// empty cache — the next `apply(_:)` will overwrite the file.
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return }
        do {
            let data = try Data(contentsOf: diskURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let presentations = try decoder.decode([PluginPresentation].self, from: data)
            byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
            logger.info("Loaded \(presentations.count) plugin presentations from disk")
        } catch {
            logger.warning(
                "Failed to load plugin presentation cache; starting fresh",
                metadata: ["error": "\(error)"]
            )
            byID = [:]
        }
    }

    /// Persist the current cache contents to disk. Writes happen via
    /// `Data.write(...)` with the `.atomic` option so a crash mid-write
    /// can't corrupt the file. Errors are logged but not surfaced — the
    /// cache continues to function in-memory.
    private func persistToDisk() async {
        let snapshot = Array(byID.values)
        // Build the encoder on the call site so we keep the encoding strategy
        // out of stored state.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let url = diskURL
        await Task.detached {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                Logger(label: "com.claudespy.pluginpresentationcache")
                    .error(
                        "Failed to persist plugin presentation cache",
                        metadata: ["error": "\(error)"]
                    )
            }
        }.value
    }

    // MARK: - Default Disk URL

    /// Default disk URL: `<Application Support>/ClaudeSpy/plugin-presentations.json`.
    /// Created lazily so iOS apps without app-support permission still launch
    /// (the cache would simply fail to persist; presentations are re-pushed
    /// on every reconnect).
    public static var defaultDiskURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSpy", isDirectory: true)
        return dir.appendingPathComponent("plugin-presentations.json")
    }
}
