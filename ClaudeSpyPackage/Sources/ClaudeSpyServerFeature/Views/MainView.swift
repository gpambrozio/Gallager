import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
import GitWorkbench
import SwiftUI

/// The main application view showing available tmux windows in a sidebar layout
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(PairingManager.self) private var pairingManager
    @Environment(MarkdownOpenSuggestionStore.self) private var markdownOpenSuggestionStore
    @Environment(\.e2eeService) private var e2eeService: E2EEService?
    @Environment(\.openSettings) private var openSettings

    public init() { }

    /// Selection state: either a local window or a remote session (hostId + sessionName)
    @State private var selectedWindow: LocalTmuxWindow?
    @State private var selectedRemoteSession: RemoteSessionSelection?
    @State private var selectedRemoteWindowId: String?
    @State private var attachError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projects: [AgentProject] = []
    @State private var isLoadingProjects = false
    @State private var creatingSelection: NewSessionCreatingState?
    @State private var detailPaneSize: CGSize = .zero
    @State private var closeConfirmation: CloseConfirmation?

    @State private var showingDisconnectConfirmation = false

    /// Tracks active session pane IDs for detecting section changes
    @State private var trackedActiveSessionPaneIds: Set<String> = []
    /// ID to scroll to in the sidebar when a window moves between sections
    @State private var scrollToWindowId: String?

    /// Per-session auto-resize state (keyed by pane target for local, "remote-hostId-paneId" for remote)
    @State private var autoResizeEnabled: Set<String> = []
    /// Per-session auto-resize opt-out when global setting is on
    @State private var autoResizeDisabled: Set<String> = []
    /// Last dimensions sent via auto-resize, keyed by pane target (local pane
    /// id or `remote.resizeKey(paneId:)`). Used to skip redundant resize calls
    /// during window drag — the cell-size rounding eliminates most spurious
    /// updates, and the per-pane keying means a left+right split with two
    /// different rendered widths is cached as two independent entries.
    @State private var lastAutoResizeDimensions: [String: (columns: Int, rows: Int)] = [:]
    /// Debounce task for auto-resize (cancelled on each new geometry change)
    @State private var autoResizeTask: Task<Void, Never>?

    /// Window IDs that have the file browser tab active (persists across tab/session switches)
    @State private var fileBrowserActiveWindowIds: Set<String> = []
    /// Cached file browser state per session name (tree, selection, sidebar width).
    /// Keyed by session, not window, so the explorer's selection/expansion/scroll
    /// state survives switching between windows in the same session — `loadTree`
    /// already invalidates and rebuilds the tree when `directoryPath` changes,
    /// and stale selections are cleared in that path.
    @State private var fileBrowserStates: [String: FileBrowserState] = [:]
    /// Cached open-file-tab strip per session (keyed by `sessionName`).
    @State private var sessionFileTabsStates: [String: SessionFileTabsState] = [:]
    /// Cached browser-tab strip per remote session. Mirrors `sessionFileTabsStates`
    /// for remote sessions — but only the browser-tab fields are used today since
    /// remote file browsing isn't implemented. Keeping the same value type avoids
    /// a parallel data structure for what is, semantically, the same state. The
    /// key is a typed struct so the hostId / sessionName pair can't be miss-parsed
    /// (tmux allows colons in session names, which would break a string key).
    @State private var remoteSessionTabsStates: [RemoteSessionTabsKey: SessionFileTabsState] = [:]

    /// Window IDs that have the Git tab active (issue #258). Mirrors
    /// `fileBrowserActiveWindowIds`; the two are mutually exclusive per window
    /// since activating one clears the other.
    @State private var gitActiveWindowIds: Set<String> = []
    /// Cached GitWorkbench store per session name, paired with the repository
    /// path it was built for so a working-directory change rebuilds it.
    /// Retaining the store keeps the git UI state (selected workspace view,
    /// file, diff) across tab/session switches, like `fileBrowserStates`.
    @State private var gitWorkbenchStores: [String: GitStoreEntry] = [:]

    /// Vends the GitWorkbench provider (live `git` CLI, or a stable mock under
    /// `--e2e-test`). Read here to build per-session stores on demand.
    @Dependency(GitWorkbenchProviderClient.self) private var gitProviderClient

    /// File path for which the "Open in Editor" picker is currently shown
    /// (triggered by Cmd+E on a focused file tab).
    @State private var editorPickerPath: String?

    /// In-flight terminal-link confirmation, shown when
    /// `settings.browserLinkBehavior == .ask` and the user clicks a web URL.
    @State private var pendingBrowserURLPrompt: PendingBrowserURLPrompt?

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { newSize in
                    detailPaneSize = newSize
                    handleAutoResize()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(selectedSessionTitle ?? "Gallager")
        .toolbar {
            toolbarContent
        }
        .task {
            // Initial load only - periodic refresh is handled by MirrorWindowManager
            await refreshPanes()
            await loadProjects()
            trackedActiveSessionPaneIds = windowManager.activeSessionPaneIds
            // Consume any pending menu bar selection that was set before this view appeared
            applyPendingMenuBarSelection()
        }
        .task {
            // Silently rescan every 60s so new projects appear without restarting.
            while true {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await loadProjects(showLoadingIndicator: false)
            }
        }
        .modifier(AlertsModifier(
            attachError: $attachError,
            closeConfirmation: $closeConfirmation,
            onPerformClose: { performClose($0) }
        ))
        .sheet(item: $pendingBrowserURLPrompt) { prompt in
            BrowserURLConfirmationView(
                url: prompt.url,
                onResolve: { choice, rememberScope in
                    pendingBrowserURLPrompt = nil
                    resolveBrowserURLPrompt(prompt, choice: choice, rememberScope: rememberScope)
                },
                onCancel: {
                    pendingBrowserURLPrompt = nil
                }
            )
        }
        .onChange(of: tmuxService.panes) { _, newPanes in
            // Ensure pane states exist for all known panes so the detail view
            // can render immediately when a window is selected (without waiting
            // for the periodic validation timer).
            windowManager.updatePaneStates(from: newPanes)

            // Clean up explorer-active flags for windows that no longer exist
            let currentWindowIds = Set(tmuxService.windows.map(\.id))
            for key in fileBrowserActiveWindowIds where !currentWindowIds.contains(key) {
                fileBrowserActiveWindowIds.remove(key)
            }
            for key in gitActiveWindowIds where !currentWindowIds.contains(key) {
                gitActiveWindowIds.remove(key)
            }

            // Prune any right-side window entries that point at terminals
            // that tmux has just removed (user typed `exit`, hit the X
            // button, killed the window, etc.). Without this, isSplit stays
            // true and the right pane shows "No Tab Selected" forever even
            // though there's no real tab on the right anymore.
            for (sessionName, tabs) in sessionFileTabsStates {
                let stale = tabs.rightSide.filter {
                    if case let .window(id) = $0 { !currentWindowIds.contains(id) } else { false }
                }
                if !stale.isEmpty {
                    tabs.rightSide.subtract(stale)
                    if let sel = tabs.selectedRight, stale.contains(sel) {
                        tabs.selectedRight = nil
                    }
                    reconcileRightPaneSelection(sessionName: sessionName)
                }
            }

            // Clean up session-scoped state for sessions that no longer exist
            let currentSessionNames = Set(tmuxService.sessions.map(\.sessionName))
            for key in fileBrowserStates.keys where !currentSessionNames.contains(key) {
                fileBrowserStates.removeValue(forKey: key)
            }
            for key in sessionFileTabsStates.keys where !currentSessionNames.contains(key) {
                sessionFileTabsStates.removeValue(forKey: key)
            }
            for key in gitWorkbenchStores.keys where !currentSessionNames.contains(key) {
                gitWorkbenchStores.removeValue(forKey: key)
            }

            // Clear pending markdown-open suggestions for removed sessions.
            for sessionName in markdownOpenSuggestionStore.suggestionsBySession.keys
                where !currentSessionNames.contains(sessionName) {
                markdownOpenSuggestionStore.sessionRemoved(sessionName: sessionName)
            }

            guard let selected = selectedWindow else { return }
            let currentWindows = tmuxService.windows
            // Windows parked on the right pane shouldn't be picked as the
            // left's selection — otherwise the same terminal would render
            // twice once tmux's active window points at a right-side tab.
            let rightSideIds = sessionFileTabsStates[selected.sessionName]?.rightSideWindowIds ?? []
            if let updated = currentWindows.first(where: { $0.id == selected.id }) {
                // Follow the tmux-active window if it changed to a different window
                // (e.g., a remote viewer switched tabs via select-window),
                // but only across left-side windows.
                let leftSessionWindows = currentWindows.filter {
                    $0.sessionName == selected.sessionName && !rightSideIds.contains($0.id)
                }
                if
                    !updated.isWindowActive,
                    let activeWindow = leftSessionWindows.first(where: \.isWindowActive) {
                    selectedWindow = activeWindow
                } else if updated != selected {
                    // Keep selection in sync with refreshed window data
                    selectedWindow = updated
                }
            } else {
                // Selected window was removed — prefer the tmux-active window
                // in the same session that isn't already on the right pane.
                let leftSessionWindows = currentWindows.filter {
                    $0.sessionName == selected.sessionName && !rightSideIds.contains($0.id)
                }
                let fallback = leftSessionWindows.first(where: \.isWindowActive) ?? leftSessionWindows.first
                selectedWindow = fallback
            }
        }
        .onChange(of: selectedWindow) { handleSelectionChanged() }
        .onChange(of: selectedRemoteSession) { handleSelectionChanged() }
        .onChange(of: selectedRemoteWindowId) { handleSelectionChanged() }
        .onChange(of: selectedRemoteWindow?.id) {
            // Keep selectedRemoteWindowId in sync when the computed property
            // resolves to a different window (e.g., selected window removed,
            // or tmux-active window changed by the host).
            if let resolvedId = selectedRemoteWindow?.id, resolvedId != selectedRemoteWindowId {
                selectedRemoteWindowId = resolvedId
            }
        }
        .modifier(RemoteSplitCleanupModifier(
            paneCount: coordinator.remoteSessionStore?.paneStates.count ?? 0,
            onPrune: pruneStaleRemoteRightSideEntries
        ))
        .onChange(of: settings.pairedHosts.map(\.id)) { _, currentHostIds in
            // Drop browser-tab state for hosts that are no longer paired so
            // the live `WKWebView` instances in `browserStates` aren't held
            // forever. Session-level cleanup (sessions deleted on a still-
            // paired host) is left to host-level cleanup; in practice an
            // empty session goes away when the user reconnects without it.
            let currentHostIdsSet = Set(currentHostIds)
            for key in remoteSessionTabsStates.keys where !currentHostIdsSet.contains(key.hostId) {
                remoteSessionTabsStates.removeValue(forKey: key)
            }
        }
        .modifier(AutoResizeObserversModifier(
            alwaysAutoResize: settings.alwaysAutoResize,
            splitSignal: currentSessionSplitSignal,
            onPreferenceChanged: {
                // Global toggle flipped — drop per-session opt-outs and
                // cached dimensions so the new state is re-evaluated from scratch.
                autoResizeDisabled.removeAll()
                lastAutoResizeDimensions.removeAll()
                handleAutoResize()
            },
            onSplitChanged: {
                // Splitting/collapsing the detail area or dragging the divider
                // changes the rendered width of any terminal in the split. The
                // `onGeometryChange` on the detail pane doesn't fire for these
                // because the overall pane size is unchanged — re-run the
                // auto-resize so tmux knows about the new pane width.
                handleAutoResize()
            }
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            markSelectedSessionsHandledIfActive()
        }
        .focusedSceneValue(\.closeCurrentTabAction, handleCloseCurrentTab)
        .modifier(MenuCommandsModifier(
            onOpenContentSearch: { handleOpenContentSearch() },
            onSelectPreviousTab: { selectAdjacentTab(direction: -1) },
            onSelectNextTab: { selectAdjacentTab(direction: 1) }
        ))
        .modifier(EditorPickerDialogModifier(
            editorPickerPath: $editorPickerPath,
            onCmdE: { handleOpenCurrentTabInEditor() }
        ))
        .onChange(of: windowManager.pendingSessionCount) {
            // When an event arrives on the already-selected session, no selection
            // change fires. Watch the pending count so we can auto-clear attention
            // for sessions the user is already viewing.
            markSelectedSessionsHandledIfActive()
        }
        .onChange(of: coordinator.pendingMenuBarSelection) {
            applyPendingMenuBarSelection()
        }
        .onDisappear {
            autoResizeTask?.cancel()
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        Group {
            if tmuxService.isRefreshing && tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
                loadingView
            } else if let error = tmuxService.lastError, tmuxService.panes.isEmpty, !settings.hasRemoteHosts {
                errorView(error)
            } else if tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
                emptyView
            } else {
                windowList
            }
        }
        .frame(minWidth: 200)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading panes...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView(
            "Error Loading Panes",
            symbol: .exclamationmarkTriangle,
            description: message
        )
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Panes Available",
            symbol: .terminal
        )
    }

    private var windowList: some View {
        let sortedSessions = settings.sidebarSortMode.sorted(tmuxService.sessions) { session in
            localSessionSortData(session)
        }

        return ScrollViewReader { proxy in
            List {
                localSessionsSection(sessions: sortedSessions)
                remoteHostSections
            }
            .listStyle(.sidebar)
            .refreshable {
                await refreshPanes()
                await coordinator.viewerConnectionManager?.requestAllSessionStates()
            }
            .onChange(of: scrollToWindowId) { _, windowId in
                guard let windowId else { return }
                withAnimation {
                    proxy.scrollTo(windowId, anchor: .center)
                }
                Task { @MainActor in scrollToWindowId = nil }
            }
            .onChange(of: windowManager.activeSessionPaneIds) {
                handleActiveSessionsChanged()
            }
        }
    }

    private func localSessionsSection(sessions: [LocalTmuxSession]) -> some View {
        Section {
            if sessions.isEmpty && settings.hasRemoteHosts {
                Text("No local sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(sessions) { session in
                    sessionButton(session: session)
                }
            }
        } header: {
            SectionHeader(
                title: "Local",
                symbol: .house,
                newSessionButtonIdentifier: "new-session-local"
            ) {
                localNewSessionPopover
            }
        }
    }

    /// Primary label for the currently selected session, used as the navigation title.
    /// Returns nil when nothing is selected so the default fallback can be shown.
    private var selectedSessionTitle: String? {
        if let remote = selectedRemoteSession {
            return remoteSessionPrimaryLabel(hostId: remote.hostId, sessionName: remote.sessionName)
        }
        if
            let window = selectedWindow,
            let session = tmuxService.sessions.first(where: { $0.windows.contains { $0.id == window.id } }) {
            return localSessionSortData(session).primaryLabel
        }
        return nil
    }

    /// Computes the primary sidebar label for a remote session using the same logic as `RemoteHostSidebarSection.sortedSessions`.
    private func remoteSessionPrimaryLabel(hostId: String, sessionName: String) -> String? {
        guard let sessionStore = coordinator.remoteSessionStore else { return nil }
        guard let session = sessionStore.sessions(for: hostId).first(where: { $0.sessionName == sessionName }) else {
            return nil
        }
        return SessionSortData.forRemoteSession(
            session,
            sidebarFields: settings.sidebarFields,
            sidebarTerminalFields: settings.sidebarTerminalFields,
            homeDirectory: sessionStore.homeDirectoryByHost[hostId]
        ).primaryLabel
    }

    /// Scans the full session (all windows) to match the session-level sidebar row — not the selected window.
    private func localSessionSortData(_ session: LocalTmuxSession) -> SessionSortData {
        let claudeSession: AgentSession? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.agentSession }
            .first

        let primaryPane = session.activeWindow?.activePane
        let paneState = primaryPane.flatMap { windowManager.paneStates[$0.paneId] }

        // Scan all windows for terminal title (matches SessionSidebarRow.terminalTitle)
        let terminalTitle: String? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.terminalTitle }
            .first { !$0.isEmpty }

        let fields = claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields

        let primaryLabel = SessionSortData.primaryLabel(
            fields: fields,
            customDescription: paneState?.customDescription,
            projectName: claudeSession?.displayName,
            sessionName: session.sessionName,
            terminalTitle: terminalTitle,
            command: primaryPane?.command,
            currentPath: primaryPane?.currentPath,
            gitBranch: paneState?.gitBranch
        )

        // Recency = the latest plugin-status arrival across the session's panes.
        // The per-event timestamp buffer was dropped (spec §16); status-arrival
        // order is the agent-blind stand-in and matches event-receipt order.
        let latestActivity = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.lastActivity(for: $0.paneId) }
            .max()

        return SessionSortData(
            sessionName: session.sessionName,
            primaryLabel: primaryLabel,
            hasClaude: claudeSession != nil,
            statusPriority: SessionSortData.statusPriority(for: claudeSession),
            statusPriorityIdleFirst: SessionSortData.statusPriorityIdleFirst(for: claudeSession),
            latestEventTimestamp: latestActivity
        )
    }

    @ViewBuilder
    private var remoteHostSections: some View {
        if settings.hasRemoteHosts, let sessionStore = coordinator.remoteSessionStore {
            ForEach(settings.pairedHosts) { host in
                RemoteHostSidebarSection(
                    host: host,
                    connection: coordinator.viewerConnectionManager?.connection(for: host.id),
                    sessionStore: sessionStore,
                    creatingSelection: creatingSelection,
                    selectedRemoteSession: $selectedRemoteSession,
                    onSelect: { selection in
                        selectedRemoteSession = selection
                        selectedRemoteWindowId = nil
                        selectedWindow = nil
                    },
                    onCreate: { project in
                        Task {
                            await createRemoteSession(on: host, inProject: project)
                        }
                    },
                    onSetDescription: { sessionName, description in
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionDescription(sessionName: sessionName, description: description)
                            _ = await manager.sendCommand(command, paneId: "", hostId: host.id)
                        }
                    },
                    onSetColor: { sessionName, color in
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionColor(sessionName: sessionName, color: color)
                            _ = await manager.sendCommand(command, paneId: "", hostId: host.id)
                        }
                    },
                    onSetEmoji: { sessionName, emoji in
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetSessionEmoji(sessionName: sessionName, emoji: emoji)
                            _ = await manager.sendCommand(command, paneId: "", hostId: host.id)
                        }
                    },
                    onToggleYolo: { paneId, enabled in
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            _ = await manager.sendCommand(
                                SetYoloMode(enabled: enabled),
                                paneId: paneId,
                                hostId: host.id
                            )
                        }
                    },
                    onCloseSession: { sessionName in
                        requestCloseRemoteSession(sessionName, hostId: host.id)
                    }
                )
            }
        }
    }

    private func sessionButton(session: LocalTmuxSession, help: String? = nil) -> some View {
        let activeWindow = session.activeWindow
        let description = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customDescription }
        let color = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customColor }
        let emoji = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customEmoji }
        let claudePane = session.windows.flatMap(\.panes).first { windowManager.paneStates[$0.paneId]?.agentSession != nil }
        let activePane = activeWindow?.activePane
        let isSessionAttached = tmuxService.attachedSessionNames.contains(session.sessionName)
        let isSelected = selectedWindow.map { selected in session.windows.contains(where: { $0.id == selected.id }) } ?? false
        // Compute progress here (and not just inside the row) so we can expose
        // a sibling AX element OUTSIDE the Button label below — when the row
        // shows a "Working" indicator, SwiftUI flips the merged button to
        // `AXBusyIndicator` and absorbs the inner `TerminalProgressBar`'s
        // separate accessibility element, dropping its `accessibilityValue`.
        // The outer mirror keeps `valueContains("60%")` queries working.
        let sessionProgress: TerminalProgressState? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.progress }
            .first

        return Button {
            // Select the session's active window for the left pane — but
            // skip any window the user has parked on the right side, so the
            // left and right panes don't end up showing the same terminal
            // after a session round-trip.
            let rightSideIds = sessionFileTabsStates[session.sessionName]?.rightSideWindowIds ?? []
            let leftCandidates = session.windows.filter { !rightSideIds.contains($0.id) }
            let pick = leftCandidates.first(where: \.isWindowActive)
                ?? leftCandidates.first
                ?? activeWindow
            if let pick {
                selectedWindow = pick
            }
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
        } label: {
            SessionSidebarRow(session: session)
        }
        .id(session.sessionName)
        .buttonStyle(.plain)
        .help(help ?? "")
        .listRowBackground(isSelected && selectedRemoteSession == nil ? Color.accentColor.opacity(0.2) : nil)
        .accessibilityChildren {
            // When the row contains a "Working" ProgressView, SwiftUI merges
            // the Button's children into one `AXBusyIndicator` element and
            // its numeric value clobbers the inner `TerminalProgressBar`'s
            // string `accessibilityValue`. The proxy injects an AX-only child
            // that sits outside that merge so e2e queries (and VoiceOver) can
            // read `Terminal progress` + `60%` regardless of working status.
            SessionProgressAccessibilityProxy(progress: sessionProgress)
        }
        .modifier(DescriptionEditingModifier(
            sessionName: session.sessionName,
            currentDescription: description,
            currentEmoji: emoji,
            onSetDescription: { sessionName, description in
                windowManager.setSessionDescription(description, for: sessionName)
            },
            onSetEmoji: { sessionName, emoji in
                windowManager.setSessionEmoji(emoji, for: sessionName)
            },
            additionalMenu: {
                ColorContextMenuButtons(currentColor: color) { newColor in
                    windowManager.setSessionColor(newColor, for: session.sessionName)
                }

                Divider()

                if let claudePane {
                    Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                        Label("Yolo Mode", symbol: .bolt)
                    }

                    Divider()
                }

                if let activePane {
                    Button {
                        attachToTerminal(activePane)
                    } label: {
                        Label("Open in Terminal", symbol: .macwindow)
                    }

                    Divider()

                    if !isAutoResizeActive(for: activePane.paneId) {
                        Button {
                            Task {
                                await performResize(
                                    localTarget: activePane.target,
                                    localPaneId: activePane.paneId,
                                    widthOverride: activeWindow.flatMap(effectiveTerminalWidth(for:))
                                )
                            }
                        } label: {
                            Label("Resize to Fit", symbol: .arrowUpLeftAndArrowDownRight)
                        }
                        .disabled(isSessionAttached)
                    }

                    Toggle(isOn: Binding(
                        get: { isAutoResizeActive(for: activePane.paneId) },
                        set: { enabled in
                            if enabled {
                                autoResizeDisabled.remove(activePane.paneId)
                                autoResizeEnabled.insert(activePane.paneId)
                                Task {
                                    await performResize(
                                        localTarget: activePane.target,
                                        localPaneId: activePane.paneId,
                                        widthOverride: activeWindow.flatMap(effectiveTerminalWidth(for:))
                                    )
                                }
                            } else {
                                autoResizeDisabled.insert(activePane.paneId)
                                autoResizeEnabled.remove(activePane.paneId)
                            }
                        }
                    )) {
                        Label("Auto-resize", symbol: .arrowDownRightAndArrowUpLeft)
                    }
                    .disabled(isSessionAttached)
                }

                Divider()

                Button(role: .destructive) {
                    requestCloseSession(session.sessionName)
                } label: {
                    Label("Close Session", symbol: .rectangleStackBadgeMinus)
                }

                Divider()
            }
        ))
    }

    // MARK: - Detail View

    /// The currently selected remote window, resolved from session store.
    /// Excludes any window pinned to the right pane (`SessionFileTabsState.rightSide`)
    /// from the "follow tmux-active" override — otherwise toggling split on
    /// the active window would leave both panes rendering it.
    private var selectedRemoteWindow: TmuxWindow? {
        guard
            let remote = selectedRemoteSession,
            let sessionStore = coordinator.remoteSessionStore else { return nil }
        let windows = sessionStore.windows(for: remote.hostId)
            .filter { $0.sessionName == remote.sessionName }
            .sorted { $0.windowIndex < $1.windowIndex }
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let rightWindowIds = remoteSessionTabsStates[key]?.rightSideWindowIds ?? []
        let leftWindows = windows.filter { !rightWindowIds.contains($0.id) }
        if
            let windowId = selectedRemoteWindowId,
            !rightWindowIds.contains(windowId),
            let window = windows.first(where: { $0.id == windowId }) {
            // Follow the tmux-active window if it changed (e.g., host
            // switched tabs on its end) — but only among left-side
            // windows, so the left pane never accidentally jumps to a
            // window that's already shown in the right pane.
            if
                !window.isWindowActive,
                let activeLeft = leftWindows.first(where: \.isWindowActive) {
                return activeLeft
            }
            return window
        }
        return leftWindows.first(where: \.isWindowActive)
            ?? leftWindows.first
            ?? windows.first(where: \.isWindowActive)
            ?? windows.first
    }

    /// All windows in the selected remote session
    private var selectedRemoteSessionWindows: [TmuxWindow] {
        guard
            let remote = selectedRemoteSession,
            let sessionStore = coordinator.remoteSessionStore else { return [] }
        return sessionStore.windows(for: remote.hostId)
            .filter { $0.sessionName == remote.sessionName }
            .sorted { $0.windowIndex < $1.windowIndex }
    }

    @ViewBuilder
    private var detailContent: some View {
        if
            let remote = selectedRemoteSession,
            let connection = coordinator.viewerConnectionManager?.connection(for: remote.hostId),
            let window = selectedRemoteWindow {
            let windows = selectedRemoteSessionWindows
            let tabsKey = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            let remoteTabs = remoteSessionTabsStates[tabsKey]
            let selectedBrowserTab: BrowserTab? = {
                guard
                    let remoteTabs,
                    let selectedId = remoteTabs.selectedBrowserTabId
                else { return nil }
                return remoteTabs.openBrowserTabs.first(where: { $0.id == selectedId })
            }()
            VStack(spacing: 0) {
                RemoteWindowTabBar(
                    windows: windows,
                    selectedWindow: window,
                    isHostConnected: connection.isHostConnected,
                    openBrowserTabs: remoteTabs?.openBrowserTabs ?? [],
                    selectedBrowserTabId: remoteTabs?.selectedBrowserTabId,
                    sessionTabs: remoteTabs,
                    onSelectWindow: { newWindow in
                        let tabs = remoteSessionTabsStates[tabsKey]
                        let payload = TabDragPayload.window(newWindow.id)
                        if tabs?.rightSide.contains(payload) == true {
                            // Right-side window: route the click to the
                            // right pane's selection so the left pane
                            // keeps showing whatever it had.
                            tabs?.selectedRight = payload
                            return
                        }
                        selectedRemoteWindowId = newWindow.id
                        // Switching back to a tmux window deselects any active
                        // browser tab so the terminal pane is rendered again
                        // even when a browser tab was previously focused.
                        tabs?.selectedBrowserTabId = nil
                        Task {
                            _ = await connection.relayClient.sendCommand(
                                SelectTmuxWindow(),
                                paneId: newWindow.id
                            )
                        }
                    },
                    onCloseWindow: { windowToClose in
                        requestCloseRemoteWindow(windowToClose, hostId: remote.hostId)
                    },
                    onNewWindow: {
                        Task {
                            let currentPath = window.activePane?.currentPath
                            let spec = CreateTmuxWindow(sessionName: remote.sessionName, workingDirectory: currentPath)
                            let result = await connection.relayClient.sendCommand(spec, paneId: "")
                            if case let .success(response) = result, let paneId = response.paneId {
                                await connection.relayClient.requestSessionState()
                                // Poll for the new window to appear in the session store,
                                // with a timeout to avoid waiting forever.
                                for _ in 0..<20 {
                                    do {
                                        try await Task.sleep(for: .milliseconds(100))
                                    } catch {
                                        return
                                    }
                                    let refreshedWindows = selectedRemoteSessionWindows
                                    if let newWindow = refreshedWindows.first(where: { $0.panes.contains(where: { $0.paneId == paneId }) }) {
                                        selectedRemoteWindowId = newWindow.id
                                        return
                                    }
                                }
                            }
                        }
                    },
                    onNewBrowser: {
                        openEmptyRemoteBrowserTab(hostId: remote.hostId, sessionName: remote.sessionName)
                    },
                    onRenameWindow: { windowToRename, newName in
                        Task {
                            _ = await connection.relayClient.sendCommand(
                                SetWindowName(windowId: windowToRename.id, name: newName),
                                paneId: ""
                            )
                        }
                    },
                    onSelectBrowserTab: { tabId in
                        selectRemoteBrowserTab(
                            tabId,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName
                        )
                    },
                    onCloseBrowserTab: { tabId in
                        closeRemoteBrowserTab(
                            tabId,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName
                        )
                    },
                    onToggleSplit: { payload in
                        toggleRemoteSplit(payload, hostId: remote.hostId, sessionName: remote.sessionName)
                    },
                    onReorderWindows: { newOrder in
                        reorderRemoteWindows(
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            to: newOrder,
                            connection: connection
                        )
                    },
                    onReorderBrowserTabs: { newOrder in
                        reorderRemoteBrowserTabs(
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            to: newOrder
                        )
                    }
                )

                remoteDetailContentArea(
                    remote: remote,
                    connection: connection,
                    window: window,
                    sessionTabs: remoteTabs,
                    selectedBrowserTab: selectedBrowserTab
                )
            }
            .id("\(remote.hostId)-\(window.id)")
        } else if
            let remote = selectedRemoteSession,
            coordinator.viewerConnectionManager?.connection(for: remote.hostId) != nil {
            // Session selected but no windows available yet
            ContentUnavailableView(
                "Loading Session",
                symbol: .terminal,
                description: "Waiting for session data..."
            )
        } else if let window = selectedWindow {
            let session = tmuxService.sessions.first(where: { $0.windows.contains(where: { $0.id == window.id }) })
            let browserState = session.flatMap { fileBrowserStates[$0.sessionName] }
            let directoryPath = window.activePane?.currentPath ?? NSHomeDirectory()
            let sessionTabs = session.flatMap { sessionFileTabsStates[$0.sessionName] }
            let selectedFileTab: OpenFileTab? = {
                guard let sessionTabs, let id = sessionTabs.selectedFileTabId else { return nil }
                return sessionTabs.openFileTabs.first(where: { $0.id == id })
            }()
            let selectedBrowserTab: BrowserTab? = {
                guard let sessionTabs, let id = sessionTabs.selectedBrowserTabId else { return nil }
                return sessionTabs.openBrowserTabs.first(where: { $0.id == id })
            }()
            let isFileBrowserActive = fileBrowserActiveWindowIds.contains(window.id)
            let isGitActive = gitActiveWindowIds.contains(window.id)
            let isAnyFileViewActive = isFileBrowserActive || isGitActive
                || selectedFileTab != nil || selectedBrowserTab != nil
            VStack(spacing: 0) {
                if let session {
                    WindowTabBar(
                        session: session,
                        selectedWindow: window,
                        isFileBrowserSelected: isFileBrowserActive && selectedFileTab == nil && selectedBrowserTab == nil,
                        isGitBrowserSelected: isGitActive,
                        isAnyFileViewActive: isAnyFileViewActive,
                        sessionTabs: sessionTabs,
                        onSelectWindow: { newWindow in
                            let tabs = sessionFileTabsStates[session.sessionName]
                            let payload = TabDragPayload.window(newWindow.id)
                            if tabs?.rightSide.contains(payload) == true {
                                // Right-side window: route the click to the
                                // right pane's selection so the left pane
                                // keeps showing whatever it had.
                                tabs?.selectedRight = payload
                                return
                            }
                            fileBrowserActiveWindowIds.remove(window.id)
                            gitActiveWindowIds.remove(window.id)
                            tabs?.selectedFileTabId = nil
                            tabs?.selectedBrowserTabId = nil
                            selectedWindow = newWindow
                            Task {
                                try? await tmuxService.selectWindow(newWindow.id)
                            }
                        },
                        onCloseWindow: { windowToClose in
                            requestCloseWindow(windowToClose)
                        },
                        onNewWindow: {
                            Task {
                                do {
                                    let paneId = try await tmuxService.newWindow(
                                        sessionName: session.sessionName,
                                        workingDirectory: window.activePane?.currentPath
                                    )
                                    if let newWindow = tmuxService.windows.first(where: { $0.panes.contains(where: { $0.paneId == paneId }) }) {
                                        selectedWindow = newWindow
                                    }
                                } catch {
                                    attachError = "Failed to create window: \(error.localizedDescription)"
                                }
                            }
                        },
                        onNewBrowser: {
                            openEmptyBrowserTab(sessionName: session.sessionName, windowId: window.id)
                        },
                        onRenameWindow: { windowToRename, newName in
                            Task {
                                try? await tmuxService.renameWindow(target: windowToRename.id, name: newName)
                                _ = await tmuxService.refreshPanes()
                                await coordinator.connectedViewerManager?.pushSessionStateToAll()
                            }
                        },
                        onSelectFileBrowser: {
                            if fileBrowserStates[session.sessionName] == nil {
                                fileBrowserStates[session.sessionName] = FileBrowserState()
                            }
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            let tabs = sessionFileTabsStates[session.sessionName]
                            if tabs?.rightSide.contains(.fileExplorer) == true {
                                // Folder button lives on the right pane:
                                // route the click to the right-side
                                // selection so the left pane is untouched.
                                tabs?.selectedRight = .fileExplorer
                                return
                            }
                            fileBrowserActiveWindowIds.insert(window.id)
                            gitActiveWindowIds.remove(window.id)
                            tabs?.selectedFileTabId = nil
                            tabs?.selectedBrowserTabId = nil
                        },
                        onSelectGitBrowser: {
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            let tabs = sessionFileTabsStates[session.sessionName]
                            if tabs?.rightSide.contains(.git) == true {
                                // Git button lives on the right pane: route the
                                // click to the right-side selection so the left
                                // pane is untouched.
                                tabs?.selectedRight = .git
                                return
                            }
                            gitActiveWindowIds.insert(window.id)
                            fileBrowserActiveWindowIds.remove(window.id)
                            tabs?.selectedFileTabId = nil
                            tabs?.selectedBrowserTabId = nil
                        },
                        onSelectFileTab: { tabId in
                            selectFileTab(tabId, sessionName: session.sessionName, windowId: window.id)
                        },
                        onCloseFileTab: { tabId in
                            closeOpenFileTab(tabId, sessionName: session.sessionName)
                        },
                        onSelectBrowserTab: { tabId in
                            selectBrowserTab(tabId, sessionName: session.sessionName, windowId: window.id)
                        },
                        onCloseBrowserTab: { tabId in
                            closeBrowserTab(tabId, sessionName: session.sessionName)
                        },
                        onToggleSplit: { payload in
                            toggleSplit(payload, sessionName: session.sessionName, windowId: window.id)
                        },
                        onShowInFileExplorer: { path in
                            fileBrowserActiveWindowIds.insert(window.id)
                            gitActiveWindowIds.remove(window.id)
                            if fileBrowserStates[session.sessionName] == nil {
                                fileBrowserStates[session.sessionName] = FileBrowserState()
                            }
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
                            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
                            fileBrowserStates[session.sessionName]?.pendingRevealPath = path
                        },
                        onAcceptOpenSuggestion: { suggestion in
                            openFileInNewTab(
                                path: suggestion.filePath,
                                directoryPath: suggestion.directoryPath,
                                sessionName: session.sessionName,
                                windowId: window.id
                            )
                            markdownOpenSuggestionStore.dismiss(sessionName: session.sessionName)
                        },
                        onReorderWindows: { newOrder in
                            reorderWindows(in: session.sessionName, to: newOrder)
                        },
                        onReorderFileTabs: { newOrder in
                            reorderFileTabs(in: session.sessionName, to: newOrder)
                        },
                        onReorderBrowserTabs: { newOrder in
                            reorderBrowserTabs(in: session.sessionName, to: newOrder)
                        }
                    )
                }

                detailContentArea(
                    window: window,
                    session: session,
                    directoryPath: directoryPath,
                    isFileBrowserActive: isFileBrowserActive,
                    isGitActive: isGitActive,
                    browserState: browserState,
                    sessionTabs: session.flatMap { sessionFileTabsStates[$0.sessionName] },
                    selectedBrowserTab: selectedBrowserTab
                )
            }
            .id(window.id)
        } else if tmuxService.panes.isEmpty && !settings.hasRemoteHosts {
            NewSessionContent(
                title: "New Session",
                projects: projects,
                isLoadingProjects: isLoadingProjects,
                creatingSelection: creatingSelection,
                onCreate: { project in
                    createNewSession(project: project)
                },
                popover: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ContentUnavailableView(
                        "Select a Window",
                        symbol: .terminal,
                        description: "Choose a window from the sidebar to view its mirror."
                    )
                    Spacer()
                }
                Spacer()
            }
        }
    }

    // MARK: - Remote Detail Body

    /// Renders the remote session detail area below the tab bar. When the
    /// session has any tabs flipped to the right pane
    /// (`SessionFileTabsState.isSplit`), draws a left pane + draggable
    /// divider + right pane laid out side by side. Otherwise renders the
    /// single-pane content unchanged.
    @ViewBuilder
    private func remoteDetailContentArea(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        window: TmuxWindow,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if let sessionTabs, sessionTabs.isSplit {
            SplitDetailContent(
                sessionTabs: sessionTabs,
                left: {
                    remoteLeftPaneContent(
                        remote: remote,
                        connection: connection,
                        window: window,
                        selectedBrowserTab: selectedBrowserTab
                    )
                },
                right: {
                    remoteRightPaneContent(
                        remote: remote,
                        connection: connection,
                        sessionTabs: sessionTabs
                    )
                }
            )
        } else {
            remoteLeftPaneContent(
                remote: remote,
                connection: connection,
                window: window,
                selectedBrowserTab: selectedBrowserTab
            )
        }
    }

    /// Renders the body of a remote session's detail pane: either the live
    /// in-app browser tab content (when one is selected) or the remote tmux
    /// pane layout. Web links clicked in the remote terminal flow through
    /// `handleRemoteTerminalURLClick` so the per-domain rules and
    /// `browserLinkBehavior` prompt apply identically to local sessions.
    @ViewBuilder
    private func remoteLeftPaneContent(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        window: TmuxWindow,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        let tabsKey = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        if
            let selectedBrowserTab,
            let browserTabState = remoteSessionTabsStates[tabsKey]?.browserStates[selectedBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    updateRemoteBrowserTabTitle(
                        tabId: selectedBrowserTab.id,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    updateRemoteBrowserTabURL(
                        tabId: selectedBrowserTab.id,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        url: newURL
                    )
                },
                onRequestNewTab: { newURL in
                    openRemoteBrowserTab(
                        url: newURL,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        originWindowId: selectedBrowserTab.originWindowId,
                        parentTabId: selectedBrowserTab.id
                    )
                }
            )
            .id(selectedBrowserTab.id)
        } else {
            RemoteWindowPaneLayoutView(
                window: window,
                connection: connection,
                settings: settings,
                onOpenURL: { url in
                    handleRemoteTerminalURLClick(
                        url,
                        hostId: remote.hostId,
                        sessionName: remote.sessionName,
                        windowId: window.id
                    )
                }
            )
        }
    }

    /// Renders the right pane of the remote split layout by dispatching on
    /// the `selectedRight` payload — window terminal or browser tab. File
    /// explorer / file tab payloads can't reach here for remote sessions
    /// (no source view emits them), so those branches fall back to the
    /// placeholder.
    @ViewBuilder
    private func remoteRightPaneContent(
        remote: RemoteSessionSelection,
        connection: ViewerConnection,
        sessionTabs: SessionFileTabsState
    ) -> some View {
        switch sessionTabs.selectedRight {
        case let .window(id):
            if let rightWindow = selectedRemoteSessionWindows.first(where: { $0.id == id }) {
                RemoteWindowPaneLayoutView(
                    window: rightWindow,
                    connection: connection,
                    settings: settings,
                    onOpenURL: { url in
                        handleRemoteTerminalURLClick(
                            url,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            windowId: rightWindow.id
                        )
                    }
                )
                .id("right-remote-\(rightWindow.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case let .browser(id):
            if
                let tab = sessionTabs.openBrowserTabs.first(where: { $0.id == id }),
                let tabState = sessionTabs.browserStates[id] {
                BrowserTabContentView(
                    state: tabState,
                    onTitleChange: { newTitle in
                        updateRemoteBrowserTabTitle(
                            tabId: id,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            title: newTitle
                        )
                    },
                    onURLChange: { newURL in
                        updateRemoteBrowserTabURL(
                            tabId: id,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            url: newURL
                        )
                    },
                    onRequestNewTab: { newURL in
                        openRemoteBrowserTab(
                            url: newURL,
                            hostId: remote.hostId,
                            sessionName: remote.sessionName,
                            originWindowId: tab.originWindowId,
                            parentTabId: tab.id
                        )
                    }
                )
                .id("right-remote-\(tab.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case .fileExplorer,
             .git,
             .file,
             nil:
            rightPanePlaceholder
        }
    }

    // MARK: - Detail Content Area (split-aware)

    /// Renders the content area below the tab bar. When the session has any
    /// tabs sent to the right pane (`SessionFileTabsState.isSplit`), draws a
    /// left pane + draggable divider + right pane laid out side by side.
    /// Otherwise renders the single-pane content unchanged.
    @ViewBuilder
    private func detailContentArea(
        window: LocalTmuxWindow,
        session: LocalTmuxSession?,
        directoryPath: String,
        isFileBrowserActive: Bool,
        isGitActive: Bool,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if let sessionTabs, sessionTabs.isSplit, let session {
            SplitDetailContent(
                sessionTabs: sessionTabs,
                left: {
                    leftPaneContent(
                        window: window,
                        session: session,
                        directoryPath: directoryPath,
                        isFileBrowserActive: isFileBrowserActive,
                        isGitActive: isGitActive,
                        browserState: browserState,
                        sessionTabs: sessionTabs,
                        selectedBrowserTab: selectedBrowserTab
                    )
                },
                right: {
                    rightPaneContent(
                        sessionName: session.sessionName,
                        directoryPath: directoryPath,
                        browserState: browserState,
                        sessionTabs: sessionTabs
                    )
                }
            )
        } else {
            leftPaneContent(
                window: window,
                session: session,
                directoryPath: directoryPath,
                isFileBrowserActive: isFileBrowserActive,
                isGitActive: isGitActive,
                browserState: browserState,
                sessionTabs: sessionTabs,
                selectedBrowserTab: selectedBrowserTab
            )
        }
    }

    @ViewBuilder
    private func leftPaneContent(
        window: LocalTmuxWindow,
        session: LocalTmuxSession?,
        directoryPath: String,
        isFileBrowserActive: Bool,
        isGitActive: Bool,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState?,
        selectedBrowserTab: BrowserTab?
    ) -> some View {
        if
            let selectedBrowserTab,
            let session,
            let browserTabState = sessionFileTabsStates[session.sessionName]?.browserStates[selectedBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    updateBrowserTabTitle(
                        tabId: selectedBrowserTab.id,
                        sessionName: session.sessionName,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    updateBrowserTabURL(
                        tabId: selectedBrowserTab.id,
                        sessionName: session.sessionName,
                        url: newURL
                    )
                },
                onRequestNewTab: { newURL in
                    openBrowserTab(
                        url: newURL,
                        sessionName: session.sessionName,
                        windowId: window.id,
                        originWindowId: selectedBrowserTab.originWindowId,
                        parentTabId: selectedBrowserTab.id
                    )
                }
            )
            .id(selectedBrowserTab.id)
        } else if
            isFileBrowserActive,
            let browserState,
            let session,
            let sessionTabs {
            FileBrowserView(
                directoryPath: directoryPath,
                state: browserState,
                sessionTabs: sessionTabs,
                onOpenFileInNewTab: { path in
                    openFileInNewTab(
                        path: path,
                        directoryPath: directoryPath,
                        sessionName: session.sessionName,
                        windowId: window.id
                    )
                }
            )
        } else if isGitActive, let session {
            gitPane(sessionName: session.sessionName, directoryPath: directoryPath)
        } else {
            WindowPaneLayoutView(
                window: window,
                onOpenURL: { url in
                    handleTerminalURLClick(
                        url,
                        directoryPath: directoryPath,
                        session: session,
                        window: window
                    )
                }
            )
        }
    }

    /// The Git tab's content (issue #258), backed by a per-session
    /// ``GitWorkbenchStore`` cached in `gitWorkbenchStores`. The store is built
    /// lazily here (in `.task`, never during `body` evaluation) so the git state
    /// survives tab/session switches, and rebuilt when the working directory
    /// changes so it tracks the same folder as the file explorer.
    @ViewBuilder
    private func gitPane(sessionName: String, directoryPath: String) -> some View {
        if let entry = gitWorkbenchStores[sessionName], entry.path == directoryPath {
            GitBrowserView(store: entry.store)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: directoryPath) {
                    ensureGitStore(sessionName: sessionName, directoryPath: directoryPath)
                }
        }
    }

    /// Creates (or rebuilds, on a directory change) the cached GitWorkbench
    /// store for a session. Safe to call from `.task`/event handlers; never call
    /// it during `body` evaluation since it mutates `@State`.
    @MainActor
    private func ensureGitStore(sessionName: String, directoryPath: String) {
        if let entry = gitWorkbenchStores[sessionName], entry.path == directoryPath { return }
        let provider = gitProviderClient.provider(URL(fileURLWithPath: directoryPath))
        let store = GitWorkbenchStore(provider: provider)
        gitWorkbenchStores[sessionName] = GitStoreEntry(path: directoryPath, store: store)
    }

    /// Renders the right pane of the split layout by dispatching on the
    /// `selectedRight` payload — window terminal, file explorer, browser
    /// tab, or file tab — and falls back to a placeholder when nothing is
    /// picked or the referenced content has gone away.
    @ViewBuilder
    private func rightPaneContent(
        sessionName: String,
        directoryPath: String,
        browserState: FileBrowserState?,
        sessionTabs: SessionFileTabsState
    ) -> some View {
        switch sessionTabs.selectedRight {
        case let .window(id):
            if let window = tmuxService.windows.first(where: { $0.id == id }) {
                WindowPaneLayoutView(
                    window: window,
                    onOpenURL: { url in
                        handleTerminalURLClick(
                            url,
                            directoryPath: directoryPath,
                            session: tmuxService.sessions.first(where: { $0.sessionName == sessionName }),
                            window: window
                        )
                    }
                )
                .id("right-window-\(window.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case .fileExplorer:
            if let browserState {
                FileBrowserView(
                    directoryPath: directoryPath,
                    state: browserState,
                    sessionTabs: sessionTabs,
                    onOpenFileInNewTab: { path in
                        openFileInNewTab(
                            path: path,
                            directoryPath: directoryPath,
                            sessionName: sessionName,
                            windowId: selectedWindow?.id ?? ""
                        )
                    }
                )
                .id("right-file-explorer")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case .git:
            gitPane(sessionName: sessionName, directoryPath: directoryPath)
                .id("right-git")
                .accessibilityIdentifier("split-right-pane")
        case let .browser(id):
            if
                let tab = sessionTabs.openBrowserTabs.first(where: { $0.id == id }),
                let tabState = sessionTabs.browserStates[id] {
                BrowserTabContentView(
                    state: tabState,
                    onTitleChange: { newTitle in
                        updateBrowserTabTitle(tabId: id, sessionName: sessionName, title: newTitle)
                    },
                    onURLChange: { newURL in
                        updateBrowserTabURL(tabId: id, sessionName: sessionName, url: newURL)
                    },
                    onRequestNewTab: { newURL in
                        openBrowserTab(
                            url: newURL,
                            sessionName: sessionName,
                            windowId: selectedWindow?.id ?? "",
                            originWindowId: tab.originWindowId,
                            parentTabId: tab.id
                        )
                    }
                )
                .id("right-\(tab.id)")
                .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case let .file(id):
            if let tab = sessionTabs.openFileTabs.first(where: { $0.id == id }) {
                OpenFileTabContentView(tab: tab, sessionTabs: sessionTabs)
                    .id("right-\(tab.id)")
                    .accessibilityIdentifier("split-right-pane")
            } else {
                rightPanePlaceholder
            }
        case nil:
            rightPanePlaceholder
        }
    }

    private var rightPanePlaceholder: some View {
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            connectionStatusView
        }

        // Actions for selected window
        ToolbarItemGroup(placement: .primaryAction) {
            if let window = selectedWindow, selectedRemoteSession == nil {
                let claudePane = window.panes.first { windowManager.paneStates[$0.paneId]?.agentSession != nil }
                let activePane = window.activePane

                // Yolo mode toggle (only for windows with active Claude sessions)
                if let claudePane {
                    Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(
                        windowManager.isYoloModeEnabled(for: claudePane.paneId)
                            ? "Yolo mode: auto-approving permissions (click to disable)"
                            : "Enable yolo mode to auto-approve permissions"
                    )
                }

                if let activePane {
                    Button {
                        attachToTerminal(activePane)
                    } label: {
                        Symbols.macwindow.image
                    }
                    .accessibilityLabel("Open session in terminal app")
                    .help("Open session in terminal app")

                    resizeToolbarGroup(
                        resizeKey: activePane.paneId,
                        localTarget: activePane.target,
                        localWindow: window,
                        isSessionAttached: tmuxService.attachedSessionNames.contains(window.sessionName)
                    )
                }

                Button {
                    requestCloseSession(window.sessionName)
                } label: {
                    Symbols.xmark.image
                }
                .accessibilityLabel("Close session")
                .help("Close session")
            } else if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow {
                // Yolo mode toggle for remote windows with active Claude sessions
                let claudePaneId = remoteWindow.panes.first(where: { $0.agentSession != nil })?.paneId
                if
                    let claudePaneId,
                    let sessionStore = coordinator.remoteSessionStore,
                    sessionStore.session(for: claudePaneId, hostId: remote.hostId) != nil {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) },
                        set: { newValue in
                            Task {
                                guard let manager = coordinator.viewerConnectionManager else { return }
                                _ = await manager.sendCommand(
                                    SetYoloMode(enabled: newValue),
                                    paneId: claudePaneId,
                                    hostId: remote.hostId
                                )
                            }
                        }
                    )) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(
                        coordinator.remoteSessionStore?.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) == true
                            ? "Yolo mode: auto-approving permissions (click to disable)"
                            : "Enable yolo mode to auto-approve permissions"
                    )
                }

                if let activePane = remoteWindow.activePane {
                    let resizeKey = remote.resizeKey(paneId: activePane.paneId)
                    resizeToolbarGroup(resizeKey: resizeKey, remoteHostId: remote.hostId, remotePaneId: activePane.paneId)
                }

                Button {
                    requestCloseRemoteSession(remote.sessionName, hostId: remote.hostId)
                } label: {
                    Symbols.xmark.image
                }
                .accessibilityLabel("Close session")
                .help("Close session")
            }

            Button {
                Task {
                    await refreshPanes()
                }
            } label: {
                Symbols.arrowClockwise.image
            }
            .accessibilityLabel("Refresh pane list")
            .help("Refresh pane list")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(tmuxService.isRefreshing)
        }
    }

    // MARK: - Connection Status View

    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            connectionStatusIcon
                .font(.caption)

            connectionActionButton
        }
        .onChange(of: coordinator.connectedViewerManager?.combinedState) { _, _ in
            showingDisconnectConfirmation = false
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected
        let anyViewerConnected = connectionManager?.anyViewerConnected ?? false

        switch combinedState {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
                .help("Disconnected from relay server")
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .help("Connecting...")
        case let .reconnecting(attempt):
            ProgressView()
                .controlSize(.small)
                .help("Reconnecting (attempt \(attempt))...")
        case .connected:
            Symbols.wifi.image
                .foregroundStyle(.green)
                .help(
                    anyViewerConnected
                        ? "Connected - viewer online"
                        : "Connected - waiting for viewer"
                )
        case let .error(message):
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
                .help("Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        if !settings.isPaired {
            // Not paired - show generate pair button
            Button("Generate Pair") {
                openSettingsToRemoteAccess()
            }
            .controlSize(.small)
            .help("Open Remote Access settings to pair with iOS")
        } else if combinedState.isConnected {
            // Connected - show disconnect button with confirmation popover
            Button("Disconnect") {
                showingDisconnectConfirmation = true
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
            .popover(isPresented: $showingDisconnectConfirmation, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Disconnect from relay server?")
                        .font(.headline)
                    Text("Paired iOS viewers will stop receiving updates until you reconnect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            showingDisconnectConfirmation = false
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Disconnect", role: .destructive) {
                            showingDisconnectConfirmation = false
                            Task {
                                await connectionManager?.disconnectAll()
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        } else if case .connecting = combinedState {
            // Connecting - no button
            EmptyView()
        } else if case .reconnecting = combinedState {
            // Reconnecting - show cancel button
            Button("Cancel") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
            .controlSize(.small)
            .help("Cancel reconnection attempts")
        } else {
            // Disconnected but paired - show connect button
            Button("Connect") {
                Task {
                    await connectionManager?.connectAll()
                }
            }
            .controlSize(.small)
            .help("Connect to relay server for iOS monitoring")
        }
    }

    // MARK: - Resize

    private func localYoloModeBinding(for paneId: String) -> Binding<Bool> {
        Binding(
            get: { windowManager.isYoloModeEnabled(for: paneId) },
            set: { newValue in
                windowManager.setYoloMode(enabled: newValue, for: paneId)
                Task {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                }
            }
        )
    }

    @ViewBuilder
    private func resizeToolbarGroup(
        resizeKey: String,
        localTarget: String? = nil,
        localWindow: LocalTmuxWindow? = nil,
        remoteHostId: String? = nil,
        remotePaneId: String? = nil,
        isSessionAttached: Bool = false
    ) -> some View {
        let attachedHelp = "Cannot resize: session is attached to a terminal"
        let autoResizeActive = isAutoResizeActive(for: resizeKey)
        // For local windows, `resizeKey` is the bare paneId, so use it as the
        // cache key in performResize. The width override comes from the
        // window's effective split-aware width when available.
        let widthOverride: CGFloat? = localWindow.flatMap(effectiveTerminalWidth(for:))

        // Hide manual resize button when auto-resize is active
        if !autoResizeActive {
            Button {
                Task {
                    await performResize(
                        localTarget: localTarget,
                        localPaneId: localTarget != nil ? resizeKey : nil,
                        remoteHostId: remoteHostId,
                        remotePaneId: remotePaneId,
                        widthOverride: widthOverride
                    )
                }
            } label: {
                Symbols.arrowUpLeftAndArrowDownRight.image
            }
            // macOS 26 auto-labels icon-only toolbar Buttons by SF Symbol
            // (e.g. arrow.up.left.and.arrow.down.right → "Enter Full Screen")
            // and drops `.help()` from the AX tree, so set the AX label
            // explicitly to keep VoiceOver and e2e queries meaningful.
            .accessibilityLabel(isSessionAttached ? attachedHelp : "Resize tmux pane to fit mirror view")
            .help(isSessionAttached ? attachedHelp : "Resize tmux pane to fit mirror view")
            .disabled(isSessionAttached)
        }

        Toggle(isOn: Binding(
            get: { autoResizeActive },
            set: { enabled in
                if enabled {
                    autoResizeDisabled.remove(resizeKey)
                    autoResizeEnabled.insert(resizeKey)
                    Task {
                        await performResize(
                            localTarget: localTarget,
                            localPaneId: localTarget != nil ? resizeKey : nil,
                            remoteHostId: remoteHostId,
                            remotePaneId: remotePaneId,
                            widthOverride: widthOverride
                        )
                    }
                } else {
                    autoResizeDisabled.insert(resizeKey)
                    autoResizeEnabled.remove(resizeKey)
                }
            }
        )) {
            Symbols.arrowDownRightAndArrowUpLeft.image
        }
        .toggleStyle(.button)
        .help(isSessionAttached ? attachedHelp : "Auto-resize tmux pane when mirror view changes size")
        .disabled(isSessionAttached)
    }

    /// Whether auto-resize is active for the given pane key (either via global preference or per-session toggle)
    private func isAutoResizeActive(for key: String) -> Bool {
        if settings.alwaysAutoResize {
            return !autoResizeDisabled.contains(key)
        }
        return autoResizeEnabled.contains(key)
    }

    /// Common reaction for any of the three selection state changes
    /// (`selectedWindow`, `selectedRemoteSession`, `selectedRemoteWindowId`):
    /// flush cached dimensions, kick off auto-resize, and clear attention for
    /// sessions the user is now looking at.
    private func handleSelectionChanged() {
        lastAutoResizeDimensions.removeAll()
        handleAutoResize()
        markSelectedSessionsHandledIfActive()
    }

    private func handleAutoResize() {
        // Cancel any pending debounced resize
        autoResizeTask?.cancel()

        // Capture current selection before the debounce sleep to avoid racing with window switches
        let currentWindow = selectedWindow
        let currentRemote = selectedRemoteSession
        let currentRemoteWindow = selectedRemoteWindow
        let rightWindow = rightPaneTerminalWindow()

        autoResizeTask = Task {
            // Debounce: wait for layout to stabilize (especially during session switches)
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            if let window = currentWindow, let activePane = window.activePane, currentRemote == nil {
                let widthOverride = effectiveTerminalWidth(for: window)
                let dimensions = calculateOptimalTerminalDimensions(widthOverride: widthOverride)
                let cached = lastAutoResizeDimensions[activePane.paneId]
                if cached?.columns != dimensions.columns || cached?.rows != dimensions.rows {
                    if
                        isAutoResizeActive(for: activePane.paneId),
                        !tmuxService.attachedSessionNames.contains(window.sessionName) {
                        await performResize(
                            localTarget: activePane.target,
                            localPaneId: activePane.paneId,
                            widthOverride: widthOverride
                        )
                    }
                }

                // Right-pane terminal (split mode): a different tmux window can
                // live on the right side. Resize it to fit the right half so
                // each terminal matches its rendered area.
                if let rightWindow, let rightPane = rightWindow.activePane {
                    let rightWidth = effectiveTerminalWidth(for: rightWindow)
                    let rightDimensions = calculateOptimalTerminalDimensions(widthOverride: rightWidth)
                    let rightCached = lastAutoResizeDimensions[rightPane.paneId]
                    if rightCached?.columns != rightDimensions.columns || rightCached?.rows != rightDimensions.rows {
                        if
                            isAutoResizeActive(for: rightPane.paneId),
                            !tmuxService.attachedSessionNames.contains(rightWindow.sessionName) {
                            await performResize(
                                localTarget: rightPane.target,
                                localPaneId: rightPane.paneId,
                                widthOverride: rightWidth
                            )
                        }
                    }
                }
            } else if
                let remote = currentRemote,
                let leftWindow = currentRemoteWindow,
                let activePane = leftWindow.activePane {
                let leftWidth = effectiveTerminalWidth(forRemote: leftWindow, in: remote)
                let resizeKey = remote.resizeKey(paneId: activePane.paneId)
                let dimensions = calculateOptimalTerminalDimensions(widthOverride: leftWidth)
                let cached = lastAutoResizeDimensions[resizeKey]
                if cached?.columns != dimensions.columns || cached?.rows != dimensions.rows {
                    if isAutoResizeActive(for: resizeKey) {
                        await performResize(
                            remoteHostId: remote.hostId,
                            remotePaneId: activePane.paneId,
                            widthOverride: leftWidth
                        )
                    }
                }

                // Right-pane remote terminal (split mode): a different remote
                // tmux window can live on the right side. Resize it to fit
                // the right half so each terminal matches its rendered area.
                if
                    let rightWindow = rightPaneRemoteTerminalWindow(remote: remote),
                    let rightPane = rightWindow.activePane {
                    let rightWidth = effectiveTerminalWidth(forRemote: rightWindow, in: remote)
                    let rightResizeKey = remote.resizeKey(paneId: rightPane.paneId)
                    let rightDimensions = calculateOptimalTerminalDimensions(widthOverride: rightWidth)
                    let rightCached = lastAutoResizeDimensions[rightResizeKey]
                    if rightCached?.columns != rightDimensions.columns || rightCached?.rows != rightDimensions.rows {
                        if isAutoResizeActive(for: rightResizeKey) {
                            await performResize(
                                remoteHostId: remote.hostId,
                                remotePaneId: rightPane.paneId,
                                widthOverride: rightWidth
                            )
                        }
                    }
                }
            }
        }
    }

    /// The tmux window currently rendered in the split-view right pane (if any).
    /// Returns `nil` when the right pane is empty, holds non-terminal content
    /// (file explorer, file tab, browser tab), or when the layout is not split.
    private func rightPaneTerminalWindow() -> LocalTmuxWindow? {
        guard
            let sessionName = selectedWindow?.sessionName,
            let tabs = sessionFileTabsStates[sessionName],
            tabs.isSplit,
            case let .window(rightWindowId) = tabs.selectedRight
        else {
            return nil
        }
        return tmuxService.windows.first { $0.id == rightWindowId }
    }

    private func performResize(
        localTarget: String? = nil,
        localPaneId: String? = nil,
        remoteHostId: String? = nil,
        remotePaneId: String? = nil,
        widthOverride: CGFloat? = nil
    ) async {
        let dimensions = calculateOptimalTerminalDimensions(widthOverride: widthOverride)

        if let localTarget {
            do {
                try await tmuxService.resizePane(localTarget, width: dimensions.columns, height: dimensions.rows)
                if let localPaneId {
                    lastAutoResizeDimensions[localPaneId] = dimensions
                }
            } catch {
                attachError = "Failed to resize: \(error.localizedDescription)"
            }
        } else if let remoteHostId, let remotePaneId {
            guard let manager = coordinator.viewerConnectionManager else { return }
            let result = await manager.sendCommand(
                ResizeTmuxPane(width: dimensions.columns, height: dimensions.rows),
                paneId: remotePaneId,
                hostId: remoteHostId
            )
            switch result {
            case .success:
                // Cache under the same key handleAutoResize uses for the remote pane
                if let remote = selectedRemoteSession {
                    lastAutoResizeDimensions[remote.resizeKey(paneId: remotePaneId)] = dimensions
                }
            case let .failure(error):
                attachError = "Failed to resize remote pane: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Session Tracking

    private func handleActiveSessionsChanged() {
        let currentIds = windowManager.activeSessionPaneIds
        let previousIds = trackedActiveSessionPaneIds

        // Detect newly added Claude sessions
        let newSessionPaneIds = currentIds.subtracting(previousIds)
        // Detect removed Claude sessions (sessions moving from Claude Sessions → Terminals)
        let removedSessionPaneIds = previousIds.subtracting(currentIds)

        if
            let selected = selectedWindow, newSessionPaneIds.contains(where: { paneId in
                selected.panes.contains { $0.paneId == paneId }
            }) {
            // The currently selected window just got a Claude session - scroll to its session
            let sessionName = selected.sessionName
            scrollToWindowId = sessionName
        } else if !removedSessionPaneIds.isEmpty, let selected = selectedWindow {
            // A session ended, causing entries to move between sections - scroll to keep visible
            let sessionName = selected.sessionName
            scrollToWindowId = sessionName
        } else if
            selectedWindow == nil, selectedRemoteSession == nil, newSessionPaneIds.count == 1,
            let newPaneId = newSessionPaneIds.first,
            let window = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == newPaneId } }) {
            // Nothing selected and a single new session appeared - auto-select the containing window
            selectedWindow = window
            scrollToWindowId = window.sessionName
        }

        trackedActiveSessionPaneIds = currentIds
    }

    // MARK: - Session Attention

    /// Marks the currently selected session(s) as handled, but only when the app is active.
    private func markSelectedSessionsHandledIfActive() {
        guard NSApp.isActive else { return }

        if let window = selectedWindow {
            var stateChanged = false
            for pane in window.panes
                where windowManager.paneStates[pane.paneId]?.agentSession?.needsAttention == true {
                windowManager.markSessionHandled(paneId: pane.paneId)
                stateChanged = true
            }
            if stateChanged {
                let newBadge = windowManager.pendingSessionCount
                Task {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                    await coordinator.connectedViewerManager?.broadcastBadgeUpdate(badge: newBadge)
                }
            }
        }

        if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow {
            for pane in remoteWindow.panes where pane.agentSession?.needsAttention == true {
                coordinator.remoteSessionStore?.markSessionHandled(paneId: pane.paneId, hostId: remote.hostId)
                Task {
                    _ = await coordinator.viewerConnectionManager?.sendCommand(
                        MarkHandled(),
                        paneId: pane.paneId,
                        hostId: remote.hostId
                    )
                }
            }
        }
    }

    // MARK: - Pending Menu Bar Selection

    /// Applies a pending menu bar selection, if any.
    /// Called both from `.task` (when the view first appears) and `.onChange` (when already visible).
    private func applyPendingMenuBarSelection() {
        guard let selection = coordinator.pendingMenuBarSelection else { return }
        coordinator.pendingMenuBarSelection = nil
        switch selection {
        case let .local(paneId):
            if let window = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == paneId } }) {
                selectedWindow = window
                selectedRemoteSession = nil
                selectedRemoteWindowId = nil
                fileBrowserActiveWindowIds.remove(window.id)
                gitActiveWindowIds.remove(window.id)
                if
                    let sessionName = tmuxService.sessions
                        .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
                        .sessionName {
                    sessionFileTabsStates[sessionName]?.selectedFileTabId = nil
                }
            }
        case let .remote(hostId, hostName, paneId):
            // Find the session name for this pane from the session store
            if let paneState = coordinator.remoteSessionStore?.paneState(for: paneId, hostId: hostId) {
                selectedRemoteSession = RemoteSessionSelection(
                    hostId: hostId,
                    hostName: hostName,
                    sessionName: paneState.sessionName
                )
                selectedRemoteWindowId = paneState.windowId
            }
            selectedWindow = nil
        }
    }

    // MARK: - Actions

    private func refreshPanes() async {
        await tmuxService.refreshPanes()
    }

    private func attachToTerminal(_ pane: PaneInfo) {
        let launcher = TerminalLauncher(settings: settings)
        Task {
            do {
                try await launcher.attachToSession(pane.sessionName)
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func requestCloseSession(_ sessionName: String) {
        Task {
            let processes = await tmuxService.runningProcesses(inSession: sessionName)
            if processes.isEmpty {
                performClose(.session(sessionName))
            } else {
                closeConfirmation = CloseConfirmation(
                    target: .session(sessionName),
                    localProcesses: processes
                )
            }
        }
    }

    private func requestCloseWindow(_ window: LocalTmuxWindow) {
        Task {
            let processes = await tmuxService.runningProcesses(inWindow: window.id)
            if processes.isEmpty {
                performClose(.window(window))
            } else {
                closeConfirmation = CloseConfirmation(
                    target: .window(window),
                    localProcesses: processes
                )
            }
        }
    }

    // MARK: - Menu Commands

    /// Cmd-W handler exposed to the menu via `.focusedSceneValue` so other
    /// scenes (Settings, About, CLI API Reference) get the default
    /// `performClose:` behaviour while this scene routes through the
    /// existing precedence: remote tab → browser tab → file tab → regular
    /// window. Lifted out so the body's modifier chain stays small enough
    /// for the type checker to handle.
    private func handleCloseCurrentTab() {
        if
            let remote = selectedRemoteSession,
            let remoteWindow = selectedRemoteWindow {
            // If a remote browser tab is selected, Cmd-W closes that tab
            // first — mirrors the local "tab over window" precedence.
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            if let selectedBrowserId = remoteSessionTabsStates[key]?.selectedBrowserTabId {
                closeRemoteBrowserTab(
                    selectedBrowserId,
                    hostId: remote.hostId,
                    sessionName: remote.sessionName
                )
                return
            }
            requestCloseRemoteWindow(remoteWindow, hostId: remote.hostId)
            return
        }
        guard let window = selectedWindow else { return }
        let sessionName = tmuxService.sessions
            .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
            .sessionName
        // If a browser tab is selected, Cmd-W closes that tab first.
        if
            let sessionName,
            let selectedBrowserId = sessionFileTabsStates[sessionName]?.selectedBrowserTabId {
            closeBrowserTab(selectedBrowserId, sessionName: sessionName)
            return
        }
        // If a file tab is selected, Cmd-W closes that tab first.
        if
            let sessionName,
            let selectedTabId = sessionFileTabsStates[sessionName]?.selectedFileTabId {
            closeOpenFileTab(selectedTabId, sessionName: sessionName)
            return
        }
        // The file browser and Git tabs have no close action — do nothing.
        guard !fileBrowserActiveWindowIds.contains(window.id) else { return }
        guard !gitActiveWindowIds.contains(window.id) else { return }
        requestCloseWindow(window)
    }

    /// Cmd-Shift-[ / Cmd-Shift-] handler. Walks the active session's tab
    /// strip in visual order — tmux windows, then the Files button, then file
    /// tabs, then browser tabs — and selects the entry `direction` steps away
    /// from the current one, wrapping around the ends so the shortcut keeps
    /// working at the boundaries. Remote sessions only have window tabs, so
    /// the helper falls back to cycling those when no local session is
    /// selected. No-op when there is exactly one tab in view.
    private func selectAdjacentTab(direction: Int) {
        if let remote = selectedRemoteSession {
            cycleRemoteWindowTab(remote: remote, direction: direction)
            return
        }
        guard let window = selectedWindow else { return }
        guard
            let session = tmuxService.sessions
                .first(where: { $0.windows.contains(where: { $0.id == window.id }) })
        else { return }
        let sessionTabs = sessionFileTabsStates[session.sessionName]
        let entries = tabStripEntries(
            session: session,
            sessionTabs: sessionTabs
        )
        guard entries.count > 1 else { return }
        let currentIndex = currentTabIndex(
            entries: entries,
            window: window,
            sessionTabs: sessionTabs
        )
        guard let currentIndex else { return }
        let nextIndex = (currentIndex + direction + entries.count) % entries.count
        applyTabSelection(
            entry: entries[nextIndex],
            session: session,
            sessionTabs: sessionTabs,
            currentWindow: window
        )
    }

    /// Logical tab-strip entries used by `selectAdjacentTab`. The cases mirror
    /// the order rendered by `WindowTabBar.singleSection` so cycling matches
    /// the user's visual mental model.
    private enum TabStripEntry: Equatable {
        case window(LocalTmuxWindow)
        case fileBrowser
        case gitBrowser
        case fileTab(UUID)
        case browserTab(UUID)
    }

    private func tabStripEntries(
        session: LocalTmuxSession,
        sessionTabs: SessionFileTabsState?
    ) -> [TabStripEntry] {
        var entries: [TabStripEntry] = session.windows.map { .window($0) }
        entries.append(.fileBrowser)
        entries.append(.gitBrowser)
        if let sessionTabs {
            entries.append(contentsOf: sessionTabs.openFileTabs.map { .fileTab($0.id) })
            entries.append(contentsOf: sessionTabs.openBrowserTabs.map { .browserTab($0.id) })
        }
        return entries
    }

    private func currentTabIndex(
        entries: [TabStripEntry],
        window: LocalTmuxWindow,
        sessionTabs: SessionFileTabsState?
    ) -> Int? {
        // Browser tab > file tab > git > file browser > selected window. The
        // first match wins so the user's actual visible tab is the cycling
        // anchor.
        if let selectedBrowserId = sessionTabs?.selectedBrowserTabId {
            if let idx = entries.firstIndex(of: .browserTab(selectedBrowserId)) {
                return idx
            }
        }
        if let selectedFileId = sessionTabs?.selectedFileTabId {
            if let idx = entries.firstIndex(of: .fileTab(selectedFileId)) {
                return idx
            }
        }
        if gitActiveWindowIds.contains(window.id) {
            if let idx = entries.firstIndex(of: .gitBrowser) {
                return idx
            }
        }
        if fileBrowserActiveWindowIds.contains(window.id) {
            if let idx = entries.firstIndex(of: .fileBrowser) {
                return idx
            }
        }
        return entries.firstIndex(of: .window(window))
    }

    private func applyTabSelection(
        entry: TabStripEntry,
        session: LocalTmuxSession,
        sessionTabs: SessionFileTabsState?,
        currentWindow: LocalTmuxWindow
    ) {
        switch entry {
        case let .window(window):
            fileBrowserActiveWindowIds.remove(currentWindow.id)
            gitActiveWindowIds.remove(currentWindow.id)
            sessionTabs?.selectedFileTabId = nil
            sessionTabs?.selectedBrowserTabId = nil
            selectedWindow = window
            Task {
                try? await tmuxService.selectWindow(window.id)
            }
        case .fileBrowser:
            fileBrowserActiveWindowIds.insert(currentWindow.id)
            gitActiveWindowIds.remove(currentWindow.id)
            if fileBrowserStates[session.sessionName] == nil {
                fileBrowserStates[session.sessionName] = FileBrowserState()
            }
            if sessionFileTabsStates[session.sessionName] == nil {
                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
            }
            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
        case .gitBrowser:
            gitActiveWindowIds.insert(currentWindow.id)
            fileBrowserActiveWindowIds.remove(currentWindow.id)
            if sessionFileTabsStates[session.sessionName] == nil {
                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
            }
            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
        case let .fileTab(tabId):
            selectFileTab(tabId, sessionName: session.sessionName, windowId: currentWindow.id)
        case let .browserTab(tabId):
            selectBrowserTab(tabId, sessionName: session.sessionName, windowId: currentWindow.id)
        }
    }

    /// Cmd-Shift-[ / Cmd-Shift-] handler for remote sessions. Walks the tab
    /// strip in visual order — tmux windows then browser tabs — and selects
    /// the entry `direction` steps away from the current one, with
    /// wraparound. Sends `SelectTmuxWindow` to the host when the new entry
    /// is a terminal so tmux follows along.
    private func cycleRemoteWindowTab(remote: RemoteSessionSelection, direction: Int) {
        let windows = selectedRemoteSessionWindows
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        let tabs = remoteSessionTabsStates[key]
        // Prefer the user's drag-reordered visual order when one is persisted —
        // tmux's `windowIndex` reflects host-side order but not any reorder the
        // user has applied locally to the tab strip.
        let liveWindowIds = Set(windows.map(\.id))
        let liveBrowserIds = Set(tabs?.openBrowserTabs.map(\.id) ?? [])
        let entries: [TabDragPayload]
        if let storedOrder = tabs?.tabOrder, !storedOrder.isEmpty {
            entries = storedOrder.filter { ref in
                switch ref {
                case let .window(id): liveWindowIds.contains(id)
                case let .browser(id): liveBrowserIds.contains(id)
                case .fileExplorer,
                     .git,
                     .file: false
                }
            }
        } else {
            var fallback: [TabDragPayload] = windows.map { .window($0.id) }
            if let openBrowserTabs = tabs?.openBrowserTabs {
                fallback.append(contentsOf: openBrowserTabs.map { .browser($0.id) })
            }
            entries = fallback
        }
        guard entries.count > 1 else { return }

        // Browser tab > selected window. The first match wins so the user's
        // actual visible tab is the cycling anchor.
        let currentIndex: Int?
        if let selectedBrowserId = tabs?.selectedBrowserTabId {
            currentIndex = entries.firstIndex(of: .browser(selectedBrowserId))
        } else if let currentId = selectedRemoteWindowId ?? selectedRemoteWindow?.id {
            currentIndex = entries.firstIndex(of: .window(currentId))
        } else {
            currentIndex = nil
        }
        guard let currentIndex else { return }
        let nextIndex = (currentIndex + direction + entries.count) % entries.count
        switch entries[nextIndex] {
        case let .window(id):
            tabs?.selectedBrowserTabId = nil
            selectedRemoteWindowId = id
            Task {
                guard let manager = coordinator.viewerConnectionManager else { return }
                _ = await manager.sendCommand(
                    SelectTmuxWindow(),
                    paneId: id,
                    hostId: remote.hostId
                )
            }
        case let .browser(id):
            selectRemoteBrowserTab(id, hostId: remote.hostId, sessionName: remote.sessionName)
        case .fileExplorer,
             .git,
             .file:
            break
        }
    }

    /// Cmd-Shift-F handler. Switches the currently-selected local session to
    /// the file explorer tab, flips its search mode to content, and asks the
    /// search field to take focus. Bails on remote sessions because remote
    /// hosts have no file explorer surface to switch to.
    private func handleOpenContentSearch() {
        guard selectedRemoteSession == nil else { return }
        guard let window = selectedWindow else { return }
        guard
            let session = tmuxService.sessions
                .first(where: { $0.windows.contains(where: { $0.id == window.id }) }) else { return }

        fileBrowserActiveWindowIds.insert(window.id)
        gitActiveWindowIds.remove(window.id)
        if fileBrowserStates[session.sessionName] == nil {
            fileBrowserStates[session.sessionName] = FileBrowserState()
        }
        if sessionFileTabsStates[session.sessionName] == nil {
            sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
        }
        sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil

        guard let browserState = fileBrowserStates[session.sessionName] else { return }
        browserState.searchMode = .content
        browserState.searchFieldFocusRequest += 1
    }

    // MARK: - File Browser Tabs

    /// Opens a file in a new tab next to the file browser, or selects the existing
    /// tab if the file is already open. Newly opened tabs become the active view.
    /// Tabs are scoped to the tmux session so they remain visible when the user
    /// switches between windows in the same session.
    ///
    /// Also ensures `fileBrowserActiveWindowIds` contains `windowId` so the
    /// FileBrowserView for that window stays mounted while the file tab is
    /// selected — its `directoryChanges` task is what drives tab deletion
    /// state, so it must continue running underneath the visible file content.
    ///
    /// `originWindowId` records which tmux window initiated the open when the
    /// tab is opened from a terminal click; closing the tab routes the user
    /// back there instead of leaving them on the file browser tree. When an
    /// existing tab is re-opened, only a non-nil incoming origin overwrites
    /// the stored value — a tree/context-menu re-open carries no origin and
    /// must not silently clear the previously-recorded terminal return target.
    private func openFileInNewTab(
        path: String,
        directoryPath: String,
        sessionName: String,
        windowId: String,
        originWindowId: String? = nil
    ) {
        fileBrowserActiveWindowIds.insert(windowId)
        gitActiveWindowIds.remove(windowId)
        if fileBrowserStates[sessionName] == nil {
            fileBrowserStates[sessionName] = FileBrowserState()
        }
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let useSplit = settings.alwaysOpenFilesInSplit
        if let existingIndex = tabs.openFileTabs.firstIndex(where: { $0.path == path }) {
            if let originWindowId {
                tabs.openFileTabs[existingIndex].originWindowId = originWindowId
            }
            let existingId = tabs.openFileTabs[existingIndex].id
            if tabs.rightSide.contains(.file(existingId)) {
                tabs.selectedRight = .file(existingId)
            } else {
                tabs.selectedFileTabId = existingId
            }
            return
        }
        let newTab = OpenFileTab(
            path: path,
            directoryPath: directoryPath,
            originWindowId: originWindowId
        )
        tabs.openFileTabs.append(newTab)
        if useSplit {
            tabs.rightSide.insert(.file(newTab.id))
            tabs.selectedRight = .file(newTab.id)
        } else {
            tabs.selectedFileTabId = newTab.id
        }
    }

    /// Selects an existing file tab on whichever side it currently lives on.
    /// Mirrors `selectBrowserTab` for browser tabs. Both branches insert
    /// `windowId` into `fileBrowserActiveWindowIds` so the tree's
    /// `directoryChanges` task stays alive and keeps `isDeleted` fresh on
    /// every file tab — including right-pane tabs whose pane no longer
    /// surfaces the file browser tree directly.
    private func selectFileTab(_ tabId: UUID, sessionName: String, windowId: String) {
        if fileBrowserStates[sessionName] == nil {
            fileBrowserStates[sessionName] = FileBrowserState()
        }
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if tabs.rightSide.contains(.file(tabId)) {
            tabs.selectedRight = .file(tabId)
            return
        }
        // Only flip the left pane into file-view mode for left-side tabs;
        // right-side clicks shouldn't disturb whatever the left pane shows.
        fileBrowserActiveWindowIds.insert(windowId)
        gitActiveWindowIds.remove(windowId)
        tabs.selectedFileTabId = tabId
        tabs.selectedBrowserTabId = nil
    }

    /// Toggles which side of the split a tab strip entry lives on (issue #498).
    /// The receiving side becomes the entry's selected slot; the originating
    /// side has its selection reset if it pointed at the moved entry. After
    /// every move `reconcileRightPaneSelection` re-picks a right-pane selection
    /// so the pane doesn't show the empty placeholder while content still lives
    /// over there.
    ///
    /// `windowId` is the *current left-pane window* — used to flip
    /// `fileBrowserActiveWindowIds` and `selectedWindow` for moves that land
    /// content back on the left. Terminal-only sessions don't materialise a
    /// `SessionFileTabsState` until the first tab opens, so the state is
    /// created on demand for the very first split-toggle click.
    private func toggleSplit(_ payload: TabDragPayload, sessionName: String, windowId: String) {
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        // Reject payloads whose underlying data has gone away between the
        // last reconcile and the click (extremely rare; we'd otherwise
        // insert a dangling id into `rightSide`).
        switch payload {
        case let .file(id) where !tabs.openFileTabs.contains(where: { $0.id == id }): return
        case let .browser(id) where !tabs.openBrowserTabs.contains(where: { $0.id == id }): return
        default: break
        }

        if tabs.rightSide.contains(payload) {
            // Moving back to the left side — receiving side becomes this entry.
            tabs.rightSide.remove(payload)
            if tabs.selectedRight == payload { tabs.selectedRight = nil }
            switch payload {
            case let .window(id):
                if let restored = tmuxService.windows.first(where: { $0.id == id }) {
                    selectedWindow = restored
                }
            case .fileExplorer:
                fileBrowserActiveWindowIds.insert(windowId)
                gitActiveWindowIds.remove(windowId)
            case .git:
                gitActiveWindowIds.insert(windowId)
                fileBrowserActiveWindowIds.remove(windowId)
                tabs.selectedFileTabId = nil
                tabs.selectedBrowserTabId = nil
            case let .file(id):
                fileBrowserActiveWindowIds.insert(windowId)
                gitActiveWindowIds.remove(windowId)
                tabs.selectedFileTabId = id
                tabs.selectedBrowserTabId = nil
            case let .browser(id):
                tabs.selectedBrowserTabId = id
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
                gitActiveWindowIds.remove(windowId)
            }
        } else {
            // Moving to the right side — becomes the right pane's selection.
            tabs.rightSide.insert(payload)
            tabs.selectedRight = payload
            switch payload {
            case let .window(id):
                if selectedWindow?.id == id {
                    let leftSessionWindows = tmuxService.windows
                        .filter { $0.sessionName == sessionName && !tabs.rightSide.contains(.window($0.id)) }
                    selectedWindow = leftSessionWindows.first(where: \.isWindowActive) ?? leftSessionWindows.first
                }
            case .fileExplorer:
                fileBrowserActiveWindowIds.remove(windowId)
            case .git:
                gitActiveWindowIds.remove(windowId)
            case let .file(id):
                if tabs.selectedFileTabId == id { tabs.selectedFileTabId = nil }
            case let .browser(id):
                if tabs.selectedBrowserTabId == id { tabs.selectedBrowserTabId = nil }
            }
        }
        reconcileRightPaneSelection(sessionName: sessionName)
    }

    /// Keeps the right pane's selection coherent with the tabs still on that
    /// side. Clears a dangling selection, then auto-picks an entry on the
    /// right when nothing is selected but at least one tab remains there.
    /// The auto-pick prefers, in order: a remaining window, the file
    /// explorer, the most recently appended browser, then the most recently
    /// appended file — avoiding the "No Tab Selected" placeholder whenever
    /// real right-side content exists.
    private func reconcileRightPaneSelection(sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if let sel = tabs.selectedRight, !tabs.rightSide.contains(sel) {
            tabs.selectedRight = nil
        }
        guard tabs.isSplit else { return }

        // If every window/file/browser is on the right, the left section is
        // effectively empty (only the "+" button would remain) — collapse
        // the split so the user isn't stuck with a half-empty layout. The
        // file-explorer button doesn't disqualify collapse on its own; it's
        // a navigation affordance, not content.
        let sessionWindows = tmuxService.windows.filter { $0.sessionName == sessionName }
        let leftEmpty = !sessionWindows.isEmpty
            && sessionWindows.allSatisfy { tabs.rightSide.contains(.window($0.id)) }
            && tabs.openFileTabs.allSatisfy { tabs.rightSide.contains(.file($0.id)) }
            && tabs.openBrowserTabs.allSatisfy { tabs.rightSide.contains(.browser($0.id)) }
        if leftEmpty {
            tabs.rightSide.removeAll()
            tabs.selectedRight = nil
            // Restore selectedWindow if the move-to-right path cleared it
            // (no left-side fallback was available at the time).
            if
                selectedWindow == nil
                || sessionWindows.first(where: { $0.id == selectedWindow?.id }) == nil {
                selectedWindow = sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first
            }
            return
        }

        if tabs.selectedRight != nil { return }
        // Auto-pick: window > file explorer > git > newest browser > newest file.
        if let window = tabs.rightSide.first(where: { if case .window = $0 { true } else { false } }) {
            tabs.selectedRight = window
        } else if tabs.rightSide.contains(.fileExplorer) {
            tabs.selectedRight = .fileExplorer
        } else if tabs.rightSide.contains(.git) {
            tabs.selectedRight = .git
        } else if let browser = tabs.openBrowserTabs.last(where: { tabs.rightSide.contains(.browser($0.id)) }) {
            tabs.selectedRight = .browser(browser.id)
        } else if let file = tabs.openFileTabs.last(where: { tabs.rightSide.contains(.file($0.id)) }) {
            tabs.selectedRight = .file(file.id)
        }
    }

    /// Routes a URL clicked in the terminal. Three flows are possible:
    ///
    /// - `file://` URL with `openClickedFileInNewTab` enabled: opens the file
    ///   in a new file tab. Returns `true`.
    /// - http/https/ftp URL: the destination depends on the effective behavior
    ///   for the URL — a per-domain rule (`settings.browserBehavior(for:)`)
    ///   takes precedence over the global `settings.browserLinkBehavior`.
    ///   `.alwaysInApp` opens an in-app browser tab and returns `true`.
    ///   `.alwaysInDefaultBrowser` returns `false` so the click falls through
    ///   to `NSWorkspace.shared.open`. `.ask` shows a confirmation dialog
    ///   (with "remember my choice" toggles) and returns `true` so the system
    ///   handler doesn't race with the user.
    /// - Anything else: `false`, system handler takes over.
    private func handleTerminalURLClick(
        _ url: URL,
        directoryPath: String,
        session: LocalTmuxSession?,
        window: LocalTmuxWindow
    ) -> Bool {
        if url.isFileURL {
            guard settings.openClickedFileInNewTab, let session else {
                return false
            }
            openFileInNewTab(
                path: url.path,
                directoryPath: directoryPath,
                sessionName: session.sessionName,
                windowId: window.id,
                originWindowId: window.id
            )
            return true
        }

        guard let session, BrowserURLDispatcher.canHandle(url) else {
            return false
        }

        let effective = settings.browserBehavior(for: url) ?? settings.browserLinkBehavior

        switch effective {
        case .alwaysInApp:
            openBrowserTab(
                url: url,
                sessionName: session.sessionName,
                windowId: window.id,
                originWindowId: window.id
            )
            return true
        case .alwaysInDefaultBrowser:
            return false
        case .ask:
            pendingBrowserURLPrompt = PendingBrowserURLPrompt(
                url: url,
                sessionName: session.sessionName,
                windowId: window.id,
                hostId: nil
            )
            return true
        }
    }

    /// Mirror of `handleTerminalURLClick` for remote sessions. Web link clicks
    /// inside a remote terminal follow the same `browserLinkBehavior` rules as
    /// local clicks — including the per-domain overrides — so the
    /// in-app/system-browser preference is honoured uniformly across
    /// host types. `file://` URLs are not routed in-app for remote sessions
    /// because the remote filesystem isn't browsable here yet; they fall
    /// through to `URLOpener` which the host treats as a no-op for unknown
    /// schemes.
    private func handleRemoteTerminalURLClick(
        _ url: URL,
        hostId: String,
        sessionName: String,
        windowId: String
    ) -> Bool {
        guard BrowserURLDispatcher.canHandle(url) else { return false }

        let effective = settings.browserBehavior(for: url) ?? settings.browserLinkBehavior

        switch effective {
        case .alwaysInApp:
            openRemoteBrowserTab(
                url: url,
                hostId: hostId,
                sessionName: sessionName,
                originWindowId: windowId
            )
            return true
        case .alwaysInDefaultBrowser:
            return false
        case .ask:
            pendingBrowserURLPrompt = PendingBrowserURLPrompt(
                url: url,
                sessionName: sessionName,
                windowId: windowId,
                hostId: hostId
            )
            return true
        }
    }

    /// Opens (or re-selects) a browser tab for `url` in the given session,
    /// activating it as the visible detail content.
    private func openBrowserTab(
        url: URL,
        sessionName: String,
        windowId: String,
        originWindowId: String? = nil,
        parentTabId: UUID? = nil
    ) {
        let tabs: SessionFileTabsState
        if let existing = sessionFileTabsStates[sessionName] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            sessionFileTabsStates[sessionName] = tabs
        }
        let useSplit = settings.alwaysOpenLinksInSplit
        // Match on the tab's live `currentURL` (driven by the WKWebView) rather
        // than the value stored on `BrowserTab`. After the user navigates away
        // from the opening URL, `BrowserTab.url` advances with them; re-using
        // that for de-dup would let a second click on the original URL spawn a
        // duplicate tab. Re-focusing is the intended behaviour.
        let existingIndex = tabs.openBrowserTabs.firstIndex { tab in
            tabs.browserStates[tab.id]?.currentURL == url
        }
        if let existingIndex {
            if let originWindowId {
                tabs.openBrowserTabs[existingIndex].originWindowId = originWindowId
            }
            let existingId = tabs.openBrowserTabs[existingIndex].id
            if tabs.rightSide.contains(.browser(existingId)) {
                tabs.selectedRight = .browser(existingId)
            } else {
                tabs.selectedBrowserTabId = existingId
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
                gitActiveWindowIds.remove(windowId)
            }
        } else {
            let newTab = BrowserTab(url: url, originWindowId: originWindowId, parentTabId: parentTabId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            if useSplit {
                tabs.rightSide.insert(.browser(newTab.id))
                tabs.selectedRight = .browser(newTab.id)
            } else {
                tabs.selectedBrowserTabId = newTab.id
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
                gitActiveWindowIds.remove(windowId)
            }
        }
    }

    /// Selects an existing browser tab and ensures the file tree/file tab views
    /// don't render alongside it.
    private func selectBrowserTab(_ tabId: UUID, sessionName: String, windowId: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if tabs.rightSide.contains(.browser(tabId)) {
            tabs.selectedRight = .browser(tabId)
            return
        }
        tabs.selectedBrowserTabId = tabId
        tabs.selectedFileTabId = nil
        fileBrowserActiveWindowIds.remove(windowId)
        gitActiveWindowIds.remove(windowId)
    }

    /// Opens a fresh, empty browser tab with `about:blank` loaded. The tab is
    /// appended at the end, selected, and the address bar is asked to take
    /// keyboard focus so the user can start typing a URL immediately. Used by
    /// the "+" menu's "New Browser" entry.
    private func openEmptyBrowserTab(sessionName: String, windowId: String) {
        if sessionFileTabsStates[sessionName] == nil {
            sessionFileTabsStates[sessionName] = SessionFileTabsState()
        }
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        // about:blank gives WKWebView a deterministic, offline starting page
        // so the new tab doesn't briefly flash a network error before the
        // user types a real URL.
        let blank = URL(staticString: "about:blank")
        let newTab = BrowserTab(url: blank)
        let state = BrowserTabState(initialURL: blank)
        // Clear the URL field text so the user sees an empty input rather
        // than the literal "about:blank" placeholder when the field gains
        // focus. The page itself still loads at the blank URL.
        state.urlFieldText = ""
        tabs.openBrowserTabs.append(newTab)
        tabs.browserStates[newTab.id] = state
        tabs.selectedBrowserTabId = newTab.id
        tabs.selectedFileTabId = nil
        fileBrowserActiveWindowIds.remove(windowId)
        gitActiveWindowIds.remove(windowId)
        state.urlFieldFocusRequest += 1
    }

    /// Rewrites tmux's window order for `sessionName` to match `newOrder`.
    /// `newOrder` lists every window id (e.g. `"sessionName:N"`) in the
    /// desired visual order. The tmux service moves each window into its new
    /// index and triggers a refresh so the in-memory window list mirrors the
    /// new layout. Since window ids embed the tmux index ("session:N"), every
    /// id changes after the move — the previously-selected window is
    /// re-located by its post-move position in `newOrder` so the selection
    /// follows the same logical window across the renumbering.
    private func reorderWindows(in sessionName: String, to newOrder: [String]) {
        let previouslySelectedId = selectedWindow?.id
        let newSelectedIndex = previouslySelectedId.flatMap { newOrder.firstIndex(of: $0) }
        // Clear the selection optimistically so the `onChange(of: tmuxService.panes)`
        // handler that fires from inside `moveWindows`'s refreshPanes() bails
        // out via its `guard let selected` early-return instead of resetting
        // selectedWindow to an arbitrary fallback (the old id no longer exists
        // post-renumber). We restore the correct, index-matched window below
        // before pushing state to viewers.
        selectedWindow = nil
        Task {
            do {
                try await tmuxService.moveWindows(in: sessionName, to: newOrder)
                if
                    let newSelectedIndex,
                    let refreshed = tmuxService.windows.first(where: {
                        $0.sessionName == sessionName && $0.windowIndex == newSelectedIndex
                    }) {
                    selectedWindow = refreshed
                }
                await coordinator.connectedViewerManager?.pushSessionStateToAll()
            } catch {
                attachError = "Failed to reorder windows: \(error.localizedDescription)"
            }
        }
    }

    /// Reorders the open file tabs in `sessionName` to match `newOrder`.
    private func reorderFileTabs(in sessionName: String, to newOrder: [UUID]) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openFileTabs.map { ($0.id, $0) })
        let reordered: [OpenFileTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openFileTabs.count else { return }
        tabs.openFileTabs = reordered
    }

    /// Reorders the open browser tabs in `sessionName` to match `newOrder`.
    private func reorderBrowserTabs(in sessionName: String, to newOrder: [UUID]) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openBrowserTabs.map { ($0.id, $0) })
        let reordered: [BrowserTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openBrowserTabs.count else { return }
        tabs.openBrowserTabs = reordered
    }

    /// Updates the cached page title for a browser tab so the tab strip
    /// re-renders with the new label.
    private func updateBrowserTabTitle(tabId: UUID, sessionName: String, title: String?) {
        guard
            let tabs = sessionFileTabsStates[sessionName],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].displayTitle != title {
            tabs.openBrowserTabs[index].displayTitle = title
        }
    }

    /// Updates the recorded URL for a browser tab as the user navigates so
    /// re-opening the same URL later picks the existing tab.
    private func updateBrowserTabURL(tabId: UUID, sessionName: String, url: URL) {
        guard
            let tabs = sessionFileTabsStates[sessionName],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].url != url {
            tabs.openBrowserTabs[index].url = url
        }
    }

    /// Removes a browser tab and its live web view. If the closed tab was
    /// selected and originated from a terminal click, the original tmux window
    /// becomes selected again — mirroring the file-tab close flow. If the
    /// closed tab was spawned from another browser tab (`target="_blank"` /
    /// `window.open()`), the parent tab is selected first instead.
    private func closeBrowserTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let payload = TabDragPayload.browser(tabId)
        let wasOnRight = tabs.rightSide.contains(payload)
        let wasSelectedLeft = tabs.selectedBrowserTabId == tabId
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.browserStates.removeValue(forKey: tabId)
        tabs.rightSide.remove(payload)
        if tabs.selectedRight == payload { tabs.selectedRight = nil }
        reconcileRightPaneSelection(sessionName: sessionName)
        // Even if the closed tab wasn't the left selection, it may still have
        // been the user's "current view" on the right pane — prefer the
        // parent-tab return for those too so a popup closed from the right
        // pane lands back on its opener.
        if
            let parentTabId = closedTab.parentTabId,
            tabs.openBrowserTabs.contains(where: { $0.id == parentTabId }) {
            if tabs.rightSide.contains(.browser(parentTabId)) {
                tabs.selectedRight = .browser(parentTabId)
            } else {
                tabs.selectedBrowserTabId = parentTabId
                tabs.selectedFileTabId = nil
            }
            return
        }
        guard wasSelectedLeft else { return }
        tabs.selectedBrowserTabId = nil
        // Right-side tabs were opened explicitly by the user; we don't bounce
        // them back to a terminal window on close. Only the left-side close
        // path preserves the original "return to origin terminal" behaviour.
        guard !wasOnRight else { return }

        guard
            let originWindowId = closedTab.originWindowId,
            let originWindow = tmuxService.windows.first(where: { $0.id == originWindowId })
        else { return }
        if selectedWindow?.id != originWindow.id {
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            selectedWindow = originWindow
            Task {
                try? await tmuxService.selectWindow(originWindow.id)
            }
        }
    }

    // MARK: - Remote Browser Tab Helpers

    /// Looks up the windows for a remote `(hostId, sessionName)` via the
    /// session store, sorted by `windowIndex`. Used as a window-list parameter
    /// for the right-pane reconciler so background sessions get reconciled
    /// against their own window list instead of the currently-selected one.
    private func remoteSessionWindows(hostId: String, sessionName: String) -> [TmuxWindow] {
        guard let sessionStore = coordinator.remoteSessionStore else { return [] }
        return sessionStore.windows(for: hostId)
            .filter { $0.sessionName == sessionName }
            .sorted { $0.windowIndex < $1.windowIndex }
    }

    /// Composite key into `remoteSessionTabsStates` for `(hostId, sessionName)`.
    /// Two paired hosts can have a session with the same name, so the hostId
    /// has to participate in the key — keying on `sessionName` alone would
    /// collide their tab strips. A typed struct (rather than a `String` like
    /// `"\(hostId):\(sessionName)"`) keeps the two components separate so a
    /// session name that happens to contain `:` can't collide with another
    /// host/session pair.
    private func remoteTabsKey(hostId: String, sessionName: String) -> RemoteSessionTabsKey {
        RemoteSessionTabsKey(hostId: hostId, sessionName: sessionName)
    }

    /// Opens (or re-selects) a browser tab inside a remote session's tab
    /// strip. Mirrors `openBrowserTab` for local sessions but reads/writes
    /// `remoteSessionTabsStates`.
    private func openRemoteBrowserTab(
        url: URL,
        hostId: String,
        sessionName: String,
        originWindowId: String? = nil,
        parentTabId: UUID? = nil
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs: SessionFileTabsState
        if let existing = remoteSessionTabsStates[key] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
        }
        // De-dup on the live `currentURL` from the WKWebView, not the value
        // stored on `BrowserTab`. After the user navigates the tab away from
        // its opening URL, `BrowserTab.url` advances with them; matching on
        // it would let a re-click of the original URL spawn a duplicate tab.
        let existingIndex = tabs.openBrowserTabs.firstIndex { tab in
            tabs.browserStates[tab.id]?.currentURL == url
        }
        if let existingIndex {
            if let originWindowId {
                tabs.openBrowserTabs[existingIndex].originWindowId = originWindowId
            }
            tabs.selectedBrowserTabId = tabs.openBrowserTabs[existingIndex].id
        } else {
            let newTab = BrowserTab(url: url, originWindowId: originWindowId, parentTabId: parentTabId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            tabs.selectedBrowserTabId = newTab.id
        }
    }

    /// Selects an existing browser tab in a remote session's tab strip.
    /// Mirrors `selectBrowserTab` for local sessions: when the tab is pinned
    /// to the right pane, route the click to `selectedRight` so the left
    /// pane keeps its current content instead of also rendering the browser.
    private func selectRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        if tabs.rightSide.contains(.browser(tabId)) {
            tabs.selectedRight = .browser(tabId)
            return
        }
        tabs.selectedBrowserTabId = tabId
    }

    /// Caches a remote browser tab's latest page title so the tab strip can
    /// re-render with the new label.
    private func updateRemoteBrowserTabTitle(
        tabId: UUID,
        hostId: String,
        sessionName: String,
        title: String?
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard
            let tabs = remoteSessionTabsStates[key],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].displayTitle != title {
            tabs.openBrowserTabs[index].displayTitle = title
        }
    }

    /// Records a remote browser tab's current URL as the user navigates so
    /// re-clicking the original URL re-focuses the existing tab.
    private func updateRemoteBrowserTabURL(
        tabId: UUID,
        hostId: String,
        sessionName: String,
        url: URL
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard
            let tabs = remoteSessionTabsStates[key],
            let index = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId })
        else { return }
        if tabs.openBrowserTabs[index].url != url {
            tabs.openBrowserTabs[index].url = url
        }
    }

    /// Removes a remote browser tab and its live web view. When the closed
    /// tab was selected and originated from a remote terminal click, the
    /// originating tmux window becomes selected again — same return-to-origin
    /// behaviour as `closeBrowserTab` for local tabs. If the closed tab was
    /// spawned from another browser tab (`target="_blank"` / `window.open()`),
    /// the parent tab is selected first instead.
    private func closeRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let payload = TabDragPayload.browser(tabId)
        let wasOnRight = tabs.rightSide.contains(payload)
        let wasSelectedLeft = tabs.selectedBrowserTabId == tabId
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.browserStates.removeValue(forKey: tabId)
        tabs.rightSide.remove(payload)
        if tabs.selectedRight == payload { tabs.selectedRight = nil }
        reconcileRemoteRightPaneSelection(
            hostId: hostId,
            sessionName: sessionName,
            sessionWindows: remoteSessionWindows(hostId: hostId, sessionName: sessionName)
        )
        // Prefer parent-tab return whether the popup was on the left or the
        // right pane, so closing it always lands back on its opener.
        if
            let parentTabId = closedTab.parentTabId,
            tabs.openBrowserTabs.contains(where: { $0.id == parentTabId }) {
            if tabs.rightSide.contains(.browser(parentTabId)) {
                tabs.selectedRight = .browser(parentTabId)
            } else {
                tabs.selectedBrowserTabId = parentTabId
            }
            return
        }
        guard wasSelectedLeft else { return }
        tabs.selectedBrowserTabId = nil
        // Right-side tabs were opened explicitly by the user; we don't bounce
        // them back to a terminal window on close. Only the left-side close
        // path preserves the original "return to origin terminal" behaviour.
        guard !wasOnRight else { return }
        guard
            let originWindowId = closedTab.originWindowId,
            let sessionStore = coordinator.remoteSessionStore
        else { return }
        let remoteWindows = sessionStore.windows(for: hostId)
            .filter { $0.sessionName == sessionName }
        if remoteWindows.contains(where: { $0.id == originWindowId }) {
            selectedRemoteWindowId = originWindowId
        } else {
            // Origin window no longer exists (e.g., closed on the host).
            // Drop the stale selection so the UI lands on a clean
            // "no window selected" state instead of a phantom id.
            selectedRemoteWindowId = nil
        }
    }

    /// Opens a fresh, empty browser tab with `about:blank` loaded in a remote
    /// session. The tab is appended at the end, selected, and the address bar
    /// is asked to take keyboard focus so the user can start typing a URL
    /// immediately. Mirror of `openEmptyBrowserTab` for remote sessions.
    private func openEmptyRemoteBrowserTab(hostId: String, sessionName: String) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs: SessionFileTabsState
        if let existing = remoteSessionTabsStates[key] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
        }
        let blank = URL(staticString: "about:blank")
        let newTab = BrowserTab(url: blank)
        let state = BrowserTabState(initialURL: blank)
        // Clear the URL field text so the user sees an empty input rather
        // than the literal "about:blank" placeholder when the field gains
        // focus. The page itself still loads at the blank URL.
        state.urlFieldText = ""
        tabs.openBrowserTabs.append(newTab)
        tabs.browserStates[newTab.id] = state
        tabs.selectedBrowserTabId = newTab.id
        state.urlFieldFocusRequest += 1
    }

    /// Toggles which side of the split a remote tab strip entry lives on.
    /// Mirrors `toggleSplit` for local sessions but operates on remote state.
    /// Only `.window` and `.browser` payloads are valid for remote sessions;
    /// `.fileExplorer` and `.file` cases are silently ignored.
    private func toggleRemoteSplit(_ payload: TabDragPayload, hostId: String, sessionName: String) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        let tabs: SessionFileTabsState
        if let existing = remoteSessionTabsStates[key] {
            tabs = existing
        } else {
            tabs = SessionFileTabsState()
            remoteSessionTabsStates[key] = tabs
        }
        // Reject payloads whose underlying data has gone away between the
        // last reconcile and the click — otherwise a stale `.window` would
        // get inserted into `tabs.rightSide` and the right pane would show
        // "No Tab Selected" until the next prune fires.
        switch payload {
        case let .browser(id) where !tabs.openBrowserTabs.contains(where: { $0.id == id }): return
        case let .window(id) where !selectedRemoteSessionWindows.contains(where: { $0.id == id }): return
        case .fileExplorer,
             .git,
             .file: return
        default: break
        }

        if tabs.rightSide.contains(payload) {
            // Moving back to the left side — receiving side becomes this entry.
            tabs.rightSide.remove(payload)
            if tabs.selectedRight == payload { tabs.selectedRight = nil }
            switch payload {
            case let .window(id):
                if selectedRemoteSessionWindows.contains(where: { $0.id == id }) {
                    selectedRemoteWindowId = id
                }
            case let .browser(id):
                tabs.selectedBrowserTabId = id
            case .fileExplorer,
                 .git,
                 .file:
                break
            }
        } else {
            // Moving to the right side — becomes the right pane's selection.
            tabs.rightSide.insert(payload)
            tabs.selectedRight = payload
            switch payload {
            case let .window(id):
                // If the moved window was the left-pane selection, pick a
                // different left-side window so both panes show distinct
                // content.
                if selectedRemoteWindowId == id || selectedRemoteWindow?.id == id {
                    let leftSessionWindows = selectedRemoteSessionWindows
                        .filter { !tabs.rightSide.contains(.window($0.id)) }
                    selectedRemoteWindowId = (leftSessionWindows.first(where: \.isWindowActive) ?? leftSessionWindows.first)?.id
                }
            case let .browser(id):
                if tabs.selectedBrowserTabId == id { tabs.selectedBrowserTabId = nil }
            case .fileExplorer,
                 .git,
                 .file:
                break
            }
        }
        reconcileRemoteRightPaneSelection(
            hostId: hostId,
            sessionName: sessionName,
            sessionWindows: remoteSessionWindows(hostId: hostId, sessionName: sessionName)
        )
    }

    /// Prune any right-side window entries that point at remote terminals
    /// the host has just removed (a window was closed remotely). Without
    /// this, `isSplit` stays true and the right pane shows "No Tab Selected"
    /// forever even though the referenced window is gone.
    private func pruneStaleRemoteRightSideEntries() {
        guard coordinator.remoteSessionStore != nil else { return }
        var prunedSelectedSession = false
        for (key, tabs) in remoteSessionTabsStates {
            let liveWindows = remoteSessionWindows(hostId: key.hostId, sessionName: key.sessionName)
            let liveIds = Set(liveWindows.map(\.id))
            let stale = tabs.rightSide.filter {
                if case let .window(id) = $0 { !liveIds.contains(id) } else { false }
            }
            guard !stale.isEmpty else { continue }
            tabs.rightSide.subtract(stale)
            if let sel = tabs.selectedRight, stale.contains(sel) {
                tabs.selectedRight = nil
            }
            reconcileRemoteRightPaneSelection(
                hostId: key.hostId,
                sessionName: key.sessionName,
                sessionWindows: liveWindows
            )
            if
                let remote = selectedRemoteSession,
                remote.hostId == key.hostId,
                remote.sessionName == key.sessionName {
                prunedSelectedSession = true
            }
        }
        // When the currently-viewed session just lost its right-pane window
        // the layout flips back to single-pane and the surviving left
        // terminal needs to grow to the full detail-pane width. The
        // `SplitSignal`-driven `AutoResizeObserversModifier` onChange would
        // in principle fire on this mutation, but the two `.onChange`
        // handlers (paneCount here and splitSignal next) are chained
        // through an `@Observable` mutation that SwiftUI can coalesce —
        // kick `handleAutoResize` directly so the surviving left pane
        // reliably resizes back. Local sessions are covered by
        // `selectedWindow`'s value-type refresh when tmux switches the
        // active window after a kill, which has no remote equivalent.
        if prunedSelectedSession {
            handleAutoResize()
        }
    }

    /// Keeps the remote right pane's selection coherent with the tabs still
    /// on that side. Mirrors `reconcileRightPaneSelection` for local sessions,
    /// but only considers windows and browser tabs (remote sessions have no
    /// file explorer / file tabs). Auto-collapses the split when every
    /// remaining window/browser tab lives on the right pane and the left
    /// section is effectively empty.
    ///
    /// `sessionWindows` is taken as a parameter (rather than read from the
    /// `selectedRemoteSessionWindows` computed property) because the prune
    /// path calls this for every cached session — including background ones —
    /// and the computed property always returns the currently-selected
    /// session's windows.
    private func reconcileRemoteRightPaneSelection(
        hostId: String,
        sessionName: String,
        sessionWindows: [TmuxWindow]
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        if let sel = tabs.selectedRight, !tabs.rightSide.contains(sel) {
            tabs.selectedRight = nil
        }
        guard tabs.isSplit else { return }

        let leftEmpty = !sessionWindows.isEmpty
            && sessionWindows.allSatisfy { tabs.rightSide.contains(.window($0.id)) }
            && tabs.openBrowserTabs.allSatisfy { tabs.rightSide.contains(.browser($0.id)) }
        if leftEmpty {
            tabs.rightSide.removeAll()
            tabs.selectedRight = nil
            // Only touch `selectedRemoteWindowId` for the currently-selected
            // session — it's session-scoped state and a background session's
            // auto-collapse can't change which window the user is viewing.
            if
                let remote = selectedRemoteSession,
                remote.hostId == hostId,
                remote.sessionName == sessionName,
                selectedRemoteWindowId == nil
                || sessionWindows.first(where: { $0.id == selectedRemoteWindowId }) == nil {
                selectedRemoteWindowId = (sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first)?.id
            }
            return
        }

        if tabs.selectedRight != nil { return }
        // Auto-pick: window > newest browser.
        if let window = tabs.rightSide.first(where: { if case .window = $0 { true } else { false } }) {
            tabs.selectedRight = window
        } else if let browser = tabs.openBrowserTabs.last(where: { tabs.rightSide.contains(.browser($0.id)) }) {
            tabs.selectedRight = .browser(browser.id)
        }
    }

    /// Pushes the new window order to the remote host via `MoveTmuxWindows`.
    /// The host rewrites tmux's window indices via the same two-phase
    /// park-then-place path used locally and pushes a refreshed session
    /// state on success.
    private func reorderRemoteWindows(
        hostId: String,
        sessionName: String,
        to newOrder: [String],
        connection: ViewerConnection
    ) {
        let previouslySelectedId = selectedRemoteWindowId ?? selectedRemoteWindow?.id
        let newSelectedIndex = previouslySelectedId.flatMap { newOrder.firstIndex(of: $0) }
        // Clear the selection optimistically so the `onChange` reconciliation
        // doesn't latch onto a now-removed id while the host renumbers
        // indices. We restore the index-matched window below after the host
        // confirms the move.
        selectedRemoteWindowId = nil
        Task {
            let result = await connection.relayClient.sendCommand(
                MoveTmuxWindows(sessionName: sessionName, windowIds: newOrder),
                paneId: ""
            )
            if case .success = result {
                guard let newSelectedIndex else { return }
                // The refreshed session state arrives asynchronously via the
                // WebSocket push, so `selectedRemoteSessionWindows` may still
                // be the pre-move list right after `sendCommand` returns.
                // Poll the session store until the window at the target
                // index appears, mirroring the `onNewWindow` pattern.
                for _ in 0..<20 {
                    if
                        let refreshed = selectedRemoteSessionWindows.first(where: {
                            $0.sessionName == sessionName && $0.windowIndex == newSelectedIndex
                        }) {
                        selectedRemoteWindowId = refreshed.id
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
                // The refreshed state never arrived in time. Falling back
                // to the previous id keeps the user on a real window
                // instead of an empty selection.
                if let previouslySelectedId {
                    selectedRemoteWindowId = previouslySelectedId
                }
            } else if let previouslySelectedId {
                // Move failed — restore the previous selection so the user
                // isn't left in a "no window selected" state.
                selectedRemoteWindowId = previouslySelectedId
            }
        }
    }

    /// Reorders the open browser tabs for a remote session.
    private func reorderRemoteBrowserTabs(
        hostId: String,
        sessionName: String,
        to newOrder: [UUID]
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        let indexed = Dictionary(uniqueKeysWithValues: tabs.openBrowserTabs.map { ($0.id, $0) })
        let reordered: [BrowserTab] = newOrder.compactMap { indexed[$0] }
        guard reordered.count == tabs.openBrowserTabs.count else { return }
        tabs.openBrowserTabs = reordered
    }

    /// Resolves the user's choice from the link confirmation dialog: opens the
    /// URL via the chosen path and — depending on `rememberScope` — either
    /// updates the global `settings.browserLinkBehavior` or adds a per-domain
    /// rule via `settings.setBrowserBehavior(_:for:)` so subsequent clicks
    /// skip the prompt for matching URLs.
    private func resolveBrowserURLPrompt(
        _ prompt: PendingBrowserURLPrompt,
        choice: BrowserPromptChoice,
        rememberScope: BrowserPromptRememberScope
    ) {
        let resolved: BrowserLinkBehavior
        switch choice {
        case .inApp:
            if let hostId = prompt.hostId {
                openRemoteBrowserTab(
                    url: prompt.url,
                    hostId: hostId,
                    sessionName: prompt.sessionName,
                    originWindowId: prompt.windowId
                )
            } else {
                openBrowserTab(
                    url: prompt.url,
                    sessionName: prompt.sessionName,
                    windowId: prompt.windowId,
                    originWindowId: prompt.windowId
                )
            }
            resolved = .alwaysInApp
        case .defaultBrowser:
            @Dependency(URLOpener.self) var urlOpener
            urlOpener.openInDefaultBrowser(prompt.url)
            resolved = .alwaysInDefaultBrowser
        }

        switch rememberScope {
        case .none:
            break
        case .global:
            settings.browserLinkBehavior = resolved
        case let .domain(host):
            settings.setBrowserBehavior(resolved, for: host)
        }
    }

    /// Removes a file tab. If the closed tab was selected, clears the selection.
    ///
    /// When the tab carries an `originWindowId` (set when opened from a
    /// terminal click), the originating terminal is reselected and its file
    /// browser is hidden so the user deterministically lands back on the
    /// terminal rather than the file tree. If the origin window is gone we
    /// still drop the file-browser membership for that id so the content area
    /// doesn't fall back to the tree — the user simply stays on whichever
    /// window is currently selected (or the empty state if none).
    ///
    /// Tabs without an origin (opened from the file browser tree, markdown
    /// suggestions, etc.) keep the legacy fallback so the file tree remains
    /// visible underneath.
    ///
    /// Invariant: this must be the only code path that removes entries from
    /// `openFileTabs`. Any bulk mutation that bypasses this method must also
    /// clear `selectedFileTabId` when the selected tab is removed, otherwise
    /// the id will dangle and the content area will render `OpenFileTabContentView`
    /// against a stale tab.
    /// Resolves the path of the currently-focused file (open file tab when one
    /// is selected, otherwise the file selected in the file browser detail
    /// pane) and stores it in `editorPickerPath` so the Cmd+E confirmation
    /// dialog presents the editor list. No-op when nothing file-shaped is in
    /// view.
    private func handleOpenCurrentTabInEditor() {
        guard let window = selectedWindow else { return }
        guard
            let sessionName = tmuxService.sessions
                .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
                .sessionName
        else { return }

        if
            let tabs = sessionFileTabsStates[sessionName],
            let selectedId = tabs.selectedFileTabId,
            let tab = tabs.openFileTabs.first(where: { $0.id == selectedId }) {
            editorPickerPath = tab.path
            return
        }

        guard
            fileBrowserActiveWindowIds.contains(window.id),
            let browserState = fileBrowserStates[sessionName]
        else { return }
        let directoryPath = window.activePane?.currentPath ?? NSHomeDirectory()
        if let path = browserState.selectedFilePath(directoryPath: directoryPath) {
            editorPickerPath = path
        }
    }

    private func closeOpenFileTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let closedIndex = tabs.openFileTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openFileTabs[closedIndex]
        let payload = TabDragPayload.file(tabId)
        let wasOnRight = tabs.rightSide.contains(payload)
        let wasSelectedLeft = tabs.selectedFileTabId == tabId
        tabs.openFileTabs.remove(at: closedIndex)
        tabs.scrollOffsets.removeValue(forKey: tabId)
        tabs.rightSide.remove(payload)
        if tabs.selectedRight == payload { tabs.selectedRight = nil }
        reconcileRightPaneSelection(sessionName: sessionName)
        guard wasSelectedLeft else { return }
        tabs.selectedFileTabId = nil
        // Right-side close flow doesn't reroute focus to a terminal window.
        guard !wasOnRight else { return }

        guard let originWindowId = closedTab.originWindowId else { return }

        // Drop membership unconditionally so the content area falls off the
        // tree even when the origin window is gone (closed/renamed). The
        // entry is otherwise only cleaned up by the panes-change observer,
        // which would briefly keep the tree visible.
        fileBrowserActiveWindowIds.remove(originWindowId)

        guard let originWindow = tmuxService.windows.first(where: { $0.id == originWindowId }) else {
            return
        }
        if selectedWindow?.id != originWindow.id {
            selectedRemoteSession = nil
            selectedRemoteWindowId = nil
            selectedWindow = originWindow
            Task {
                try? await tmuxService.selectWindow(originWindow.id)
            }
        }
    }

    // MARK: - Remote Close

    private func requestCloseRemoteWindow(_ window: TmuxWindow, hostId: String) {
        Task {
            guard let manager = coordinator.viewerConnectionManager else { return }
            let spec = CheckRunningProcesses(target: .window(window.id))
            let result = await manager.sendCommand(spec, paneId: "", hostId: hostId)
            switch result {
            case let .success(response):
                let processes = response.runningProcesses ?? []
                if processes.isEmpty {
                    performClose(.remoteWindow(window, hostId: hostId))
                } else {
                    closeConfirmation = CloseConfirmation(
                        target: .remoteWindow(window, hostId: hostId),
                        runningProcesses: processes
                    )
                }
            case let .failure(error):
                attachError = error.localizedDescription
            }
        }
    }

    private func requestCloseRemoteSession(_ sessionName: String, hostId: String) {
        Task {
            guard let manager = coordinator.viewerConnectionManager else { return }
            let spec = CheckRunningProcesses(target: .session(sessionName))
            let result = await manager.sendCommand(spec, paneId: "", hostId: hostId)
            switch result {
            case let .success(response):
                let processes = response.runningProcesses ?? []
                if processes.isEmpty {
                    performClose(.remoteSession(sessionName: sessionName, hostId: hostId))
                } else {
                    closeConfirmation = CloseConfirmation(
                        target: .remoteSession(sessionName: sessionName, hostId: hostId),
                        runningProcesses: processes
                    )
                }
            case let .failure(error):
                attachError = error.localizedDescription
            }
        }
    }

    private func performClose(_ target: CloseConfirmation.Target) {
        Task {
            do {
                switch target {
                case let .session(sessionName):
                    try await tmuxService.killSession(sessionName)
                case let .window(window):
                    try await tmuxService.killWindow(window.id)
                    // If the closed window was selected, select another window in the session
                    if selectedWindow?.id == window.id {
                        let session = tmuxService.sessions.first { $0.sessionName == window.sessionName }
                        selectedWindow = session?.activeWindow
                    }
                case let .remoteWindow(window, hostId):
                    guard let manager = coordinator.viewerConnectionManager else { return }
                    let result = await manager.sendCommand(
                        KillTmuxWindow(windowId: window.id),
                        paneId: "",
                        hostId: hostId
                    )
                    if case .success = result {
                        // Select another window if the closed one was selected
                        if selectedRemoteWindowId == window.id {
                            let remaining = selectedRemoteSessionWindows.filter { $0.id != window.id }
                            selectedRemoteWindowId = remaining.first(where: \.isWindowActive)?.id ?? remaining.first?.id
                        }
                    } else if case let .failure(error) = result {
                        attachError = error.localizedDescription
                    }
                case let .remoteSession(sessionName, hostId):
                    guard let manager = coordinator.viewerConnectionManager else { return }
                    let result = await manager.sendCommand(
                        KillTmuxSession(sessionName: sessionName),
                        paneId: "",
                        hostId: hostId
                    )
                    if case let .failure(error) = result {
                        attachError = error.localizedDescription
                    }
                }
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func openSettingsToRemoteAccess() {
        // Set the tab to Remote Access before opening settings
        settings.selectedSettingsTab = .remoteAccess
        NSApp.setActivationPolicy(.regular)
        openSettings()
        MenuBarExtraView.bringAppToFront()
    }

    // MARK: - New Session

    private var localNewSessionPopover: some View {
        NewSessionContent(
            title: "New Session",
            projects: projects,
            isLoadingProjects: isLoadingProjects,
            creatingSelection: creatingSelection,
            onCreate: { project in
                createNewSession(project: project)
            }
        )
    }

    // MARK: - New Session Actions

    private func loadProjects(showLoadingIndicator: Bool = true) async {
        if showLoadingIndicator {
            isLoadingProjects = true
        }
        projects = await coordinator.scanProjects()
        if showLoadingIndicator {
            isLoadingProjects = false
        }
    }

    /// Calculates optimal terminal dimensions based on available detail pane space.
    ///
    /// Uses the current font settings to determine character cell size and calculates
    /// how many columns and rows fit in the available space, accounting for UI padding.
    ///
    /// When the detail area is split between a left and right pane (issue #498),
    /// callers pass the rendered width of the specific pane via `widthOverride`
    /// so the terminal is resized to fit its half — not the full detail width.
    ///
    /// - Parameter widthOverride: Effective rendered width to use instead of
    ///   the full `detailPaneSize.width`. Pass `nil` for the unsplit layout.
    /// - Returns: A tuple of (columns, rows) for the terminal dimensions
    private func calculateOptimalTerminalDimensions(widthOverride: CGFloat? = nil) -> (columns: Int, rows: Int) {
        let effectiveWidth = widthOverride ?? detailPaneSize.width

        // Guard against uninitialized or invalid size
        guard effectiveWidth >= 100, detailPaneSize.height >= 100 else {
            return (columns: 120, rows: 40)
        }

        // Calculate cell size using current font settings
        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )

        // Horizontal padding: SwiftTerm scroller buffer
        let horizontalPadding = FontMetrics.horizontalBuffer

        // Vertical padding: window tab bar (~30px) + status bar (~28px) + some buffer for spacing
        let verticalPadding: CGFloat = 30 + (settings.showStatusBar ? 40 : 10)

        // Calculate available content area
        let availableWidth = max(0, effectiveWidth - horizontalPadding)
        let availableHeight = max(0, detailPaneSize.height - verticalPadding)

        // Apply reasonable bounds
        // Minimum: 80x24 (standard terminal size)
        // Maximum: 300x100 (prevent unreasonably large terminals)
        let columns = max(80, min(300, Int(availableWidth / cellSize.width)))
        let rows = max(24, min(100, Int(availableHeight / cellSize.height)))

        return (columns, rows)
    }

    /// Returns the rendered width of the terminal area for the given window,
    /// accounting for the split-view layout (issue #498). When the window's
    /// session has a split active, the terminal occupies only the side of the
    /// split it lives on — `nil` falls back to the full `detailPaneSize.width`
    /// so non-split sessions keep the original behavior.
    private func effectiveTerminalWidth(for window: LocalTmuxWindow) -> CGFloat? {
        effectiveTerminalWidth(
            tabs: sessionFileTabsStates[window.sessionName],
            windowId: window.id
        )
    }

    /// Remote counterpart to `effectiveTerminalWidth(for:)`. Reads the split
    /// state stored under the per-host/per-session key so remote terminals
    /// participate in the same split-aware auto-resize as host terminals.
    private func effectiveTerminalWidth(
        forRemote window: TmuxWindow,
        in remote: RemoteSessionSelection
    ) -> CGFloat? {
        let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
        return effectiveTerminalWidth(
            tabs: remoteSessionTabsStates[key],
            windowId: window.id
        )
    }

    private func effectiveTerminalWidth(
        tabs: SessionFileTabsState?,
        windowId: String
    ) -> CGFloat? {
        guard let tabs, tabs.isSplit else { return nil }
        let isOnRight = tabs.rightSide.contains(.window(windowId))
        let ratio = isOnRight ? (1 - tabs.splitRatio) : tabs.splitRatio
        return max(0, detailPaneSize.width * ratio - SplitLayout.dividerWidth / 2)
    }

    /// The remote `TmuxWindow` currently rendered in the split-view right
    /// pane (if any). Mirrors `rightPaneTerminalWindow()` for remote sessions
    /// so the right-side terminal participates in auto-resize too.
    private func rightPaneRemoteTerminalWindow(remote: RemoteSessionSelection) -> TmuxWindow? {
        guard
            let sessionStore = coordinator.remoteSessionStore,
            let tabs = remoteSessionTabsStates[remoteTabsKey(
                hostId: remote.hostId,
                sessionName: remote.sessionName
            )],
            tabs.isSplit,
            case let .window(rightWindowId) = tabs.selectedRight
        else {
            return nil
        }
        return sessionStore.windows(for: remote.hostId)
            .first { $0.sessionName == remote.sessionName && $0.id == rightWindowId }
    }

    /// Equatable snapshot of the currently selected session's split layout,
    /// used as the source for `.onChange(of:)` so the auto-resize logic fires
    /// when the user splits/collapses the detail area or drags the divider.
    /// Returns `nil` when nothing is selected so `.onChange` still fires on
    /// the first non-nil transition.
    private var currentSessionSplitSignal: SplitSignal? {
        if
            let sessionName = selectedWindow?.sessionName,
            let tabs = sessionFileTabsStates[sessionName] {
            return splitSignal(from: tabs)
        }
        if let remote = selectedRemoteSession {
            let key = remoteTabsKey(hostId: remote.hostId, sessionName: remote.sessionName)
            guard let tabs = remoteSessionTabsStates[key] else { return nil }
            return splitSignal(from: tabs)
        }
        return nil
    }

    private func splitSignal(from tabs: SessionFileTabsState) -> SplitSignal {
        let rightWindowId: String? = {
            if case let .window(id) = tabs.selectedRight { return id }
            return nil
        }()
        return SplitSignal(
            isSplit: tabs.isSplit,
            splitRatio: tabs.splitRatio,
            rightWindowId: rightWindowId
        )
    }

    /// Equatable bundle of split-view state used to drive `.onChange(of:)`.
    private struct SplitSignal: Equatable {
        let isSplit: Bool
        let splitRatio: CGFloat
        /// Right-pane terminal window id, when one is parked there. Included
        /// in the signal so swapping the right pane between two terminals
        /// also re-triggers auto-resize.
        let rightWindowId: String?
    }

    private func createNewSession(project: AgentProject?) {
        guard creatingSelection == nil else { return }
        creatingSelection = project.map { .project($0.id) } ?? .newTerminal

        Task {
            do {
                // Determine session name and working directory
                let sessionName = project?.name ?? "terminal"
                let workingDirectory = project?.path ?? FileManager.default.homeDirectoryForCurrentUser.path()

                // Resolve the launch command from the project's owning plugin core
                // (`commandForLaunch`, gated on the plugin's auto-run setting). A
                // nil runCommand means "open in a bare shell".
                let launch = if let project {
                    await coordinator.resolveLaunch(forPluginID: project.pluginID, projectPath: project.path)
                } else {
                    (runCommand: String?.none, extraEnvironment: [String]())
                }
                let runCommand = launch.runCommand

                var extraEnvironment: [String] = []
                if let configDir = project?.configDir {
                    extraEnvironment.append("CLAUDE_CONFIG_DIR=\(configDir)")
                }
                extraEnvironment.append(contentsOf: launch.extraEnvironment)

                // Calculate optimal dimensions based on available space
                let dimensions = calculateOptimalTerminalDimensions()

                // Create the session with calculated dimensions; name the first
                // window after the launch command's binary (or "terminal 1" for a
                // bare shell). Take the first token + its last path component so a
                // full path with args ("/usr/bin/claude --foo") shows as "claude".
                let firstWindowName: String = if let runCommand {
                    URL(fileURLWithPath: runCommand.split(separator: " ").first.map(String.init) ?? runCommand)
                        .lastPathComponent
                } else {
                    "terminal 1"
                }
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: sessionName,
                    width: dimensions.columns,
                    height: dimensions.rows,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand,
                    extraEnvironment: extraEnvironment,
                    firstWindowName: firstWindowName
                )

                // Find the window containing the new pane and select it.
                // Clearing the remote selection mirrors createRemoteSession's
                // own "clear the other side" step — without it, the sidebar's
                // local-row highlight stays suppressed (see the listRowBackground
                // check in sessionButton) whenever a remote session was the
                // last thing the user interacted with, even after that remote
                // session was closed.
                if let newWindow = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == paneId } }) {
                    selectedRemoteSession = nil
                    selectedRemoteWindowId = nil
                    selectedWindow = newWindow
                }
            } catch {
                attachError = "Failed to create session: \(error.localizedDescription)"
            }

            creatingSelection = nil
        }
    }

    // MARK: - Remote Session Creation

    private func createRemoteSession(on host: PairedHost, inProject project: AgentProject?) async {
        guard creatingSelection == nil else { return }

        creatingSelection = project.map { .project($0.id) } ?? .newTerminal

        let sessionName = project?.name ?? "terminal"
        let dimensions = calculateOptimalTerminalDimensions()

        let command = CreateTmuxSession(
            sessionName: sessionName,
            width: dimensions.columns,
            height: dimensions.rows,
            workingDirectory: project?.path,
            configDir: project?.configDir,
            pluginID: project?.pluginID ?? "claude-code"
        )

        guard let manager = coordinator.viewerConnectionManager else {
            attachError = "Viewer connection not available"
            creatingSelection = nil
            return
        }

        let result = await manager.sendCommand(command, paneId: "", hostId: host.id)

        switch result {
        case let .success(response):
            creatingSelection = nil

            // Request a refresh to update the remote session list
            await manager.requestSessionState(for: host.id)

            // Select the new remote session if we got a pane ID
            if
                let paneId = response.paneId,
                let paneState = coordinator.remoteSessionStore?.paneState(for: paneId, hostId: host.id) {
                selectedRemoteSession = RemoteSessionSelection(
                    hostId: host.id,
                    hostName: host.displayName,
                    sessionName: paneState.sessionName
                )
                selectedRemoteWindowId = paneState.windowId
                selectedWindow = nil
            }
        case let .failure(error):
            let projectContext = project?.name ?? "terminal"
            attachError = "Failed to create \(projectContext) on \(host.displayName): \(error.localizedDescription)"
            creatingSelection = nil
        }
    }
}

/// Typed dictionary key for `remoteSessionTabsStates`. Stores the host id and
/// session name as separate fields so a session name that contains a colon
/// can't collide with another `(hostId, sessionName)` pair (tmux allows
/// colons in session names).
struct RemoteSessionTabsKey: Hashable {
    let hostId: String
    let sessionName: String
}

/// Cached GitWorkbench store for a session's Git tab (issue #258), paired with
/// the repository directory it was created for. `MainView` rebuilds the entry
/// when the active window's working directory changes so the Git tab always
/// reflects the same folder as the file explorer.
struct GitStoreEntry {
    let path: String
    let store: GitWorkbenchStore
}
