import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
import SwiftUI

/// The main application view showing available tmux panes in a sidebar layout
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(PairingManager.self) private var pairingManager
    @Dependency(ClaudeProjectScanner.self) private var projectScanner
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    public init() { }

    /// Selection state: either a local pane or a remote pane (hostId + paneId)
    @State private var selectedPane: PaneInfo?
    @State private var selectedRemotePane: RemotePaneSelection?
    @State private var attachError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCloseConfirmation = false
    @State private var projects: [ClaudeProjectInfo] = []
    @State private var isLoadingProjects = false
    @State private var creatingSelection: NewSessionCreatingState?
    @State private var detailPaneSize: CGSize = .zero

    /// Per-session auto-resize state (keyed by pane target for local, "remote-hostId-paneId" for remote)
    @State private var autoResizeEnabled: Set<String> = []
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
        .navigationTitle("Available Panes")
        .toolbar {
            toolbarContent
        }
        .task {
            // Initial load only - periodic refresh is handled by MirrorWindowManager
            await refreshPanes()
            await loadProjects()
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
        .onChange(of: tmuxService.panes) { _, newPanes in
            // Keep selection valid - if selected pane was removed, clear selection
            if
                let selected = selectedPane,
                !newPanes.contains(where: { $0.id == selected.id }) {
                selectedPane = nil
            }
        }
        .onChange(of: selectedPane) {
            // Reset cached dimensions and trigger auto-resize for the newly selected pane
            lastAutoResizeDimensions = nil
            handleAutoResize()
        }
        .onChange(of: selectedRemotePane) {
            lastAutoResizeDimensions = nil
            handleAutoResize()
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
                paneList
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

    private var paneList: some View {
        let panesWithClaude = tmuxService.panes.filter { windowManager.activeSessions[$0.paneId] != nil }
        let panesWithoutClaude = tmuxService.panes.filter { windowManager.activeSessions[$0.paneId] == nil }

        return List {
            // Local pane sections
            if !panesWithClaude.isEmpty {
                Section {
                    ForEach(panesWithClaude) { pane in
                        Button {
                            selectedPane = pane
                            selectedRemotePane = nil
                        } label: {
                            PaneSidebarRow(pane: pane)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(pane.target)
                        .help("Claude Code session active")
                        .listRowBackground(selectedPane == pane && selectedRemotePane == nil ? Color.accentColor.opacity(0.2) : nil)
                    }
                } header: {
                    SectionHeader(title: "Claude Sessions", symbol: .sparkles) {
                        localNewSessionPopover
                    }
                }
            }

            if !panesWithoutClaude.isEmpty {
                Section {
                    ForEach(panesWithoutClaude) { pane in
                        Button {
                            selectedPane = pane
                            selectedRemotePane = nil
                        } label: {
                            PaneSidebarRow(pane: pane)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(pane.target)
                        .listRowBackground(selectedPane == pane && selectedRemotePane == nil ? Color.accentColor.opacity(0.2) : nil)
                    }
                } header: {
                    if panesWithClaude.isEmpty {
                        SectionHeader(title: "Terminals", symbol: .terminal) {
                            localNewSessionPopover
                        }
                    } else {
                        SectionHeader(title: "Terminals", symbol: .terminal)
                    }
                }
            }

            // Empty local state - still show a section with + button
            if panesWithClaude.isEmpty && panesWithoutClaude.isEmpty && settings.hasRemoteHosts {
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

            // Remote host sections
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
                            selectedPane = nil
                        },
                        onCreate: { project in
                            Task {
                                await createRemoteSession(on: host, inProject: project)
                            }
                        }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await refreshPanes()
            await coordinator.viewerConnectionManager?.requestAllSessionStates()
        }
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
        } else if let pane = selectedPane {
            MirrorWindowView(paneInfo: pane)
                .id(pane.id)
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
                        "Select a Pane",
                        symbol: .terminal,
                        description: "Choose a pane from the sidebar to view its mirror."
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

        // Actions for selected pane
        ToolbarItemGroup(placement: .primaryAction) {
            if let pane = selectedPane, selectedRemotePane == nil {
                Button {
                    attachToTerminal(pane)
                } label: {
                    Symbols.macwindow.image
                }
                .help("Open session in terminal app")

                Button {
                    windowManager.openMirror(for: pane)
                } label: {
                    Symbols.macwindowBadgePlus.image
                }
                .help("Open mirror in new window")

                resizeToolbarGroup(
                    resizeKey: pane.target,
                    localTarget: pane.target,
                    isSessionAttached: tmuxService.attachedSessionNames.contains(pane.sessionName)
                )

                Button {
                    showingCloseConfirmation = true
                } label: {
                    Symbols.xmark.image
                }
                .help("Close session")
                .confirmationDialog(
                    "Close Session?",
                    isPresented: $showingCloseConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Close \"\(pane.sessionName)\"", role: .destructive) {
                        closeSession(pane.sessionName)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will end all processes in the session.")
                }
            } else if let remote = selectedRemotePane {
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

    @ViewBuilder
    private func resizeToolbarGroup(
        resizeKey: String,
        localTarget: String? = nil,
        remoteHostId: String? = nil,
        remotePaneId: String? = nil,
        isSessionAttached: Bool = false
    ) -> some View {
        let attachedHelp = "Cannot resize: session is attached to a terminal"

        Button {
            Task {
                await performResize(localTarget: localTarget, remoteHostId: remoteHostId, remotePaneId: remotePaneId)
            }
        } label: {
            Symbols.arrowUpLeftAndArrowDownRight.image
        }
        .help(isSessionAttached ? attachedHelp : "Resize tmux pane to fit mirror view")
        .disabled(isSessionAttached)

        Toggle(isOn: Binding(
            get: { autoResizeEnabled.contains(resizeKey) },
            set: { enabled in
                if enabled {
                    autoResizeEnabled.insert(resizeKey)
                    Task {
                        await performResize(localTarget: localTarget, remoteHostId: remoteHostId, remotePaneId: remotePaneId)
                    }
                } else {
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

    private func handleAutoResize() {
        // Cancel any pending debounced resize
        autoResizeTask?.cancel()

        // Capture current selection before the debounce sleep to avoid racing with pane switches
        let currentPane = selectedPane
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

            if let pane = currentPane, currentRemote == nil {
                guard autoResizeEnabled.contains(pane.target) else { return }
                guard !tmuxService.attachedSessionNames.contains(pane.sessionName) else { return }
                await performResize(localTarget: pane.target)
            } else if let remote = currentRemote {
                guard autoResizeEnabled.contains(remote.resizeKey) else { return }
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
        projects = await projectScanner.scanProjects()
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

        // Vertical padding: status bar (~28px) + some buffer for spacing
        let verticalPadding: CGFloat = settings.showStatusBar ? 40 : 10

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

                // Find the new pane and select it
                if let newPane = tmuxService.panes.first(where: { $0.paneId == paneId }) {
                    selectedPane = newPane
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
                selectedPane = nil
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

/// A row displaying a single pane in the sidebar
private struct PaneSidebarRow: View {
    @Environment(MirrorWindowManager.self) private var windowManager

    let pane: PaneInfo

    /// Check if pane has active Claude session
    private var hasClaude: Bool {
        windowManager.activeSessions[pane.paneId] != nil
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.target)
                        .font(.system(.body, design: .monospaced))

                    if hasClaude {
                        Symbols.sparkles.image
                            .foregroundStyle(.purple)
                            .font(.caption)
                    }
                }

                Text(pane.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(pane.currentPath.abbreviatedPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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

    @Environment(AppSettings.self) private var settings

    private var sessions: [(paneId: String, session: ClaudeSession)] {
        sessionStore.sessions(for: host.id)
    }

    private var panes: [PaneInfoMessage] {
        sessionStore.panes(for: host.id)
    }

    private var hasContent: Bool {
        !sessions.isEmpty || !panes.isEmpty
    }

    var body: some View {
        Section {
            if hasContent {
                ForEach(sessions, id: \.paneId) { item in
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
                            hasClaude: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.paneId)
                    .listRowBackground(
                        selectedRemotePane?.paneId == item.paneId && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
                }

                ForEach(panes) { pane in
                    Button {
                        onSelect(RemotePaneSelection(
                            hostId: host.id,
                            hostName: host.displayName,
                            paneId: pane.id
                        ))
                    } label: {
                        RemotePaneSidebarRow(
                            title: pane.currentPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? pane.id,
                            subtitle: "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)",
                            hasClaude: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)")
                    .listRowBackground(
                        selectedRemotePane?.paneId == pane.id && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
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
    let hasClaude: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(.body, design: .monospaced))

                    if hasClaude {
                        Symbols.sparkles.image
                            .foregroundStyle(.purple)
                            .font(.caption)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
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
