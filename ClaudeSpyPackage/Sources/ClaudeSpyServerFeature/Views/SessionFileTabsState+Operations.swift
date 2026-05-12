import Foundation

/// High-level tab operations for `SessionFileTabsState`. Lifted out of
/// `MainView` so the cross-cutting selection/routing logic in `MainView`
/// stays focused and the tab-state mutations live next to the state itself.
///
/// Methods return values describe follow-up work the caller still needs to
/// do — e.g., closing a tab returns the origin window id (when applicable)
/// so the caller can route focus back to the originating terminal.
extension SessionFileTabsState {
    /// Opens (or re-selects) a file tab for `path`.
    ///
    /// When an existing tab is re-opened, only a non-nil incoming
    /// `originWindowId` overwrites the stored value — a tree/context-menu
    /// re-open carries no origin and must not silently clear the
    /// previously-recorded terminal return target.
    ///
    /// `useSplit` mirrors `Settings.alwaysOpenFilesInSplit`: when true, new
    /// tabs are sent to the right pane.
    func openFileTab(
        path: String,
        directoryPath: String,
        originWindowId: String? = nil,
        useSplit: Bool
    ) {
        if let existingIndex = openFileTabs.firstIndex(where: { $0.path == path }) {
            if let originWindowId {
                openFileTabs[existingIndex].originWindowId = originWindowId
            }
            let existingId = openFileTabs[existingIndex].id
            if rightSideFileTabIds.contains(existingId) {
                selectedRightFileTabId = existingId
                selectedRightBrowserTabId = nil
            } else {
                selectedFileTabId = existingId
            }
            return
        }
        let newTab = OpenFileTab(
            path: path,
            directoryPath: directoryPath,
            originWindowId: originWindowId
        )
        openFileTabs.append(newTab)
        if useSplit {
            rightSideFileTabIds.insert(newTab.id)
            selectedRightFileTabId = newTab.id
            selectedRightBrowserTabId = nil
        } else {
            selectedFileTabId = newTab.id
        }
    }

    /// Selects an existing file tab on whichever side it currently lives on.
    func selectFileTab(_ tabId: UUID) {
        if rightSideFileTabIds.contains(tabId) {
            selectedRightFileTabId = tabId
            selectedRightBrowserTabId = nil
            return
        }
        selectedFileTabId = tabId
        selectedBrowserTabId = nil
    }

    /// Toggles which side of the split a file tab lives on (issue #498). The
    /// receiving side becomes the tab's selected entry; the originating side
    /// has its selection reset if it pointed at the moved tab. After every
    /// move `reconcileRightPaneSelection` re-picks a right-pane selection so
    /// the right pane doesn't show the empty placeholder while real tabs are
    /// still over there.
    ///
    /// Returns `true` when the tab is now on the left side (caller should
    /// ensure the originating window is in `fileBrowserActiveWindowIds` so
    /// the underlying file browser tree stays mounted).
    @discardableResult
    func toggleFileTabSplit(_ tabId: UUID) -> Bool {
        guard openFileTabs.contains(where: { $0.id == tabId }) else { return false }
        let nowOnLeft: Bool
        if rightSideFileTabIds.contains(tabId) {
            rightSideFileTabIds.remove(tabId)
            if selectedRightFileTabId == tabId {
                selectedRightFileTabId = nil
            }
            selectedFileTabId = tabId
            selectedBrowserTabId = nil
            nowOnLeft = true
        } else {
            rightSideFileTabIds.insert(tabId)
            if selectedFileTabId == tabId {
                selectedFileTabId = nil
            }
            selectedRightFileTabId = tabId
            selectedRightBrowserTabId = nil
            nowOnLeft = false
        }
        reconcileRightPaneSelection()
        return nowOnLeft
    }

    /// Toggles which side of the split a browser tab lives on (issue #498).
    /// Mirrors `toggleFileTabSplit`. Returns `true` when the tab is now on
    /// the left side (caller should drop the originating window from
    /// `fileBrowserActiveWindowIds` because browser tabs replace the tree).
    @discardableResult
    func toggleBrowserTabSplit(_ tabId: UUID) -> Bool {
        guard openBrowserTabs.contains(where: { $0.id == tabId }) else { return false }
        let nowOnLeft: Bool
        if rightSideBrowserTabIds.contains(tabId) {
            rightSideBrowserTabIds.remove(tabId)
            if selectedRightBrowserTabId == tabId {
                selectedRightBrowserTabId = nil
            }
            selectedBrowserTabId = tabId
            selectedFileTabId = nil
            nowOnLeft = true
        } else {
            rightSideBrowserTabIds.insert(tabId)
            if selectedBrowserTabId == tabId {
                selectedBrowserTabId = nil
            }
            selectedRightBrowserTabId = tabId
            selectedRightFileTabId = nil
            nowOnLeft = false
        }
        reconcileRightPaneSelection()
        return nowOnLeft
    }

    /// Keeps the right pane's selection coherent with the tabs still on that
    /// side. Clears dangling selections, then auto-picks a tab on the right
    /// when nothing is selected but at least one tab remains there. Prefers
    /// the most recently appended file tab and falls back to the most
    /// recently appended browser tab — the goal is to avoid the "No Tab
    /// Selected" placeholder whenever a real tab could fill the pane.
    func reconcileRightPaneSelection() {
        if let id = selectedRightFileTabId, !rightSideFileTabIds.contains(id) {
            selectedRightFileTabId = nil
        }
        if let id = selectedRightBrowserTabId, !rightSideBrowserTabIds.contains(id) {
            selectedRightBrowserTabId = nil
        }
        guard isSplit else { return }
        if selectedRightFileTabId != nil || selectedRightBrowserTabId != nil {
            return
        }
        if let fileTab = openFileTabs.last(where: { rightSideFileTabIds.contains($0.id) }) {
            selectedRightFileTabId = fileTab.id
        } else if let browserTab = openBrowserTabs.last(where: { rightSideBrowserTabIds.contains($0.id) }) {
            selectedRightBrowserTabId = browserTab.id
        }
    }

