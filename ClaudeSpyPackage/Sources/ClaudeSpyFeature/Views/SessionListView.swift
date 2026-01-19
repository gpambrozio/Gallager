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
        @Environment(SessionStore.self) private var sessionStore
        @Environment(RelayClient.self) private var relayClient
        @Environment(IOSSettings.self) private var settings

        @State private var isCreatingSession = false

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
        }

        // MARK: - New Session Button

        private var newSessionButton: some View {
            Button {
                Task {
                    await createNewSession()
                }
            } label: {
                if isCreatingSession {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Symbols.plus.image
                }
            }
            .disabled(!relayClient.isMacConnected || isCreatingSession)
        }

        private func createNewSession() async {
            guard !isCreatingSession else { return }

            isCreatingSession = true
            defer { isCreatingSession = false }

            let command = CreateTmuxSession(
                sessionName: settings.newSessionName,
                width: settings.newSessionWidth,
                height: settings.newSessionHeight
            )

            // paneId is not used for session creation, pass empty string
            let result = await relayClient.sendCommand(command, paneId: "")

            switch result {
            case .success:
                // Session created - the session list will update via sessionState
                // Request a refresh to show the new session immediately
                await relayClient.requestSessionState()
            case let .failure(error):
                // Could show an alert here, but for now just log
                print("Failed to create session: \(error)")
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

    #Preview {
        NavigationStack {
            SessionListView()
        }
        .environment(SessionStore())
        .environment(RelayClient())
        .environment(IOSSettings.shared)
    }
#endif
