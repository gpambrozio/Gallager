import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI
import UniformTypeIdentifiers

/// Horizontal tab bar showing windows in a tmux session.
/// Always visible, even for single-window sessions. The leading "+" button
/// pops up a menu to create either a new terminal window (issued through
/// `onNewWindow`) or a new browser tab (issued through `onNewBrowser`).
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
    /// Creates a new in-app browser tab (selected, address bar focused). Called
    /// from the "+" menu's "New Browser" option.
    let onNewBrowser: () -> Void
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
    /// Rearranges the tmux windows in the session to match the supplied id
    /// order. Invoked when the user drops a window tab into a new slot. The
    /// caller persists the new order via `tmux move-window`.
    let onReorderWindows: ([String]) -> Void
    /// Reorders the open file tabs. The caller mutates the `openFileTabs`
    /// array on `SessionFileTabsState` so the new layout survives session
    /// switches like every other tab-list mutation.
    let onReorderFileTabs: ([UUID]) -> Void
    /// Reorders the open browser tabs.
    let onReorderBrowserTabs: ([UUID]) -> Void

    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(MarkdownOpenSuggestionStore.self) private var openSuggestionStore

    /// Cached width of the split-mode tab strip. Measured via the background
    /// `onGeometryChange` so the HStack can drive intrinsic height instead of
    /// being pinned by a `GeometryReader` parent — keeps the split and
    /// non-split rows the same height under Dynamic Type and padding tweaks.
    @State private var splitRowWidth: CGFloat = 0

    @State private var hoveredWindowId: String?
    @State private var hoveredFileTabId: UUID?
    @State private var hoveredBrowserTabId: UUID?

    /// Currently-displayed drop indicator: nil while nothing is being dragged.
    /// The bar shows a vertical accent line to the left of the matching tab
    /// while a compatible drag is hovering, giving the user a clear preview
    /// of where the drop will land.
    @State private var dropIndicator: TabDragKind?

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
                newWindowButton
                tmuxWindowTabsRow
                fileBrowserButton
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
                newWindowButton
                tmuxWindowTabsRow
                fileBrowserButton
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
        Menu {
            Button {
                onNewWindow()
            } label: {
                Label("New Terminal", symbol: .terminal)
            }
            Button {
                onNewBrowser()
            } label: {
                Label("New Browser", symbol: .globe)
            }
        } label: {
            Symbols.plus.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("New terminal or browser in \(session.sessionName)")
        .accessibilityLabel("New Tab")
    }

    private var fileBrowserButton: some View {
        Button(action: onSelectFileBrowser) {
            Symbols.folderFill.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Browse files in \(session.sessionName)")
        .accessibilityLabel("Files")
        .accessibilityValue(isFileBrowserSelected ? "selected" : "")
        .tabStripItemStyle(isSelected: isFileBrowserSelected)
    }

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id && !isAnyFileViewActive
        let isHovered = hoveredWindowId == window.id
        let hasClaude = window.panes.contains { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        let showDropIndicator = dropIndicator == .window(window.id)

        return HStack(spacing: 0) {
            Button {
                onSelectWindow(window)
            } label: {
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
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(window.id) \(windowName)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close window: \(windowName)",
                helpText: "Close window",
                action: { onCloseWindow(window) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected)
        .overlay(alignment: .leading) {
            DropIndicator(visible: showDropIndicator)
        }
        .modifier(WindowRenamingModifier(
            currentName: window.windowName,
            onRename: { newName in
                onRenameWindow(window, newName)
            }
        ))
        .onHover { hovering in
            hoveredWindowId = hovering ? window.id : nil
        }
        .draggable(TabDragPayload.window(window.id)) {
            TabDragPreview(label: windowName, symbol: hasClaude ? .sparkles : .terminal)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: .window(window.id))
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? .window(window.id) : nil, for: .window)
        }
    }

    @ViewBuilder
    private func openFileTabView(_ tab: OpenFileTab) -> some View {
        let isOnRight = isFileTabOnRight(tab.id)
        let isSelected = isOnRight
            ? tab.id == selectedRightFileTabId
            : tab.id == selectedFileTabId
        let isHovered = hoveredFileTabId == tab.id
        let showDropIndicator = dropIndicator == .file(tab.id)

        HStack(spacing: 0) {
            Button {
                onSelectFileTab(tab.id)
            } label: {
                HStack(spacing: 4) {
                    Symbols.docPlaintextFill.image
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(tab.name)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .strikethrough(tab.isDeleted, color: .secondary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File tab: \(tab.name)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: isOnRight,
                tabKind: "file tab",
                tabName: tab.name,
                action: { onToggleFileTabSplit(tab.id) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close file tab: \(tab.name)",
                action: { onCloseFileTab(tab.id) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: isOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: showDropIndicator)
        }
        .fileContextMenu(
            fullPath: tab.path,
            directoryPath: tab.directoryPath,
            isDirectory: false,
            onOpenFileInNewTab: nil,
            onShowInFileExplorer: onShowInFileExplorer
        )
        .onHover { hovering in
            hoveredFileTabId = hovering ? tab.id : nil
        }
        .draggable(TabDragPayload.file(tab.id)) {
            TabDragPreview(label: tab.name, symbol: .docPlaintextFill)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: .file(tab.id))
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? .file(tab.id) : nil, for: .file)
        }
    }

    @ViewBuilder
    private func openBrowserTabView(_ tab: BrowserTab) -> some View {
        let isOnRight = isBrowserTabOnRight(tab.id)
        let isSelected = isOnRight
            ? tab.id == selectedRightBrowserTabId
            : tab.id == selectedBrowserTabId
        let isHovered = hoveredBrowserTabId == tab.id
        let showDropIndicator = dropIndicator == .browser(tab.id)

        HStack(spacing: 0) {
            Button {
                onSelectBrowserTab(tab.id)
            } label: {
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
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.url.absoluteString)
            .accessibilityLabel("Browser tab: \(tab.tabLabel)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: isOnRight,
                tabKind: "browser tab",
                tabName: tab.tabLabel,
                action: { onToggleBrowserTabSplit(tab.id) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close browser tab: \(tab.tabLabel)",
                action: { onCloseBrowserTab(tab.id) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: isOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: showDropIndicator)
        }
        .onHover { hovering in
            hoveredBrowserTabId = hovering ? tab.id : nil
        }
        .draggable(TabDragPayload.browser(tab.id)) {
            TabDragPreview(label: tab.tabLabel, symbol: .globe)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: .browser(tab.id))
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? .browser(tab.id) : nil, for: .browser)
        }
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

    // MARK: - Drag and Drop

    /// Updates the in-flight drop indicator, clearing any stale value when the
    /// pointer leaves the tab without dropping (the `isTargeted` callback runs
    /// in both directions). Each kind of tab tracks its own target so leaving
    /// a window tab while hovering a file tab still hides the window indicator.
    private func updateDropIndicator(target: TabDragKind?, for kind: TabDragKind.Discriminator) {
        if let target {
            dropIndicator = target
        } else if dropIndicator?.discriminator == kind {
            dropIndicator = nil
        }
    }

    /// Translates a drop event into a reorder callback. Only same-kind drags
    /// are honoured — dragging a file tab onto a window tab is a no-op so the
    /// tmux index space stays consistent. `payloads` always contains exactly
    /// one entry because `.draggable(_:)` produces a single value.
    private func handleDrop(payloads: [TabDragPayload], target: TabDragPayload) -> Bool {
        defer { dropIndicator = nil }
        guard let source = payloads.first, source != target else { return false }
        switch (source, target) {
        case let (.window(sourceId), .window(targetId)):
            let ids = session.windows.map(\.id)
            guard
                let sourceIndex = ids.firstIndex(of: sourceId),
                let targetIndex = ids.firstIndex(of: targetId),
                sourceIndex != targetIndex
            else { return false }
            var reordered = ids
            let moved = reordered.remove(at: sourceIndex)
            reordered.insert(moved, at: targetIndex)
            onReorderWindows(reordered)
            return true
        case let (.file(sourceId), .file(targetId)):
            return reorder(
                ids: openFileTabs.map(\.id),
                sourceId: sourceId,
                targetId: targetId,
                apply: onReorderFileTabs
            )
        case let (.browser(sourceId), .browser(targetId)):
            return reorder(
                ids: openBrowserTabs.map(\.id),
                sourceId: sourceId,
                targetId: targetId,
                apply: onReorderBrowserTabs
            )
        default:
            return false
        }
    }

    private func reorder<ID: Equatable>(
        ids: [ID],
        sourceId: ID,
        targetId: ID,
        apply: ([ID]) -> Void
    ) -> Bool {
        guard
            let sourceIndex = ids.firstIndex(of: sourceId),
            let targetIndex = ids.firstIndex(of: targetId),
            sourceIndex != targetIndex
        else { return false }
        var reordered = ids
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: targetIndex)
        apply(reordered)
        return true
    }
}

// MARK: - Drag Payload

/// Transferable payload used by the tab strip's drag-and-drop reorder. The
/// enum cases preserve the kind of tab being moved so the drop handler can
/// reject cross-kind drops (a terminal can't slot into the file-tab list).
private enum TabDragPayload: Codable, Hashable, Transferable {
    case window(String)
    case file(UUID)
    case browser(UUID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .gallagerTabDrag)
    }
}

/// In-flight drop highlight key. Mirrors `TabDragPayload` but lives in this
/// view's state because the dropped value is consumed by the closure that
/// fires after the user releases — the targeted state has to be tracked
/// separately while the drag is still moving.
private enum TabDragKind: Hashable {
    case window(String)
    case file(UUID)
    case browser(UUID)

    /// Coarse kind for clearing the indicator when the cursor leaves a tab
    /// of the same category. Without this, a hover from a window tab to a
    /// file tab would briefly clear the window indicator before the file's
    /// `isTargeted` callback fires, causing a single-frame flicker.
    enum Discriminator {
        case window
        case file
        case browser
    }

    var discriminator: Discriminator {
        switch self {
        case .window: return .window
        case .file: return .file
        case .browser: return .browser
        }
    }
}

/// Visual hint shown while a compatible drag is hovering a tab — a thin
/// vertical accent line on the leading edge that previews the drop slot.
private struct DropIndicator: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: visible)
            .allowsHitTesting(false)
    }
}

/// Compact preview view drawn under the cursor while a tab is being dragged.
/// Mirrors the on-strip styling so the user sees a recognisable "ghost" of
/// the tab they're moving.
private struct TabDragPreview: View {
    let label: String
    let symbol: Symbols

    var body: some View {
        HStack(spacing: 4) {
            symbol.image
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .cornerRadius(4)
        .shadow(radius: 2)
    }
}

extension UTType {
    /// Custom UTI used for tab-strip drags. The payload never crosses process
    /// boundaries — it only travels inside a single Gallager process — so we
    /// use `importedAs:` to avoid the runtime warning that `exportedAs:`
    /// produces when the identifier isn't declared in the app's Info.plist.
    static var gallagerTabDrag: UTType {
        UTType(importedAs: "engineering.dx.gallager.tab-drag")
    }
}
