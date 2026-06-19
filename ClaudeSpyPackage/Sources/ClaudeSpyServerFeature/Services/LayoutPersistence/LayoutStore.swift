#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Persists per-session workbench layouts and answers the two restore
    /// questions from `docs/folder-layout-persistence-plan.md` §4.3:
    ///
    /// 1. `record(for:)` — the exact layout for a session id (host + tmux name),
    ///    used to restore an already-running session on cold launch.
    /// 2. `folderDefault(folder:excluding:)` — the most-recently-active layout for
    ///    a folder, used to seed a brand-new session on a known folder.
    ///
    /// Writes are awaited and immediate; debouncing lives at the call site
    /// (`MainView`). The store never throws into the app — persistence failures
    /// degrade to "no saved layout" rather than disrupting the workbench.
    @DependencyClient
    struct LayoutStore: Sendable {
        /// Exact record for a session key, or `nil` if none.
        var record: @Sendable (_ key: SavedSessionLayout.Key) async -> SavedSessionLayout?
        /// Most-recently-active record on `folder`, optionally excluding one key
        /// (the session being seeded, so it never seeds from itself).
        var folderDefault: @Sendable (
            _ folder: String,
            _ excluding: SavedSessionLayout.Key?
        ) async -> SavedSessionLayout?
        /// Insert or replace a record.
        var save: @Sendable (_ record: SavedSessionLayout) async -> Void
        /// Remove a record.
        var remove: @Sendable (_ key: SavedSessionLayout.Key) async -> Void
        /// Garbage-collect stale records: drop anything older than `maxAge`, then
        /// cap to the `maxCount` most-recently-active. Called once on launch.
        var prune: @Sendable (_ maxAge: TimeInterval, _ maxCount: Int) async -> Void
    }

    extension LayoutStore {
        /// Default pruning policy applied on launch.
        static let defaultMaxAge: TimeInterval = 60 * 60 * 24 * 60 // 60 days
        static let defaultMaxCount = 500
    }

    // MARK: - In-memory factory (previews / tests)

    extension LayoutStore {
        /// Disk-free store seeded with `initial`, for previews and E2E/unit tests.
        static func inMemory(_ initial: [SavedSessionLayout] = []) -> LayoutStore {
            let storage = LayoutStorage(inMemory: initial)
            return LayoutStore(storage: storage)
        }
    }

    // MARK: - DependencyKey

    extension LayoutStore: DependencyKey {
        /// One shared, disk-backed storage actor for the live app.
        private static let sharedStorage = LayoutStorage(directory: LayoutStorage.defaultDirectory)

        static var liveValue: LayoutStore {
            LayoutStore(storage: sharedStorage)
        }

        /// Previews don't persist.
        static var previewValue: LayoutStore {
            .inMemory()
        }
    }

    private extension LayoutStore {
        /// Bridge the struct's closures to a storage actor.
        init(storage: LayoutStorage) {
            self.init(
                record: { await storage.record(for: $0) },
                folderDefault: { await storage.folderDefault(folder: $0, excluding: $1) },
                save: { await storage.save($0) },
                remove: { await storage.remove($0) },
                prune: { await storage.prune(maxAge: $0, maxCount: $1, now: Date()) }
            )
        }
    }

    // MARK: - Storage actor

    /// Holds the records in memory and (optionally) mirrors them to a single
    /// JSON file. A combined file is rewritten atomically on each mutation;
    /// writes are debounced upstream, so the rewrite cost is negligible.
    actor LayoutStorage {
        private let fileURL: URL?
        private var records: [SavedSessionLayout.Key: SavedSessionLayout]
        private var loaded: Bool

        /// Disk-backed. Loads lazily on first access.
        init(directory: URL?) {
            self.fileURL = directory?.appendingPathComponent("layouts.json")
            self.records = [:]
            self.loaded = false
        }

        /// Disk-free, seeded.
        init(inMemory initial: [SavedSessionLayout]) {
            self.fileURL = nil
            self.records = Dictionary(initial.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
            self.loaded = true
        }

        static var defaultDirectory: URL? {
            guard
                let base = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else { return nil }
            return base
                .appendingPathComponent("Gallager", isDirectory: true)
                .appendingPathComponent("Layouts", isDirectory: true)
        }

        func record(for key: SavedSessionLayout.Key) -> SavedSessionLayout? {
            ensureLoaded()
            return records[key]
        }

        func folderDefault(folder: String, excluding: SavedSessionLayout.Key?) -> SavedSessionLayout? {
            ensureLoaded()
            return records.values
                .filter { rec in
                    guard rec.folder == folder else { return false }
                    if let excluding, rec.key == excluding { return false }
                    return true
                }
                .max { $0.lastActive < $1.lastActive }
        }

        func save(_ record: SavedSessionLayout) {
            ensureLoaded()
            records[record.key] = record
            persist()
        }

        func remove(_ key: SavedSessionLayout.Key) {
            ensureLoaded()
            records[key] = nil
            persist()
        }

        func prune(maxAge: TimeInterval, maxCount: Int, now: Date) {
            ensureLoaded()
            let cutoff = now.addingTimeInterval(-maxAge)
            for (key, rec) in records where rec.lastActive < cutoff {
                records[key] = nil
            }
            if records.count > maxCount {
                let keep = records.values
                    .sorted { $0.lastActive > $1.lastActive }
                    .prefix(maxCount)
                records = Dictionary(keep.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
            }
            persist()
        }

        // MARK: - Disk

        private func ensureLoaded() {
            guard !loaded else { return }
            loaded = true
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
            guard let decoded = try? JSONDecoder().decode([SavedSessionLayout].self, from: data) else { return }
            records = Dictionary(decoded.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        }

        private func persist() {
            guard let fileURL else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(Array(records.values))
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // Best-effort: layout persistence must never disrupt the app.
            }
        }
    }
#endif
