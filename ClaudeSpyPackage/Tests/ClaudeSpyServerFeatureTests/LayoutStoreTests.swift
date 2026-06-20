#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers the in-memory `LayoutStore`: per-folder save/load, same-folder
    /// overwrite (most-recent write wins), independence across folders, and
    /// prune-by-count. See `docs/folder-layout-persistence-plan.md` §4.2–4.3.
    @Suite("LayoutStore")
    struct LayoutStoreTests {
        private func record(
            folder: String,
            lastActive: TimeInterval,
            host: String = "local"
        ) -> SavedFolderRecord {
            SavedFolderRecord(
                host: host,
                folder: folder,
                lastActive: Date(timeIntervalSince1970: lastActive),
                layout: SavedFolderLayout(
                    fileTabs: [SavedFileTab(id: UUID(), path: "\(folder)/f.swift", directoryPath: folder)]
                )
            )
        }

        private func key(_ folder: String, host: String = "local") -> SavedFolderRecord.Key {
            SavedFolderRecord.Key(host: host, folder: folder)
        }

        @Test("save then record returns the folder's record")
        func saveAndFetch() async {
            let store = LayoutStore.inMemory()
            let rec = record(folder: "/proj", lastActive: 100)
            await store.save(rec)

            #expect(await store.record(key("/proj")) == rec)
            #expect(await store.record(key("/missing")) == nil)
        }

        @Test("saving the same folder overwrites — most-recent write wins")
        func sameFolderOverwrites() async {
            let store = LayoutStore.inMemory([record(folder: "/proj", lastActive: 100)])

            let newer = record(folder: "/proj", lastActive: 200)
            await store.save(newer)

            #expect(await store.record(key("/proj")) == newer)
        }

        @Test("records on different folders are independent")
        func foldersAreIndependent() async {
            let store = LayoutStore.inMemory([
                record(folder: "/proj", lastActive: 100),
                record(folder: "/other", lastActive: 200),
            ])

            #expect(await store.record(key("/proj"))?.folder == "/proj")
            #expect(await store.record(key("/other"))?.folder == "/other")
        }

        @Test("remove deletes the folder record")
        func removeDeletes() async {
            let store = LayoutStore.inMemory([record(folder: "/proj", lastActive: 100)])
            await store.remove(key("/proj"))
            #expect(await store.record(key("/proj")) == nil)
        }

        @Test("prune caps to the most-recently-active records")
        func pruneCapsByCount() async {
            let store = LayoutStore.inMemory([
                record(folder: "/a", lastActive: 1),
                record(folder: "/b", lastActive: 2),
                record(folder: "/c", lastActive: 3),
            ])

            // Keep only the 2 most-recent; age limit large so only count applies.
            await store.prune(.greatestFiniteMagnitude, 2)

            #expect(await store.record(key("/a")) == nil)
            #expect(await store.record(key("/b")) != nil)
            #expect(await store.record(key("/c")) != nil)
        }

        @Test("prune drops records older than maxAge")
        func pruneDropsStale() async {
            let now = Date()
            let store = LayoutStore.inMemory([
                SavedFolderRecord(
                    host: "local",
                    folder: "/stale",
                    lastActive: now.addingTimeInterval(-1_000),
                    layout: SavedFolderLayout(fileTabs: [SavedFileTab(id: UUID(), path: "/stale/f", directoryPath: "/stale")])
                ),
                record(folder: "/fresh", lastActive: now.timeIntervalSince1970),
            ])

            await store.prune(500, .max)

            #expect(await store.record(key("/stale")) == nil)
            #expect(await store.record(key("/fresh")) != nil)
        }
    }
#endif
