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

    /// Source-of-truth ordering for the tab strip — reconciles the persisted
    /// `sessionTabs.tabOrder` with the live windows / file tabs / browser tabs
    /// so newly-discovered entries are slotted in and removed entries drop
    /// out without rewriting the array elsewhere. The view body renders from
    /// this and the `.onChange` below writes it back into `sessionTabs` so the
    /// order survives session switches.
    private var effectiveTabOrder: [TabDragPayload] {
        let stored = sessionTabs?.tabOrder ?? []
        let knownWindowIds = Set(session.windows.map(\.id))
        let knownFileIds = Set(openFileTabs.map(\.id))
        let knownBrowserIds = Set(openBrowserTabs.map(\.id))

        // 1. Drop any stored entry whose underlying tab no longer exists.
        var order: [TabDragPayload] = []
        var sawFileExplorer = false
        for ref in stored {
            switch ref {
            case let .window(id):
                if knownWindowIds.contains(id) { order.append(ref) }
            case .fileExplorer:
                // Defensive dedupe — keep only the first .fileExplorer entry
                if !sawFileExplorer {
                    order.append(ref)
                    sawFileExplorer = true
                }
            case let .file(id):
                if knownFileIds.contains(id) { order.append(ref) }
            case let .browser(id):
                if knownBrowserIds.contains(id) { order.append(ref) }
            }
        }

        // 2. Track which entries are already in the order after the filter.
        var seenWindows: Set<String> = []
        var seenFiles: Set<UUID> = []
        var seenBrowsers: Set<UUID> = []
        for ref in order {
            switch ref {
            case let .window(id): seenWindows.insert(id)
            case let .file(id): seenFiles.insert(id)
            case let .browser(id): seenBrowsers.insert(id)
            case .fileExplorer: break
            }
        }

        // 3. Slot any new windows in just before the file-explorer button
        //    (so the default layout — windows, then folder, then files /
        //    browsers — is preserved on first run and for late-joining
        //    windows opened by tmux directly).
        for window in session.windows where !seenWindows.contains(window.id) {
            let insertAt = sawFileExplorer
                ? (order.firstIndex(of: .fileExplorer) ?? order.count)
                : order.count
            order.insert(.window(window.id), at: insertAt)
            seenWindows.insert(window.id)
        }

        // 4. Ensure exactly one file-explorer entry — slot it right after the
        //    last window if missing entirely.
        if !sawFileExplorer {
            let insertAt: Int
            if let lastWinIdx = order.lastIndex(where: { if case .window = $0 { true } else { false } }) {
                insertAt = lastWinIdx + 1
            } else {
                insertAt = 0
            }
            order.insert(.fileExplorer, at: insertAt)
        }

        // 5. Append any new file tabs and browser tabs at the end.
        for tab in openFileTabs where !seenFiles.contains(tab.id) {
            order.append(.file(tab.id))
        }
        for tab in openBrowserTabs where !seenBrowsers.contains(tab.id) {
            order.append(.browser(tab.id))
        }

        return order
    }

    /// Effective order restricted to entries visible on the left section in
    /// split mode (everything except the file/browser tabs that have been
    /// sent to the right pane).
    private var leftSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { ref in
            switch ref {
            case .window,
                 .fileExplorer:
                return true
            case let .file(id):
                return !isFileTabOnRight(id)
            case let .browser(id):
                return !isBrowserTabOnRight(id)
            }
        }
    }

    /// Effective order restricted to entries visible on the right section in
    /// split mode (file/browser tabs flipped to the right side).
    private var rightSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { ref in
            switch ref {
            case let .file(id):
                return isFileTabOnRight(id)
            case let .browser(id):
                return isBrowserTabOnRight(id)
            case .window,
                 .fileExplorer:
                return false
            }
        }
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
        // Persist the reconciled order so newly-appended windows / tabs and
        // pruned entries survive view rebuilds and session switches. The
        // computed value is idempotent (`reconcile(reconcile(x)) == reconcile(x)`)
        // so this can't loop.
        .onChange(of: effectiveTabOrder) { _, new in
            if sessionTabs?.tabOrder != new {
                sessionTabs?.tabOrder = new
            }
        }
        .onAppear {
            let computed = effectiveTabOrder
            if sessionTabs?.tabOrder != computed {
                sessionTabs?.tabOrder = computed
            }
        }
    }

    private var singleSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                newWindowButton
                ForEach(effectiveTabOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                if let suggestion = openSuggestionStore.suggestionsBySession[session.sessionName] {
                    openSuggestionBar(suggestion)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    /// Left section of the split-aware tab strip: the "+" button plus every
    /// entry in the unified order that hasn't been sent to the right pane.
    private var leftSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                newWindowButton
                ForEach(leftSectionOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                if let suggestion = openSuggestionStore.suggestionsBySession[session.sessionName] {
                    openSuggestionBar(suggestion)
                }
                Spacer()
            }
            .padding(.leading, 8)
        }
    }

    /// Right section of the split-aware tab strip: file / browser tabs that
    /// have been flipped to the right pane, in their unified-order position.
    private var rightSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(rightSectionOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                Spacer()
            }
            .padding(.trailing, 8)
        }
    }

    /// Dispatches a unified-order entry to the right view. Returns `EmptyView`
    /// for entries whose underlying data has gone away between reconciliation
    /// and this render pass (extremely rare; the next body cycle prunes it).
    @ViewBuilder
    private func tabView(for ref: TabDragPayload) -> some View {
        switch ref {
        case let .window(id):
            if let window = session.windows.first(where: { $0.id == id }) {
                windowTab(window)
            }
        case .fileExplorer:
            fileBrowserButton
        case let .file(id):
            if let tab = openFileTabs.first(where: { $0.id == id }) {
                openFileTabView(tab)
            }
        case let .browser(id):
            if let tab = openBrowserTabs.first(where: { $0.id == id }) {
                openBrowserTabView(tab)
            }
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
        let showDropIndicator = dropIndicator == .fileExplorer
        return Button(action: onSelectFileBrowser) {
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
        .overlay(alignment: .leading) {
            DropIndicator(visible: showDropIndicator)
        }
        .draggable(TabDragPayload.fileExplorer) {
            TabDragPreview(label: "Files", symbol: .folderFill)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: .fileExplorer)
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? .fileExplorer : nil, for: .fileExplorer)
        }
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

    /// Translates a drop event into a reorder of the unified `tabOrder`. Any
    /// kind can target any other kind (window onto browser, file-explorer
    /// onto window, etc.) — the entry simply moves to the target's position
    /// using Slack-style asymmetric insertion (right→left drops land at the
    /// target's slot; left→right drops land after it). When the window
    /// subsequence changes, the new order is also pushed to tmux via
    /// `move-window`; when the file or browser subsequences change, the
    /// corresponding `openFileTabs` / `openBrowserTabs` arrays are updated
    /// so other consumers see the same order.
    private func handleDrop(payloads: [TabDragPayload], target: TabDragPayload) -> Bool {
        defer { dropIndicator = nil }
        guard let source = payloads.first, source != target else { return false }

        var order = effectiveTabOrder
        guard
            let sourceIndex = order.firstIndex(of: source),
            let targetIndex = order.firstIndex(of: target),
            sourceIndex != targetIndex
        else { return false }

        let moved = order.remove(at: sourceIndex)
        // After removal: if source was before target, target's index shifted
        // down by one — inserting at the original `targetIndex` now places
        // source *after* the target. If source was after target, target's
        // index is unchanged — inserting at `targetIndex` places source
        // *before* it. Same asymmetric (Slack-like) semantics as the
        // existing scenario test (drag winC onto winA → winC,winA,winB).
        order.insert(moved, at: targetIndex)

        sessionTabs?.tabOrder = order

        // Sync the per-kind subsequences out to the rest of the app so
        // anything still iterating the old arrays (keyboard nav, tmux's
        // own window indices) sees the new order.
        syncSubsequences(from: order)

        return true
    }

    /// Derives the windows / files / browsers subsequences from the unified
    /// `tabOrder` and pushes each one out to the matching reorder callback
    /// when it differs from the live data. Idempotent — re-invoking with the
    /// same order is a no-op.
    private func syncSubsequences(from order: [TabDragPayload]) {
        let windowIds: [String] = order.compactMap { ref in
            if case let .window(id) = ref { return id } else { return nil }
        }
        let fileIds: [UUID] = order.compactMap { ref in
            if case let .file(id) = ref { return id } else { return nil }
        }
        let browserIds: [UUID] = order.compactMap { ref in
            if case let .browser(id) = ref { return id } else { return nil }
        }

        if windowIds != session.windows.map(\.id), !windowIds.isEmpty {
            onReorderWindows(windowIds)
        }
        if fileIds != openFileTabs.map(\.id) {
            onReorderFileTabs(fileIds)
        }
        if browserIds != openBrowserTabs.map(\.id) {
            onReorderBrowserTabs(browserIds)
        }
    }
}

