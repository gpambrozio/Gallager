#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    // MARK: - Navigation

    /// Navigation value for the session list
    struct SessionNavigation: Hashable {
        let sessionName: String
        let hostId: String
    }

    /// View displaying a list of active Claude sessions and terminals from all paired hosts.
    struct SessionListView: View {
        @Binding var navigationPath: NavigationPath
        let onOpenSettings: () -> Void

        @Environment(SessionStore.self) private var sessionStore
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(IOSSettings.self) private var settings

        @State private var creatingSelection: ProjectPickerSelection?
        @State private var creationError: String?
        @State private var selectedHostForNewSession: PairedHost?

        var body: some View {
            Group {
                if sessionStore.hasSessions || !settings.pairedHosts.isEmpty {
                    sessionsList
                } else {
                    emptyStateView
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SessionNavigation.self) { destination in
                if let connection = connectionManager.connection(for: destination.hostId) {
                    WindowLayoutView(
                        sessionName: destination.sessionName,
                        hostId: destination.hostId,
                        relayClient: connection.relayClient,
                        settings: settings
                    )
                } else {
                    hostDisconnectedView
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenSettings()
                    } label: {
                        Symbols.gearshape.image
                    }
                    .accessibilityLabel("Settings")
                }
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
            .sheet(item: $selectedHostForNewSession) { host in
                ProjectPickerSheet(
                    host: host,
                    creatingSelection: creatingSelection
                ) { selectedProject in
                    Task {
                        await createNewSession(on: host, inProject: selectedProject)
                    }
                }
            }
        }

        // MARK: - Sessions List (Grouped by Host)

        private var sessionsList: some View {
            List {
                ForEach(settings.pairedHosts) { host in
                    HostSessionsSection(
                        host: host,
                        connection: connectionManager.connection(for: host.id),
                        sessions: sessionStore.sessions(for: host.id),
                        showUsername: settings.hasDuplicateHostName(for: host),
                        onNewSession: {
                            selectedHostForNewSession = host
                        },
                        onSetDescription: { sessionName, description in
                            Task {
                                let command = SetSessionDescription(sessionName: sessionName, description: description)
                                _ = await connectionManager.sendCommand(command, paneId: "", hostId: host.id)
                            }
                        },
                        onSetColor: { sessionName, color in
                            Task {
                                let command = SetSessionColor(sessionName: sessionName, color: color)
                                _ = await connectionManager.sendCommand(command, paneId: "", hostId: host.id)
                            }
                        },
                        onSetEmoji: { sessionName, emoji in
                            Task {
                                let command = SetSessionEmoji(sessionName: sessionName, emoji: emoji)
                                _ = await connectionManager.sendCommand(command, paneId: "", hostId: host.id)
                            }
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
                Label("No Hosts Paired", symbol: .laptopcomputer)
            } description: {
                Text("Pair a host to see sessions here")
            }
        }

        /// Shown when navigating to a session whose host is no longer connected
        private var hostDisconnectedView: some View {
            ContentUnavailableView {
                Label("Host Disconnected", symbol: .wifiSlash)
            } description: {
                Text("This host is no longer connected. Go back and reconnect to view this session.")
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
            let totalCount = settings.pairedHosts.count

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

        private func createNewSession(on host: PairedHost, inProject project: AgentProject?) async {
            guard creatingSelection == nil else { return }

            // Track which item was selected for the spinner
            creatingSelection = project.map { .project($0.id) } ?? .newTerminal

            // Use project name for session name if available, otherwise use default
            let sessionName = project?.name ?? settings.newSessionName

            let command = CreateTmuxSession(
                sessionName: sessionName,
                width: settings.newSessionWidth,
                height: settings.newSessionHeight,
                workingDirectory: project?.path,
                claudeConfigDir: project?.claudeConfigDir,
                pluginID: project?.pluginID ?? "claude-code"
            )

            // paneId is not used for session creation, pass empty string
            let result = await connectionManager.sendCommand(command, paneId: "", hostId: host.id)

            switch result {
            case let .success(response):
                // Session created - dismiss sheet and clear selection
                creatingSelection = nil
                selectedHostForNewSession = nil

                // Request a refresh to update the session list
                await connectionManager.requestSessionState(for: host.id)

                // Navigate to the new terminal if we got a pane ID
                if
                    let paneId = response.paneId,
                    let paneState = sessionStore.paneState(for: paneId, hostId: host.id) {
                    navigationPath.append(SessionNavigation(sessionName: paneState.sessionName, hostId: host.id))
                }
            case let .failure(error):
                // Include project name in error for context (sheet stays open)
                let projectContext = project?.name ?? "terminal"
                creationError = "Failed to create \(projectContext): \(error.localizedDescription)"
                creatingSelection = nil
            }
        }
    }

    // MARK: - Host Sessions Section

    /// A section displaying sessions and terminals from a single host, grouped by tmux session
    struct HostSessionsSection: View {
        let host: PairedHost
        let connection: ViewerConnection?
        let sessions: [TmuxSession]
        var showUsername = false
        let onNewSession: () -> Void
        var onSetDescription: (String, String?) -> Void = { _, _ in }
        var onSetColor: (String, SessionColor?) -> Void = { _, _ in }
        var onSetEmoji: (String, String?) -> Void = { _, _ in }

        @Environment(SessionStore.self) private var sessionStore

        private var hasContent: Bool {
            !sessions.isEmpty
        }

        /// Sessions that contain at least one Claude session
        private var agentSessions: [TmuxSession] {
            sessions.filter(\.hasClaude)
        }

        /// Sessions without any Claude sessions (plain terminals)
        private var terminalSessions: [TmuxSession] {
            sessions.filter { !$0.hasClaude }
        }

        var body: some View {
            Section {
                if let mismatch = connection?.versionMismatch {
                    HostVersionMismatchRow(host: host, mismatch: mismatch) {
                        Task { await connection?.enableReconnectAndRetry() }
                    }
                    .accessibilityIdentifier("host-version-mismatch-row")
                } else if hasContent {
                    // Claude sessions
                    ForEach(agentSessions) { session in
                        sessionRow(session)
                    }

                    // Plain terminal sessions
                    ForEach(terminalSessions) { session in
                        sessionRow(session)
                    }
                } else {
                    // Empty state for this host
                    if connection?.isHostConnected == true {
                        Text("No active sessions")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Host offline")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HostSectionHeader(
                    host: host,
                    connection: connection,
                    showUsername: showUsername,
                    onNewSession: onNewSession
                )
            }
        }

        @ViewBuilder
        private func sessionRow(_ session: TmuxSession) -> some View {
            let activeWindow = session.activeWindow
            let activePaneInSession = activeWindow?.activePane ?? activeWindow?.panes.first
            // Find the first pane with a Claude session (may differ from the active pane)
            let claudePaneInSession = session.windows.flatMap(\.panes).first(where: { $0.agentSession != nil })
            // CLI-driven state override propagated from the host, if any pane has one set.
            let cliSessionState = session.windows.flatMap(\.panes).compactMap(\.cliSessionState).first
            // Latest `OSC 9;4` progress from any pane in this session, propagated by the host.
            let sessionProgress = session.windows.flatMap(\.panes).compactMap(\.progress).first

            NavigationLink(value: SessionNavigation(sessionName: session.sessionName, hostId: host.id)) {
                VStack(spacing: 0) {
                    if let claudePane = claudePaneInSession, let agentSession = claudePane.agentSession {
                        SessionRowView(
                            paneId: claudePane.paneId,
                            session: agentSession,
                            cliSessionState: cliSessionState,
                            isActive: sessionStore.isPaneActive(paneId: claudePane.paneId, hostId: host.id),
                            customDescription: session.customDescription,
                            customEmoji: session.customEmoji,
                            windowCount: session.windows.count
                        )
                    } else if let pane = activePaneInSession {
                        TerminalRowView(
                            pane: pane,
                            customEmoji: session.customEmoji,
                            windowCount: session.windows.count
                        )
                    }
                }
                // The visual progress bar is rendered as an .overlay outside
                // the NavigationLink (below) so the cell stays compact, but
                // overlays sit outside the row's combined Button AX element.
                // Mirror the bar's label/value into the button via an
                // invisible label so e2e queries (and VoiceOver) can find it.
                .overlay {
                    if let sessionProgress {
                        Text("Terminal progress \(sessionProgress.accessibilityValueString)")
                            .accessibilityLabel("Terminal progress")
                            .accessibilityValue(sessionProgress.accessibilityValueString)
                            .font(.system(size: 1))
                            .opacity(0)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .overlay(alignment: .leading) {
                SessionColorBar(color: session.customColor)
                    .padding(.top, -8)
                    .padding(.bottom, 8)
            }
            .overlay(alignment: .bottom) {
                if let sessionProgress {
                    TerminalProgressBar(state: sessionProgress)
                        .padding(.leading, 16)
                }
            }
            .accessibilityValue(cliSessionState?.statusLabel ?? claudePaneInSession?.agentSession?.statusLabel ?? "")
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
                }
            ))
            .listRowInsets(
                EdgeInsets(top: 15, leading: 0, bottom: 0, trailing: 16)
            )
        }
    }

    // MARK: - Host Section Header

    /// Header for a host's session section showing name and connection status
    struct HostSectionHeader: View {
        let host: PairedHost
        let connection: ViewerConnection?
        var showUsername = false
        let onNewSession: () -> Void

        var body: some View {
            HStack {
                // Host name
                Text(host.displayName(showUsername: showUsername))

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
                .accessibilityLabel("New Session")

                // Connection status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
        }

        private var statusColor: Color {
            guard let connection else { return .gray }

            if connection.versionMismatch != nil {
                return .orange
            }
            if connection.isHostConnected {
                return .green
            } else if connection.isRelayConnected {
                return .yellow
            } else {
                return .red
            }
        }
    }

    // MARK: - Host Version Mismatch Row

    /// Callout row rendered inside a host's session section when the host's
    /// peerHello handshake failed version compatibility. Lives on the Sessions
    /// tab — the first surface users see — so a "Host offline" caption is never
    /// the only explanation for an unreachable host.
    private struct HostVersionMismatchRow: View {
        let host: PairedHost
        let mismatch: VersionCompatibility.VersionMismatch
        let onRetry: () -> Void

        @State private var showingRetryDialog = false

        var body: some View {
            Button {
                showingRetryDialog = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Symbols.arrowUpCircleFill.image
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .confirmationDialog(
                dialogTitle,
                isPresented: $showingRetryDialog,
                titleVisibility: .visible
            ) {
                Button("Retry") {
                    onRetry()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(dialogMessage)
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

        private var dialogTitle: String {
            switch mismatch {
            case .weAreTooOld:
                "Retry connection?"
            case .partnerTooOld:
                "Retry connection to \(host.displayName)?"
            }
        }

        private var dialogMessage: String {
            switch mismatch {
            case .weAreTooOld:
                "Try again after updating this app to a compatible version."
            case .partnerTooOld:
                "If \(host.displayName) was updated to a compatible version, the connection will succeed."
            }
        }
    }

    // MARK: - Session Row View

    struct SessionRowView: View {
        let paneId: String
        let session: AgentSession
        var cliSessionState: CLISessionState?
        let isActive: Bool
        var customDescription: String?
        var customEmoji: String?
        var windowCount = 1

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    Group {
                        if let cliSessionState {
                            SessionStatusIndicator(cliState: cliSessionState)
                        } else {
                            SessionStatusIndicator(session: session)
                        }
                    }
                    .frame(width: 20, height: 20)

                    if let customEmoji {
                        SessionEmojiBadge(emoji: customEmoji)
                            .font(.system(size: 16))
                    }
                }
                .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    // Custom description shown prominently if set
                    if let customDescription {
                        HStack {
                            Text(customDescription)
                                .font(.headline)
                            if windowCount > 1 {
                                Text("\(windowCount) windows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                            PluginBadge(pluginID: session.pluginID)
                        }

                        Text(session.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            // Project folder name (or pane ID as fallback)
                            Text(session.displayName)
                                .font(.headline)
                            if windowCount > 1 {
                                Text("\(windowCount) windows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                            PluginBadge(pluginID: session.pluginID)
                        }
                    }

                    // swiftlint:disable:next todo
                    // TODO(plugin-system): The latest event title/timestamp
                    // and the trailing-5 event count came from
                    // `ClaudeSession.events` and `latestEvent`, both of which
                    // are gone in the AgentSession migration. Task 18+ will
                    // surface a status string pushed by the plugin sidecar.
                    if let timestamp = session.lastEventTimestamp {
                        HStack {
                            Text(session.statusLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(DateFormatters.relativeTime(for: timestamp))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Plugin Badge

    /// Compact icon + short-name badge identifying which plugin owns a
    /// session. Reads the presentation from `PluginPresentationCache` —
    /// the Mac pushes one `plugin_presentations` payload per connect /
    /// upgrade so the cache is normally warm before any session row
    /// renders. When the cache hasn't seen this plugin yet (e.g. the
    /// session arrived in a `session_state` message before the Mac
    /// pushed presentations), falls back to the raw plugin id text and
    /// a neutral gear icon so the row still renders.
    private struct PluginBadge: View {
        let pluginID: String

        @Environment(PluginPresentationCache.self) private var cache

        // Decoded once per icon-data change (see `.task(id:)`) rather than on
        // every `body` evaluation, so repeated list re-renders reuse the same
        // image instead of re-parsing the PNG each time.
        @State private var decodedIcon: UIImage?

        var body: some View {
            HStack(spacing: 4) {
                icon
                    .frame(width: 14, height: 14)
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.18))
            )
            .foregroundStyle(Color.accentColor)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .task(id: cache.presentation(for: pluginID)?.iconPNGData) {
                if let data = cache.presentation(for: pluginID)?.iconPNGData {
                    decodedIcon = UIImage(data: data)
                } else {
                    decodedIcon = nil
                }
            }
        }

        private var label: String {
            cache.presentation(for: pluginID)?.shortName ?? pluginID
        }

        @ViewBuilder
        private var icon: some View {
            if let decodedIcon {
                Image(uiImage: decodedIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Symbols.gearshape.image
                    .font(.caption2)
            }
        }
    }

    // MARK: - Terminal Row View

    /// Row view for plain terminals (no Claude session)
    struct TerminalRowView: View {
        let pane: PaneState
        var customEmoji: String?
        var windowCount = 1

        /// Display name derived from current path or pane ID
        private var displayName: String {
            if let path = pane.currentPath, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return pane.paneId
        }

        /// Subtitle showing session:window.pane info
        private var subtitle: String {
            pane.target.isEmpty ? pane.paneId : pane.target
        }

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    Group {
                        if let cliState = pane.cliSessionState {
                            SessionStatusIndicator(cliState: cliState)
                        } else {
                            // Terminal icon instead of activity indicator
                            Symbols.terminal.image
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)

                    if let customEmoji {
                        SessionEmojiBadge(emoji: customEmoji)
                            .font(.system(size: 16))
                    }
                }
                .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    // Custom description shown prominently if set
                    if let customDescription = pane.customDescription {
                        HStack {
                            Text(customDescription)
                                .font(.headline)
                            if windowCount > 1 {
                                Text("\(windowCount) windows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }

                        Text(displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            // Display name (folder name or pane ID)
                            Text(displayName)
                                .font(.headline)
                            if windowCount > 1 {
                                Text("\(windowCount) windows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }

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

                Spacer()
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
        let host: PairedHost
        /// The currently selected item (shows spinner), nil if nothing selected yet
        let creatingSelection: ProjectPickerSelection?
        let onSelect: (AgentProject?) -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(SessionStore.self) private var sessionStore
        @Environment(PluginPresentationCache.self) private var presentationCache
        @State private var searchText = ""

        private var isCreating: Bool {
            creatingSelection != nil
        }

        /// Projects for this host, read from SessionStore to auto-update when state arrives
        private var projects: [AgentProject] {
            sessionStore.projects(for: host.id)
        }

        private var filteredProjects: [AgentProject] {
            guard !searchText.isEmpty else { return projects }
            return projects.filter { $0.name.fuzzyMatches(searchText) }
        }

        var body: some View {
            NavigationStack {
                List {
                    // Default option (no specific project)
                    if searchText.isEmpty {
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
                    }

                    // Project list
                    if !filteredProjects.isEmpty {
                        Section("Projects") {
                            ForEach(filteredProjects) { project in
                                Button {
                                    onSelect(project)
                                } label: {
                                    HStack {
                                        Symbols.folder.image
                                            .foregroundStyle(.blue)
                                            .frame(width: 24)

                                        VStack(alignment: .leading) {
                                            HStack(spacing: 6) {
                                                Text(project.name)
                                                    .foregroundStyle(.primary)

                                                if project.pluginID != "claude-code" {
                                                    Text(
                                                        presentationCache.presentation(for: project.pluginID)?.shortName
                                                            ?? project.pluginID
                                                    )
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(
                                                        Capsule().fill(Color.accentColor.opacity(0.18))
                                                    )
                                                    .foregroundStyle(Color.accentColor)
                                                }
                                            }
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
                    } else if !searchText.isEmpty {
                        Section {
                            Text("No matching projects")
                                .foregroundStyle(.secondary)
                        }
                    } else if !sessionStore.hasReceivedState(for: host.id) {
                        Section("Projects") {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading projects...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "Search projects")
                .onSubmit(of: .search) {
                    if filteredProjects.count == 1 {
                        onSelect(filteredProjects[0])
                    }
                }
                .navigationTitle("New Session on \(host.displayName)")
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

    // MARK: - Preview

    #Preview("Session List") {
        SessionListPreview()
    }

    @MainActor
    private struct SessionListPreview: View {
        @State private var navigationPath = NavigationPath()
        @State private var sessionStore = SessionStore()
        @State private var settings = IOSSettings()
        @State private var connectionManager: ViewerConnectionManager?
        // Previews persist nothing; route the cache at a throwaway temp file.
        @State private var presentationCache = PluginPresentationCache(
            diskURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("SessionListPreview-presentations.json")
        )

        private let host = PairedHost(
            id: "preview-host",
            hostName: "Preview Mac",
            username: "preview",
            partnerPublicKey: "",
            partnerPublicKeyId: ""
        )

        var body: some View {
            Group {
                if let connectionManager {
                    NavigationStack(path: $navigationPath) {
                        SessionListView(navigationPath: $navigationPath, onOpenSettings: { })
                            .environment(sessionStore)
                            .environment(connectionManager)
                            .environment(settings)
                            .environment(presentationCache)
                    }
                } else {
                    ProgressView()
                }
            }
            .task {
                settings.addPairing(host)

                let panes: [String: PaneState] = [
                    "%1": PaneState(
                        paneId: "%1",
                        target: "alpha:0.0",
                        sessionName: "alpha",
                        currentPath: "/Users/preview/AlphaProject",
                        isActive: true,
                        isWindowActive: true,
                        customColor: .blue,
                        agentSession: AgentSession(
                            id: "preview-alpha",
                            pluginID: "claude-code",
                            tmuxPane: "%1",
                            projectPath: "/Users/preview/AlphaProject"
                        )
                    ),
                    "%2": PaneState(
                        paneId: "%2",
                        target: "bravo:0.0",
                        sessionName: "bravo",
                        currentPath: "/Users/preview/BravoProject",
                        isActive: true,
                        isWindowActive: true,
                        customColor: .red,
                        agentSession: AgentSession(
                            id: "preview-bravo",
                            pluginID: "codex",
                            tmuxPane: "%2",
                            projectPath: "/Users/preview/BravoProject"
                        ),
                        progress: .normal(50)
                    ),
                    "%3": PaneState(
                        paneId: "%3",
                        target: "scratch:0.0",
                        sessionName: "scratch",
                        command: "zsh",
                        currentPath: "/Users/preview",
                        isActive: true,
                        isWindowActive: true
                    ),
                ]
                sessionStore.handleStateUpdate(SessionStateMessage(
                    pairId: host.id,
                    paneStates: panes,
                    homeDirectory: "/Users/preview"
                ))

                connectionManager = try? await ViewerConnectionManager()
            }
        }
    }
#endif
