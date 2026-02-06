#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    // MARK: - Navigation

    /// Navigation value for the session list
    enum SessionNavigation: Hashable {
        /// Navigate to live terminal for a Claude session
        case claudeSession(paneId: String, hostId: String)
        /// Navigate to live terminal for a plain terminal (no Claude session)
        case plainTerminal(paneId: String, hostId: String)
    }

    /// View displaying a list of active Claude sessions and terminals from all paired Macs.
    struct SessionListView: View {
        @Binding var navigationPath: NavigationPath

        @Environment(SessionStore.self) private var sessionStore
        @Environment(ConnectionManager.self) private var connectionManager
        @Environment(IOSSettings.self) private var settings

        @State private var creatingSelection: ProjectPickerSelection?
        @State private var creationError: String?
        @State private var selectedMacForNewSession: PairedMac?

        var body: some View {
            Group {
                if sessionStore.hasSessions || !settings.pairedMacs.isEmpty {
                    sessionsList
                } else {
                    emptyStateView
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SessionNavigation.self) { destination in
                switch destination {
                case let .claudeSession(paneId, hostId):
                    if let connection = connectionManager.connection(for: hostId) {
                        ClaudeSessionTerminalView(
                            paneId: paneId,
                            sessionStore: sessionStore,
                            relayClient: connection.relayClient,
                            settings: settings
                        )
                    } else {
                        macDisconnectedView
                    }
                case let .plainTerminal(paneId, hostId):
                    if let connection = connectionManager.connection(for: hostId) {
                        PlainTerminalView(
                            paneId: paneId,
                            relayClient: connection.relayClient,
                            settings: settings
                        )
                    } else {
                        macDisconnectedView
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    overallConnectionStatusView
                }
            }
            .alert("Session Creation Failed", isPresented: .init(
                get: { creationError != nil },
                set: { if !$0 { creationError = nil } }
            )) {
                Button("OK") {
                    creationError = nil
                }
            } message: {
                if let error = creationError {
                    Text(error)
                }
            }
            .sheet(item: $selectedMacForNewSession) { mac in
                ProjectPickerSheet(
                    mac: mac,
                    creatingSelection: creatingSelection
                ) { selectedProject in
                    Task {
                        await createNewSession(on: mac, inProject: selectedProject)
                    }
                }
            }
        }

        // MARK: - Sessions List (Grouped by Mac)

        private var sessionsList: some View {
            List {
                ForEach(settings.pairedMacs) { mac in
                    MacSessionsSection(
                        mac: mac,
                        connection: connectionManager.connection(for: mac.id),
                        sessions: sessionStore.sessions(for: mac.id),
                        panes: sessionStore.panes(for: mac.id),
                        showUsername: settings.hasDuplicateMacName(for: mac),
                        onNewSession: {
                            selectedMacForNewSession = mac
                        }
                    )
                }
            }
            .refreshable {
                await connectionManager.requestAllSessionStates()
            }
        }

        // MARK: - Empty State

        private var emptyStateView: some View {
            ContentUnavailableView {
                Label("No Macs Paired", symbol: .laptopcomputer)
            } description: {
                Text("Pair your Mac to see sessions here")
            }
        }

        /// Shown when navigating to a session whose Mac is no longer connected
        private var macDisconnectedView: some View {
            ContentUnavailableView {
                Label("Mac Disconnected", symbol: .wifiSlash)
            } description: {
                Text("This Mac is no longer connected. Go back and reconnect to view this session.")
            }
        }

        // MARK: - Overall Connection Status

        private var overallConnectionStatusView: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(overallConnectionStatusColor)
                    .frame(width: 8, height: 8)

                Text(overallConnectionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        private var overallConnectionStatusColor: Color {
            if connectionManager.anyHostConnected {
                return .green
            } else if connectionManager.isConnecting {
                return .yellow
            } else {
                return .red
            }
        }

        private var overallConnectionStatusText: String {
            let connectedCount = connectionManager.activeConnections.filter(\.isHostConnected).count
            let totalCount = settings.pairedMacs.count

            if connectedCount == totalCount && totalCount > 0 {
                return totalCount == 1 ? "Connected" : "All Connected"
            } else if connectedCount > 0 {
                return "\(connectedCount)/\(totalCount) Online"
            } else if connectionManager.isConnecting {
                return "Connecting..."
            } else {
                return "Disconnected"
            }
        }

        // MARK: - New Session Creation

        private func createNewSession(on mac: PairedMac, inProject project: ClaudeProjectInfo?) async {
            guard creatingSelection == nil else { return }

            // Track which item was selected for the spinner
            creatingSelection = project.map { .project($0.id) } ?? .newTerminal

            // Use project name for session name if available, otherwise use default
            let sessionName = project?.name ?? settings.newSessionName

            let command = CreateTmuxSession(
                sessionName: sessionName,
                width: settings.newSessionWidth,
                height: settings.newSessionHeight,
                workingDirectory: project?.path
            )

            // paneId is not used for session creation, pass empty string
            let result = await connectionManager.sendCommand(command, paneId: "", hostId: mac.id)

            switch result {
            case let .success(response):
                // Session created - dismiss sheet and clear selection
                creatingSelection = nil
                selectedMacForNewSession = nil

                // Request a refresh to update the session list
                await connectionManager.requestSessionState(for: mac.id)

                // Navigate to the new terminal if we got a pane ID
                if let paneId = response.paneId {
                    navigationPath.append(SessionNavigation.plainTerminal(paneId: paneId, hostId: mac.id))
                }
            case let .failure(error):
                // Include project name in error for context (sheet stays open)
                let projectContext = project?.name ?? "terminal"
                creationError = "Failed to create \(projectContext): \(error.localizedDescription)"
                creatingSelection = nil
            }
        }
    }

    // MARK: - Mac Sessions Section

    /// A section displaying sessions and terminals from a single Mac
    struct MacSessionsSection: View {
        let mac: PairedMac
        let connection: MacConnection?
        let sessions: [(paneId: String, session: ClaudeSession)]
        let panes: [PaneInfoMessage]
        var showUsername = false
        let onNewSession: () -> Void

        @Environment(SessionStore.self) private var sessionStore

        private var hasContent: Bool {
            !sessions.isEmpty || !panes.isEmpty
        }

        var body: some View {
            Section {
                if hasContent {
                    // Claude sessions for this Mac
                    ForEach(sessions, id: \.paneId) { item in
                        NavigationLink(value: SessionNavigation.claudeSession(paneId: item.paneId, hostId: mac.id)) {
                            SessionRowView(
                                paneId: item.paneId,
                                session: item.session,
                                isActive: sessionStore.isPaneActive(item.paneId)
                            )
                        }
                    }

                    // Plain terminals for this Mac
                    ForEach(panes) { pane in
                        NavigationLink(value: SessionNavigation.plainTerminal(paneId: pane.id, hostId: mac.id)) {
                            TerminalRowView(pane: pane)
                        }
                    }
                } else {
                    // Empty state for this Mac
                    if connection?.isHostConnected == true {
                        Text("No active sessions")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Mac offline")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                MacSectionHeader(
                    mac: mac,
                    connection: connection,
                    showUsername: showUsername,
                    onNewSession: onNewSession
                )
            }
        }
    }

    // MARK: - Mac Section Header

    /// Header for a Mac's session section showing name and connection status
    struct MacSectionHeader: View {
        let mac: PairedMac
        let connection: MacConnection?
        var showUsername = false
        let onNewSession: () -> Void

        var body: some View {
            HStack {
                // Mac name
                Text(mac.displayName(showUsername: showUsername))

                Spacer()

                // New session button
                Button {
                    onNewSession()
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .disabled(connection?.isHostConnected != true)
                .buttonStyle(.borderless)

                // Connection status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
        }

        private var statusColor: Color {
            guard let connection else { return .gray }

            if connection.isHostConnected {
                return .green
            } else if connection.isRelayConnected {
                return .yellow
            } else {
                return .red
            }
        }
    }

    // MARK: - Session Row View

    struct SessionRowView: View {
        let paneId: String
        let session: ClaudeSession
        let isActive: Bool

        private var indicatorColor: Color {
            if session.needsAttention {
                return .red
            } else if isActive {
                return .green
            } else {
                return .gray.opacity(0.3)
            }
        }

        var body: some View {
            HStack(spacing: 12) {
                // Activity indicator - red for notification, green for active, gray for inactive
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    // Project folder name (or pane ID as fallback)
                    Text(session.displayName)
                        .font(.headline)

                    // Latest event summary
                    if let latestEvent = session.latestEvent {
                        HStack {
                            Text(latestEvent.action.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(DateFormatters.relativeTime(for: latestEvent.timestamp))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Event count
                    Text("\(session.events.count) recent events")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Terminal Row View

    /// Row view for plain terminals (no Claude session)
    struct TerminalRowView: View {
        let pane: PaneInfoMessage

        /// Display name derived from current path or pane ID
        private var displayName: String {
            if let path = pane.currentPath, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return pane.id
        }

        /// Subtitle showing session:window.pane info
        private var subtitle: String {
            "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
        }

        var body: some View {
            HStack(spacing: 12) {
                // Terminal icon instead of activity indicator
                Symbols.terminal.image
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    // Display name (folder name or pane ID)
                    Text(displayName)
                        .font(.headline)

                    // Command and path info
                    HStack {
                        if let command = pane.command, !command.isEmpty {
                            Text(command)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Dimensions
                    Text("\(pane.width)×\(pane.height)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Project Picker Sheet

    /// Identifier for the selected item in the project picker
    enum ProjectPickerSelection: Equatable {
        case newTerminal
        case project(String) // project path as ID
    }

    /// Sheet for selecting a Claude project to create a new session in
    struct ProjectPickerSheet: View {
        let mac: PairedMac
        /// The currently selected item (shows spinner), nil if nothing selected yet
        let creatingSelection: ProjectPickerSelection?
        let onSelect: (ClaudeProjectInfo?) -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(SessionStore.self) private var sessionStore

        private var isCreating: Bool {
            creatingSelection != nil
        }

        /// Projects for this Mac, read from SessionStore to auto-update when state arrives
        private var projects: [ClaudeProjectInfo] {
            sessionStore.projects(for: mac.id)
        }

        var body: some View {
            NavigationStack {
                List {
                    // Default option (no specific project)
                    Section {
                        Button {
                            onSelect(nil)
                        } label: {
                            HStack {
                                Symbols.terminal.image
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading) {
                                    Text("New Terminal")
                                        .foregroundStyle(.primary)
                                    Text("Start in home directory")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if creatingSelection == .newTerminal {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isCreating)
                    }

                    // Project list
                    if !projects.isEmpty {
                        Section("Claude Projects") {
                            ForEach(projects) { project in
                                Button {
                                    onSelect(project)
                                } label: {
                                    HStack {
                                        Symbols.folder.image
                                            .foregroundStyle(.blue)
                                            .frame(width: 24)

                                        VStack(alignment: .leading) {
                                            Text(project.name)
                                                .foregroundStyle(.primary)
                                            Text(project.path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()

                                        if creatingSelection == .project(project.id) {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                }
                                .disabled(isCreating)
                            }
                        }
                    } else if !sessionStore.hasReceivedState(for: mac.id) {
                        Section("Claude Projects") {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading projects...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("New Session on \(mac.displayName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .disabled(isCreating)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
#endif
