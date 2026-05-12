import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Horizontal tab bar showing windows in a tmux session.
/// Always visible, even for single-window sessions (with a "+" tab to create new windows).
struct WindowTabBar: View {
    let session: LocalTmuxSession
    let selectedWindow: LocalTmuxWindow
    /// True only when the Files (tree) tab is the active view — i.e. the file browser
    /// is open and no file tab is currently selected.
    let isFileBrowserSelected: Bool
    /// True when any non-terminal view is showing (file tree, a file tab, or a
    /// browser tab). Used to deselect the underlying tmux window tab so it
    /// doesn't render as concurrently selected with another tab.
    let isAnyFileViewActive: Bool
    /// Per-session tab state (file/browser tabs, split layout, selections).
    /// `nil` while a session hasn't materialised any tabs yet — the bar
    /// renders as if the lists were empty and `isSplit` were `false`.
    let sessionTabs: SessionFileTabsState?
    let onSelectWindow: (LocalTmuxWindow) -> Void
    let onCloseWindow: (LocalTmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (LocalTmuxWindow, String) -> Void
    let onSelectFileBrowser: () -> Void
    let onSelectFileTab: (UUID) -> Void
    let onCloseFileTab: (UUID) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void
    /// Toggles split state for a file tab. If the tab is on the left, sends it
    /// to the right (opening the split). If on the right, sends it back to the
    /// left (and collapses the split if the right side becomes empty).
    let onToggleFileTabSplit: (UUID) -> Void
    /// Same as `onToggleFileTabSplit` but for browser tabs.
    let onToggleBrowserTabSplit: (UUID) -> Void
    let onShowInFileExplorer: (String) -> Void
    let onAcceptOpenSuggestion: (MarkdownOpenSuggestion) -> Void
    let onDismissOpenSuggestion: () -> Void

    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(MarkdownOpenSuggestionStore.self) private var openSuggestionStore

    /// Cached width of the split-mode tab strip. Measured via the background
    /// `onGeometryChange` so the HStack can drive intrinsic height instead of
    /// being pinned by a `GeometryReader` parent — keeps the split and
    /// non-split rows the same height under Dynamic Type and padding tweaks.
    @State private var splitRowWidth: CGFloat = 0

    /// Read-only accessors that mirror `SessionFileTabsState`. Defined as
    /// computed properties (not stored) so observation tracking happens on
    /// every `body` evaluation — `sessionTabs` being `nil` is treated as an
    /// empty, non-split session.
    private var openFileTabs: [OpenFileTab] {
        sessionTabs?.openFileTabs ?? []
    }

    private var openBrowserTabs: [BrowserTab] {
        sessionTabs?.openBrowserTabs ?? []
    }

    private var selectedFileTabId: UUID? {
        sessionTabs?.selectedFileTabId
    }

    private var selectedBrowserTabId: UUID? {
        sessionTabs?.selectedBrowserTabId
    }

    private var selectedRightFileTabId: UUID? {
        sessionTabs?.selectedRightFileTabId
    }

    private var selectedRightBrowserTabId: UUID? {
        sessionTabs?.selectedRightBrowserTabId
    }

    private var isSplit: Bool {
        sessionTabs?.isSplit ?? false
    }

    private var splitRatio: CGFloat {
        sessionTabs?.splitRatio ?? 0.5
    }

    private func isFileTabOnRight(_ id: UUID) -> Bool {
        sessionTabs?.isFileTabOnRight(id) ?? false
    }

    private func isBrowserTabOnRight(_ id: UUID) -> Bool {
        sessionTabs?.isBrowserTabOnRight(id) ?? false
    }

    var body: some View {
        Group {
            if isSplit {
                // Use `spacing:` for the visual gap so the row's height is
                // driven by the `ScrollView(.horizontal)` siblings' intrinsic
                // (content-based) vertical size instead of being inflated by
                // a greedy spacer view. `fixedSize(vertical: true)` ensures
                // the HStack reports that intrinsic height upward so the
                // VStack parent still gives the detail area the remainder.
                HStack(spacing: SplitLayout.dividerWidth) {
                    leftSection
                        .frame(width: max(0, splitRowWidth * splitRatio - SplitLayout.dividerWidth / 2))
                    rightSection
                        .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    splitRowWidth = newWidth
                }
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
            } else {
                singleSection
                    .background(.bar)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
            }
        }
    }

    private var singleSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                tmuxWindowTabsRow
                newWindowButton
                fileBrowserTab
                ForEach(openFileTabs) { tab in
                    openFileTabView(tab)
                }
                ForEach(openBrowserTabs) { tab in
                    openBrowserTabView(tab)
                }
                if let suggestion = openSuggestionStore.suggestionsBySession[session.sessionName] {
                    openSuggestionBar(suggestion)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    /// Left section of the split-aware tab strip: window tabs, "+" button,
    /// folder button, and every file/browser tab that lives on the left pane.
    private var leftSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                tmuxWindowTabsRow
                newWindowButton
                fileBrowserTab
                ForEach(openFileTabs.filter { !isFileTabOnRight($0.id) }) { tab in
                    openFileTabView(tab)
                }
                ForEach(openBrowserTabs.filter { !isBrowserTabOnRight($0.id) }) { tab in
                    openBrowserTabView(tab)
                }
                if let suggestion = openSuggestionStore.suggestionsBySession[session.sessionName] {
                    openSuggestionBar(suggestion)
                }
                Spacer()
            }
            .padding(.leading, 8)
        }
    }

    /// Right section of the split-aware tab strip: only the file/browser tabs
    /// currently assigned to the right pane.
    private var rightSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(openFileTabs.filter { isFileTabOnRight($0.id) }) { tab in
                    openFileTabView(tab)
                }
                ForEach(openBrowserTabs.filter { isBrowserTabOnRight($0.id) }) { tab in
                    openBrowserTabView(tab)
                }
                Spacer()
            }
            .padding(.trailing, 8)
        }
    }

    private var tmuxWindowTabsRow: some View {
        ForEach(session.windows) { window in
            windowTab(window)
        }
    }

    private var newWindowButton: some View {
        Button(action: onNewWindow) {
            Symbols.plus.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New window in \(session.sessionName)")
        .accessibilityLabel("New Window")
    }

    private var fileBrowserTab: some View {
        Button(action: onSelectFileBrowser) {
            Symbols.folderFill.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isFileBrowserSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .overlay(alignment: .bottom) {
                    if isFileBrowserSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isFileBrowserSelected ? .primary : .secondary)
        .help("Browse files in \(session.sessionName)")
        .accessibilityLabel("Files")
        .accessibilityValue(isFileBrowserSelected ? "selected" : "")
    }

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id && !isAnyFileViewActive
        let hasClaude = window.panes.contains { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

        return TabBarItem(
            isSelected: isSelected,
            onSelect: { onSelectWindow(window) },
            labelAccessibilityLabel: "\(window.id) \(windowName)",
            onClose: { onCloseWindow(window) },
            closeAccessibilityLabel: "Close window",
            closeHelp: "Close window"
        ) {
            HStack(spacing: 4) {
                if hasClaude {
                    Symbols.sparkles.image
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }

                Text(windowName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .modifier(WindowRenamingModifier(
            currentName: window.windowName,
            onRename: { newName in
                onRenameWindow(window, newName)
            }
        ))
    }

    private func openFileTabView(_ tab: OpenFileTab) -> some View {
        let isOnRight = isFileTabOnRight(tab.id)
        let isSelected = isOnRight
            ? tab.id == selectedRightFileTabId
            : tab.id == selectedFileTabId
        let splitSymbol: Symbols = !isSplit
            ? .rectangleSplit2x1
            : (isOnRight ? .arrowLeft : .arrowRight)
        let splitHelp: String = !isSplit
            ? "Open in split view"
            : (isOnRight ? "Move tab to left side" : "Move tab to right side")
        let splitAccessibility: String = !isSplit
            ? "Open file tab in split: \(tab.name)"
            : (isOnRight ? "Move file tab to left: \(tab.name)" : "Move file tab to right: \(tab.name)")

        return TabBarItem(
            isSelected: isSelected,
            onSelect: { onSelectFileTab(tab.id) },
            labelAccessibilityLabel: "File tab: \(tab.name)",
            onClose: { onCloseFileTab(tab.id) },
            closeAccessibilityLabel: "Close file tab: \(tab.name)",
            closeHelp: "Close tab",
            splitSymbol: splitSymbol,
            onSplitToggle: { onToggleFileTabSplit(tab.id) },
            splitHelp: splitHelp,
            splitAccessibilityLabel: splitAccessibility,
            showLeadingAccent: isSplit && isOnRight
        ) {
            HStack(spacing: 4) {
                Symbols.docPlaintextFill.image
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(tab.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .strikethrough(tab.isDeleted, color: .secondary)
            }
        }
        .fileContextMenu(
            fullPath: tab.path,
            directoryPath: tab.directoryPath,
            isDirectory: false,
            onOpenFileInNewTab: nil,
            onShowInFileExplorer: onShowInFileExplorer
        )
    }

    private func openBrowserTabView(_ tab: BrowserTab) -> some View {
        let isOnRight = isBrowserTabOnRight(tab.id)
        let isSelected = isOnRight
            ? tab.id == selectedRightBrowserTabId
            : tab.id == selectedBrowserTabId
        let splitSymbol: Symbols = !isSplit
            ? .rectangleSplit2x1
            : (isOnRight ? .arrowLeft : .arrowRight)
        let splitHelp: String = !isSplit
            ? "Open in split view"
            : (isOnRight ? "Move tab to left side" : "Move tab to right side")
        let splitAccessibility: String = !isSplit
            ? "Open browser tab in split: \(tab.tabLabel)"
            : (isOnRight ? "Move browser tab to left: \(tab.tabLabel)" : "Move browser tab to right: \(tab.tabLabel)")

        return TabBarItem(
            isSelected: isSelected,
            onSelect: { onSelectBrowserTab(tab.id) },
            labelAccessibilityLabel: "Browser tab: \(tab.tabLabel)",
            onClose: { onCloseBrowserTab(tab.id) },
            closeAccessibilityLabel: "Close browser tab: \(tab.tabLabel)",
            closeHelp: "Close tab",
            splitSymbol: splitSymbol,
            onSplitToggle: { onToggleBrowserTabSplit(tab.id) },
            splitHelp: splitHelp,
            splitAccessibilityLabel: splitAccessibility,
            showLeadingAccent: isSplit && isOnRight
        ) {
            HStack(spacing: 4) {
                Symbols.globe.image
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(tab.tabLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
        .help(tab.url.absoluteString)
    }

    @ViewBuilder
    private func openSuggestionBar(_ suggestion: MarkdownOpenSuggestion) -> some View {
        let label = suggestion.isPlan
            ? "Want to open the plan?"
            : "Want to open \(suggestion.fileName)?"
        HStack(spacing: 6) {
            Symbols.docPlaintextFill.image
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
            Button("Yes") {
                onAcceptOpenSuggestion(suggestion)
            }
            .controlSize(.mini)
            .accessibilityLabel("Open suggested file: Yes")
            Button("No") {
                onDismissOpenSuggestion()
            }
            .controlSize(.mini)
            .accessibilityLabel("Open suggested file: No")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
