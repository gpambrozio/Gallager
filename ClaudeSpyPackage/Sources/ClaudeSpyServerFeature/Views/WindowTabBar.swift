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
    let openFileTabs: [OpenFileTab]
    let selectedFileTabId: UUID?
    let openBrowserTabs: [BrowserTab]
    let selectedBrowserTabId: UUID?
    let onSelectWindow: (LocalTmuxWindow) -> Void
    let onCloseWindow: (LocalTmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (LocalTmuxWindow, String) -> Void
    let onSelectFileBrowser: () -> Void
    let onSelectFileTab: (UUID) -> Void
    let onCloseFileTab: (UUID) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void
    let onShowInFileExplorer: (String) -> Void
    let onAcceptOpenSuggestion: (MarkdownOpenSuggestion) -> Void

    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(MarkdownOpenSuggestionStore.self) private var openSuggestionStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.windows) { window in
                    windowTab(window)
                }

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
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
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
        TabBarItem(
            isSelected: tab.id == selectedFileTabId,
            onSelect: { onSelectFileTab(tab.id) },
            labelAccessibilityLabel: "File tab: \(tab.name)",
            onClose: { onCloseFileTab(tab.id) },
            closeAccessibilityLabel: "Close file tab: \(tab.name)",
            closeHelp: "Close tab"
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
        TabBarItem(
            isSelected: tab.id == selectedBrowserTabId,
            onSelect: { onSelectBrowserTab(tab.id) },
            labelAccessibilityLabel: "Browser tab: \(tab.tabLabel)",
            onClose: { onCloseBrowserTab(tab.id) },
            closeAccessibilityLabel: "Close browser tab: \(tab.tabLabel)",
            closeHelp: "Close tab"
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
                openSuggestionStore.dismiss(sessionName: session.sessionName)
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
