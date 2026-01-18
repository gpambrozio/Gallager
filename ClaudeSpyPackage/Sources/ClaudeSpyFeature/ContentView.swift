import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import SwiftUI

#if os(iOS)
    import UserNotifications
#endif

/// Main entry point for the ClaudeSpy iOS app.
///
/// Manages the app's primary state:
/// - Shows pairing view if not paired
/// - Shows main session view once paired
/// - Handles WebSocket connection lifecycle
/// - Manages background task to keep connection alive when backgrounded
public struct ContentView: View {
    @State private var settings = IOSSettings.shared
    @State private var relayClient = RelayClient()
    @State private var sessionStore = SessionStore()
    @State private var e2eeService: E2EEService?

    #if os(iOS)
        @Environment(\.scenePhase) private var scenePhase
        @State private var pushService = PushNotificationService.shared
        @State private var backgroundTaskService = BackgroundTaskService.shared
    #endif

    public init() { }

    public var body: some View {
        Group {
            if settings.isPaired {
                MainView()
            } else {
                PairingView(onPaired: { pairId, macName in
                    handlePairingComplete(pairId: pairId, macName: macName)
                })
            }
        }
        .environment(settings)
        .environment(relayClient)
        .environment(sessionStore)
        .environment(\.e2eeService, e2eeService)
        .task {
            await initializeE2EEService()
            setupRelayClientHandlers()
            await autoConnectIfNeeded()
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        #endif
    }

    #if os(iOS)
        /// Handle scene phase changes to manage background task lifecycle.
        ///
        /// When the app enters the background, we start a background task to keep
        /// the WebSocket connection alive for ~30 seconds. This allows receiving
        /// any pending events before iOS suspends the app.
        ///
        /// When returning to foreground, we immediately attempt reconnection to avoid
        /// waiting for exponential backoff timers.
        private func handleScenePhaseChange(_ phase: ScenePhase) {
            switch phase {
            case .background:
                // Only start background task if we're connected
                if relayClient.state.isConnected {
                    backgroundTaskService.startBackgroundTask()
                }
            case .active:
                // End background task when returning to foreground
                backgroundTaskService.endBackgroundTask()

                // If we're in a reconnecting state or disconnected, immediately try to connect
                // rather than waiting for exponential backoff
                Task {
                    await relayClient.reconnectImmediately()
                }
            case .inactive:
                // Transitional state - no action needed
                break
            @unknown default:
                break
            }
        }
    #endif

    // MARK: - Setup

    private func setupRelayClientHandlers() {
        relayClient.onHookEvent = { [sessionStore] event in
            Task { @MainActor in
                sessionStore.handleEvent(event)

                #if os(iOS)
                    // If app is backgrounded, show a local notification.
                    // The server won't send a push since we're "connected" via WebSocket,
                    // but the user can't see the app, so we need to alert them.
                    if scenePhase != .active {
                        if let notification = event.buildNotification() {
                            PushNotificationService.shared.scheduleLocalNotification(
                                title: notification.title,
                                body: notification.body,
                                paneId: event.event.tmuxPane
                            )
                        }
                    }
                #endif
            }
        }

        relayClient.onSessionState = { [sessionStore] state in
            Task { @MainActor in
                sessionStore.handleStateUpdate(state)
            }
        }

        // Set up partner key handler to persist Mac's public key for reconnection
        relayClient.onPartnerKeyReceived = { [settings] publicKey, publicKeyId in
            settings.partnerPublicKey = publicKey
            settings.partnerPublicKeyId = publicKeyId
        }
    }

    private func autoConnectIfNeeded() async {
        guard
            settings.isPaired,
            settings.autoReconnect,
            let pairId = settings.pairId,
            let serverURL = URL(string: settings.externalServerURL),
            let keyInfo = publicKeyInfo,
            let service = e2eeService
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName,
            publicKey: keyInfo.key,
            publicKeyId: keyInfo.keyId,
            e2eeService: service,
            partnerPublicKey: settings.partnerPublicKey,
            partnerPublicKeyId: settings.partnerPublicKeyId
        )

        #if os(iOS)
            // Request push permissions if not already authorized
            if pushService.permissionStatus != .authorized {
                await requestPushNotificationPermissions()
            }

            // Send push token if we have one and are now connected
            if let token = pushService.tokenString, relayClient.state.isConnected {
                await relayClient.sendPushToken(token)
            }
        #endif
    }