    /// Opens (or re-selects) a browser tab for `url`.
    ///
    /// Existing tabs are matched on the live `BrowserTabState.currentURL`
    /// rather than the stored `BrowserTab.url` — after the user navigates
    /// away from the opening URL, re-using the stored value for dedup would
    /// let a second click on the original URL spawn a duplicate tab.
    ///
    /// Returns `true` when the (newly added or re-selected) tab is on the
    /// left side. Callers use this to drop the originating window from
    /// `fileBrowserActiveWindowIds` because a left-side browser replaces
    /// the file tree.
    @discardableResult
    func openBrowserTab(
        url: URL,
        originWindowId: String? = nil,
        useSplit: Bool
    ) -> Bool {
        let existingIndex = openBrowserTabs.firstIndex { tab in
            browserStates[tab.id]?.currentURL == url
        }
        if let existingIndex {
            if let originWindowId {
                openBrowserTabs[existingIndex].originWindowId = originWindowId
            }
            let existingId = openBrowserTabs[existingIndex].id
            if rightSideBrowserTabIds.contains(existingId) {
                selectedRightBrowserTabId = existingId
                selectedRightFileTabId = nil
                return false
            }
            selectedBrowserTabId = existingId
            selectedFileTabId = nil
            return true
        }
        let newTab = BrowserTab(url: url, originWindowId: originWindowId)
        openBrowserTabs.append(newTab)
        browserStates[newTab.id] = BrowserTabState(initialURL: url)
        if useSplit {
            rightSideBrowserTabIds.insert(newTab.id)
            selectedRightBrowserTabId = newTab.id
            selectedRightFileTabId = nil
            return false
        }
        selectedBrowserTabId = newTab.id
        selectedFileTabId = nil
        return true
    }

    /// Selects an existing browser tab. Returns `true` when the tab lives
    /// on the left side (caller drops the window from
    /// `fileBrowserActiveWindowIds`); `false` for right-side selections.
    @discardableResult
    func selectBrowserTab(_ tabId: UUID) -> Bool {
        if rightSideBrowserTabIds.contains(tabId) {
            selectedRightBrowserTabId = tabId
            selectedRightFileTabId = nil
            return false
        }
        selectedBrowserTabId = tabId
        selectedFileTabId = nil
        return true
    }

    /// Updates the cached page title for a browser tab so the tab strip
    /// re-renders with the new label.
    func updateBrowserTabTitle(tabId: UUID, title: String?) {
        guard let index = openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        if openBrowserTabs[index].displayTitle != title {
            openBrowserTabs[index].displayTitle = title
        }
    }

    /// Updates the recorded URL for a browser tab as the user navigates so
    /// re-opening the same URL later picks the existing tab.
    func updateBrowserTabURL(tabId: UUID, url: URL) {
        guard let index = openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        if openBrowserTabs[index].url != url {
            openBrowserTabs[index].url = url
        }
    }

    /// Removes a browser tab and its live web view. Returns the origin
    /// window id when the closed tab was on the left side and was the
    /// selected entry — the caller routes focus back to that window. Right-
    /// side closes never re-route focus (the user opened those explicitly).
    func closeBrowserTab(_ tabId: UUID) -> String? {
        guard let closedIndex = openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let closedTab = openBrowserTabs[closedIndex]
        let wasOnRight = rightSideBrowserTabIds.contains(tabId)
        let wasSelectedLeft = selectedBrowserTabId == tabId
        let wasSelectedRight = selectedRightBrowserTabId == tabId
        openBrowserTabs.remove(at: closedIndex)
        browserStates.removeValue(forKey: tabId)
        rightSideBrowserTabIds.remove(tabId)
        if wasSelectedRight {
            selectedRightBrowserTabId = nil
        }
        reconcileRightPaneSelection()
        guard wasSelectedLeft else { return nil }
        selectedBrowserTabId = nil
        guard !wasOnRight else { return nil }
        return closedTab.originWindowId
    }

    /// Removes a file tab. Returns the origin window id when the closed tab
    /// was on the left side and was the selected entry — the caller routes
    /// focus back to that window. Right-side closes never re-route focus.
    ///
    /// Invariant: this must be the only code path that removes entries from
    /// `openFileTabs`. Any bulk mutation that bypasses this method must also
    /// clear `selectedFileTabId` when the selected tab is removed, otherwise
    /// the id will dangle and the content area will render
    /// `OpenFileTabContentView` against a stale tab.
    func closeFileTab(_ tabId: UUID) -> String? {
        guard let closedIndex = openFileTabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let closedTab = openFileTabs[closedIndex]
        let wasOnRight = rightSideFileTabIds.contains(tabId)
        let wasSelectedLeft = selectedFileTabId == tabId
        let wasSelectedRight = selectedRightFileTabId == tabId
        openFileTabs.remove(at: closedIndex)
        scrollOffsets.removeValue(forKey: tabId)
        rightSideFileTabIds.remove(tabId)
        if wasSelectedRight {
            selectedRightFileTabId = nil
        }
        reconcileRightPaneSelection()
        guard wasSelectedLeft else { return nil }
        selectedFileTabId = nil
        guard !wasOnRight else { return nil }
        return closedTab.originWindowId
    }
}
