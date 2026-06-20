#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Persists workbench layouts, one record per **folder** (see
    /// `docs/folder-layout-persistence-plan.md`). The store answers a single
    /// restore question — "what's the saved layout for this folder?" — used both
    /// to seed a brand-new session on a known folder and to restore an
    /// already-running session on cold launch. There is no per-session record and
    /// no "default" derivation: the folder *is* the key.
    ///
    /// Writes are awaited and immediate; debouncing lives at the call site
    /// (`MainView`). The store never throws into the app — persistence failures
    /// degrade to "no saved layout" rather than disrupting the workbench.
    @DependencyClient
    struct LayoutStore: Sendable {
        /// Saved layout for a folder key, or `nil` if none.
        var record: @Sendable (_ key: SavedFolderRecord.Key) async -> SavedFolderRecord?
        /// Insert or replace the folder's record (most-recent write wins when two
        /// sessions share a folder).
        var save: @Sendable (_ record: SavedFolderRecord) async -> Void
        /// Remove a folder's record.
        var remove: @Sendable (_ key: SavedFolderRecord.Key) async -> Void
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
        static func inMemory(_ initial: [SavedFolderRecord] = []) -> LayoutStore {
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
        private var records: [SavedFolderRecord.Key: SavedFolderRecord]
        private var loaded: Bool

        /// Disk-backed. Loads lazily on first access.
        init(directory: URL?) {
            self.fileURL = directory?.appendingPathComponent("layouts.json")
            self.records = [:]
            self.loaded = false
        }

        /// Disk-free, seeded.
        init(inMemory initial: [SavedFolderRecord]) {
            self.fileURL = nil
            self.records = Dictionary(initial.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
            self.loaded = true
        }

        /// Stored under the Gallager state root (`~/.gallager/state/Layouts`, or
        /// the per-instance `--gallager-state-root` under E2E) so test runs stay
        /// isolated and auto-cleaned rather than touching the real user library.
        static var defaultDirectory: URL? {
            GallagerPaths(stateRootOverride: parseStateRootOverride())
                .stateRoot
                .appendingPathComponent("Layouts", isDirectory: true)
        }

        /// Mirror of `AppCoordinator`'s `--gallager-state-root` parse so the
        /// static live store lands in the same isolated tree the rest of the app
        /// uses, without threading `GallagerPaths` through a `@Dependency`.
        private static func parseStateRootOverride() -> URL? {
            let args = CommandLine.arguments
            guard
                let flagIndex = args.firstIndex(of: "--gallager-state-root"),
                flagIndex + 1 < args.count,
                !args[flagIndex + 1].isEmpty
            else { return nil }
            return URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
        }

        func record(for key: SavedFolderRecord.Key) -> SavedFolderRecord? {
            ensureLoaded()
            return records[key]
        }

        func save(_ record: SavedFolderRecord) {
            ensureLoaded()
            records[record.key] = record
            persist()
        }

        func remove(_ key: SavedFolderRecord.Key) {
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
            guard let decoded = try? JSONDecoder().decode([SavedFolderRecord].self, from: data) else { return }
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
