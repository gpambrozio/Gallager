import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - PluginRegistry

/// In-memory + on-disk store of installed plugins (Spec §9.1).
///
/// Owns `registry.json`. Reads it lazily on first access, writes it atomically
/// (temp file + rename) on every mutation, and keeps an in-actor cache so
/// subsequent reads don't re-hit the disk.
///
/// Mutators:
///  - `mergeBundled(_:)`: replaces bundled entries with a fresh list, preserves
///    user-set `enabled` bits across version bumps, and drops bundled entries
///    that are no longer shipped.
///  - `addUserInstall(_:)`: adds a new entry (idempotent on id).
///  - `remove(id:)`: deletes an entry by id.
///  - `setEnabled(id:enabled:)`: toggles a single entry's enabled bit.
public actor PluginRegistry {
    private let layout: PluginRootLayout
    private let logger: Logger
    private var cache: [PluginRegistryEntry]?

    public init(
        layout: PluginRootLayout,
        logger: Logger = Logger(label: "gallager.plugin.registry")
    ) {
        self.layout = layout
        self.logger = logger
    }

    /// Returns the current registry contents, loading from disk if not yet
    /// cached. A missing file resolves to an empty list (first launch).
    public func entries() throws -> [PluginRegistryEntry] {
        if let cache { return cache }
        let loaded = try load()
        cache = loaded
        return loaded
    }

    /// Merge the bundled-plugin set into the registry.
    ///
    /// Called at app startup with the freshly discovered set of bundled
    /// plugins under `Gallager.app/Contents/Resources/plugins/`.
    ///
    /// Semantics:
    ///  - Bundled entries currently in the registry whose ids are NOT in
    ///    `bundled` are removed (the plugin was dropped from the shipping app).
    ///  - For each id in `bundled`: if the registry already has an entry,
    ///    update its non-enabled fields from the supplied entry but preserve
    ///    the existing `enabled` bit (so a user who disabled it doesn't get
    ///    it re-enabled on app update). Otherwise append as new.
    ///  - User-installed (`.url`) entries are untouched.
    public func mergeBundled(_ bundled: [PluginRegistryEntry]) throws {
        var current = try entries()
        let bundledIDs = Set(bundled.map(\.id))

        // Drop bundled entries that are no longer shipped.
        current.removeAll { $0.source == .bundled && !bundledIDs.contains($0.id) }

        for newEntry in bundled {
            if let idx = current.firstIndex(where: { $0.id == newEntry.id }) {
                // Preserve the user-set enabled bit; everything else (version,
                // sha, etc.) gets replaced by the shipped entry.
                let existingEnabled = current[idx].enabled
                var updated = newEntry
                updated.enabled = existingEnabled
                current[idx] = updated
            } else {
                current.append(newEntry)
            }
        }

        try persist(current)
    }

    /// Append a user-installed plugin (or upsert if the id already exists).
    ///
    /// Used for fresh registry seeding in tests and for `Settings → Add
    /// Plugin from URL…` (Spec §9.2). Bundled-plugin onboarding goes through
    /// `mergeBundled` instead.
    public func addUserInstall(_ entry: PluginRegistryEntry) throws {
        var current = try entries()
        if let idx = current.firstIndex(where: { $0.id == entry.id }) {
            current[idx] = entry
        } else {
            current.append(entry)
        }
        try persist(current)
    }

    /// Remove an entry by id. No-op if the id isn't present.
    public func remove(id: String) throws {
        var current = try entries()
        let before = current.count
        current.removeAll { $0.id == id }
        guard current.count != before else { return }
        try persist(current)
    }

    /// Toggle the enabled bit for one entry. Throws `unknownPlugin` if the id
    /// isn't registered.
    public func setEnabled(id: String, enabled: Bool) throws {
        var current = try entries()
        guard let idx = current.firstIndex(where: { $0.id == id }) else {
            throw PluginRegistryError.unknownPlugin(id: id)
        }
        guard current[idx].enabled != enabled else { return }
        current[idx].enabled = enabled
        try persist(current)
    }

    // MARK: - Disk I/O

    private func load() throws -> [PluginRegistryEntry] {
        let url = layout.registryURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PluginRegistryEntry].self, from: data)
        } catch {
            // A corrupt registry.json shouldn't take the whole runtime down,
            // but we also don't want to silently overwrite the user's data.
            // Surface the error to the caller and let them decide.
            throw PluginRegistryError.decodeFailed(
                underlying: String(describing: error)
            )
        }
    }

    /// Atomically replace `registry.json` with `entries`.
    ///
    /// Writes to a UUID-suffixed temp file in the registry's parent dir, then
    /// uses `FileManager.replaceItemAt` to swap. If anything fails, the
    /// existing file is untouched and the in-memory cache is NOT updated —
    /// so a future call still sees the on-disk truth.
    private func persist(_ entries: [PluginRegistryEntry]) throws {
        let url = layout.registryURL()
        let parent = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder.gallagerOrdered.encode(entries)

        let tmpURL = parent.appendingPathComponent(
            "registry.json.tmp.\(UUID().uuidString)"
        )

        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw PluginRegistryError.persistFailed(
                reason: "tmp write failed: \(error)"
            )
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                // No existing file to replace — just move into place.
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw PluginRegistryError.persistFailed(
                reason: "rename failed: \(error)"
            )
        }

        cache = entries
    }
}

// MARK: - PluginRegistryError

public enum PluginRegistryError: Error, Equatable, CustomStringConvertible {
    case persistFailed(reason: String)
    case decodeFailed(underlying: String)
    case unknownPlugin(id: String)

    public var description: String {
        switch self {
        case let .persistFailed(reason):
            return "PluginRegistry persist failed: \(reason)"
        case let .decodeFailed(underlying):
            return "PluginRegistry decode failed: \(underlying)"
        case let .unknownPlugin(id):
            return "PluginRegistry has no entry with id '\(id)'"
        }
    }
}

// MARK: - JSONEncoder helper

extension JSONEncoder {
    /// Encoder used for all on-disk Gallager JSON files: pretty-printed,
    /// stable key ordering, snake_case wire keys, ISO-8601 dates.
    ///
    /// Stable key ordering makes diffs in the registry file readable when
    /// they show up in `git diff` (during development) or in support logs.
    static var gallagerOrdered: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
