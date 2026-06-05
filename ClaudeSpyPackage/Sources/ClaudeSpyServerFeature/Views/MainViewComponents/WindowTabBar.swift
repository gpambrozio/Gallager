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
    /// True only when the Git tab is the active view (issue #258).
    let isGitBrowserSelected: Bool
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
    /// Activates the Git tab for the current window (issue #258).
    let onSelectGitBrowser: () -> Void
    let onSelectFileTab: (UUID) -> Void
    let onCloseFileTab: (UUID) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void
    /// Toggles which side of the split a tab strip entry lives on. If the
    /// entry is on the left, sends it to the right (opening the split). If
    /// on the right, sends it back to the left (and collapses the split if
    /// the right side becomes empty). The host dispatches on the payload's
    /// case to update the matching state.
    let onToggleSplit: (TabDragPayload) -> Void
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

    /// Currently-displayed drop indicator: nil while nothing is being dragged.
    /// The bar shows a vertical accent line to the left of the matching tab
    /// while a compatible drag is hovering, giving the user a clear preview
    /// of where the drop will land.
    @State private var dropIndicator: TabDragPayload?

    /// Which section's trailing drop zone is currently hovered, if any. Drawn
    /// separately from `dropIndicator` because the zone isn't a tab and has
    /// its own visual treatment.
    @State private var trailingDropTargetedSection: TabSection?

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

    private var selectedRight: TabDragPayload? {
        sessionTabs?.selectedRight
    }

    private var isSplit: Bool {
        sessionTabs?.isSplit ?? false
    }

    private var splitRatio: CGFloat {
        sessionTabs?.splitRatio ?? 0.5
    }

    /// True when the given payload currently lives in the right pane.
    private func isOnRight(_ payload: TabDragPayload) -> Bool {
        sessionTabs?.rightSide.contains(payload) ?? false
    }

    /// Source-of-truth ordering for the tab strip — reconciles the persisted
    /// `sessionTabs.tabOrder` with the live windows / file tabs / browser tabs
    /// so newly-discovered entries are slotted in and removed entries drop
    /// out without rewriting the array elsewhere. The view body renders from
    /// this and the `.onChange` below writes it back into `sessionTabs` so the
    /// order survives session switches.
    private var effectiveTabOrder: [TabDragPayload] {
        // Local sessions get both the file-explorer and Git singletons
        // (`includeGit` defaults to true), so the Git tab takes part in
        // drag-reordering and keyboard cycling alongside everything else.
        TabDragPayload.reconciledOrder(
            windowIds: session.windows.map(\.id),
            fileTabIds: openFileTabs.map(\.id),
            browserTabIds: openBrowserTabs.map(\.id),
            storedOrder: sessionTabs?.tabOrder ?? []
        )
    }

    /// Effective order restricted to entries visible on the left section in
    /// split mode (everything that hasn't been dragged into the right pane).
    private var leftSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { !isOnRight($0) }
    }

    /// Effective order restricted to entries visible on the right section in
    /// split mode (anything flipped to the right side — windows, the file
    /// explorer, file tabs, or browser tabs).
    private var rightSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { isOnRight($0) }
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
                trailingDropZone(for: .single)
            }
            .padding(.horizontal, 8)
            // Without this, the trailing drop zone's `maxWidth: .infinity`
            // also propagates an unbounded vertical preference upward and
            // the whole tab strip stretches to fill the parent VStack.
            // Pinning the row to its natural ideal height keeps the strip
            // the same compact size it was before drag-and-drop landed.
            .fixedSize(horizontal: false, vertical: true)
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
                trailingDropZone(for: .left)
            }
            .padding(.leading, 8)
            .fixedSize(horizontal: false, vertical: true)
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
                trailingDropZone(for: .right)
            }
            .padding(.trailing, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Trailing drop target that fills the rest of the tab strip so users can
    /// drop a tab "past the last tab" to move it to the end of the section.
    /// Acts as the layout `Spacer` would have — `maxWidth: .infinity` takes
    /// the remaining horizontal slack. The surrounding HStack's
    /// `fixedSize(vertical: true)` keeps the strip at its natural height so
    /// the Color.clear hit area collapses to the same row height as the tabs.
    ///
    /// `.accessibilityElement()` + `.accessibilityIdentifier(...)` expose the
    /// otherwise-decorative `Color.clear` to AX so E2E scenarios can drag onto
    /// it via `macDragElement`. The label is the same for every section
    /// because there's only one trailing zone visible at any time per HStack.
    private func trailingDropZone(for section: TabSection) -> some View {
        let isTargeted = trailingDropTargetedSection == section
        let identifier = switch section {
        case .single: "tab-trailing-drop-single"
        case .left: "tab-trailing-drop-left"
        case .right: "tab-trailing-drop-right"
        }
        return Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                DropIndicator(visible: isTargeted)
                    .padding(.leading, 4)
            }
            .dropDestination(for: TabDragPayload.self) { payloads, _ in
                handleEndDrop(payloads: payloads, section: section)
            } isTargeted: { hovering in
                trailingDropTargetedSection = hovering ? section : (
                    trailingDropTargetedSection == section ? nil : trailingDropTargetedSection
                )
            }
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("Tab strip trailing drop zone")
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
        case .git:
            gitBrowserButton
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
        NewTabMenuButton(
            helpText: "New terminal or browser in \(session.sessionName)",
            onNewTerminal: onNewWindow,
            onNewBrowser: onNewBrowser
        )
    }

    private var fileBrowserButton: some View {
        let tabIsOnRight = isOnRight(.fileExplorer)
        // The button is "selected" when it drives the visible content of
        // whichever pane it currently lives in — the left pane via the
        // existing `isFileBrowserSelected` flag, or the right pane when
        // `selectedRight == .fileExplorer`.
        let isSelected = tabIsOnRight
            ? selectedRight == .fileExplorer
            : isFileBrowserSelected
        return HStack(spacing: 0) {
            Button(action: onSelectFileBrowser) {
                Symbols.folderFill.image
                    .font(.caption)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Browse files in \(session.sessionName)")
            .accessibilityLabel("Files")
            .accessibilityValue(isSelected ? "selected" : "")

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "file explorer",
                tabName: "Files",
                action: { onToggleSplit(.fileExplorer) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: dropIndicator == .fileExplorer)
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

    /// The Git tab button (issue #258). A singleton like `fileBrowserButton`,
    /// living immediately to its right, with the same split-toggle and
    /// drag-and-drop affordances.
    private var gitBrowserButton: some View {
        let tabIsOnRight = isOnRight(.git)
        let isSelected = tabIsOnRight
            ? selectedRight == .git
            : isGitBrowserSelected
        return HStack(spacing: 0) {
            Button(action: onSelectGitBrowser) {
                Symbols.arrowTriangleBranch.image
                    .font(.caption)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Git changes for \(session.sessionName)")
            .accessibilityLabel("Git")
            .accessibilityValue(isSelected ? "selected" : "")

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "git",
                tabName: "Git",
                action: { onToggleSplit(.git) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: dropIndicator == .git)
        }
        .draggable(TabDragPayload.git) {
            TabDragPreview(label: "Git", symbol: .arrowTriangleBranch)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: .git)
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? .git : nil, for: .git)
        }
    }

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        // A window on the right pane is "selected" when it's the currently-
        // rendered right-side content. On the left (or in single mode) the
        // existing rule applies: the tab is the active terminal and no
        // file/browser/explorer is occupying the left pane.
        let payload = TabDragPayload.window(window.id)
        let tabIsOnRight = isOnRight(payload)
        let isSelected = tabIsOnRight
            ? selectedRight == payload
            : window.id == selectedWindow.id && !isAnyFileViewActive
        let isHovered = hoveredWindowId == window.id
        let hasClaude = window.panes.contains { windowManager.paneStates[$0.paneId]?.agentSession != nil }
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

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

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "terminal",
                tabName: windowName,
                action: { onToggleSplit(payload) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close window: \(windowName)",
                helpText: "Close window",
                action: { onCloseWindow(window) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: dropIndicator == payload)
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
        .draggable(payload) {
            TabDragPreview(label: windowName, symbol: hasClaude ? .sparkles : .terminal)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: payload)
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? payload : nil, for: .window)
        }
    }

    @ViewBuilder
    private func openFileTabView(_ tab: OpenFileTab) -> some View {
        let payload = TabDragPayload.file(tab.id)
        let tabIsOnRight = isOnRight(payload)
        let isSelected = tabIsOnRight
            ? selectedRight == payload
            : tab.id == selectedFileTabId
        let isHovered = hoveredFileTabId == tab.id

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
                isOnRight: tabIsOnRight,
                tabKind: "file tab",
                tabName: tab.name,
                action: { onToggleSplit(payload) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close file tab: \(tab.name)",
                action: { onCloseFileTab(tab.id) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: dropIndicator == payload)
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
        .draggable(payload) {
            TabDragPreview(label: tab.name, symbol: .docPlaintextFill)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: payload)
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? payload : nil, for: .file)
        }
    }

    private func openBrowserTabView(_ tab: BrowserTab) -> some View {
        let payload = TabDragPayload.browser(tab.id)
        let isOnRight = isOnRight(payload)
        let isSelected = isOnRight
            ? selectedRight == payload
            : tab.id == selectedBrowserTabId

        return BrowserTabStripItem(
            tab: tab,
            isSelected: isSelected,
            isOnRight: isOnRight,
            isSplit: isSplit,
            showsDropIndicator: dropIndicator == payload,
            onSelect: { onSelectBrowserTab(tab.id) },
            onClose: { onCloseBrowserTab(tab.id) },
            onToggleSplit: { onToggleSplit(payload) },
            onDrop: { payloads in handleDrop(payloads: payloads, target: payload) },
            onTargetedChanged: { isTargeted in
                updateDropIndicator(target: isTargeted ? payload : nil, for: .browser)
            }
        )
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
    private func updateDropIndicator(target: TabDragPayload?, for kind: TabDragPayload.Kind) {
        if let target {
            dropIndicator = target
        } else if dropIndicator?.kind == kind {
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

        // If the drop crosses the split, also flip the source file/browser
        // tab's side membership so it shows up in the pane the user dropped
        // it into. Windows and the file explorer don't have a side concept,
        // so this is a no-op for them.
        adjustSplitSideIfNeeded(source: source, to: sectionOf(target))

        // Sync the per-kind subsequences out to the rest of the app so
        // anything still iterating the old arrays (keyboard nav, tmux's
        // own window indices) sees the new order.
        syncSubsequences(from: order)

        return true
    }

    /// Drop handler for the trailing drop zone of a section. Moves the
    /// source to the end of that section so users can drag "past the last
    /// tab" instead of having to drop onto a specific neighbour. In split
    /// mode, "end of left section" means just before the first right-side
    /// entry so the right pane's tabs keep their visual position.
    private func handleEndDrop(payloads: [TabDragPayload], section: TabSection) -> Bool {
        defer { trailingDropTargetedSection = nil }
        guard let source = payloads.first else { return false }

        var order = effectiveTabOrder
        guard let sourceIndex = order.firstIndex(of: source) else { return false }

        let moved = order.remove(at: sourceIndex)

        let insertIndex: Int
        switch section {
        case .single,
             .right:
            insertIndex = order.count
        case .left:
            // Insert right after the last entry that belongs to the left
            // section. Falls through to the end if the left section is
            // empty (e.g. every tab was sent to the right).
            insertIndex = (order.lastIndex { !isOnRight($0) } ?? -1) + 1
        }

        order.insert(moved, at: min(insertIndex, order.count))
        sessionTabs?.tabOrder = order
        adjustSplitSideIfNeeded(source: source, to: section)
        syncSubsequences(from: order)
        return true
    }

    /// Which section a unified-order entry currently lives in. Every kind
    /// can land on either side now — windows render their terminal on the
    /// right pane, the file explorer renders the file tree on the right.
    private func sectionOf(_ ref: TabDragPayload) -> TabSection {
        if isOnRight(ref) { return .right }
        return isSplit ? .left : .single
    }

    /// Flips the source's split-side membership when it crossed sections
    /// during the drag. Reuses the host's `onToggleSplit` callback so all
    /// the side-effect bookkeeping (selection updates, right-pane
    /// reconciliation, fileBrowserActiveWindowIds) runs through the same
    /// code path as the split-toggle button on each tab.
    private func adjustSplitSideIfNeeded(source: TabDragPayload, to section: TabSection) {
        if isOnRight(source) != (section == .right) {
            onToggleSplit(source)
        }
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
    /// The Git tab (issue #258). A singleton like `.fileExplorer` — one per
    /// session, no associated id.
    case git
    case file(UUID)
    case browser(UUID)

    /// Coarse category, used to clear a stale drop indicator when the cursor
    /// leaves a tab of one kind and enters another. Without this, an
    /// out-of-order `isTargeted=false` from a peer would wipe out the
    /// indicator that the new target just set.
    enum Kind: Hashable {
        case window
        case fileExplorer
        case git
        case file
        case browser
    }

    var kind: Kind {
        switch self {
        case .window: .window
        case .fileExplorer: .fileExplorer
        case .git: .git
        case .file: .file
        case .browser: .browser
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .gallagerTabDrag)
    }

    /// Source-of-truth ordering for a session's tab strip. Reconciles the
    /// persisted free-form `storedOrder` (what the user dragged into place)
    /// with the live windows / file tabs / browser tabs so newly-discovered
    /// entries are slotted in and removed entries drop out, while every
    /// surviving entry keeps the user's interleaved position.
    ///
    /// Shared by the visible `WindowTabBar`, the visible `RemoteWindowTabBar`,
    /// and the Cmd-Shift-[ / Cmd-Shift-] keyboard navigation (both local and
    /// remote) so every surface walks the strip in the exact same order — see
    /// issue #566, where the keyboard path used a fixed kind-grouped order and
    /// ignored reordering.
    ///
    /// Remote sessions have no file explorer or file tabs; pass
    /// `includeFileExplorer: false` for them so the synthetic `.fileExplorer`
    /// entry is neither kept nor inserted and new windows slot in before the
    /// first browser tab instead of before the (absent) explorer.
    ///
    /// The Git tab (issue #258) is another local-only singleton: it sits
    /// immediately to the right of the file explorer in the default layout and,
    /// like the explorer, doesn't exist on remote sessions. Pass
    /// `includeGit: false` for remote so `.git` is neither kept nor inserted.
    static func reconciledOrder(
        windowIds: [String],
        fileTabIds: [UUID],
        browserTabIds: [UUID],
        storedOrder: [TabDragPayload],
        includeFileExplorer: Bool = true,
        includeGit: Bool = true
    ) -> [TabDragPayload] {
        let liveWindows = windowIds.map { TabDragPayload.window($0) }
        let liveFiles = fileTabIds.map { TabDragPayload.file($0) }
        let liveBrowsers = browserTabIds.map { TabDragPayload.browser($0) }
        var live: Set<TabDragPayload> = Set(liveWindows + liveFiles + liveBrowsers)
        if includeFileExplorer {
            live.insert(.fileExplorer)
        }
        if includeGit {
            live.insert(.git)
        }

        // Keep stored entries whose underlying data still exists, dedup'd.
        var order: [TabDragPayload] = []
        var seen: Set<TabDragPayload> = []
        for ref in storedOrder where live.contains(ref) && seen.insert(ref).inserted {
            order.append(ref)
        }

        // New windows slot in just before the file-explorer button (or, on
        // remote sessions with no explorer, the first browser tab) — preserves
        // the default layout (windows, folder, git, files/browsers) for first
        // runs and late-joining tmux windows.
        var insertAt: Int
        if includeFileExplorer {
            insertAt = order.firstIndex(of: .fileExplorer) ?? order.count
        } else {
            insertAt = order.firstIndex { if case .browser = $0 { true } else { false } } ?? order.count
        }
        for window in liveWindows where seen.insert(window).inserted {
            order.insert(window, at: insertAt)
            insertAt += 1
        }
        if includeFileExplorer, seen.insert(.fileExplorer).inserted {
            order.insert(.fileExplorer, at: insertAt)
        }
        // The Git button sits immediately to the right of the file-explorer
        // button (issue #258); for a new git entry not yet in the stored order,
        // slot it just after the explorer (or at the front of the singletons
        // when the explorer is absent).
        if includeGit, seen.insert(.git).inserted {
            let gitInsertAt = includeFileExplorer
                ? (order.firstIndex(of: .fileExplorer).map { $0 + 1 } ?? order.count)
                : insertAt
            order.insert(.git, at: min(gitInsertAt, order.count))
        }
        // New file/browser tabs append at the end.
        for tab in liveFiles + liveBrowsers where seen.insert(tab).inserted {
            order.append(tab)
        }
        return order
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
