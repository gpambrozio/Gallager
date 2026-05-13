import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
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
    @State private var projects: [ClaudeProjectInfo] = []
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
    /// Last dimensions sent via auto-resize, used to skip redundant calls during window drag
    @State private var lastAutoResizeDimensions: (columns: Int, rows: Int)?
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
    /// Cached browser-tab strip per remote session (keyed by
    /// `"\(hostId):\(sessionName)"`). Mirrors `sessionFileTabsStates` for
    /// remote sessions — but only the browser-tab fields are used today since
    /// remote file browsing isn't implemented. Keeping the same type avoids a
    /// parallel data structure for what is, semantically, the same state.
    @State private var remoteSessionTabsStates: [String: SessionFileTabsState] = [:]

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
        .onChange(of: settings.additionalClaudeFolders) {
            Task { await loadProjects() }
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

            // Clean up session-scoped state for sessions that no longer exist
            let currentSessionNames = Set(tmuxService.sessions.map(\.sessionName))
            for key in fileBrowserStates.keys where !currentSessionNames.contains(key) {
                fileBrowserStates.removeValue(forKey: key)
            }
            for key in sessionFileTabsStates.keys where !currentSessionNames.contains(key) {
                sessionFileTabsStates.removeValue(forKey: key)
            }

            // Clear pending markdown-open suggestions for removed sessions.
            for sessionName in markdownOpenSuggestionStore.suggestionsBySession.keys
                where !currentSessionNames.contains(sessionName) {
                markdownOpenSuggestionStore.sessionRemoved(sessionName: sessionName)
            }

            guard let selected = selectedWindow else { return }
            let currentWindows = tmuxService.windows
            if let updated = currentWindows.first(where: { $0.id == selected.id }) {
                // Follow the tmux-active window if it changed to a different window
                // (e.g., a remote viewer switched tabs via select-window)
                let sessionWindows = currentWindows.filter { $0.sessionName == selected.sessionName }
                if
                    !updated.isWindowActive,
                    let activeWindow = sessionWindows.first(where: \.isWindowActive) {
                    selectedWindow = activeWindow
                } else if updated != selected {
                    // Keep selection in sync with refreshed window data
                    selectedWindow = updated
                }
            } else {
                // Selected window was removed — prefer the tmux-active window in the same session
                let sessionWindows = currentWindows.filter { $0.sessionName == selected.sessionName }
                let fallback = sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first
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
        .onChange(of: settings.pairedHosts.map(\.id)) { _, currentHostIds in
            // Drop browser-tab state for hosts that are no longer paired so
            // the live `WKWebView` instances in `browserStates` aren't held
            // forever. Session-level cleanup (sessions deleted on a still-
            // paired host) is left to host-level cleanup; in practice an
            // empty session goes away when the user reconnects without it.
            let currentHostIdsSet = Set(currentHostIds)
            for key in remoteSessionTabsStates.keys {
                // Keys are `"\(hostId):\(sessionName)"`, so the hostId is
                // everything before the first colon. Safe because
                // `PairedHost.id` is UUID-formatted (hex + hyphens, no colons);
                // if that ever changes this split needs to change too.
                let hostId = String(key.split(separator: ":", maxSplits: 1).first ?? "")
                if !currentHostIdsSet.contains(hostId) {
                    remoteSessionTabsStates.removeValue(forKey: key)
                }
            }
        }
        .onChange(of: settings.alwaysAutoResize) {
            // When the global auto-resize setting changes, clear per-session opt-outs, reset cached dimensions and re-evaluate resize
            autoResizeDisabled.removeAll()
            lastAutoResizeDimensions = nil
            handleAutoResize()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            markSelectedSessionsHandledIfActive()
        }
        .focusedSceneValue(\.closeCurrentTabAction, handleCloseCurrentTab)
        .modifier(MenuCommandsModifier(
            onOpenContentSearch: { handleOpenContentSearch() }
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
            SectionHeader(title: "Local", symbol: .house) {
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
        let claudeSession: ClaudeSession? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.claudeSession }
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

        return SessionSortData(
            sessionName: session.sessionName,
            primaryLabel: primaryLabel,
            hasClaude: claudeSession != nil,
            statusPriority: SessionSortData.statusPriority(for: claudeSession),
            statusPriorityIdleFirst: SessionSortData.statusPriorityIdleFirst(for: claudeSession),
            latestEventTimestamp: claudeSession?.latestEvent?.timestamp
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
        let claudePane = session.windows.flatMap(\.panes).first { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
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
            // Select the session's active window
            if let activeWindow {
                selectedWindow = activeWindow
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
                                await performResize(localTarget: activePane.target)
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
                                    await performResize(localTarget: activePane.target)
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

    /// The currently selected remote window, resolved from session store
    private var selectedRemoteWindow: TmuxWindow? {
        guard
            let remote = selectedRemoteSession,
            let sessionStore = coordinator.remoteSessionStore else { return nil }
        let windows = sessionStore.windows(for: remote.hostId)
            .filter { $0.sessionName == remote.sessionName }
            .sorted { $0.windowIndex < $1.windowIndex }
        if
            let windowId = selectedRemoteWindowId,
            let window = windows.first(where: { $0.id == windowId }) {
            // Follow the tmux-active window if it changed (e.g., host switched tabs)
            if !window.isWindowActive, let activeWindow = windows.first(where: \.isWindowActive) {
                return activeWindow
            }
            return window
        }
        return windows.first(where: \.isWindowActive) ?? windows.first
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
                    onSelectWindow: { newWindow in
                        selectedRemoteWindowId = newWindow.id
                        // Switching back to a tmux window deselects any active
                        // browser tab so the terminal pane is rendered again
                        // even when a browser tab was previously focused.
                        remoteSessionTabsStates[tabsKey]?.selectedBrowserTabId = nil
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
                    }
                )

                remoteDetailBody(
                    remote: remote,
                    connection: connection,
                    window: window,
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
            let isAnyFileViewActive = isFileBrowserActive || selectedFileTab != nil || selectedBrowserTab != nil
            VStack(spacing: 0) {
                if let session {
                    WindowTabBar(
                        session: session,
                        selectedWindow: window,
                        isFileBrowserSelected: isFileBrowserActive && selectedFileTab == nil && selectedBrowserTab == nil,
                        isAnyFileViewActive: isAnyFileViewActive,
                        sessionTabs: sessionTabs,
                        onSelectWindow: { newWindow in
                            fileBrowserActiveWindowIds.remove(window.id)
                            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
                            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
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
                        onRenameWindow: { windowToRename, newName in
                            Task {
                                try? await tmuxService.renameWindow(target: windowToRename.id, name: newName)
                                _ = await tmuxService.refreshPanes()
                                await coordinator.connectedViewerManager?.pushSessionStateToAll()
                            }
                        },
                        onSelectFileBrowser: {
                            fileBrowserActiveWindowIds.insert(window.id)
                            if fileBrowserStates[session.sessionName] == nil {
                                fileBrowserStates[session.sessionName] = FileBrowserState()
                            }
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
                            sessionFileTabsStates[session.sessionName]?.selectedBrowserTabId = nil
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
                        onToggleFileTabSplit: { tabId in
                            toggleFileTabSplit(tabId, sessionName: session.sessionName, windowId: window.id)
                        },
                        onToggleBrowserTabSplit: { tabId in
                            toggleBrowserTabSplit(tabId, sessionName: session.sessionName, windowId: window.id)
                        },
                        onShowInFileExplorer: { path in
                            fileBrowserActiveWindowIds.insert(window.id)
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
                        }
                    )
                }

                detailContentArea(
                    window: window,
                    session: session,
                    directoryPath: directoryPath,
                    isFileBrowserActive: isFileBrowserActive,
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

    /// Renders the body of a remote session's detail pane: either the live
    /// in-app browser tab content (when one is selected) or the remote tmux
    /// pane layout. Web links clicked in the remote terminal flow through
    /// `handleRemoteTerminalURLClick` so the per-domain rules and
    /// `browserLinkBehavior` prompt apply identically to local sessions.
    @ViewBuilder
    private func remoteDetailBody(
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
                        browserState: browserState,
                        sessionTabs: sessionTabs,
                        selectedBrowserTab: selectedBrowserTab
                    )
                },
                right: {
                    rightPaneContent(
                        sessionName: session.sessionName,
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

    /// Renders the right pane of the split layout. Shows a browser tab content
    /// view when a right-side browser tab is selected, otherwise the selected
    /// file tab's contents, otherwise a placeholder.
    @ViewBuilder
    private func rightPaneContent(
        sessionName: String,
        sessionTabs: SessionFileTabsState
    ) -> some View {
        let selectedRightBrowserTab: BrowserTab? = {
            guard let id = sessionTabs.selectedRightBrowserTabId else { return nil }
            return sessionTabs.openBrowserTabs.first(where: { $0.id == id })
        }()
        let selectedRightFileTab: OpenFileTab? = {
            guard let id = sessionTabs.selectedRightFileTabId else { return nil }
            return sessionTabs.openFileTabs.first(where: { $0.id == id })
        }()
        if
            let selectedRightBrowserTab,
            let browserTabState = sessionTabs.browserStates[selectedRightBrowserTab.id] {
            BrowserTabContentView(
                state: browserTabState,
                onTitleChange: { newTitle in
                    updateBrowserTabTitle(
                        tabId: selectedRightBrowserTab.id,
                        sessionName: sessionName,
                        title: newTitle
                    )
                },
                onURLChange: { newURL in
                    updateBrowserTabURL(
                        tabId: selectedRightBrowserTab.id,
                        sessionName: sessionName,
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            connectionStatusView
        }

        // Actions for selected window
        ToolbarItemGroup(placement: .primaryAction) {
            if let window = selectedWindow, selectedRemoteSession == nil {
                let claudePane = window.panes.first { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
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
                    .help("Open session in terminal app")

                    resizeToolbarGroup(
                        resizeKey: activePane.paneId,
                        localTarget: activePane.target,
                        isSessionAttached: tmuxService.attachedSessionNames.contains(window.sessionName)
                    )
                }

                Button {
                    requestCloseSession(window.sessionName)
                } label: {
                    Symbols.xmark.image
                }
                .help("Close session")
            } else if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow {
                // Yolo mode toggle for remote windows with active Claude sessions
                let claudePaneId = remoteWindow.panes.first(where: { $0.claudeSession != nil })?.paneId
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
                .help("Close session")
            }

            Button {
                Task {
                    await refreshPanes()
                }
            } label: {
                Symbols.arrowClockwise.image
            }
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
        remoteHostId: String? = nil,
        remotePaneId: String? = nil,
        isSessionAttached: Bool = false
    ) -> some View {
        let attachedHelp = "Cannot resize: session is attached to a terminal"
        let autoResizeActive = isAutoResizeActive(for: resizeKey)

        // Hide manual resize button when auto-resize is active
        if !autoResizeActive {
            Button {
                Task {
                    await performResize(localTarget: localTarget, remoteHostId: remoteHostId, remotePaneId: remotePaneId)
                }
            } label: {
                Symbols.arrowUpLeftAndArrowDownRight.image
            }
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
                        await performResize(localTarget: localTarget, remoteHostId: remoteHostId, remotePaneId: remotePaneId)
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
        lastAutoResizeDimensions = nil
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

        autoResizeTask = Task {
            // Debounce: wait for layout to stabilize (especially during session switches)
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let dimensions = calculateOptimalTerminalDimensions()

            // Skip if dimensions unchanged (cell-size rounding eliminates most redundant calls during drag)
            if
                let last = lastAutoResizeDimensions,
                last.columns == dimensions.columns && last.rows == dimensions.rows {
                return
            }

            if let window = currentWindow, let activePane = window.activePane, currentRemote == nil {
                guard isAutoResizeActive(for: activePane.paneId) else { return }
                guard !tmuxService.attachedSessionNames.contains(window.sessionName) else { return }
                await performResize(localTarget: activePane.target)
            } else if let remote = currentRemote, let activePane = currentRemoteWindow?.activePane {
                let resizeKey = remote.resizeKey(paneId: activePane.paneId)
                guard isAutoResizeActive(for: resizeKey) else { return }
                await performResize(remoteHostId: remote.hostId, remotePaneId: activePane.paneId)
            }
        }
    }

    private func performResize(
        localTarget: String? = nil,
        remoteHostId: String? = nil,
        remotePaneId: String? = nil
    ) async {
        let dimensions = calculateOptimalTerminalDimensions()
        lastAutoResizeDimensions = dimensions

        if let localTarget {
            do {
                try await tmuxService.resizePane(localTarget, width: dimensions.columns, height: dimensions.rows)
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
            if case let .failure(error) = result {
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
                where windowManager.paneStates[pane.paneId]?.claudeSession?.needsAttention == true {
                windowManager.markSessionHandled(paneId: pane.paneId)
                stateChanged = true
            }
            if stateChanged {
                Task {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                }
            }
        }

        if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow {
            for pane in remoteWindow.panes where pane.claudeSession?.needsAttention == true {
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
        // The file browser tab itself has no close action — do nothing.
        guard !fileBrowserActiveWindowIds.contains(window.id) else { return }
        requestCloseWindow(window)
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
            if tabs.rightSideFileTabIds.contains(existingId) {
                tabs.selectedRightFileTabId = existingId
                tabs.selectedRightBrowserTabId = nil
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
            tabs.rightSideFileTabIds.insert(newTab.id)
            tabs.selectedRightFileTabId = newTab.id
            tabs.selectedRightBrowserTabId = nil
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
        fileBrowserActiveWindowIds.insert(windowId)
        if tabs.rightSideFileTabIds.contains(tabId) {
            tabs.selectedRightFileTabId = tabId
            tabs.selectedRightBrowserTabId = nil
            return
        }
        tabs.selectedFileTabId = tabId
        tabs.selectedBrowserTabId = nil
    }

    /// Toggles which side of the split a file tab lives on (issue #498). The
    /// receiving side becomes the tab's selected entry; the originating side
    /// has its selection reset if it pointed at the moved tab. After every
    /// move `reconcileRightPaneSelection` re-picks a right-pane selection so
    /// the right pane doesn't show the empty placeholder while real tabs are
    /// still over there.
    private func toggleFileTabSplit(_ tabId: UUID, sessionName: String, windowId: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard tabs.openFileTabs.contains(where: { $0.id == tabId }) else { return }
        if tabs.rightSideFileTabIds.contains(tabId) {
            tabs.rightSideFileTabIds.remove(tabId)
            if tabs.selectedRightFileTabId == tabId {
                tabs.selectedRightFileTabId = nil
            }
            // Receiving side becomes this tab.
            fileBrowserActiveWindowIds.insert(windowId)
            tabs.selectedFileTabId = tabId
            tabs.selectedBrowserTabId = nil
        } else {
            tabs.rightSideFileTabIds.insert(tabId)
            if tabs.selectedFileTabId == tabId {
                tabs.selectedFileTabId = nil
            }
            tabs.selectedRightFileTabId = tabId
            tabs.selectedRightBrowserTabId = nil
        }
        reconcileRightPaneSelection(sessionName: sessionName)
    }

    /// Toggles which side of the split a browser tab lives on (issue #498).
    /// Mirrors `toggleFileTabSplit`.
    private func toggleBrowserTabSplit(_ tabId: UUID, sessionName: String, windowId: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard tabs.openBrowserTabs.contains(where: { $0.id == tabId }) else { return }
        if tabs.rightSideBrowserTabIds.contains(tabId) {
            tabs.rightSideBrowserTabIds.remove(tabId)
            if tabs.selectedRightBrowserTabId == tabId {
                tabs.selectedRightBrowserTabId = nil
            }
            tabs.selectedBrowserTabId = tabId
            tabs.selectedFileTabId = nil
            fileBrowserActiveWindowIds.remove(windowId)
        } else {
            tabs.rightSideBrowserTabIds.insert(tabId)
            if tabs.selectedBrowserTabId == tabId {
                tabs.selectedBrowserTabId = nil
            }
            tabs.selectedRightBrowserTabId = tabId
            tabs.selectedRightFileTabId = nil
        }
        reconcileRightPaneSelection(sessionName: sessionName)
    }

    /// Keeps the right pane's selection coherent with the tabs still on that
    /// side. Clears dangling selections, then auto-picks a tab on the right
    /// when nothing is selected but at least one tab remains there. Prefers
    /// the most recently appended file tab and falls back to the most
    /// recently appended browser tab — the goal is to avoid the "No Tab
    /// Selected" placeholder whenever a real tab could fill the pane.
    private func reconcileRightPaneSelection(sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if let id = tabs.selectedRightFileTabId, !tabs.rightSideFileTabIds.contains(id) {
            tabs.selectedRightFileTabId = nil
        }
        if let id = tabs.selectedRightBrowserTabId, !tabs.rightSideBrowserTabIds.contains(id) {
            tabs.selectedRightBrowserTabId = nil
        }
        guard tabs.isSplit else { return }
        if tabs.selectedRightFileTabId != nil || tabs.selectedRightBrowserTabId != nil {
            return
        }
        if let fileTab = tabs.openFileTabs.last(where: { tabs.rightSideFileTabIds.contains($0.id) }) {
            tabs.selectedRightFileTabId = fileTab.id
        } else if let browserTab = tabs.openBrowserTabs.last(where: { tabs.rightSideBrowserTabIds.contains($0.id) }) {
            tabs.selectedRightBrowserTabId = browserTab.id
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
                windowId: windowId,
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
        originWindowId: String? = nil
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
            if tabs.rightSideBrowserTabIds.contains(existingId) {
                tabs.selectedRightBrowserTabId = existingId
                tabs.selectedRightFileTabId = nil
            } else {
                tabs.selectedBrowserTabId = existingId
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
            }
        } else {
            let newTab = BrowserTab(url: url, originWindowId: originWindowId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            if useSplit {
                tabs.rightSideBrowserTabIds.insert(newTab.id)
                tabs.selectedRightBrowserTabId = newTab.id
                tabs.selectedRightFileTabId = nil
            } else {
                tabs.selectedBrowserTabId = newTab.id
                tabs.selectedFileTabId = nil
                fileBrowserActiveWindowIds.remove(windowId)
            }
        }
    }

    /// Selects an existing browser tab and ensures the file tree/file tab views
    /// don't render alongside it.
    private func selectBrowserTab(_ tabId: UUID, sessionName: String, windowId: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        if tabs.rightSideBrowserTabIds.contains(tabId) {
            tabs.selectedRightBrowserTabId = tabId
            tabs.selectedRightFileTabId = nil
            return
        }
        tabs.selectedBrowserTabId = tabId
        tabs.selectedFileTabId = nil
        fileBrowserActiveWindowIds.remove(windowId)
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
    /// becomes selected again — mirroring the file-tab close flow.
    private func closeBrowserTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let wasOnRight = tabs.rightSideBrowserTabIds.contains(tabId)
        let wasSelectedLeft = tabs.selectedBrowserTabId == tabId
        let wasSelectedRight = tabs.selectedRightBrowserTabId == tabId
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.browserStates.removeValue(forKey: tabId)
        tabs.rightSideBrowserTabIds.remove(tabId)
        if wasSelectedRight {
            tabs.selectedRightBrowserTabId = nil
        }
        reconcileRightPaneSelection(sessionName: sessionName)
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

    /// Composite key into `remoteSessionTabsStates` for `(hostId, sessionName)`.
    /// Two paired hosts can have a session with the same name, so the hostId
    /// has to participate in the key — keying on `sessionName` alone would
    /// collide their tab strips.
    private func remoteTabsKey(hostId: String, sessionName: String) -> String {
        "\(hostId):\(sessionName)"
    }

    /// Opens (or re-selects) a browser tab inside a remote session's tab
    /// strip. Mirrors `openBrowserTab` for local sessions but reads/writes
    /// `remoteSessionTabsStates`.
    private func openRemoteBrowserTab(
        url: URL,
        hostId: String,
        sessionName: String,
        windowId: String,
        originWindowId: String? = nil
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
            let newTab = BrowserTab(url: url, originWindowId: originWindowId)
            tabs.openBrowserTabs.append(newTab)
            tabs.browserStates[newTab.id] = BrowserTabState(initialURL: url)
            tabs.selectedBrowserTabId = newTab.id
        }
    }

    /// Selects an existing browser tab in a remote session's tab strip.
    private func selectRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
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
    /// behaviour as `closeBrowserTab` for local tabs.
    private func closeRemoteBrowserTab(
        _ tabId: UUID,
        hostId: String,
        sessionName: String
    ) {
        let key = remoteTabsKey(hostId: hostId, sessionName: sessionName)
        guard let tabs = remoteSessionTabsStates[key] else { return }
        guard let closedIndex = tabs.openBrowserTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openBrowserTabs[closedIndex]
        let wasSelected = tabs.selectedBrowserTabId == tabId
        tabs.openBrowserTabs.remove(at: closedIndex)
        tabs.browserStates.removeValue(forKey: tabId)
        guard wasSelected else { return }
        tabs.selectedBrowserTabId = nil
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
                    windowId: prompt.windowId,
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
        let wasOnRight = tabs.rightSideFileTabIds.contains(tabId)
        let wasSelectedLeft = tabs.selectedFileTabId == tabId
        let wasSelectedRight = tabs.selectedRightFileTabId == tabId
        tabs.openFileTabs.remove(at: closedIndex)
        tabs.scrollOffsets.removeValue(forKey: tabId)
        tabs.rightSideFileTabIds.remove(tabId)
        if wasSelectedRight {
            tabs.selectedRightFileTabId = nil
        }
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
    /// - Returns: A tuple of (columns, rows) for the terminal dimensions
    private func calculateOptimalTerminalDimensions() -> (columns: Int, rows: Int) {
        // Guard against uninitialized or invalid size
        guard detailPaneSize.width >= 100, detailPaneSize.height >= 100 else {
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
        let availableWidth = max(0, detailPaneSize.width - horizontalPadding)
        let availableHeight = max(0, detailPaneSize.height - verticalPadding)

        // Apply reasonable bounds
        // Minimum: 80x24 (standard terminal size)
        // Maximum: 300x100 (prevent unreasonably large terminals)
        let columns = max(80, min(300, Int(availableWidth / cellSize.width)))
        let rows = max(24, min(100, Int(availableHeight / cellSize.height)))

        return (columns, rows)
    }

    private func createNewSession(project: ClaudeProjectInfo?) {
        guard creatingSelection == nil else { return }
        creatingSelection = project.map { .project($0.id) } ?? .newTerminal

        Task {
            do {
                // Determine session name and working directory
                let sessionName = project?.name ?? "terminal"
                let workingDirectory = project?.path ?? FileManager.default.homeDirectoryForCurrentUser.path()

                // Determine if we should run the claude command (only for project sessions)
                let runCommand: String? = if project != nil && settings.autoRunClaudeInProjects {
                    settings.claudeCommandPath
                } else {
                    nil
                }

                let extraEnvironment: [String] = if let configDir = project?.claudeConfigDir {
                    ["CLAUDE_CONFIG_DIR=\(configDir)"]
                } else {
                    []
                }

                // Calculate optimal dimensions based on available space
                let dimensions = calculateOptimalTerminalDimensions()

                // Create the session with calculated dimensions
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: sessionName,
                    width: dimensions.columns,
                    height: dimensions.rows,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand,
                    extraEnvironment: extraEnvironment,
                    isClaudeProject: project != nil
                )

                // Find the window containing the new pane and select it
                if let newWindow = tmuxService.windows.first(where: { $0.panes.contains { $0.paneId == paneId } }) {
                    selectedWindow = newWindow
                }
            } catch {
                attachError = "Failed to create session: \(error.localizedDescription)"
            }

            creatingSelection = nil
        }
    }

    // MARK: - Remote Session Creation

    private func createRemoteSession(on host: PairedHost, inProject project: ClaudeProjectInfo?) async {
        guard creatingSelection == nil else { return }

        creatingSelection = project.map { .project($0.id) } ?? .newTerminal

        let sessionName = project?.name ?? "terminal"
        let dimensions = calculateOptimalTerminalDimensions()

        let command = CreateTmuxSession(
            sessionName: sessionName,
            width: dimensions.columns,
            height: dimensions.rows,
            workingDirectory: project?.path,
            claudeConfigDir: project?.claudeConfigDir
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
