import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Renders the detail-pane content area below the window tab bar for a
/// selected *local* window. Picks between a browser tab, file browser tree,
/// file tab content, or terminal mirror based on the current session-scoped
/// tab state, and routes through `SplitDetailContent` when the session has
/// any tabs sent to the right pane.
///
/// Lifted out of `MainView` so the cross-cutting state wiring (the
/// `detailContent` body) stays focused. The view is a thin renderer — all
/// state mutations are routed back to MainView via the callbacks.
struct MainDetailPaneContent: View {
    let window: LocalTmuxWindow
    let session: LocalTmuxSession?
    let directoryPath: String
    let isFileBrowserActive: Bool
    let browserState: FileBrowserState?
    let sessionTabs: SessionFileTabsState?
    let selectedBrowserTab: BrowserTab?

    /// Opens a file tab for the given path. Provided as a callback because
    /// `MainView` also needs to update `fileBrowserActiveWindowIds`.
    let onOpenFileInNewTab: (_ path: String) -> Void
    /// Handles a URL clicked in the terminal. Returns true when MainView
    /// consumed the click (the system handler should NOT also open the URL).
    let onTerminalURLClick: TerminalOpenURLHandler

    var body: some View {
        if let sessionTabs, sessionTabs.isSplit, let session {
            SplitDetailContent(
                sessionTabs: sessionTabs,
                left: { leftPane },
                right: {
                    MainDetailRightPane(
                        sessionName: session.sessionName,
                        sessionTabs: sessionTabs
                    )
                }
            )
        } else {
            leftPane
        }
    }

    /// Body of the left (single-pane in non-split mode) pane: browser tab,
    /// file browser tree, or terminal mirror — whichever the current tab
    /// state selects.
    @ViewBuilder
    private var leftPane: some View {
        if
            let selectedBrowserTab,
            let sessionTabs,
            let browserTabState = sessionTabs.browserStates[selectedBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    sessionTabs.updateBrowserTabTitle(
                        tabId: selectedBrowserTab.id,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    sessionTabs.updateBrowserTabURL(
                        tabId: selectedBrowserTab.id,
                        url: newURL
                    )
                }
            )
            .id(selectedBrowserTab.id)
        } else if
            isFileBrowserActive,
            let browserState,
            let sessionTabs {
            FileBrowserView(
                directoryPath: directoryPath,
                state: browserState,
                sessionTabs: sessionTabs,
                onOpenFileInNewTab: onOpenFileInNewTab
            )
        } else {
            WindowPaneLayoutView(
                window: window,
                onOpenURL: onTerminalURLClick
            )
        }
    }
}

/// Right pane of the split layout. Shows whichever tab is currently selected
/// on the right side (browser tab, file tab) or a placeholder when nothing
/// is selected. Mirrors `MainDetailPaneContent.leftPane` for the right side.
struct MainDetailRightPane: View {
    let sessionName: String
    @Bindable var sessionTabs: SessionFileTabsState

    private var selectedRightBrowserTab: BrowserTab? {
        guard let id = sessionTabs.selectedRightBrowserTabId else { return nil }
        return sessionTabs.openBrowserTabs.first(where: { $0.id == id })
    }

    private var selectedRightFileTab: OpenFileTab? {
        guard let id = sessionTabs.selectedRightFileTabId else { return nil }
        return sessionTabs.openFileTabs.first(where: { $0.id == id })
    }

    var body: some View {
        if
            let selectedRightBrowserTab,
            let browserTabState = sessionTabs.browserStates[selectedRightBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    sessionTabs.updateBrowserTabTitle(
                        tabId: selectedRightBrowserTab.id,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    sessionTabs.updateBrowserTabURL(
                        tabId: selectedRightBrowserTab.id,
                        url: newURL
                    )
                }
            )
            .id("right-\(selectedRightBrowserTab.id)")
            .accessibilityIdentifier("split-right-pane")
        } else if let selectedRightFileTab {
            OpenFileTabContentView(tab: selectedRightFileTab, sessionTabs: sessionTabs)
                .id("right-\(selectedRightFileTab.id)")
                .accessibilityIdentifier("split-right-pane")
        } else {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "No Tab Selected",
                    symbol: .rectangleSplit2x1,
                    description: "Pick a tab on the right side to view it."
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("split-right-pane")
        }
    }
}