    // MARK: - E2EE Initialization

    private func initializeE2EEService() async {
        guard e2eeService == nil else { return }

        do {
            // Use shared keychain access group so Notification Service Extension can decrypt
            let keyManager = KeyManager(accessGroup: sharedKeychainAccessGroup)
            e2eeService = try await E2EEService(keyManager: keyManager)
        } catch {
            // Log error but continue - encryption won't work
            // In production, might want to show an error to the user
            print("Failed to initialize E2EEService: \(error)")
        }
    }

    /// Helper to get public key info for connection.
    private var publicKeyInfo: (key: String, keyId: String)? {
        guard let service = e2eeService else { return nil }
        return (
            key: service.publicKey.base64EncodedString(),
            keyId: service.keyId
        )
    }

    // MARK: - Pairing

    private func handlePairingComplete(pairId: String, macName: String?) {
        settings.savePairing(pairId: pairId, macName: macName)

        // Connect to relay server and set up push notifications
        Task {
            guard
                let serverURL = URL(string: settings.externalServerURL),
                let keyInfo = publicKeyInfo,
                let service = e2eeService
            else { return }

            await relayClient.connect(
                serverURL: serverURL,
                pairId: pairId,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName,
                publicKey: keyInfo.key,
                publicKeyId: keyInfo.keyId,
                e2eeService: service
                // Note: No partner keys yet - will be received via WebSocket
            )

            // Request push notification permissions after successful pairing
            #if os(iOS)
                await requestPushNotificationPermissions()
            #endif
        }
    }

    #if os(iOS)
        /// Request push notification permissions and register token with server
        private func requestPushNotificationPermissions() async {
            do {
                try await pushService.requestAuthorization()

                // Wait a brief moment for the token to be received from APNs
                try? await Task.sleep(for: .milliseconds(500))

                // If we have a token and are connected, send it to the server
                if let token = pushService.tokenString, relayClient.state.isConnected {
                    await relayClient.sendPushToken(token)
                }
            } catch {
                // Permission denied or error - not critical, app still works without push
                print("Push notification authorization failed: \(error)")
            }
        }
    #endif
}

// MARK: - Main View

/// The main tabbed interface after pairing.
struct MainView: View {
    @Environment(IOSSettings.self) private var settings
    @Environment(RelayClient.self) private var relayClient
    @Environment(\.e2eeService) private var e2eeService

    @State private var selectedTab: Tab = .sessions
    @State private var sessionsNavigationPath = NavigationPath()

    #if os(iOS)
        @State private var pushService = PushNotificationService.shared
        /// Tracks the currently displayed session pane ID for deep link deduplication.
        /// Set when navigating to a session, cleared when popping back to the list.
        @State private var currentlyDisplayedPaneId: String?
    #endif

