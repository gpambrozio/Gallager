import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import SwiftUI

/// The main application view showing available tmux windows in a sidebar layout
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(PairingManager.self) private var pairingManager
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    public init() { }

    /// Selection state: either a local window or a remote pane (hostId + paneId)
    @State private var selectedWindow: LocalTmuxWindow?
    @State private var selectedRemotePane: RemotePaneSelection?
    @State private var attachError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCloseConfirmation = false
    @State private var projects: [ClaudeProjectInfo] = []
    @State private var isLoadingProjects = false
    @State private var creatingSelection: NewSessionCreatingState?
    @State private var detailPaneSize: CGSize = .zero
    @State private var contextMenuCloseSessionName: String?

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
        .navigationTitle("Available Windows")
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
        .alert("Close Session?", isPresented: .init(
            get: { contextMenuCloseSessionName != nil },
            set: { if !$0 { contextMenuCloseSessionName = nil } }
        )) {
            if let sessionName = contextMenuCloseSessionName {
                Button("Close \"\(sessionName)\"", role: .destructive) {
                    closeSession(sessionName)
                }
            }
            Button("Cancel", role: .cancel) { contextMenuCloseSessionName = nil }
        } message: {
            Text("This will end all processes in the session.")
        }
        .onChange(of: tmuxService.panes) { _, newPanes in
            // Ensure pane states exist for all known panes so the detail view
            // can render immediately when a window is selected (without waiting
            // for the periodic validation timer).
            windowManager.updatePaneStates(from: newPanes)

            guard let selected = selectedWindow else { return }
            let currentWindows = tmuxService.windows
            if let updated = currentWindows.first(where: { $0.id == selected.id }) {
                // Keep selection in sync with refreshed window data
                if updated != selected {
                    selectedWindow = updated
                }
            } else {
                // Selected window was removed — try to select another window in the same session
                let fallback = currentWindows.first(where: { $0.sessionName == selected.sessionName })
                selectedWindow = fallback
            }
        }
        .onChange(of: selectedWindow) {
            // Reset cached dimensions and trigger auto-resize for the newly selected window
            lastAutoResizeDimensions = nil
            handleAutoResize()

            markSelectedSessionsHandledIfActive()
        }
        .onChange(of: selectedRemotePane) {
            lastAutoResizeDimensions = nil
            handleAutoResize()

            markSelectedSessionsHandledIfActive()
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
        .onChange(of: coordinator.pendingMenuBarSelection) {
            applyPendingMenuBarSelection()
        }
        .onDisappear {
            autoResizeTask?.cancel()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
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

    /// Whether a session has any pane with an active Claude session
    private func sessionHasClaude(_ session: LocalTmuxSession) -> Bool {
        session.windows.contains { window in
            window.panes.contains { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        }
    }

    private var windowList: some View {
        let allSessions = tmuxService.sessions
        let sessionsWithClaude = allSessions.filter { sessionHasClaude($0) }
        let sessionsWithoutClaude = allSessions.filter { !sessionHasClaude($0) }

        return ScrollViewReader { proxy in
            List {
                claudeSessionsSection(sessions: sessionsWithClaude)
                terminalsSection(sessions: sessionsWithoutClaude, hasClaudeSessions: !sessionsWithClaude.isEmpty)
                emptyLocalSection(hasAnyWindows: !sessionsWithClaude.isEmpty || !sessionsWithoutClaude.isEmpty)
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

    @ViewBuilder
    private func claudeSessionsSection(sessions: [LocalTmuxSession]) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    sessionButton(session: session, help: "Claude Code session active")
                }
            } header: {
                SectionHeader(title: "Claude Sessions", symbol: .sparkles) {
                    localNewSessionPopover
                }
            }
        }
    }

    @ViewBuilder
    private func terminalsSection(sessions: [LocalTmuxSession], hasClaudeSessions: Bool) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    sessionButton(session: session)
                }
            } header: {
                if !hasClaudeSessions {
                    SectionHeader(title: "Terminals", symbol: .terminal) {
                        localNewSessionPopover
                    }
                } else {
                    SectionHeader(title: "Terminals", symbol: .terminal)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyLocalSection(hasAnyWindows: Bool) -> some View {
        if !hasAnyWindows && settings.hasRemoteHosts {
            Section {
                Text("No local sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } header: {
                SectionHeader(title: "Local", symbol: .terminal) {
                    localNewSessionPopover
                }
            }
        }
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
                    selectedRemotePane: $selectedRemotePane,
                    onSelect: { selection in
                        selectedRemotePane = selection
                        selectedWindow = nil
                    },
                    onCreate: { project in
                        Task {
                            await createRemoteSession(on: host, inProject: project)
                        }
                    },
                    onSetDescription: { windowId, description in
                        Task {
                            guard let manager = coordinator.viewerConnectionManager else { return }
                            let command = SetWindowDescription(windowId: windowId, description: description)
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
                    onResize: { paneId in
                        Task {
                            await performResize(remoteHostId: host.id, remotePaneId: paneId)
                        }
                    },
                    isAutoResizeEnabled: { resizeKey in
                        autoResizeEnabled.contains(resizeKey)
                    },
                    onToggleAutoResize: { resizeKey, enabled in
                        if enabled {
                            autoResizeEnabled.insert(resizeKey)
                            let paneId = RemotePaneSelection.paneId(from: resizeKey, hostId: host.id)
                            Task {
                                await performResize(remoteHostId: host.id, remotePaneId: paneId)
                            }
                        } else {
                            autoResizeEnabled.remove(resizeKey)
                        }
                    }
                )
            }
        }
    }

    private func sessionButton(session: LocalTmuxSession, help: String? = nil) -> some View {
        let activeWindow = session.activeWindow
        let description = activeWindow?.activePane.flatMap { windowManager.paneStates[$0.paneId]?.customDescription }
        let claudePane = session.windows.flatMap(\.panes).first { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let activePane = activeWindow?.activePane
        let isSessionAttached = tmuxService.attachedSessionNames.contains(session.sessionName)
        let isSelected = selectedWindow.map { selected in session.windows.contains(where: { $0.id == selected.id }) } ?? false

        return Button {
            // Select the session's active window
            if let activeWindow {
                selectedWindow = activeWindow
            }
            selectedRemotePane = nil
        } label: {
            SessionSidebarRow(session: session)
        }
        .id(session.sessionName)
        .buttonStyle(.plain)
        .help(help ?? "")
        .listRowBackground(isSelected && selectedRemotePane == nil ? Color.accentColor.opacity(0.2) : nil)
        .modifier(DescriptionEditingModifier(
            windowId: activeWindow?.id ?? session.sessionName,
            currentDescription: description,
            onSetDescription: { windowId, description in
                windowManager.setWindowDescription(description, for: windowId)
            },
            additionalMenu: {
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

                    Button {
                        windowManager.openMirror(for: activePane)
                    } label: {
                        Label("Open in New Window", symbol: .macwindowBadgePlus)
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
                    contextMenuCloseSessionName = session.sessionName
                } label: {
                    Label("Close Session", symbol: .xmark)
                }

                Divider()
            }
        ))
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailContent: some View {
        if
            let remote = selectedRemotePane,
            let connection = coordinator.viewerConnectionManager?.connection(for: remote.hostId) {
            RemoteTerminalContainerView(
                paneId: remote.paneId,
                hostName: remote.hostName,
                connection: connection,
                settings: settings,
                onStreamEnd: {
                    selectedRemotePane = nil
                }
            )
            .id(remote.resizeKey)
        } else if let window = selectedWindow {
            let session = tmuxService.sessions.first(where: { $0.windows.contains(where: { $0.id == window.id }) })
            VStack(spacing: 0) {
                if let session {
                    WindowTabBar(
                        session: session,
                        selectedWindow: window,
                        onSelectWindow: { newWindow in
                            selectedWindow = newWindow
                            Task {
                                try? await tmuxService.selectWindow(newWindow.id)
                            }
                        },
                        onNewWindow: {
                            Task {
                                let currentPath = window.activePane?.currentPath
                                let paneId = try? await tmuxService.newWindow(
                                    sessionName: session.sessionName,
                                    workingDirectory: currentPath
                                )
                                // Select the newly created window
                                if
                                    let paneId,
                                    let newWindow = tmuxService.windows.first(where: { $0.panes.contains(where: { $0.paneId == paneId }) }) {
                                    selectedWindow = newWindow
                                }
                            }
                        }
                    )
                }

                WindowPaneLayoutView(window: window)
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
            if let window = selectedWindow, selectedRemotePane == nil {
                let claudePane = window.panes.first { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
                let activePane = window.activePane

                // Yolo mode toggle (only for windows with active Claude sessions)
                if let claudePane {
                    Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(windowManager.isYoloModeEnabled(for: claudePane.paneId)
                        ? "Yolo mode: auto-approving permissions (click to disable)"
                        : "Enable yolo mode to auto-approve permissions")
                }

                if let activePane {
                    Button {
                        attachToTerminal(activePane)
                    } label: {
                        Symbols.macwindow.image
                    }
                    .help("Open session in terminal app")

                    Button {
                        windowManager.openMirror(for: activePane)
                    } label: {
                        Symbols.macwindowBadgePlus.image
                    }
                    .help("Open mirror in new window")

                    resizeToolbarGroup(
                        resizeKey: activePane.paneId,
                        localTarget: activePane.target,
                        isSessionAttached: tmuxService.attachedSessionNames.contains(window.sessionName)
                    )
                }

                Button {
                    showingCloseConfirmation = true
                } label: {
                    Symbols.xmark.image
                }
                .help("Close session")
                .popover(isPresented: $showingCloseConfirmation, arrowEdge: .bottom) {
                    CloseSessionConfirmation(sessionName: window.sessionName) {
                        closeSession(window.sessionName)
                    }
                }
            } else if let remote = selectedRemotePane {
                // Yolo mode toggle for remote panes with active Claude sessions
                if
                    let sessionStore = coordinator.remoteSessionStore,
                    sessionStore.session(for: remote.paneId) != nil {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(for: remote.paneId) },
                        set: { newValue in
                            Task {
                                guard let manager = coordinator.viewerConnectionManager else { return }
                                _ = await manager.sendCommand(
                                    SetYoloMode(enabled: newValue),
                                    paneId: remote.paneId,
                                    hostId: remote.hostId
                                )
                            }
                        }
                    )) {
                        Symbols.bolt.image
                    }
                    .toggleStyle(.button)
                    .help(coordinator.remoteSessionStore?.isYoloModeEnabled(for: remote.paneId) == true
                        ? "Yolo mode: auto-approving permissions (click to disable)"
                        : "Enable yolo mode to auto-approve permissions")
                }

                resizeToolbarGroup(resizeKey: remote.resizeKey, remoteHostId: remote.hostId, remotePaneId: remote.paneId)
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

    @ViewBuilder
    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            connectionStatusIcon
                .font(.caption)

            connectionActionButton
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
                .help(anyViewerConnected
                    ? "Connected - viewer online"
                    : "Connected - waiting for viewer")
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
            // Connected - show disconnect button
            Button("Disconnect") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
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
        let currentRemote = selectedRemotePane

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
            } else if let remote = currentRemote {
                guard isAutoResizeActive(for: remote.resizeKey) else { return }
                await performResize(remoteHostId: remote.hostId, remotePaneId: remote.paneId)
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
            selectedWindow == nil, selectedRemotePane == nil, newSessionPaneIds.count == 1,
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

        if let remote = selectedRemotePane {
            coordinator.remoteSessionStore?.markSessionHandled(paneId: remote.paneId)
            Task {
                _ = await coordinator.viewerConnectionManager?.sendCommand(
                    MarkHandled(),
                    paneId: remote.paneId,
                    hostId: remote.hostId
                )
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
                selectedRemotePane = nil
            }
        case let .remote(hostId, hostName, paneId):
            selectedRemotePane = RemotePaneSelection(
                hostId: hostId,
                hostName: hostName,
                paneId: paneId
            )
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

    private func closeSession(_ sessionName: String) {
        Task {
            do {
                try await tmuxService.killSession(sessionName)
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func openSettingsToRemoteAccess() {
        // Set the tab to Remote Access before opening settings
        settings.selectedSettingsTab = .remoteAccess

        // Open the Settings window using macOS selector
        // Note: This uses a private selector that may change in future macOS versions
        let selector = Selector(("showSettingsWindow:"))
        if NSApp.responds(to: selector) {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
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

    private func loadProjects() async {
        isLoadingProjects = true
        projects = await coordinator.scanProjects()
        isLoadingProjects = false
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

                // Calculate optimal dimensions based on available space
                let dimensions = calculateOptimalTerminalDimensions()

                // Create the session with calculated dimensions
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: sessionName,
                    width: dimensions.columns,
                    height: dimensions.rows,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand
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
            workingDirectory: project?.path
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

            // Select the new remote pane if we got a pane ID
            if let paneId = response.paneId {
                let selection = RemotePaneSelection(
                    hostId: host.id,
                    hostName: host.displayName,
                    paneId: paneId
                )
                selectedRemotePane = selection
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

    let session: LocalTmuxSession

    /// The active window (or first)
    private var activeWindow: LocalTmuxWindow? { session.activeWindow }

    /// The primary pane to show info for (active pane or first pane in active window)
    private var primaryPane: PaneInfo? { activeWindow?.activePane }

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

    /// Terminal title detected via OSC escape sequences (from primary pane)
    private var terminalTitle: String? {
        primaryPaneState?.terminalTitle
    }

    /// Custom description for this session (from the active window's primary pane)
    private var customDescription: String? {
        primaryPaneState?.customDescription
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let session = claudeSession {
                SessionStatusIndicator(session: session)
                    .font(.system(size: 16))
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Custom description shown prominently if set
                if let customDescription {
                    Text(customDescription)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(session.sessionName)
                        .font(.system(customDescription != nil ? .caption : .body, design: .monospaced))
                        .foregroundStyle(customDescription != nil ? .secondary : .primary)

                    if session.windows.count > 1 {
                        Text("\(session.windows.count) windows")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let terminalTitle, !terminalTitle.isEmpty {
                    Text(terminalTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let pane = primaryPane {
                    Text(pane.command)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(pane.currentPath.abbreviatedPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let sessionSubtitle {
                    Text(sessionSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        // Invisible text exposing session status to macOS accessibility tree for e2e tests.
        // ProgressView (working state) prevents AX from reading .accessibilityValue directly.
        .overlay {
            if let status = claudeSession?.statusLabel {
                Text(status)
                    .font(.system(size: 1))
                    .opacity(0)
                    .accessibilityLabel(status)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Window Tab Bar

/// Horizontal tab bar showing windows in a tmux session.
/// Always visible, even for single-window sessions (with a "+" tab to create new windows).
private struct WindowTabBar: View {
    let session: LocalTmuxSession
    let selectedWindow: LocalTmuxWindow
    let onSelectWindow: (LocalTmuxWindow) -> Void
    let onNewWindow: () -> Void

    @Environment(MirrorWindowManager.self) private var windowManager

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

                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id
        let hasClaude = window.panes.contains { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let windowName = tabLabel(for: window)

        return Button {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityLabel(window.id)
    }

    private func tabLabel(for window: LocalTmuxWindow) -> String {
        if !window.windowName.isEmpty, Int(window.windowName) == nil {
            return window.windowName
        }
        return "\(window.windowIndex)"
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

// MARK: - Remote Pane Selection

/// Identifies a selected remote pane by host and pane ID
private struct RemotePaneSelection: Equatable, Hashable {
    let hostId: String
    let hostName: String
    let paneId: String

    var resizeKey: String { "remote-\(hostId)-\(paneId)" }

    /// Extracts the paneId from a resizeKey generated by this type.
    static func paneId(from resizeKey: String, hostId: String) -> String {
        let prefix = "remote-\(hostId)-"
        guard resizeKey.hasPrefix(prefix) else { return resizeKey }
        return String(resizeKey.dropFirst(prefix.count))
    }
}

// MARK: - Remote Host Sidebar Section

/// Sidebar section for a remote Mac host's sessions and panes
private struct RemoteHostSidebarSection: View {
    let host: PairedHost
    let connection: ViewerConnection?
    let sessionStore: SessionStore
    let creatingSelection: NewSessionCreatingState?
    @Binding var selectedRemotePane: RemotePaneSelection?
    let onSelect: (RemotePaneSelection) -> Void
    let onCreate: (ClaudeProjectInfo?) -> Void
    let onSetDescription: (String, String?) -> Void
    let onToggleYolo: (String, Bool) -> Void
    let onResize: (String) -> Void
    let isAutoResizeEnabled: (String) -> Bool
    let onToggleAutoResize: (String, Bool) -> Void

    @Environment(AppSettings.self) private var settings

    private var sessions: [(paneId: String, session: ClaudeSession)] {
        sessionStore.sessions(for: host.id)
    }

    private var panes: [PaneState] {
        sessionStore.panes(for: host.id)
    }

    private var hasContent: Bool {
        !sessions.isEmpty || !panes.isEmpty
    }

    var body: some View {
        Section {
            if hasContent {
                ForEach(sessions, id: \.paneId) { item in
                    let paneState = sessionStore.paneState(for: item.paneId)
                    Button {
                        onSelect(RemotePaneSelection(
                            hostId: host.id,
                            hostName: host.displayName,
                            paneId: item.paneId
                        ))
                    } label: {
                        RemotePaneSidebarRow(
                            title: item.session.displayName,
                            subtitle: item.paneId,
                            claudeSession: item.session,
                            customDescription: paneState?.customDescription
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedRemotePane?.paneId == item.paneId && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
                    .modifier(DescriptionEditingModifier(
                        windowId: paneState?.windowId ?? "",
                        currentDescription: paneState?.customDescription,
                        isDisabled: paneState == nil || connection?.isHostConnected != true,
                        onSetDescription: onSetDescription,
                        additionalMenu: {
                            remoteContextMenuItems(paneId: item.paneId, hasClaude: true)
                        }
                    ))
                }

                ForEach(panes) { pane in
                    Button {
                        onSelect(RemotePaneSelection(
                            hostId: host.id,
                            hostName: host.displayName,
                            paneId: pane.paneId
                        ))
                    } label: {
                        RemotePaneSidebarRow(
                            title: pane.currentPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? pane.paneId,
                            subtitle: pane.target.isEmpty ? pane.paneId : pane.target,
                            claudeSession: nil,
                            customDescription: pane.customDescription
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pane.customDescription ?? (pane.target.isEmpty ? pane.paneId : pane.target))
                    .listRowBackground(
                        selectedRemotePane?.paneId == pane.paneId && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
                    .modifier(DescriptionEditingModifier(
                        windowId: pane.windowId,
                        currentDescription: pane.customDescription,
                        isDisabled: connection?.isHostConnected != true,
                        onSetDescription: onSetDescription,
                        additionalMenu: {
                            remoteContextMenuItems(paneId: pane.paneId, hasClaude: false)
                        }
                    ))
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
    private func remoteContextMenuItems(paneId: String, hasClaude: Bool) -> some View {
        let resizeKey = "remote-\(host.id)-\(paneId)"
        let isDisconnected = connection?.isHostConnected != true

        if hasClaude {
            Toggle(isOn: Binding(
                get: { sessionStore.isYoloModeEnabled(for: paneId) },
                set: { onToggleYolo(paneId, $0) }
            )) {
                Label("Yolo Mode", symbol: .bolt)
            }
            .disabled(isDisconnected)

            Divider()
        }

        Button {
            onResize(paneId)
        } label: {
            Label("Resize to Fit", symbol: .arrowUpLeftAndArrowDownRight)
        }
        .disabled(isDisconnected)

        Toggle(isOn: Binding(
            get: { isAutoResizeEnabled(resizeKey) },
            set: { onToggleAutoResize(resizeKey, $0) }
        )) {
            Label("Auto-resize", symbol: .arrowDownRightAndArrowUpLeft)
        }
        .disabled(isDisconnected)

        Divider()
    }

    private var hostStatusColor: Color {
        guard let connection else { return .gray }
        if connection.isHostConnected { return .green }
        if connection.isRelayConnected { return .yellow }
        return .red
    }
}

// MARK: - Remote Pane Sidebar Row

private struct RemotePaneSidebarRow: View {
    let title: String
    let subtitle: String
    let claudeSession: ClaudeSession?
    var customDescription: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let session = claudeSession {
                SessionStatusIndicator(session: session)
                    .font(.system(size: 16))
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let customDescription {
                    Text(customDescription)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(title)
                    .font(.system(customDescription != nil ? .caption : .body, design: .monospaced))
                    .foregroundStyle(customDescription != nil ? .secondary : .primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        // Invisible text exposing session status to macOS accessibility tree for e2e tests.
        // ProgressView (working state) prevents AX from reading .accessibilityValue directly.
        .overlay {
            if let status = claudeSession?.statusLabel {
                Text(status)
                    .font(.system(size: 1))
                    .opacity(0)
                    .accessibilityLabel(status)
            }
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

// MARK: - Close Session Confirmation Popover

private struct CloseSessionConfirmation: View {
    let sessionName: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Close Session?")
                .font(.headline)
            Text("This will end all processes in the session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Close \"\(sessionName)\"", role: .destructive) {
                    dismiss()
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 250)
    }
}