// MARK: - Drag Payload

/// Transferable identifier for every entry in the unified tab strip — tmux
/// windows, the file-explorer button, open file tabs, and open browser tabs.
/// Doubles as the storage element for `SessionFileTabsState.tabOrder`, so the
/// session can persist a free-form ordering where the four kinds intermix in
/// any sequence the user has dragged them into.
enum TabDragPayload: Codable, Hashable, Transferable {
    case window(String)
    case fileExplorer
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
    case fileExplorer
    case file(UUID)
    case browser(UUID)

    /// Coarse kind for clearing the indicator when the cursor leaves a tab
    /// of one category and is about to enter another. Without this, an
    /// out-of-order `isTargeted=false` from a peer can wipe out the
    /// indicator that the new target just set.
    enum Discriminator {
        case window
        case fileExplorer
        case file
        case browser
    }

    var discriminator: Discriminator {
        switch self {
        case .window: return .window
        case .fileExplorer: return .fileExplorer
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
    /// Custom UTI used for tab-strip drags. The identifier is declared in
    /// `ClaudeSpyServer/Info.plist` under `UTExportedTypeDeclarations` so
    /// the system can resolve it without a runtime warning and
    /// `.dropDestination(for:)` accepts the payload reliably.
    static var gallagerTabDrag: UTType {
        UTType(exportedAs: "engineering.dx.gallager.tab-drag")
    }
}
