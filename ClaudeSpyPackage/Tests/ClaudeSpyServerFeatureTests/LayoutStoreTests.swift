#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers the in-memory `LayoutStore`: exact-record lookup, the
    /// "most-recently-active on this folder" default query (with self-exclusion),
    /// and prune-by-count. See `docs/folder-layout-persistence-plan.md` §4.2–4.3.
    @Suite("LayoutStore")
    struct LayoutStoreTests {
        private func record(
            session: String,
            folder: String,
            lastActive: TimeInterval,
            host: String = "local"
        ) -> SavedSessionLayout {
            SavedSessionLayout(
                host: host,
                sessionName: session,
                folder: folder,
                lastActive: Date(timeIntervalSince1970: lastActive),
                layout: SavedFolderLayout(
                    fileTabs: [SavedFileTab(id: UUID(), path: "\(folder)/f.swift", directoryPath: folder)]
                )
            )
        }

        @Test("save then record returns the exact record by key")
        func saveAndFetch() async {
            let store = LayoutStore.inMemory()
            let rec = record(session: "alpha", folder: "/proj", lastActive: 100)
            await store.save(rec)

            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "alpha")) == rec)
            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "missing")) == nil)
        }

        @Test("folderDefault returns the most-recently-active record for the folder")
        func folderDefaultMostRecent() async {
            let store = LayoutStore.inMemory([
                record(session: "alpha", folder: "/proj", lastActive: 100),
                record(session: "beta", folder: "/proj", lastActive: 200),
                record(session: "gamma", folder: "/other", lastActive: 999),
            ])

            let def = await store.folderDefault("/proj", nil)
            #expect(def?.sessionName == "beta")
        }

        @Test("folderDefault excludes the requesting session so it never seeds from itself")
        func folderDefaultExcludesSelf() async {
            let store = LayoutStore.inMemory([
                record(session: "alpha", folder: "/proj", lastActive: 100),
                record(session: "beta", folder: "/proj", lastActive: 200),
            ])

            let def = await store.folderDefault("/proj", SavedSessionLayout.Key(host: "local", sessionName: "beta"))
            #expect(def?.sessionName == "alpha")
        }

        @Test("folderDefault returns nil when no record matches the folder")
        func folderDefaultNoMatch() async {
            let store = LayoutStore.inMemory([
                record(session: "alpha", folder: "/proj", lastActive: 100),
            ])
            #expect(await store.folderDefault("/nope", nil) == nil)
        }

        @Test("remove deletes the record")
        func removeDeletes() async {
            let store = LayoutStore.inMemory([
                record(session: "alpha", folder: "/proj", lastActive: 100),
            ])
            await store.remove(SavedSessionLayout.Key(host: "local", sessionName: "alpha"))
            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "alpha")) == nil)
        }

        @Test("prune caps to the most-recently-active records")
        func pruneCapsByCount() async {
            let store = LayoutStore.inMemory([
                record(session: "a", folder: "/p", lastActive: 1),
                record(session: "b", folder: "/p", lastActive: 2),
                record(session: "c", folder: "/p", lastActive: 3),
            ])

            // Keep only the 2 most-recent; age limit large so only count applies.
            await store.prune(.greatestFiniteMagnitude, 2)

            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "a")) == nil)
            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "b")) != nil)
            #expect(await store.record(SavedSessionLayout.Key(host: "local", sessionName: "c")) != nil)
        }
    }
#endif
