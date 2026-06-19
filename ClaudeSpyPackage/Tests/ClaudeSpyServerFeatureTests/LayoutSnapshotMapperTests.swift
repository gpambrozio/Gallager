#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers the `SessionFileTabsState` ⇄ `SavedFolderLayout` translation:
    /// file/browser tabs survive a round trip, window references re-map by tmux
    /// window *index* (and drop when the target session lacks that index), and
    /// the split arrangement / selection are preserved. See
    /// `docs/folder-layout-persistence-plan.md`.
    @Suite("LayoutSnapshotMapper")
    @MainActor
    struct LayoutSnapshotMapperTests {
        // MARK: - Capture

        @Test("Snapshot maps windows to indices, drops unknown windows and deleted files")
        func snapshotMapsAndFilters() {
            let keepId = UUID()
            let deletedId = UUID()

            let tabs = SessionFileTabsState()
            tabs.openFileTabs = [
                OpenFileTab(id: keepId, path: "/proj/a.swift", directoryPath: "/proj"),
                OpenFileTab(id: deletedId, path: "/proj/gone.swift", directoryPath: "/proj", isDeleted: true),
            ]
            tabs.selectedFileTabId = keepId
            tabs.splitRatio = 0.7
            tabs.tabOrder = [
                .window("win-A"),
                .window("win-orphan"), // no live index → dropped
                .fileExplorer,
                .git,
                .file(keepId),
                .file(deletedId), // filtered out (deleted)
            ]
            tabs.rightSide = [.window("win-A")]
            tabs.selectedRight = .window("win-A")

            let indices = ["win-A": 0, "win-B": 1]
            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: nil,
                windowIndexForId: { indices[$0] }
            )

            #expect(layout.fileTabs == [SavedFileTab(id: keepId, path: "/proj/a.swift", directoryPath: "/proj")])
            #expect(layout.tabOrder == [
                .window(index: 0),
                .fileExplorer,
                .git,
                .file(id: keepId),
            ])
            #expect(layout.rightSide == [.window(index: 0)])
            #expect(layout.selectedRight == .window(index: 0))
            #expect(layout.selectedLeft == .file(id: keepId))
            #expect(layout.splitRatio == 0.7)
        }

        @Test("Sidebar width is captured when a file browser is present")
        func snapshotCapturesFileTree() {
            let tabs = SessionFileTabsState()
            let fileBrowser = FileBrowserState()
            fileBrowser.sidebarWidth = 321

            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: fileBrowser,
                windowIndexForId: { _ in nil }
            )

            #expect(layout.fileTree?.sidebarWidth == 321)
        }

        // MARK: - Restore

        @Test("Apply preserves file tabs and re-maps window indices to live ids, dropping absent ones")
        func applyRemapsWindows() {
            let fileId = UUID()
            let layout = SavedFolderLayout(
                fileTabs: [SavedFileTab(id: fileId, path: "/proj/a.swift", directoryPath: "/proj")],
                tabOrder: [.window(index: 0), .window(index: 1), .file(id: fileId), .fileExplorer],
                rightSide: [.window(index: 0)],
                selectedLeft: .file(id: fileId),
                selectedRight: .window(index: 0),
                splitRatio: 0.99, // out of range → clamped
                fileTree: SavedFileTree(sidebarWidth: 200)
            )

            let tabs = SessionFileTabsState()
            let fileBrowser = FileBrowserState()
            // The restored session only has a window at index 0.
            let idForIndex = [0: "new-0"]
            LayoutSnapshotMapper.apply(
                layout,
                to: tabs,
                fileBrowser: fileBrowser,
                windowIdForIndex: { idForIndex[$0] },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )

            #expect(tabs.openFileTabs.map(\.id) == [fileId])
            #expect(tabs.openFileTabs.map(\.path) == ["/proj/a.swift"])
            // index 1 has no live window → dropped; index 0 → "new-0".
            #expect(tabs.tabOrder == [.window("new-0"), .file(fileId), .fileExplorer])
            #expect(tabs.rightSide == [.window("new-0")])
            #expect(tabs.selectedFileTabId == fileId)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.splitRatio == SplitLayout.maxRatio)
            #expect(fileBrowser.sidebarWidth == 200)
        }

        @Test("Browser tabs round-trip their URLs, ids and live state")
        func browserRoundTrip() {
            let b1 = UUID()
            let b2 = UUID()
            let tabs = SessionFileTabsState()
            tabs.openBrowserTabs = [
                BrowserTab(id: b1, url: URL(string: "https://example.com")!, displayTitle: "Ex"),
                BrowserTab(id: b2, url: URL(string: "https://swift.org")!, parentTabId: b1),
            ]
            tabs.selectedBrowserTabId = b2
            tabs.tabOrder = [.browser(b1), .browser(b2)]

            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: nil,
                windowIndexForId: { _ in nil }
            )

            let restored = SessionFileTabsState()
            LayoutSnapshotMapper.apply(
                layout,
                to: restored,
                fileBrowser: nil,
                windowIdForIndex: { _ in nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )

            #expect(restored.openBrowserTabs.map(\.id) == [b1, b2])
            #expect(restored.openBrowserTabs.map(\.url.absoluteString) == [
                "https://example.com",
                "https://swift.org",
            ])
            #expect(restored.openBrowserTabs[1].parentTabId == b1)
            #expect(restored.browserStates[b1] != nil)
            #expect(restored.browserStates[b2] != nil)
            #expect(restored.selectedBrowserTabId == b2)
            #expect(restored.tabOrder == [.browser(b1), .browser(b2)])
        }

        // MARK: - Codable

        @Test("SavedFolderLayout survives a JSON round trip")
        func codableRoundTrip() throws {
            let layout = SavedFolderLayout(
                fileTabs: [SavedFileTab(id: UUID(), path: "/p/a", directoryPath: "/p")],
                browserTabs: [SavedBrowserTab(id: UUID(), url: URL(string: "https://x.io")!)],
                tabOrder: [.window(index: 2), .fileExplorer, .git],
                rightSide: [.git],
                selectedLeft: nil,
                selectedRight: .git,
                splitRatio: 0.4,
                fileTree: SavedFileTree(sidebarWidth: 250, expandedPaths: ["/p"])
            )

            let data = try JSONEncoder().encode(layout)
            let decoded = try JSONDecoder().decode(SavedFolderLayout.self, from: data)
            #expect(decoded == layout)
        }
    }
#endif
