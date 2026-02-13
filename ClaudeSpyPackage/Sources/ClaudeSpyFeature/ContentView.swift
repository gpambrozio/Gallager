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
        @State private var settings = IOSSettings.shared
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

            connectionManager.onPartnerKeyReceived = { hostId, publicKey, keyId in
                let settings = IOSSettings.shared
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

            connectionManager.onUnpaired = { hostId in
                let settings = IOSSettings.shared
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

    /// The main tabbed interface after pairing.
    struct MainView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(SessionStore.self) private var sessionStore
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        @State private var selectedTab: Tab = .sessions
        @State private var sessionsNavigationPath = NavigationPath()

        @State private var pushService = PushNotificationService.shared
        /// Tracks the currently displayed session pane ID for deep link deduplication.
        /// Set when navigating to a session, cleared when popping back to the list.
        @State private var currentlyDisplayedPaneId: String?

        enum Tab {
            case sessions
            case settings
        }

        /// Whether to hide the tab bar (iPhone in landscape only).
        /// iPad keeps the tab bar visible in all orientations since it has more screen space.
        private var hideTabBar: Bool {
            UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
        }

        var body: some View {
            TabView(selection: $selectedTab) {
                NavigationStack(path: $sessionsNavigationPath) {
                    SessionListView(
                        navigationPath: $sessionsNavigationPath
                    )
                    .toolbar(hideTabBar ? .hidden : .visible, for: .tabBar)
                }
                .tabItem {
                    Label("Sessions", symbol: .terminal)
                }
                .tag(Tab.sessions)

                NavigationStack {
                    SettingsView()
                        .toolbar(hideTabBar ? .hidden : .visible, for: .tabBar)
                }
                .tabItem {
                    Label("Settings", symbol: .gearshape)
                }
                .tag(Tab.settings)
            }
            .task {
                await connectIfNeeded()
            }
            .onChange(of: pushService.pendingDeepLink) { _, deepLink in
                handleDeepLink(deepLink)
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

            // Switch to sessions tab
            selectedTab = .sessions

            // If we're already displaying this session, don't navigate again.
            // This prevents redundant navigation when receiving multiple push
            // notifications for the same session.
            guard currentlyDisplayedPaneId != deepLink.paneId else {
                return
            }

            // Navigate to the session detail after a brief delay. This delay is necessary
            // because NavigationStack may ignore path appends if the tab transition hasn't
            // completed. 100ms provides reliable behavior across device types.
            //
            // We reset the navigation path first to ensure only one session detail view
            // exists in the stack. Multiple push notifications would otherwise pile up
            // session views indefinitely.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                sessionsNavigationPath = NavigationPath()
                sessionsNavigationPath.append(SessionNavigation.claudeSession(paneId: deepLink.paneId, hostId: deepLink.hostId))
                currentlyDisplayedPaneId = deepLink.paneId
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

                // About Section
                Section("About") {
                    LabeledContent("Device ID") {
                        Text(settings.deviceId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    LabeledContent("Device Name", value: settings.deviceName)
                }
            }
            .navigationTitle("Settings")
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
