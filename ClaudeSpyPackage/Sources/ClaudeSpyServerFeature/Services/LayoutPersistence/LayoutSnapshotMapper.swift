#if os(macOS)
    import Foundation

    /// Translates between the live, in-memory `SessionFileTabsState` (+ its
    /// `FileBrowserState`) and the serializable `SavedFolderLayout`.
    ///
    /// The two directions are not symmetric: capturing reads the live runtime
    /// types; restoring rebuilds them into a *fresh* session. Window references
    /// are translated by tmux window *index* via injected resolvers (the mapper
    /// stays free of any knowledge of tmux id formatting, which keeps it pure and
    /// unit-testable). Browser tabs are rebuilt through an injected factory so the
    /// mapper never touches `WKWebView`.
    enum LayoutSnapshotMapper {
        // MARK: - Capture

        /// Snapshot the live workbench into a serializable layout.
        ///
        /// - Parameter windowIndexForId: maps a live tmux window id (as stored in
        ///   a `.window` tab payload) to its index within the session, or `nil`
        ///   if the window no longer exists. Window refs that don't resolve are
        ///   dropped from the snapshot.
        @MainActor
        static func snapshot(
            from tabs: SessionFileTabsState,
            fileBrowser: FileBrowserState?,
            windowIndexForId: (String) -> Int?
        ) -> SavedFolderLayout {
            // Deleted tabs reference files that no longer exist — don't persist them.
            let liveFileTabs = tabs.openFileTabs.filter { !$0.isDeleted }
            let fileTabs = liveFileTabs.map {
                SavedFileTab(id: $0.id, path: $0.path, directoryPath: $0.directoryPath)
            }
            let browserTabs = tabs.openBrowserTabs.map { tab in
                SavedBrowserTab(
                    id: tab.id,
                    url: tab.url,
                    // Prefer the live page title the web view reported.
                    displayTitle: tabs.browserStates[tab.id]?.pageTitle ?? tab.displayTitle,
                    parentId: tab.parentTabId
                )
            }

            let keptFileIds = Set(fileTabs.map(\.id))
            let keptBrowserIds = Set(browserTabs.map(\.id))

            func ref(for payload: TabDragPayload) -> SavedTabRef? {
                savedRef(
                    for: payload,
                    windowIndexForId: windowIndexForId,
                    keptFileIds: keptFileIds,
                    keptBrowserIds: keptBrowserIds
                )
            }

            let selectedLeft: SavedTabRef? =
                if let id = tabs.selectedFileTabId, keptFileIds.contains(id) {
                    .file(id: id)
                } else if let id = tabs.selectedBrowserTabId, keptBrowserIds.contains(id) {
                    .browser(id: id)
                } else {
                    nil
                }

            let fileTree = fileBrowser.map {
                SavedFileTree(sidebarWidth: $0.sidebarWidth, expandedPaths: [])
            }

            return SavedFolderLayout(
                fileTabs: fileTabs,
                browserTabs: browserTabs,
                tabOrder: tabs.tabOrder.compactMap(ref),
                rightSide: tabs.rightSide.compactMap(ref),
                selectedLeft: selectedLeft,
                selectedRight: tabs.selectedRight.flatMap(ref),
                splitRatio: tabs.splitRatio,
                fileTree: fileTree
            )
        }

        // MARK: - Restore

        /// Hydrate a *fresh* (empty) workbench from a saved layout. No-op-safe to
        /// call on a populated state, but intended only for seeding at birth.
        ///
        /// - Parameters:
        ///   - windowIdForIndex: maps a tmux window index back to the live
        ///     session's window id, or `nil` if the session has no window at that
        ///     index. Window refs that don't resolve are dropped.
        ///   - makeBrowserState: builds a live `BrowserTabState` (with its
        ///     `WKWebView`) for a restored browser tab. Injected so the mapper
        ///     stays UI-free and testable.
        @MainActor
        static func apply(
            _ layout: SavedFolderLayout,
            to tabs: SessionFileTabsState,
            fileBrowser: FileBrowserState?,
            windowIdForIndex: (Int) -> String?,
            makeBrowserState: (BrowserTab) -> BrowserTabState
        ) {
            // File tabs — ids preserved so SavedTabRef.file references stay valid.
            tabs.openFileTabs = layout.fileTabs.map {
                OpenFileTab(id: $0.id, path: $0.path, directoryPath: $0.directoryPath)
            }

            // Browser tabs — rebuild the value type and its live state.
            var restoredBrowserTabs: [BrowserTab] = []
            var restoredStates: [UUID: BrowserTabState] = [:]
            for saved in layout.browserTabs {
                let tab = BrowserTab(
                    id: saved.id,
                    url: saved.url,
                    displayTitle: saved.displayTitle,
                    parentTabId: saved.parentId
                )
                restoredBrowserTabs.append(tab)
                restoredStates[tab.id] = makeBrowserState(tab)
            }
            tabs.openBrowserTabs = restoredBrowserTabs
            tabs.browserStates = restoredStates

            let restoredFileIds = Set(tabs.openFileTabs.map(\.id))
            let restoredBrowserIds = Set(restoredBrowserTabs.map(\.id))

            func payload(for ref: SavedTabRef) -> TabDragPayload? {
                runtimePayload(
                    for: ref,
                    windowIdForIndex: windowIdForIndex,
                    restoredFileIds: restoredFileIds,
                    restoredBrowserIds: restoredBrowserIds
                )
            }

            tabs.tabOrder = layout.tabOrder.compactMap(payload)
            tabs.rightSide = Set(layout.rightSide.compactMap(payload))
            tabs.selectedRight = layout.selectedRight.flatMap(payload)

            switch layout.selectedLeft.flatMap(payload) {
            case let .file(id):
                tabs.selectedFileTabId = id
                tabs.selectedBrowserTabId = nil
            case let .browser(id):
                tabs.selectedBrowserTabId = id
                tabs.selectedFileTabId = nil
            default:
                tabs.selectedFileTabId = nil
                tabs.selectedBrowserTabId = nil
            }

            tabs.splitRatio = min(max(layout.splitRatio, SplitLayout.minRatio), SplitLayout.maxRatio)

            if let fileTree = layout.fileTree, let fileBrowser {
                fileBrowser.sidebarWidth = fileTree.sidebarWidth
            }
        }

        // MARK: - Ref translation

        private static func savedRef(
            for payload: TabDragPayload,
            windowIndexForId: (String) -> Int?,
            keptFileIds: Set<UUID>,
            keptBrowserIds: Set<UUID>
        ) -> SavedTabRef? {
            switch payload {
            case let .window(id):
                windowIndexForId(id).map { .window(index: $0) }
            case .fileExplorer:
                .fileExplorer
            case .git:
                .git
            case let .file(id):
                keptFileIds.contains(id) ? .file(id: id) : nil
            case let .browser(id):
                keptBrowserIds.contains(id) ? .browser(id: id) : nil
            }
        }

        private static func runtimePayload(
            for ref: SavedTabRef,
            windowIdForIndex: (Int) -> String?,
            restoredFileIds: Set<UUID>,
            restoredBrowserIds: Set<UUID>
        ) -> TabDragPayload? {
            switch ref {
            case let .window(index):
                windowIdForIndex(index).map { .window($0) }
            case .fileExplorer:
                .fileExplorer
            case .git:
                .git
            case let .file(id):
                restoredFileIds.contains(id) ? .file(id) : nil
            case let .browser(id):
                restoredBrowserIds.contains(id) ? .browser(id) : nil
            }
        }
    }
#endif
