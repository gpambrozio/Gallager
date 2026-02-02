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
    @Environment(ExternalServerClient.self) private var serverClient
    @Environment(PairingManager.self) private var pairingManager
    @Environment(\.claudeProjectScanner) private var projectScanner
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    public init() { }

    @State private var selectedPane: PaneInfo?
    @State private var attachError: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCloseConfirmation = false
    @State private var showingNewSessionSheet = false
    @State private var projects: [ClaudeProjectInfo] = []
    @State private var isLoadingProjects = false
    @State private var isCreatingSession = false
    @State private var creatingProjectPath: String?

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
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
            if tmuxService.isRefreshing && tmuxService.panes.isEmpty {
                loadingView
            } else if let error = tmuxService.lastError, tmuxService.panes.isEmpty {
                errorView(error)
            } else if tmuxService.panes.isEmpty {
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
            symbol: .terminal,
            description: "Start tmux and create some panes to mirror."
        )
    }

    private var paneList: some View {
        let panesWithClaude = tmuxService.panes.filter { windowManager.activeSessions[$0.paneId] != nil }
        let panesWithoutClaude = tmuxService.panes.filter { windowManager.activeSessions[$0.paneId] == nil }

        return List(selection: $selectedPane) {
            if !panesWithClaude.isEmpty {
                Section {
                    ForEach(panesWithClaude) { pane in
                        PaneSidebarRow(pane: pane)
                            .tag(pane)
                    }
                } header: {
                    SectionHeader(title: "Claude Sessions", symbol: .sparkles)
                }
            }

            if !panesWithoutClaude.isEmpty {
                Section {
                    ForEach(panesWithoutClaude) { pane in
                        PaneSidebarRow(pane: pane)
                            .tag(pane)
                    }
                } header: {
                    SectionHeader(title: "Terminals", symbol: .terminal)
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await refreshPanes()
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailContent: some View {
        if let pane = selectedPane {
            MirrorWindowView(paneInfo: pane)
                .id(pane.id)
        } else {
            ContentUnavailableView(
                "Select a Pane",
                symbol: .terminal,
                description: "Choose a pane from the sidebar to view its mirror."
            )
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
            if let pane = selectedPane {
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
                showingNewSessionSheet = true
            } label: {
                Symbols.plus.image
            }
            .help("Create new tmux session")
            .keyboardShortcut("n", modifiers: [.command, .shift])
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
        switch serverClient.state {
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
                .help(serverClient.isIOSConnected
                    ? "Connected - iOS device online"
                    : "Connected - waiting for iOS")
        case let .error(message):
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
                .help("Error: \(message)")
        }
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        if !settings.isPaired {
            // Not paired - show generate pair button
            Button("Generate Pair") {
                openSettingsToRemoteAccess()
            }
            .controlSize(.small)
            .help("Open Remote Access settings to pair with iOS")
        } else if serverClient.state.isConnected {
            // Connected - show disconnect button
            Button("Disconnect") {
                Task {
                    await serverClient.disconnect()
                }
            }
            .controlSize(.small)
            .help("Disconnect from relay server")
        } else if case .connecting = serverClient.state {
            // Connecting - no button
            EmptyView()
        } else if case .reconnecting = serverClient.state {
            // Reconnecting - show cancel button
            Button("Cancel") {
                Task {
                    await serverClient.disconnect()
                }
            }
            .controlSize(.small)
            .help("Cancel reconnection attempts")
        } else {
            // Disconnected but paired - show connect button
            Button("Connect") {
                Task {
                    await connectToServer()
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

    private func connectToServer() async {
        guard
            let pairId = settings.pairId,
            let serverURL = URL(string: settings.externalServerURL),
            let e2eeService
        else {
            return
        }

        let keyInfo = pairingManager.publicKeyInfo
        await serverClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: Host.current().localizedName ?? "Mac",
            publicKey: keyInfo.publicKey.base64EncodedString(),
            publicKeyId: keyInfo.keyId,
            e2eeService: e2eeService,
            partnerPublicKey: settings.partnerPublicKey,
            partnerPublicKeyId: settings.partnerPublicKeyId
        )
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

    private func createNewSession(project: ClaudeProjectInfo?) {
        isCreatingSession = true
        creatingProjectPath = project?.path

        Task {
            do {
                // Determine session name and working directory
                let sessionName = project?.name ?? "terminal"
                let workingDirectory = project?.path

                // Determine if we should run the claude command
                let runCommand: String? = if workingDirectory != nil && settings.autoRunClaudeInProjects {
                    settings.claudeCommandPath
                } else {
                    nil
                }

                // Create the session with reasonable default dimensions
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: sessionName,
                    width: 120,
                    height: 40,
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
}

// MARK: - Section Header

/// A prominent section header with icon and title
private struct SectionHeader: View {
    let title: String
    let symbol: Symbols

    var body: some View {
        HStack(spacing: 6) {
            symbol.image
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))
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
