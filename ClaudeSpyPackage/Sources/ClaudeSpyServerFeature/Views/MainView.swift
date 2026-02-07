import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import SwiftUI

/// The main application view showing available tmux panes in a sidebar layout
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(PairingManager.self) private var pairingManager
    @Environment(\.claudeProjectScanner) private var projectScanner
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    public init() { }

    /// Selection state: either a local pane or a remote pane (hostId + paneId)
    @State private var selectedPane: PaneInfo?
    @State private var selectedRemotePane: RemotePaneSelection?
    @State private var attachError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCloseConfirmation = false
    @State private var showingNewSessionSheet = false
    @State private var projects: [ClaudeProjectInfo] = []
    @State private var isLoadingProjects = false
    @State private var isCreatingSession = false
    @State private var creatingProjectPath: String?
    @State private var detailPaneSize: CGSize = .zero

    /// Remote session creation state
    @State private var selectedHostForNewSession: PairedHost?
    @State private var remoteCreatingSelection: RemoteProjectPickerSelection?

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .popover(isPresented: $showingNewSessionSheet) {
                    NewSessionPopover(
                        projects: projects,
                        isLoadingProjects: isLoadingProjects,
                        isCreatingSession: isCreatingSession,
                        creatingProjectPath: creatingProjectPath,
                        onCreate: { project in
                            createNewSession(project: project)
                        }
                    )
                }
                .sheet(item: $selectedHostForNewSession) { host in
                    RemoteNewSessionSheet(
                        host: host,
                        sessionStore: coordinator.remoteSessionStore,
                        creatingSelection: remoteCreatingSelection,
                        onCreate: { project in
                            Task {
                                await createRemoteSession(on: host, inProject: project)
                            }
                        }
                    )
                }
        } detail: {
            detailContent
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { newSize in
                    detailPaneSize = newSize
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
        .background {
            // Hidden button to preserve Cmd+Shift+N keyboard shortcut for new local session
            Button("") { showingNewSessionSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .hidden()
        }
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
            symbol: .terminal,
            description: "Start tmux and create some panes to mirror."
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
                        PaneSidebarRow(pane: pane)
                            .listRowBackground(selectedPane == pane && selectedRemotePane == nil ? Color.accentColor.opacity(0.2) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPane = pane
                                selectedRemotePane = nil
                            }
                    }
                } header: {
                    SectionHeader(title: "Claude Sessions", symbol: .sparkles) {
                        showingNewSessionSheet = true
                    }
                }
            }

            if !panesWithoutClaude.isEmpty {
                Section {
                    ForEach(panesWithoutClaude) { pane in
                        PaneSidebarRow(pane: pane)
                            .listRowBackground(selectedPane == pane && selectedRemotePane == nil ? Color.accentColor.opacity(0.2) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPane = pane
                                selectedRemotePane = nil
                            }
                    }
                } header: {
                    // Only show + on Terminals header if Claude Sessions section is empty
                    if panesWithClaude.isEmpty {
                        SectionHeader(title: "Terminals", symbol: .terminal) {
                            showingNewSessionSheet = true
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
                        showingNewSessionSheet = true
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
                        selectedRemotePane: $selectedRemotePane,
                        onSelect: { selection in
                            selectedRemotePane = selection
                            selectedPane = nil
                        },
                        onNewSession: {
                            selectedHostForNewSession = host
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
        if let remote = selectedRemotePane,
           let connection = coordinator.viewerConnectionManager?.connection(for: remote.hostId) {
            RemoteTerminalContainerView(
                paneId: remote.paneId,
                hostName: remote.hostName,
                connection: connection,
                settings: settings
            )
            .id("remote-\(remote.hostId)-\(remote.paneId)")
        } else if let pane = selectedPane {
            MirrorWindowView(paneInfo: pane)
                .id(pane.id)
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
            if selectedRemotePane == nil, let pane = selectedPane {
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
        case .extendedBackoff:
            ProgressView()
                .controlSize(.small)
                .help("Reconnecting in 5 minutes...")
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

    // MARK: - New Session Actions

    private func loadProjects() async {
        guard let scanner = projectScanner else { return }
        isLoadingProjects = true
        projects = await scanner.scanProjects()
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
        isCreatingSession = true
        creatingProjectPath = project?.path

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

                showingNewSessionSheet = false
            } catch {
                attachError = "Failed to create session: \(error.localizedDescription)"
            }

            isCreatingSession = false
            creatingProjectPath = nil
        }
    }

    // MARK: - Remote Session Creation

    private func createRemoteSession(on host: PairedHost, inProject project: ClaudeProjectInfo?) async {
        guard remoteCreatingSelection == nil else { return }

        remoteCreatingSelection = project.map { .project($0.id) } ?? .newTerminal

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
            remoteCreatingSelection = nil
            return
        }

        let result = await manager.sendCommand(command, paneId: "", hostId: host.id)

        switch result {
        case let .success(response):
            remoteCreatingSelection = nil
            selectedHostForNewSession = nil

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
            remoteCreatingSelection = nil
        }
    }
}

// MARK: - Section Header

/// A prominent section header with icon and title, optionally showing a "+" button
private struct SectionHeader: View {
    let title: String
    let symbol: Symbols
    var onNewSession: (() -> Void)?

    init(title: String, symbol: Symbols, onNewSession: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.onNewSession = onNewSession
    }

    var body: some View {
        HStack(spacing: 6) {
            symbol.image
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))

            if let onNewSession {
                Spacer()

                Button {
                    onNewSession()
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Create new session")
            }
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
        .help(hasClaude ? "Claude Code session active" : "")
    }
}

// MARK: - New Session Popover

/// Popover for creating a new tmux session, optionally in a Claude project folder
private struct NewSessionPopover: View {
    let projects: [ClaudeProjectInfo]
    let isLoadingProjects: Bool
    let isCreatingSession: Bool
    let creatingProjectPath: String?
    let onCreate: (ClaudeProjectInfo?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("New Session")
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 8) {
                    // New Terminal option
                    NewSessionRow(
                        title: "New Terminal",
                        subtitle: "Start in home directory",
                        symbol: .terminal,
                        isCreating: isCreatingSession && creatingProjectPath == nil,
                        isDisabled: isCreatingSession
                    ) {
                        onCreate(nil)
                    }

                    if isLoadingProjects {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading projects...")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else if !projects.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Claude Projects")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(projects) { project in
                            NewSessionRow(
                                title: project.name,
                                subtitle: project.path.abbreviatedPath,
                                symbol: .folder,
                                isCreating: creatingProjectPath == project.path,
                                isDisabled: isCreatingSession
                            ) {
                                onCreate(project)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 280)
    }
}

// MARK: - Remote Pane Selection

/// Identifies a selected remote pane by host and pane ID
private struct RemotePaneSelection: Equatable, Hashable {
    let hostId: String
    let hostName: String
    let paneId: String
}

// MARK: - Remote Host Sidebar Section

/// Sidebar section for a remote Mac host's sessions and panes
private struct RemoteHostSidebarSection: View {
    let host: PairedHost
    let connection: ViewerConnection?
    let sessionStore: SessionStore
    @Binding var selectedRemotePane: RemotePaneSelection?
    let onSelect: (RemotePaneSelection) -> Void
    let onNewSession: () -> Void

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
                    RemotePaneSidebarRow(
                        title: item.session.displayName,
                        subtitle: item.paneId,
                        hasClaude: true
                    )
                    .listRowBackground(
                        selectedRemotePane?.paneId == item.paneId && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(RemotePaneSelection(
                            hostId: host.id,
                            hostName: host.displayName,
                            paneId: item.paneId
                        ))
                    }
                }

                ForEach(panes) { pane in
                    RemotePaneSidebarRow(
                        title: pane.currentPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? pane.id,
                        subtitle: "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)",
                        hasClaude: false
                    )
                    .listRowBackground(
                        selectedRemotePane?.paneId == pane.id && selectedRemotePane?.hostId == host.id
                            ? Color.accentColor.opacity(0.2) : nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(RemotePaneSelection(
                            hostId: host.id,
                            hostName: host.displayName,
                            paneId: pane.id
                        ))
                    }
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
            HStack(spacing: 6) {
                Symbols.laptopcomputer.image
                    .font(.headline.weight(.semibold))

                Text(host.displayName(showUsername: settings.hasDuplicateHostName(for: host)))
                    .font(.headline.weight(.semibold))

                Spacer()

                Button {
                    onNewSession()
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(connection?.isHostConnected != true)
                .help("Create new session on \(host.displayName)")

                Circle()
                    .fill(hostStatusColor)
                    .frame(width: 8, height: 8)
            }
            .foregroundStyle(.primary)
            .padding(.top, 8)
            .padding(.bottom, 4)
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

// MARK: - Remote New Session

/// Identifier for the selected item in the remote project picker
private enum RemoteProjectPickerSelection: Equatable {
    case newTerminal
    case project(String)
}

/// Sheet for creating a new session on a remote host, with optional project selection
private struct RemoteNewSessionSheet: View {
    let host: PairedHost
    let sessionStore: SessionStore?
    let creatingSelection: RemoteProjectPickerSelection?
    let onCreate: (ClaudeProjectInfo?) -> Void

    @Environment(\.dismiss) private var dismiss

    private var isCreating: Bool {
        creatingSelection != nil
    }

    private var projects: [ClaudeProjectInfo] {
        sessionStore?.projects(for: host.id) ?? []
    }

    private var hasReceivedState: Bool {
        sessionStore?.hasReceivedState(for: host.id) ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isCreating)

                Spacer()

                Text("New Session on \(host.displayName)")
                    .font(.headline)

                Spacer()

                // Balance the Cancel button width
                Button("Cancel") { }
                    .hidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 8) {
                    NewSessionRow(
                        title: "New Terminal",
                        subtitle: "Start in home directory",
                        symbol: .terminal,
                        isCreating: creatingSelection == .newTerminal,
                        isDisabled: isCreating
                    ) {
                        onCreate(nil)
                    }

                    if !projects.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Claude Projects")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(projects) { project in
                            NewSessionRow(
                                title: project.name,
                                subtitle: project.path.abbreviatedPath,
                                symbol: .folder,
                                isCreating: creatingSelection == .project(project.id),
                                isDisabled: isCreating
                            ) {
                                onCreate(project)
                            }
                        }
                    } else if !hasReceivedState {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading projects...")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
    }
}
