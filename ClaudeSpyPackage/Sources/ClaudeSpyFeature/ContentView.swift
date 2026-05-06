#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI
    import UserNotifications

    /// Main entry point for the ClaudeSpy iOS app.
    ///
    /// Manages the app's primary state:
    /// - Shows pairing view if no hosts are paired
    /// - Shows main session view once at least one host is paired
    /// - Handles WebSocket connections for all paired hosts
    /// - Manages background task to keep connections alive when backgrounded
    public struct ContentView: View {
        @State private var settings = IOSSettings()
        @State private var connectionManager: ViewerConnectionManager?
        @State private var sessionStore = SessionStore()
        @State private var initializationError: String?

        @Environment(\.scenePhase) private var scenePhase
        @State private var pushService = PushNotificationService.shared
        @State private var backgroundTaskService = BackgroundTaskService.shared

        public init() { }

        public var body: some View {
            Group {
                if let error = initializationError {
                    ContentUnavailableView(
                        "Initialization Failed",
                        image: Symbols.exclamationmarkTriangle.rawValue,
                        description: Text(error)
                    )
                } else if let connectionManager {
                    if settings.isPaired {
                        MainView()
                            .environment(connectionManager)
                    } else if let e2ee = connectionManager.pairingService {
                        NavigationStack {
                            PairingView { pairedHost in
                                handlePairingComplete(pairedHost)
                            }
                            .e2eeService(e2ee)
                        }
                    } else {
                        // Key pair not available - shouldn't happen
                        ContentUnavailableView(
                            "Encryption Error",
                            image: Symbols.lockTriangleBadgeExclamationmark.rawValue,
                            description: Text("Unable to initialize encryption. Please restart the app.")
                        )
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }
            .environment(settings)
            .environment(sessionStore)
            .preferredColorScheme(settings.appearanceMode.colorScheme)
            .task {
                await initializeConnectionManager()
                setupConnectionManagerHandlers()
                await autoConnectIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }

        /// Handle scene phase changes to manage background task lifecycle.
        ///
        /// When the app enters the background, we start a background task to keep
        /// the WebSocket connections alive for ~30 seconds. This allows receiving
        /// any pending events before iOS suspends the app.
        ///
        /// When returning to foreground, we immediately attempt reconnection to avoid
        /// waiting for exponential backoff timers.
        private func handleScenePhaseChange(_ phase: ScenePhase) {
            switch phase {
            case .background:
                // Only start background task if we have any active connections
                if connectionManager?.anyHostConnected == true {
                    backgroundTaskService.startBackgroundTask()
                }
            case .active:
                // End background task when returning to foreground
                backgroundTaskService.endBackgroundTask()

                // Immediately try to reconnect all connections
                Task {
                    await connectionManager?.reconnectAllImmediately()
                }
            case .inactive:
                // Transitional state - no action needed
                break
            @unknown default:
                break
            }
        }

        // MARK: - Setup

        private func setupConnectionManagerHandlers() {
            guard let connectionManager else { return }

            connectionManager.onHookEvent = { [sessionStore] event in
                Task { @MainActor in
                    sessionStore.handleEvent(event)

                    // If app is backgrounded, show a local notification.
                    // The server won't send a push since we're "connected" via WebSocket,
                    // but the user can't see the app, so we need to alert them.
                    if scenePhase != .active {
                        if let notification = event.buildNotification() {
                            PushNotificationService.shared.scheduleLocalNotification(
                                title: notification.title,
                                body: notification.body,
                                paneId: event.event.tmuxPane,
                                hostId: event.pairId
                            )
                        }
                    }
                }
            }

            connectionManager.onSessionState = { [sessionStore] state in
                Task { @MainActor in
                    sessionStore.handleStateUpdate(state)
                }
            }

            connectionManager.onPartnerKeyReceived = { [settings] hostId, publicKey, keyId in
                if let host = settings.getPairing(id: hostId) {
                    let updatedHost = PairedHost(
                        id: host.id,
                        hostName: host.hostName,
                        username: host.username,
                        partnerPublicKey: publicKey,
                        partnerPublicKeyId: keyId,
                        pairedAt: host.pairedAt,
                        customName: host.customName
                    )
                    settings.updatePairing(updatedHost)
                }
            }

            connectionManager.onHostDisconnected = { [sessionStore] hostId in
                sessionStore.clearSessions(for: hostId)
            }

            connectionManager.onUnpaired = { [settings] hostId in
                settings.removePairing(id: hostId)
            }
        }

        private func autoConnectIfNeeded() async {
            guard
                settings.isPaired,
                settings.autoReconnect,
                let connectionManager,
                let serverURL = URL(string: settings.externalServerURL)
            else {
                return
            }

            await connectionManager.connectAll(
                pairedHosts: settings.pairedHosts,
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName
            )

            // Request push permissions if not already authorized
            if pushService.permissionStatus != .authorized {
                await requestPushNotificationPermissions()
            }

            // Send push token to all connected hosts
            if let token = pushService.tokenString {
                await connectionManager.sendPushTokenToAll(token)
            }
        }

        // MARK: - Connection Manager Initialization

        private func initializeConnectionManager() async {
            guard connectionManager == nil else { return }

            do {
                connectionManager = try await ViewerConnectionManager()
            } catch {
                initializationError = "Failed to initialize encryption: \(error.localizedDescription)"
            }
        }

        // MARK: - Pairing

        private func handlePairingComplete(_ pairedHost: PairedHost) {
            // Add the new pairing to settings
            settings.addPairing(pairedHost)

            // Connect to the new host
            Task {
                guard let connectionManager, let serverURL = URL(string: settings.externalServerURL) else { return }

                await connectionManager.connect(
                    to: pairedHost,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: settings.deviceName
                )

                // Request push notification permissions after successful pairing
                await requestPushNotificationPermissions()
            }
        }

        /// Request push notification permissions and register token with server
        private func requestPushNotificationPermissions() async {
            do {
                try await pushService.requestAuthorization()

                // Wait a brief moment for the token to be received from APNs
                try? await Task.sleep(for: .milliseconds(500))

                // If we have a token and have connections, send it to all servers
                if let token = pushService.tokenString, let connectionManager {
                    await connectionManager.sendPushTokenToAll(token)
                }
            } catch {
                // Permission denied or error - not critical, app still works without push
                print("Push notification authorization failed: \(error)")
            }
        }
    }

    // MARK: - Main View

    /// The main interface after pairing.
    ///
    /// Shows a session list with a Settings button in the toolbar that
    /// presents the SettingsView as a sheet.
    struct MainView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(SessionStore.self) private var sessionStore

        @State private var sessionsNavigationPath = NavigationPath()
        @State private var showingSettings = false

        @State private var pushService = PushNotificationService.shared
        /// Tracks the currently displayed session pane ID for deep link deduplication.
        /// Set when navigating to a session, cleared when popping back to the list.
        @State private var currentlyDisplayedPaneId: String?

        var body: some View {
            // Wrapping the NavigationStack in a Group lets the `.sheet`
            // modifier sit at a peer level of the navigation transition,
            // so dismissing the Settings sheet and pushing onto the nav
            // stack don't fight each other (avoids a sleep workaround in
            // handleDeepLink).
            Group {
                NavigationStack(path: $sessionsNavigationPath) {
                    SessionListView(
                        navigationPath: $sessionsNavigationPath,
                        onOpenSettings: { showingSettings = true }
                    )
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    showingSettings = false
                                }
                            }
                        }
                }
                // Sheets present in a separate window context, so the
                // root view's `.preferredColorScheme` doesn't always
                // re-propagate after the sheet is on screen. Re-apply
                // here so toggling the picker updates the sheet's chrome.
                .preferredColorScheme(settings.appearanceMode.colorScheme)
            }
            .task {
                await connectIfNeeded()
            }
            .onChange(of: pushService.pendingDeepLink) { _, _ in
                // Consume so the value resets to nil — a subsequent notification
                // with an identical payload would otherwise be suppressed by
                // Equatable and never re-trigger this onChange.
                if let deepLink = pushService.consumePendingDeepLink() {
                    handleDeepLink(deepLink)
                }
            }
            .onChange(of: sessionsNavigationPath.count) { _, count in
                // Clear the currently displayed pane ID when user pops back to session list
                if count == 0 {
                    currentlyDisplayedPaneId = nil
                }
            }
            .onAppear {
                // Check for pending deep link when view appears (e.g., app launched from notification)
                if let deepLink = pushService.consumePendingDeepLink() {
                    handleDeepLink(deepLink)
                }
            }
        }

        /// Navigate to a specific session when a deep link is received.
        ///
        /// Note: If the session no longer exists (e.g., notification was delayed and session ended),
        /// ClaudeSessionTerminalView will show an appropriate empty state.
        private func handleDeepLink(_ deepLink: PushNotificationService.DeepLinkInfo?) {
            guard let deepLink else { return }

            // Dismiss Settings sheet if open so the deep link target is visible
            showingSettings = false

            // If we're already displaying this session, don't navigate again.
            // This prevents redundant navigation when receiving multiple push
            // notifications for the same session.
            guard currentlyDisplayedPaneId != deepLink.paneId else {
                return
            }

            // We reset the navigation path first to ensure only one session detail view
            // exists in the stack. Multiple push notifications would otherwise pile up
            // session views indefinitely.
            Task { @MainActor in
                sessionsNavigationPath = NavigationPath()

                // Pane state may not be synced yet on cold start (e.g., launched via
                // push notification). Retry briefly to allow the session store to populate.
                var paneState = sessionStore.paneState(for: deepLink.paneId, hostId: deepLink.hostId)
                if paneState == nil {
                    for _ in 0..<5 {
                        try? await Task.sleep(for: .milliseconds(500))
                        paneState = sessionStore.paneState(for: deepLink.paneId, hostId: deepLink.hostId)
                        if paneState != nil { break }
                    }
                }

                if let paneState {
                    sessionsNavigationPath.append(SessionNavigation(sessionName: paneState.sessionName, hostId: deepLink.hostId))
                    currentlyDisplayedPaneId = deepLink.paneId
                }
            }
        }

        private func connectIfNeeded() async {
            // Connect all paired hosts if not already connected
            guard
                !connectionManager.isConnecting,
                let serverURL = URL(string: settings.externalServerURL)
            else { return }

            await connectionManager.connectAll(
                pairedHosts: settings.pairedHosts,
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName
            )
        }
    }

    // MARK: - Settings View

    struct SettingsView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager

        /// In-flight edit buffer for the device name field. Synced to/from
        /// `settings.deviceName` so the field shows the system name when no
        /// custom name is set.
        @State private var deviceNameDraft = ""

        /// The device name that was committed to settings on the last edit.
        /// Used to detect whether the user actually changed the name when the
        /// field loses focus, so we only reconnect when something differs.
        @State private var lastCommittedDeviceName = ""

        /// Tracks focus on the device-name field so we can also commit when
        /// the user dismisses the keyboard by tapping elsewhere — `onSubmit`
        /// alone would silently discard the draft.
        @FocusState private var deviceNameFieldFocused: Bool

        /// Available monospace fonts for terminal display
        static let availableFonts = [
            "Menlo",
            "SF Mono",
            "Courier New",
            "Monaco",
            "Courier",
        ]

        var body: some View {
            List {
                // Connection Status Section
                Section("Connection") {
                    LabeledContent("Status") {
                        HStack {
                            Circle()
                                .fill(connectionStatusColor)
                                .frame(width: 8, height: 8)
                            Text(connectionStatusText)
                        }
                    }

                    if !connectionManager.anyHostConnected {
                        Button("Connect All") {
                            Task {
                                guard let serverURL = URL(string: settings.externalServerURL) else { return }
                                await connectionManager.connectAll(
                                    pairedHosts: settings.pairedHosts,
                                    serverURL: serverURL,
                                    deviceId: settings.deviceId,
                                    deviceName: settings.deviceName
                                )
                            }
                        }
                    } else {
                        Button("Disconnect All") {
                            Task {
                                await connectionManager.disconnectAll()
                            }
                        }
                    }
                }

                // Paired Hosts Section
                Section {
                    NavigationLink {
                        ManageHostsView()
                    } label: {
                        HStack {
                            Text("Paired Hosts")
                            Spacer()
                            Text("\(settings.pairedHosts.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Appearance Section
                Section {
                    @Bindable var settings = settings

                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Choose Light, Dark, or follow the iOS system setting.")
                }

                // Terminal Section
                Section {
                    @Bindable var settings = settings

                    Picker("Font", selection: $settings.terminalFontName) {
                        ForEach(Self.availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $settings.terminalFontSize,
                        in: 6...20,
                        step: 1
                    )
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Customize the font used in terminal snapshots.")
                }

                // New Session Section
                Section {
                    @Bindable var settings = settings

                    TextField("Session Name", text: $settings.newSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Stepper(
                        "Width: \(settings.newSessionWidth) columns",
                        value: $settings.newSessionWidth,
                        in: 40...300,
                        step: 10
                    )

                    Stepper(
                        "Height: \(settings.newSessionHeight) rows",
                        value: $settings.newSessionHeight,
                        in: 10...100,
                        step: 5
                    )
                } header: {
                    Text("New Session")
                } footer: {
                    Text("Settings for new tmux sessions created from iOS. If a session with this name exists, a number will be appended.")
                }

                // Server Section
                Section("Server") {
                    @Bindable var settings = settings
                    TextField("Server URL", text: $settings.externalServerURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    Toggle("Auto-connect on launch", isOn: $settings.autoReconnect)
                }

                // Device Name Section
                Section {
                    TextField(settings.systemDeviceName, text: $deviceNameDraft)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($deviceNameFieldFocused)
                        .onSubmit { commitDeviceName() }
                        .onChange(of: deviceNameFieldFocused) { _, isFocused in
                            if !isFocused { commitDeviceName() }
                        }
                        .accessibilityIdentifier("device-name-field")
                } header: {
                    Text("Device Name")
                } footer: {
                    Text("Shown to the Macs you've paired with. Leave blank to use the system name (\(settings.systemDeviceName)).")
                }

                // About Section
                Section("About") {
                    LabeledContent("Device ID") {
                        Text(settings.deviceId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Why Gallager Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gallager is named after Robert G. Gallager, a pioneering information theorist and close colleague of Claude Shannon, after whom Anthropic's Claude AI is named.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: AboutLinks.gallagerWikipedia) {
                        HStack {
                            Text("Robert G. Gallager")
                            Spacer()
                            Text("Wikipedia")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: AboutLinks.shannonWikipedia) {
                        HStack {
                            Text("Claude Shannon")
                            Spacer()
                            Text("Wikipedia")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Why \"Gallager\"?")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                deviceNameDraft = settings.customDeviceName ?? ""
                lastCommittedDeviceName = deviceNameDraft
            }
        }

        /// Persist the edited device name and push the update to paired hosts.
        ///
        /// Treats whitespace-only input as "clear back to system name" by
        /// storing `nil`, which makes `IOSSettings.deviceName` fall back to
        /// `UIDevice.current.name`. To propagate the change to already-connected
        /// hosts, disconnects and reconnects all of them — the new name rides
        /// along on the next `RegisterViewerMessage`.
        private func commitDeviceName() {
            let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != lastCommittedDeviceName else {
                return
            }

            settings.customDeviceName = trimmed.isEmpty ? nil : trimmed
            lastCommittedDeviceName = trimmed

            // Push the new name to any currently connected hosts by reconnecting.
            guard
                settings.isPaired,
                let serverURL = URL(string: settings.externalServerURL)
            else { return }

            Task {
                await connectionManager.disconnectAll()
                await connectionManager.connectAll(
                    pairedHosts: settings.pairedHosts,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: settings.deviceName
                )
            }
        }

        private var connectionStatusColor: Color {
            if connectionManager.anyHostConnected {
                return .green
            } else if connectionManager.isConnecting {
                return .yellow
            } else {
                return .gray
            }
        }

        private var connectionStatusText: String {
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
    }

    #Preview {
        ContentView()
    }
#endif
