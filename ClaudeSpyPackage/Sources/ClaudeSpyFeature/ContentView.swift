import SwiftUI
import ClaudeSpyCommon

/// Main entry point for the ClaudeSpy iOS app.
///
/// Manages the app's primary state:
/// - Shows pairing view if not paired
/// - Shows main session view once paired
/// - Handles WebSocket connection lifecycle
public struct ContentView: View {
    @State private var settings = IOSSettings.shared
    @State private var relayClient = RelayClient()
    @State private var sessionStore = SessionStore()

    public init() {}

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
        .task {
            setupRelayClientHandlers()
            await autoConnectIfNeeded()
        }
    }

    // MARK: - Setup

    private func setupRelayClientHandlers() {
        relayClient.onHookEvent = { [sessionStore] event in
            Task { @MainActor in
                sessionStore.handleEvent(event)
            }
        }

        relayClient.onSessionState = { [sessionStore] state in
            Task { @MainActor in
                sessionStore.handleStateUpdate(state)
            }
        }

        relayClient.onMacConnectionChange = { connected in
            // Mac connection status changed
            // Could clear sessions on disconnect if desired:
            // sessionStore.clearOnDisconnect()
            _ = connected
        }
    }

    private func autoConnectIfNeeded() async {
        guard settings.isPaired,
              settings.autoReconnect,
              let pairId = settings.pairId,
              let serverURL = URL(string: settings.externalServerURL)
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName
        )
    }

    // MARK: - Pairing

    private func handlePairingComplete(pairId: String, macName: String?) {
        settings.savePairing(pairId: pairId, macName: macName)

        // Connect to relay server
        Task {
            guard let serverURL = URL(string: settings.externalServerURL) else { return }

            await relayClient.connect(
                serverURL: serverURL,
                pairId: pairId,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName
            )
        }
    }
}

// MARK: - Main View

/// The main tabbed interface after pairing.
struct MainView: View {
    @Environment(IOSSettings.self) private var settings
    @Environment(RelayClient.self) private var relayClient

    @State private var selectedTab: Tab = .sessions

    enum Tab {
        case sessions
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
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
    }

    private func connectIfNeeded() async {
        // Connect if paired but not already connected
        guard !relayClient.state.isConnected,
              relayClient.state != .connecting,
              let pairId = settings.pairId,
              let serverURL = URL(string: settings.externalServerURL)
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(IOSSettings.self) private var settings
    @Environment(RelayClient.self) private var relayClient

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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to pair again to reconnect.")
        }
    }

    private var connectionStatusColor: Color {
        switch relayClient.state {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .yellow
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private func connect() async {
        guard let pairId = settings.pairId,
              let serverURL = URL(string: settings.externalServerURL)
        else {
            return
        }

        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: settings.deviceName
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
