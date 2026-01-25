#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    // MARK: - Navigation

    /// Navigation value for the session list
    enum SessionNavigation: Hashable {
        /// Navigate to a Claude session detail view
        case claudeSession(paneId: String)
        /// Navigate directly to live terminal for a plain terminal (no Claude session)
        case plainTerminal(paneId: String)
    }

    /// View displaying a list of active Claude sessions and terminals from the Mac.
    struct SessionListView: View {
        @Binding var navigationPath: NavigationPath

        @Environment(SessionStore.self) private var sessionStore
        @Environment(RelayClient.self) private var relayClient
        @Environment(IOSSettings.self) private var settings

        @State private var creatingSelection: ProjectPickerSelection?
        @State private var creationError: String?
        @State private var showProjectPicker = false

        var body: some View {
            Group {
                if sessionStore.hasSessions {
                    sessionsList
                } else {
                    emptyStateView
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionNavigation.self) { destination in
                switch destination {
                case let .claudeSession(paneId):
                    SessionDetailView(
                        paneId: paneId,
                        sessionStore: sessionStore,
                        relayClient: relayClient
                    )
                case let .plainTerminal(paneId):
                    PlainTerminalView(
                        paneId: paneId,
                        relayClient: relayClient,
                        settings: settings
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    newSessionButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    connectionStatusView
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
            .sheet(isPresented: $showProjectPicker) {
                ProjectPickerSheet(
                    projects: sessionStore.claudeProjects,
                    creatingSelection: creatingSelection
                ) { selectedProject in
                    Task {
                        await createNewSession(inProject: selectedProject)
                    }
                }
            }
        }

        // MARK: - New Session Button

        private var newSessionButton: some View {
            Button {
                showProjectPicker = true
            } label: {
                if creatingSelection != nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Symbols.plus.image
                }
            }
            .disabled(!relayClient.isMacConnected || creatingSelection != nil)
        }

        private func createNewSession(inProject project: ClaudeProjectInfo?) async {
            guard creatingSelection == nil else { return }

            // Track which item was selected for the spinner
            creatingSelection = project.map { .project($0.id) } ?? .newTerminal
            defer {
                creatingSelection = nil
                showProjectPicker = false
            }

            // Use project name for session name if available, otherwise use default
            let sessionName = project?.name ?? settings.newSessionName

            let command = CreateTmuxSession(
                sessionName: sessionName,
                width: settings.newSessionWidth,
                height: settings.newSessionHeight,
                workingDirectory: project?.path
            )

            // paneId is not used for session creation, pass empty string
            let result = await relayClient.sendCommand(command, paneId: "")

            switch result {
            case let .success(response):
                // Session created - request a refresh to update the session list
                await relayClient.requestSessionState()

                // Navigate to the new terminal if we got a pane ID
                if let paneId = response.paneId {
                    navigationPath.append(SessionNavigation.plainTerminal(paneId: paneId))
                }
            case let .failure(error):
                creationError = error.localizedDescription
            }
        }

        // MARK: - Sessions List

        private var sessionsList: some View {
            List {
                // Section 1: Claude Sessions (if any)
                if !sessionStore.claudeSessionPanes.isEmpty {
                    Section("Claude Code") {
                        ForEach(sessionStore.claudeSessionPanes, id: \.paneId) { item in
                            NavigationLink(value: SessionNavigation.claudeSession(paneId: item.paneId)) {
                                SessionRowView(
                                    paneId: item.paneId,
                                    session: item.session,
                                    isActive: sessionStore.isPaneActive(item.paneId)
                                )
                            }
                        }
                    }
                }

                // Section 2: Plain Terminals (if any)
                if !sessionStore.plainTerminalPanes.isEmpty {
                    Section("Terminals") {
                        ForEach(sessionStore.plainTerminalPanes) { pane in
                            NavigationLink(value: SessionNavigation.plainTerminal(paneId: pane.id)) {
                                TerminalRowView(pane: pane)
                            }
                        }
                    }
                }
            }
            .refreshable {
                await relayClient.requestSessionState()
            }
        }

        // MARK: - Empty State

        private var emptyStateView: some View {
            ContentUnavailableView {
                Label("No Terminals", symbol: .terminal)
            } description: {
                if relayClient.isMacConnected {
                    Text("No active terminals on your Mac")
                } else {
                    Text("Waiting for Mac to connect...")
                }
            } actions: {
                if relayClient.state.isConnected {
                    Button("Refresh") {
                        Task {
                            await relayClient.requestSessionState()
                        }
                    }
                }
            }
        }

        // MARK: - Connection Status

        private var connectionStatusView: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)

                Text(connectionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        private var connectionStatusColor: Color {
            if relayClient.isMacConnected {
                return .green
            } else if relayClient.state.isConnected {
                return .yellow
            } else {
                return .red
            }
        }

        private var connectionStatusText: String {
            if relayClient.isMacConnected {
                return "Mac Online"
            } else if relayClient.state.isConnected {
                return "Waiting for Mac"
            } else {
                return relayClient.state.statusText
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
        let projects: [ClaudeProjectInfo]
        /// The currently selected item (shows spinner), nil if nothing selected yet
        let creatingSelection: ProjectPickerSelection?
        let onSelect: (ClaudeProjectInfo?) -> Void

        @Environment(\.dismiss) private var dismiss

        private var isCreating: Bool {
            creatingSelection != nil
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
                    }
                }
                .navigationTitle("New Session")
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

    #Preview {
        @Previewable @State var path = NavigationPath()
        NavigationStack(path: $path) {
            SessionListView(navigationPath: $path)
        }
        .environment(SessionStore())
        .environment(RelayClient())
        .environment(IOSSettings.shared)
    }
#endif
