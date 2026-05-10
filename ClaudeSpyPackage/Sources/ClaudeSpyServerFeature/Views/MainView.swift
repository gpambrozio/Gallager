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

    /// File path for which the "Open in Editor" picker is currently shown
    /// (triggered by Cmd+E on a focused file tab).
    @State private var editorPickerPath: String?

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
        .onChange(of: selectedWindow) {
            // Reset cached dimensions and trigger auto-resize for the newly selected window
            lastAutoResizeDimensions = nil
            handleAutoResize()

            markSelectedSessionsHandledIfActive()
        }
        .onChange(of: selectedRemoteSession) {
            lastAutoResizeDimensions = nil
            handleAutoResize()

            markSelectedSessionsHandledIfActive()
        }
        .onChange(of: selectedRemoteWindowId) {
            lastAutoResizeDimensions = nil
            handleAutoResize()

            markSelectedSessionsHandledIfActive()
        }
        .onChange(of: selectedRemoteWindow?.id) {
            // Keep selectedRemoteWindowId in sync when the computed property
            // resolves to a different window (e.g., selected window removed,
            // or tmux-active window changed by the host).
            if let resolvedId = selectedRemoteWindow?.id, resolvedId != selectedRemoteWindowId {
                selectedRemoteWindowId = resolvedId
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
        .onReceive(NotificationCenter.default.publisher(for: .closeCurrentTab)) { _ in
            // Close remote tab if a remote session is selected
            if
                let remote = selectedRemoteSession,
                let remoteWindow = selectedRemoteWindow {
                requestCloseRemoteWindow(remoteWindow, hostId: remote.hostId)
                return
            }
            guard let window = selectedWindow else { return }
            let sessionName = tmuxService.sessions
                .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
                .sessionName
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
            // string `accessibilityValue`. `accessibilityChildren` declares
            // an extra AX-only child that sits outside that merge so e2e
            // queries (and VoiceOver) can read `Terminal progress` + `60%`
            // regardless of the row's working status.
            if let sessionProgress {
                Text("Terminal progress")
                    .accessibilityLabel("Terminal progress")
                    .accessibilityValue(sessionProgress.accessibilityValueString)
            }
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
            VStack(spacing: 0) {
                RemoteWindowTabBar(
                    windows: windows,
                    selectedWindow: window,
                    isHostConnected: connection.isHostConnected,
                    onSelectWindow: { newWindow in
                        selectedRemoteWindowId = newWindow.id
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
                    }
                )

                RemoteWindowPaneLayoutView(
                    window: window,
                    connection: connection,
                    settings: settings
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
            let isFileBrowserActive = fileBrowserActiveWindowIds.contains(window.id)
            let isAnyFileViewActive = isFileBrowserActive || selectedFileTab != nil
            VStack(spacing: 0) {
                if let session {
                    WindowTabBar(
                        session: session,
                        selectedWindow: window,
                        isFileBrowserSelected: isFileBrowserActive && selectedFileTab == nil,
                        isAnyFileViewActive: isAnyFileViewActive,
                        openFileTabs: sessionTabs?.openFileTabs ?? [],
                        selectedFileTabId: sessionTabs?.selectedFileTabId,
                        onSelectWindow: { newWindow in
                            fileBrowserActiveWindowIds.remove(window.id)
                            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = nil
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
                        },
                        onSelectFileTab: { tabId in
                            // Ensure FileBrowserView is mounted for the current
                            // window so its tree-scan tasks keep refreshing
                            // tab deletion state while the file tab is the
                            // active view.
                            fileBrowserActiveWindowIds.insert(window.id)
                            if fileBrowserStates[session.sessionName] == nil {
                                fileBrowserStates[session.sessionName] = FileBrowserState()
                            }
                            if sessionFileTabsStates[session.sessionName] == nil {
                                sessionFileTabsStates[session.sessionName] = SessionFileTabsState()
                            }
                            sessionFileTabsStates[session.sessionName]?.selectedFileTabId = tabId
                        },
                        onCloseFileTab: { tabId in
                            closeOpenFileTab(tabId, sessionName: session.sessionName)
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

                if
                    isFileBrowserActive,
                    let browserState,
                    let session,
                    let sessionTabs = sessionFileTabsStates[session.sessionName] {
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
        if let existingIndex = tabs.openFileTabs.firstIndex(where: { $0.path == path }) {
            if let originWindowId {
                tabs.openFileTabs[existingIndex].originWindowId = originWindowId
            }
            tabs.selectedFileTabId = tabs.openFileTabs[existingIndex].id
            return
        }
        let newTab = OpenFileTab(
            path: path,
            directoryPath: directoryPath,
            originWindowId: originWindowId
        )
        tabs.openFileTabs.append(newTab)
        tabs.selectedFileTabId = newTab.id
    }

    /// Routes a URL clicked in the terminal. When `openClickedFileInNewTab` is
    /// enabled and the URL is a `file://` link, the file is opened as a new tab
    /// next to the file browser. Returns `true` in that case so the caller
    /// knows not to fall back to `NSWorkspace.shared.open`. Non-file URLs and
    /// clicks made while the setting is off return `false` so the system
    /// browser handles them as before.
    private func handleTerminalURLClick(
        _ url: URL,
        directoryPath: String,
        session: LocalTmuxSession?,
        window: LocalTmuxWindow
    ) -> Bool {
        guard
            settings.openClickedFileInNewTab,
            url.isFileURL,
            let session
        else {
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
    /// Resolves the path of the currently-selected file tab and stores it in
    /// `editorPickerPath` so the Cmd+E confirmation dialog presents the editor
    /// list. No-op when no file tab is focused.
    private func handleOpenCurrentTabInEditor() {
        guard let window = selectedWindow else { return }
        guard
            let sessionName = tmuxService.sessions
                .first(where: { $0.windows.contains(where: { $0.id == window.id }) })?
                .sessionName
        else { return }
        guard
            let tabs = sessionFileTabsStates[sessionName],
            let selectedId = tabs.selectedFileTabId,
            let tab = tabs.openFileTabs.first(where: { $0.id == selectedId })
        else { return }
        editorPickerPath = tab.path
    }

    private func closeOpenFileTab(_ tabId: UUID, sessionName: String) {
        guard let tabs = sessionFileTabsStates[sessionName] else { return }
        guard let closedIndex = tabs.openFileTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = tabs.openFileTabs[closedIndex]
        let wasSelected = tabs.selectedFileTabId == tabId
        tabs.openFileTabs.remove(at: closedIndex)
        tabs.scrollOffsets.removeValue(forKey: tabId)
        guard wasSelected else { return }
        tabs.selectedFileTabId = nil

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

// MARK: - Section Header

/// A prominent section header with icon and title, optionally showing a "+" button with popover and trailing content
private struct SectionHeader<Trailing: View, Popover: View>: View {
    let title: String
    let symbol: Symbols
    var isNewSessionDisabled: Bool
    let trailing: Trailing
    let popover: Popover
    let hasPopover: Bool

    @State private var showingPopover = false

    var body: some View {
        HStack(spacing: 6) {
            symbol.image
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))

            if hasPopover || !(trailing is EmptyView) {
                Spacer()
            }

            if hasPopover {
                Button {
                    showingPopover = true
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isNewSessionDisabled)
                .accessibilityLabel("Create new session")
                .help("Create new session")
                .popover(isPresented: $showingPopover) {
                    popover
                }
            }

            trailing
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 8)
    }
}

// Convenience: no popover, no trailing
extension SectionHeader where Trailing == EmptyView, Popover == EmptyView {
    init(title: String, symbol: Symbols) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = false
        self.trailing = EmptyView()
        self.popover = EmptyView()
        self.hasPopover = false
    }
}

// Convenience: popover only, no trailing
extension SectionHeader where Trailing == EmptyView {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = EmptyView()
        self.popover = popover()
        self.hasPopover = true
    }
}

// Convenience: popover + trailing
extension SectionHeader {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = trailing()
        self.popover = popover()
        self.hasPopover = true
    }
}

// MARK: - Sidebar Row

/// A row displaying a tmux session in the sidebar
private struct SessionSidebarRow: View {
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings

    let session: LocalTmuxSession

    /// Progress state for this session, picked from the first pane that has
    /// one. Same iteration shape as the Mac-as-viewer (`RemoteSessionSidebarRow`)
    /// and iOS (`SessionListView.sessionRow`) sites so all three render the
    /// same pane's progress when multiple panes are emitting at once.
    /// Recomputed on each render — observation tracks `windowManager.paneStates`
    /// and re-renders this row only when the lookup result actually changes.
    private var sessionProgress: TerminalProgressState? {
        session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.progress }
            .first
    }

    /// The active window (or first)
    private var activeWindow: LocalTmuxWindow? {
        session.activeWindow
    }

    /// The primary pane to show info for (active pane or first pane in active window)
    private var primaryPane: PaneInfo? {
        activeWindow?.activePane
    }

    private var primaryPaneState: PaneState? {
        guard let pane = primaryPane else { return nil }
        return windowManager.paneStates[pane.paneId]
    }

    /// The first Claude session found in any pane of any window, if any
    private var claudeSession: ClaudeSession? {
        for window in session.windows {
            for pane in window.panes {
                if let session = windowManager.paneStates[pane.paneId]?.claudeSession {
                    return session
                }
            }
        }
        return nil
    }

    /// CLI-driven state override, if any pane in the session has one set.
    private var cliSessionState: CLISessionState? {
        for window in session.windows {
            for pane in window.panes {
                if let state = windowManager.paneStates[pane.paneId]?.cliSessionState {
                    return state
                }
            }
        }
        return nil
    }

    /// The first non-empty terminal title found across all windows
    private var terminalTitle: String? {
        for window in session.windows {
            for pane in window.panes {
                if let title = windowManager.paneStates[pane.paneId]?.terminalTitle, !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    /// The latest event subtitle from the first pane with a Claude session
    private var sessionSubtitle: String? {
        for window in session.windows {
            for pane in window.panes {
                if let subtitle = windowManager.paneStates[pane.paneId]?.claudeSession?.latestEvent?.action.subtitle {
                    return subtitle
                }
            }
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                if let cliSessionState {
                    SessionStatusIndicator(cliState: cliSessionState)
                        .font(.system(size: 16))
                } else if let claudeSession {
                    SessionStatusIndicator(session: claudeSession)
                        .font(.system(size: 16))
                } else {
                    Symbols.terminal.image
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                if let customEmoji = primaryPaneState?.customEmoji {
                    SessionEmojiBadge(emoji: customEmoji)
                        .font(.system(size: 14))
                }
            }
            .frame(width: 20)

            SessionFieldsView(
                fields: claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: primaryPaneState?.customDescription,
                projectName: claudeSession?.displayName,
                sessionName: session.sessionName,
                terminalTitle: terminalTitle,
                command: primaryPane?.command,
                currentPath: primaryPane?.currentPath,
                gitBranch: primaryPaneState?.gitBranch,
                latestEvent: sessionSubtitle
            )

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured (session name may not appear as
        // visible Text). Also expose status since ProgressView (working state) prevents AX
        // from reading .accessibilityValue directly on the indicator.
        .accessibilityValue(session.sessionName)
        .overlay {
            ZStack {
                if let status = cliSessionState?.statusLabel ?? claudeSession?.statusLabel {
                    Text(status)
                        .accessibilityLabel(status)
                }
                // The project name is rendered by SessionFieldsView, but when the row's
                // Button combines its children's AX into a single label, that leaf can
                // drop out intermittently — exposing it as its own hidden label gives
                // e2e tests a stable element to find.
                if let projectName = claudeSession?.displayName {
                    Text(projectName)
                        .accessibilityLabel(projectName)
                }
            }
            .font(.system(size: 1))
            .opacity(0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            SessionColorBar(color: primaryPaneState?.customColor)
                .padding(.leading, -16)
        }
        .overlay(alignment: .bottom) {
            if let sessionProgress {
                TerminalProgressBar(state: sessionProgress)
                    .padding(.bottom, -4)
            }
        }
    }
}

// MARK: - Window Tab Label

/// Returns the display label for a tmux window tab.
/// Shared between `WindowTabBar` (local) and `RemoteWindowTabBar` (remote).
private func windowTabLabel(windowName: String, windowIndex: Int) -> String {
    if !windowName.isEmpty {
        return windowName
    }
    return "\(windowIndex)"
}

// MARK: - Window Tab Bar

/// Horizontal tab bar showing windows in a tmux session.
/// Always visible, even for single-window sessions (with a "+" tab to create new windows).
private struct WindowTabBar: View {
    let session: LocalTmuxSession
    let selectedWindow: LocalTmuxWindow
    /// True only when the Files (tree) tab is the active view — i.e. the file browser
    /// is open and no file tab is currently selected.
    let isFileBrowserSelected: Bool
    /// True when any non-terminal view is showing (file tree OR a file tab). Used to
    /// deselect the underlying tmux window tab so it doesn't render as concurrently
    /// selected with a file view.
    let isAnyFileViewActive: Bool
    let openFileTabs: [OpenFileTab]
    let selectedFileTabId: UUID?
    let onSelectWindow: (LocalTmuxWindow) -> Void
    let onCloseWindow: (LocalTmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (LocalTmuxWindow, String) -> Void
    let onSelectFileBrowser: () -> Void
    let onSelectFileTab: (UUID) -> Void
    let onCloseFileTab: (UUID) -> Void
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

                // "+" button to create a new window
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

                // File browser tab
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

                ForEach(openFileTabs) { tab in
                    openFileTabView(tab)
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

    @State private var hoveredWindowId: String?
    @State private var hoveredFileTabId: UUID?

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id && !isAnyFileViewActive
        let isHovered = hoveredWindowId == window.id
        let hasClaude = window.panes.contains { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let windowName = tabLabel(for: window)

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

            Button {
                onCloseWindow(window)
            } label: {
                Symbols.xmark.image
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close window")
            .padding(.trailing, 6)
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
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
    }

    private func tabLabel(for window: LocalTmuxWindow) -> String {
        windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
    }

    @ViewBuilder
    private func openFileTabView(_ tab: OpenFileTab) -> some View {
        let isSelected = tab.id == selectedFileTabId
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

            Button {
                onCloseFileTab(tab.id)
            } label: {
                Symbols.xmark.image
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close tab")
            .padding(.trailing, 6)
            .accessibilityLabel("Close file tab: \(tab.name)")
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
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

// MARK: - Remote Window Tab Bar

/// Horizontal tab bar for remote session windows, mirroring `WindowTabBar` for local sessions.
private struct RemoteWindowTabBar: View {
    let windows: [TmuxWindow]
    let selectedWindow: TmuxWindow
    let isHostConnected: Bool
    let onSelectWindow: (TmuxWindow) -> Void
    let onCloseWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (TmuxWindow, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(windows) { window in
                    windowTab(window)
                }

                Button(action: onNewWindow) {
                    Symbols.plus.image
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New window")
                .accessibilityLabel("New Window")
                .disabled(!isHostConnected)

                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @State private var hoveredWindowId: String?

    private func windowTab(_ window: TmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id
        let isHovered = hoveredWindowId == window.id
        let windowName = tabLabel(for: window)

        return HStack(spacing: 0) {
            Button {
                onSelectWindow(window)
            } label: {
                HStack(spacing: 4) {
                    if window.hasClaude {
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

            Button {
                onCloseWindow(window)
            } label: {
                Symbols.xmark.image
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close window")
            .padding(.trailing, 6)
            .disabled(!isHostConnected)
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .modifier(WindowRenamingModifier(
            currentName: window.windowName,
            isDisabled: !isHostConnected,
            onRename: { newName in
                onRenameWindow(window, newName)
            }
        ))
        .onHover { hovering in
            hoveredWindowId = hovering ? window.id : nil
        }
    }

    private func tabLabel(for window: TmuxWindow) -> String {
        windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
    }
}

// MARK: - New Session

/// Tracks which item is currently being created in the new session view
private enum NewSessionCreatingState: Equatable {
    case newTerminal
    case project(String)
}

/// Unified content for creating a new session, used in popovers and the empty-state detail area
private struct NewSessionContent: View {
    let title: String
    let projects: [ClaudeProjectInfo]
    let isLoadingProjects: Bool
    let creatingSelection: NewSessionCreatingState?
    let onCreate: (ClaudeProjectInfo?) -> Void
    /// When true, constrains size for popover use. When false, expands to fill available space.
    var popover = true

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""

    private var isCreating: Bool {
        creatingSelection != nil
    }

    private var filteredProjects: [ClaudeProjectInfo] {
        guard !searchText.isEmpty else { return projects }
        return projects.filter { $0.name.fuzzyMatches(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if !isLoadingProjects && !projects.isEmpty {
                HStack(spacing: 6) {
                    Symbols.magnifyingglass.image
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    TextField("Search projects...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Search projects")
                        .onSubmit {
                            if filteredProjects.count == 1 {
                                let project = filteredProjects[0]
                                dismiss()
                                onCreate(project)
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Symbols.xmarkCircleFill.image
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onAppear {
                    isSearchFocused = true
                }
            }

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    if searchText.isEmpty {
                        NewSessionRow(
                            title: "New Terminal",
                            subtitle: "Start in home directory",
                            symbol: .terminal,
                            isCreating: creatingSelection == .newTerminal,
                            isDisabled: isCreating
                        ) {
                            dismiss()
                            onCreate(nil)
                        }
                    }

                    if isLoadingProjects {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading projects...")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else if !filteredProjects.isEmpty {
                        if searchText.isEmpty {
                            Divider()
                                .padding(.vertical, 4)

                            Text("Claude Projects")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(filteredProjects) { project in
                            NewSessionRow(
                                title: project.name,
                                subtitle: project.path.abbreviatedPath,
                                symbol: .folder,
                                isCreating: creatingSelection == .project(project.id),
                                isDisabled: isCreating
                            ) {
                                dismiss()
                                onCreate(project)
                            }
                        }
                    } else if !searchText.isEmpty {
                        Text("No matching projects")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: popover ? 300 : .infinity)
        }
        .frame(maxWidth: popover ? 280 : 400)
        .frame(width: popover ? 280 : nil)
    }
}

// MARK: - Remote Session Selection

/// Identifies a selected remote session by host and session name
private struct RemoteSessionSelection: Equatable, Hashable {
    let hostId: String
    let hostName: String
    let sessionName: String

    /// Returns the auto-resize key for the active pane in a given window
    func resizeKey(paneId: String) -> String {
        "remote-\(hostId)-\(paneId)"
    }

    /// Extracts the paneId from a resizeKey generated by this type.
    static func paneId(from resizeKey: String, hostId: String) -> String {
        let prefix = "remote-\(hostId)-"
        guard resizeKey.hasPrefix(prefix) else { return resizeKey }
        return String(resizeKey.dropFirst(prefix.count))
    }
}

// MARK: - Remote Host Sidebar Section

/// Sidebar section for a remote Mac host's sessions, grouped by tmux session
private struct RemoteHostSidebarSection: View {
    let host: PairedHost
    let connection: ViewerConnection?
    let sessionStore: SessionStore
    let creatingSelection: NewSessionCreatingState?
    @Binding var selectedRemoteSession: RemoteSessionSelection?
    let onSelect: (RemoteSessionSelection) -> Void
    let onCreate: (ClaudeProjectInfo?) -> Void
    let onSetDescription: (String, String?) -> Void
    let onSetColor: (String, SessionColor?) -> Void
    let onSetEmoji: (String, String?) -> Void
    let onToggleYolo: (String, Bool) -> Void
    let onCloseSession: (String) -> Void

    @Environment(AppSettings.self) private var settings

    /// Remote sessions grouped by tmux session (mirrors local session grouping)
    private var tmuxSessions: [TmuxSession] {
        sessionStore.sessions(for: host.id)
    }

    private var hasContent: Bool {
        !tmuxSessions.isEmpty
    }

    private var sortedSessions: [TmuxSession] {
        settings.sidebarSortMode.sorted(tmuxSessions) { session in
            SessionSortData.forRemoteSession(
                session,
                sidebarFields: settings.sidebarFields,
                sidebarTerminalFields: settings.sidebarTerminalFields,
                homeDirectory: sessionStore.homeDirectoryByHost[host.id]
            )
        }
    }

    var body: some View {
        Section {
            if let mismatch = connection?.versionMismatch {
                RemoteHostVersionMismatchRow(host: host, mismatch: mismatch) {
                    Task { await connection?.enableReconnectAndRetry() }
                }
            } else if hasContent {
                ForEach(sortedSessions) { session in
                    remoteSessionButton(session)
                }
            } else if connection?.isHostConnected == true {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("Host offline")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            SectionHeader(
                title: host.displayName(showUsername: settings.hasDuplicateHostName(for: host)),
                symbol: .laptopcomputer,
                isNewSessionDisabled: connection?.isHostConnected != true,
                trailing: {
                    Circle()
                        .fill(hostStatusColor)
                        .frame(width: 8, height: 8)
                },
                popover: {
                    NewSessionContent(
                        title: "New Session on \(host.displayName)",
                        projects: sessionStore.projects(for: host.id),
                        isLoadingProjects: !sessionStore.hasReceivedState(for: host.id),
                        creatingSelection: creatingSelection,
                        onCreate: onCreate
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func remoteSessionButton(_ session: TmuxSession) -> some View {
        let claudePane = session.windows.flatMap(\.panes).first(where: { $0.claudeSession != nil })
        let isSelected = selectedRemoteSession?.sessionName == session.sessionName
            && selectedRemoteSession?.hostId == host.id
        // See `sessionButton` — when the row gains a "Working" indicator the
        // merged button becomes `AXBusyIndicator` and swallows the bar's
        // separate accessibility element. Mirror the bar AX info on a sibling
        // outside the Button label so `valueContains` queries keep working.
        let sessionProgress: TerminalProgressState? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap(\.progress)
            .first

        Button {
            onSelect(RemoteSessionSelection(
                hostId: host.id,
                hostName: host.displayName,
                sessionName: session.sessionName
            ))
        } label: {
            RemoteSessionSidebarRow(
                session: session,
                claudeSession: claudePane?.claudeSession,
                homeDirectory: sessionStore.homeDirectoryByHost[host.id]
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : nil)
        .accessibilityChildren {
            if let sessionProgress {
                Text("Terminal progress")
                    .accessibilityLabel("Terminal progress")
                    .accessibilityValue(sessionProgress.accessibilityValueString)
            }
        }
        .modifier(DescriptionEditingModifier(
            sessionName: session.sessionName,
            currentDescription: session.customDescription,
            currentEmoji: session.customEmoji,
            isDisabled: connection?.isHostConnected != true,
            onSetDescription: onSetDescription,
            onSetEmoji: onSetEmoji,
            additionalMenu: {
                ColorContextMenuButtons(
                    currentColor: session.customColor,
                    isDisabled: connection?.isHostConnected != true
                ) { newColor in
                    onSetColor(session.sessionName, newColor)
                }

                Divider()

                if let claudePane {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(paneId: claudePane.paneId, hostId: host.id) },
                        set: { onToggleYolo(claudePane.paneId, $0) }
                    )) {
                        Label("Yolo Mode", symbol: .bolt)
                    }
                    .disabled(connection?.isHostConnected != true)

                    Divider()
                }

                Button(role: .destructive) {
                    onCloseSession(session.sessionName)
                } label: {
                    Label("Close Session", symbol: .rectangleStackBadgeMinus)
                }
                .disabled(connection?.isHostConnected != true)

                Divider()
            }
        ))
    }

    private var hostStatusColor: Color {
        guard let connection else { return .gray }
        if connection.versionMismatch != nil { return .orange }
        if connection.isHostConnected { return .green }
        if connection.isRelayConnected { return .yellow }
        return .red
    }
}

// MARK: - Remote Host Version Mismatch Row

/// Sidebar row shown in a remote host section when the host's peerHello handshake
/// failed version compatibility. Replaces the "Host offline" caption so the user
/// can see why this host cannot be reached.
private struct RemoteHostVersionMismatchRow: View {
    let host: PairedHost
    let mismatch: VersionCompatibility.VersionMismatch
    let onRetry: () -> Void

    @State private var showingRetryPopover = false

    var body: some View {
        Button {
            showingRetryPopover = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Symbols.arrowUpCircleFill.image
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host-version-mismatch-row")
        .popover(isPresented: $showingRetryPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(popoverHeading)
                    .font(.headline)
                Text(popoverDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        showingRetryPopover = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button {
                        showingRetryPopover = false
                        onRetry()
                    } label: {
                        Label("Retry", symbol: .arrowClockwise)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
    }

    private var title: String {
        switch mismatch {
        case .weAreTooOld:
            "Update this app"
        case .partnerTooOld:
            "\(host.displayName) needs updating"
        }
    }

    private var detail: String {
        switch mismatch {
        case let .weAreTooOld(required):
            "\(host.displayName) requires version \(required) or later."
        case let .partnerTooOld(partnerVersion):
            partnerVersion.isEmpty
                ? "The host is running an older version and cannot connect."
                : "The host is running version \(partnerVersion) and cannot connect."
        }
    }

    private var popoverHeading: String {
        switch mismatch {
        case .weAreTooOld:
            "Update this app"
        case .partnerTooOld:
            "Retry connection?"
        }
    }

    private var popoverDetail: String {
        switch mismatch {
        case let .weAreTooOld(required):
            "\(host.displayName) requires version \(required) or later. Try again after updating this app."
        case .partnerTooOld:
            "Try connecting again. If \(host.displayName) was updated to a compatible version, the connection will succeed."
        }
    }
}

// MARK: - Remote Session Sidebar Row

/// Sidebar row displaying a remote tmux session, grouped by session name
private struct RemoteSessionSidebarRow: View {
    @Environment(AppSettings.self) private var settings

    let session: TmuxSession
    let claudeSession: ClaudeSession?
    var homeDirectory: String?

    /// The latest event subtitle from the Claude session's pane
    private var latestEventSubtitle: String? {
        session.windows
            .flatMap(\.panes)
            .compactMap(\.claudeSession?.latestEvent?.action.subtitle)
            .first
    }

    /// CLI-driven state override propagated from the host, if any.
    private var cliSessionState: CLISessionState? {
        session.windows
            .flatMap(\.panes)
            .compactMap(\.cliSessionState)
            .first
    }

    /// Latest `OSC 9;4` progress from the host, picked from the first pane
    /// in this session that has one. Same iteration shape as the host's
    /// `SessionSidebarRow.sessionProgress` and the iOS session list, so when
    /// multiple panes in one session emit progress all three platforms agree
    /// on which pane wins.
    private var sessionProgress: TerminalProgressState? {
        session.windows.lazy
            .flatMap(\.panes)
            .compactMap(\.progress)
            .first
    }

    var body: some View {
        rowContent
            .overlay(alignment: .leading) {
                SessionColorBar(color: session.customColor)
                    .padding(.leading, -16)
            }
            .overlay(alignment: .bottom) {
                if let sessionProgress {
                    TerminalProgressBar(state: sessionProgress)
                        .padding(.bottom, -4)
                }
            }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                if let cliSessionState {
                    SessionStatusIndicator(cliState: cliSessionState)
                        .font(.system(size: 16))
                } else if let claudeSession {
                    SessionStatusIndicator(session: claudeSession)
                        .font(.system(size: 16))
                } else {
                    Symbols.terminal.image
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                if let customEmoji = session.customEmoji {
                    SessionEmojiBadge(emoji: customEmoji)
                        .font(.system(size: 14))
                }
            }
            .frame(width: 20)

            SessionFieldsView(
                fields: claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: session.customDescription,
                projectName: claudeSession?.displayName,
                sessionName: session.sessionName,
                terminalTitle: session.activeWindow?.activePane?.terminalTitle,
                command: session.activeWindow?.activePane?.command,
                currentPath: session.activeWindow?.activePane?.currentPath,
                gitBranch: session.activeWindow?.activePane?.gitBranch,
                latestEvent: latestEventSubtitle,
                homeDirectory: homeDirectory
            )

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured.
        .accessibilityValue(session.sessionName)
        // Invisible text exposing session status and project name to macOS accessibility
        // tree for e2e tests. The Button that wraps this row can combine children into a
        // single label, dropping leaf Texts — these hidden labels give tests stable targets.
        .overlay {
            ZStack {
                if let status = cliSessionState?.statusLabel ?? claudeSession?.statusLabel {
                    Text(status)
                        .accessibilityLabel(status)
                }
                if let projectName = claudeSession?.displayName {
                    Text(projectName)
                        .accessibilityLabel(projectName)
                }
            }
            .font(.system(size: 1))
            .opacity(0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A row in the new session sheet representing a selectable option
private struct NewSessionRow: View {
    let title: String
    let subtitle: String
    let symbol: Symbols
    let isCreating: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                symbol.image
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Symbols.chevronRight.image
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Editor Picker Dialog Modifier

/// Confirmation dialog driven by `editorPickerPath` that lists the user's
/// configured editors and forwards the selection to ``EditorClient``.
///
/// Lives in its own modifier so the SwiftUI view-builder for `MainView.body`
/// stays small enough for the type-checker to handle.
private struct EditorPickerDialogModifier: ViewModifier {
    @Binding var editorPickerPath: String?
    let onCmdE: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    private var dialogIsPresented: Binding<Bool> {
        Binding(
            get: { editorPickerPath != nil },
            set: { newValue in
                if !newValue { editorPickerPath = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openCurrentTabInEditor)) { _ in
                onCmdE()
            }
            .confirmationDialog(
                "Open in Editor",
                isPresented: dialogIsPresented,
                titleVisibility: .visible,
                presenting: editorPickerPath,
                actions: dialogActions,
                message: dialogMessage
            )
    }

    @ViewBuilder
    private func dialogActions(path: String) -> some View {
        ForEach(settings.editors) { editor in
            Button(editor.displayName) {
                // Resolve the dependency inside the action so test overrides
                // installed via `withDependencies` are picked up correctly —
                // stored properties on a ViewModifier would re-resolve on every
                // body evaluation and side-step scoped overrides.
                @Dependency(EditorClient.self) var client
                let editorName = editor.displayName
                Task {
                    let launched = await client.openFile(editor, path)
                    if !launched {
                        postEditorLaunchFailed(editorName: editorName, path: path)
                    }
                }
                editorPickerPath = nil
            }
        }
        if settings.editors.isEmpty {
            Button("Configure Editors…") {
                settings.selectedSettingsTab = .editors
                openSettings()
                editorPickerPath = nil
            }
        }
        Button("Cancel", role: .cancel) {
            editorPickerPath = nil
        }
    }

    private func dialogMessage(path: String) -> some View {
        Text(URL(fileURLWithPath: path).lastPathComponent)
    }
}

// MARK: - Alerts Modifier

private struct AlertsModifier: ViewModifier {
    @Binding var attachError: String?
    @Binding var closeConfirmation: CloseConfirmation?
    let onPerformClose: (CloseConfirmation.Target) -> Void

    func body(content: Content) -> some View {
        content
            // Routed through here so editor-launch failures surface via the
            // same alert affordance as other transient errors. Defined inside
            // the existing alerts modifier (rather than as a new chained
            // `.onReceive` in `MainView.body`) to keep the body's modifier
            // chain inside SwiftUI's type-checker budget.
            .onReceive(NotificationCenter.default.publisher(for: .editorLaunchFailed)) { notification in
                if let message = notification.userInfo?[editorLaunchFailedMessageKey] as? String {
                    attachError = message
                }
            }
            .alert("Terminal Error", isPresented: .init(
                get: { attachError != nil },
                set: { if !$0 { attachError = nil } }
            )) {
                Button("OK") { attachError = nil }
            } message: {
                if let error = attachError {
                    Text(error)
                }
            }
            .alert(
                closeConfirmation?.title ?? "Close?",
                isPresented: .init(
                    get: { closeConfirmation != nil },
                    set: { if !$0 { closeConfirmation = nil } }
                )
            ) {
                if let confirmation = closeConfirmation {
                    Button("Close Anyway", role: .destructive) {
                        onPerformClose(confirmation.target)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) { closeConfirmation = nil }
            } message: {
                if let confirmation = closeConfirmation {
                    Text(confirmation.message)
                }
            }
    }
}

// MARK: - Close Confirmation

private struct CloseConfirmation {
    enum Target {
        case session(String)
        case window(LocalTmuxWindow)
        case remoteWindow(TmuxWindow, hostId: String)
        case remoteSession(sessionName: String, hostId: String)
    }

    let target: Target
    let runningProcesses: [RunningProcessInfo]

    /// Create from local TmuxService processes
    init(target: Target, localProcesses: [TmuxService.RunningProcess]) {
        self.target = target
        self.runningProcesses = localProcesses.map {
            RunningProcessInfo(paneIndex: $0.paneIndex, name: $0.name, isForeground: $0.isForeground)
        }
    }

    /// Create from remote RunningProcessInfo (already in wire format)
    init(target: Target, runningProcesses: [RunningProcessInfo]) {
        self.target = target
        self.runningProcesses = runningProcesses
    }

    var title: String {
        switch target {
        case .session,
             .remoteSession: "Close Session?"
        case .window,
             .remoteWindow: "Close Window?"
        }
    }

    var targetName: String {
        switch target {
        case let .session(name): name
        case let .window(window): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteWindow(window, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteSession(name, _): name
        }
    }

    var message: String {
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Pane \(paneIndex): \(names)"
        }
        return "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
    }
}