    enum Tab {
        case sessions
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $sessionsNavigationPath) {
                SessionListView()
            }
            .tabItem {
                Label("Sessions", symbol: .terminal)
            }
            .tag(Tab.sessions)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", symbol: .gearshape)
            }
            .tag(Tab.settings)
        }
        .task {
            await connectIfNeeded()
        }
        #if os(iOS)
        .onChange(of: pushService.pendingDeepLinkPaneId) { _, paneId in
            handleDeepLink(paneId: paneId)
        }
        .onChange(of: sessionsNavigationPath.count) { _, count in
            // Clear the currently displayed pane ID when user pops back to session list
            if count == 0 {
                currentlyDisplayedPaneId = nil
            }
        }
        .onAppear {
            // Check for pending deep link when view appears (e.g., app launched from notification)
            if let paneId = pushService.consumePendingDeepLink() {
                handleDeepLink(paneId: paneId)
            }
        }
        #endif
    }

    #if os(iOS)
        /// Navigate to a specific session when a deep link is received.
        ///
        /// Note: If the session no longer exists (e.g., notification was delayed and session ended),
        /// SessionDetailView will show an appropriate empty state.
        private func handleDeepLink(paneId: String?) {
            guard let paneId else { return }

            // Clear the pending deep link. This is intentionally called here even though
            // onAppear may have already consumed it—ensures state is cleared regardless
            // of which code path triggered the navigation.
            _ = pushService.consumePendingDeepLink()

            // Switch to sessions tab
            selectedTab = .sessions

            // If we're already displaying this session, don't navigate again.
            // This prevents redundant navigation when receiving multiple push
            // notifications for the same session.
            guard currentlyDisplayedPaneId != paneId else {
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
                sessionsNavigationPath.append(SessionNavigation.claudeSession(paneId: paneId))
                currentlyDisplayedPaneId = paneId
            }
        }
    #endif

    private func connectIfNeeded() async {
        // Connect if paired but not already connected
        guard
            !relayClient.state.isConnected,
            relayClient.state != .connecting,
            let pairId = settings.pairId,
            let serverURL = URL(string: settings.externalServerURL),
            let service = e2eeService
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName,
            publicKey: service.publicKey.base64EncodedString(),
            publicKeyId: service.keyId,
            e2eeService: service,
            partnerPublicKey: settings.partnerPublicKey,
            partnerPublicKeyId: settings.partnerPublicKeyId
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(IOSSettings.self) private var settings
    @Environment(RelayClient.self) private var relayClient
    @Environment(\.e2eeService) private var e2eeService

    @State private var showingUnpairConfirmation = false

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
                        Text(relayClient.state.statusText)
                    }
                }

                LabeledContent("Mac Status") {
                    HStack {
                        Circle()
                            .fill(relayClient.isMacConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(relayClient.isMacConnected ? "Connected" : "Disconnected")
                    }
                }

                if !relayClient.state.isConnected {
                    Button("Connect") {
                        Task {
                            await connect()
                        }
                    }
                } else {
                    Button("Disconnect") {
                        Task {
                            await relayClient.disconnect()
                        }
                    }
                }
            }

            // Pairing Section
            Section("Pairing") {
                if let macName = settings.pairedMacName {
                    LabeledContent("Paired Mac", value: macName)
                }

                if let pairId = settings.pairId {
                    LabeledContent("Pair ID") {
                        Text(pairId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Button("Unpair", role: .destructive) {
                    showingUnpairConfirmation = true
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

            // Server Section
            Section("Server") {
                @Bindable var settings = settings
                TextField("Server URL", text: $settings.externalServerURL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
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
        .confirmationDialog(
            "Unpair from Mac?",
            isPresented: $showingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                Task {
                    await unpair()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You will need to pair again to reconnect.")
        }
    }

    private var connectionStatusColor: Color {
        switch relayClient.state {
        case .connected:
            return .green
        case .connecting,
             .reconnecting:
            return .yellow
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private func connect() async {
        guard
            let pairId = settings.pairId,
            let serverURL = URL(string: settings.externalServerURL),
            let service = e2eeService
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName,
            publicKey: service.publicKey.base64EncodedString(),
            publicKeyId: service.keyId,
            e2eeService: service,
            partnerPublicKey: settings.partnerPublicKey,
            partnerPublicKeyId: settings.partnerPublicKeyId
        )
    }

    private func unpair() async {
        await relayClient.disconnect()
        settings.clearPairing()
    }
}

#Preview {
    ContentView()
}
