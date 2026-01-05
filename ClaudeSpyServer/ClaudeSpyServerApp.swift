import ClaudeSpyCommon
import ClaudeSpyServerFeature
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var windowManager: MirrorWindowManager?
    @State private var pairingManager: PairingManager?
    @State private var externalServerClient = ExternalServerClient()
    @State private var commandExecutor: TmuxCommandExecutor?

    private let hookServer = HookServerService()

    init() {
        let initialSettings = AppSettings()
        self._settings = State(initialValue: initialSettings)

        let service = TmuxService(
            tmuxPath: initialSettings.tmuxPath,
            socketPath: initialSettings.tmuxSocket.isEmpty ? nil : initialSettings.tmuxSocket
        )
        self._tmuxService = State(initialValue: service)
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(tmuxService)
                .environment(windowManager ?? createWindowManager())
                .environment(pairingManager ?? createPairingManager())
                .environment(externalServerClient)
                .task {
                    await hookServer.startServer()
                    await setupExternalServerClient()
                    await autoConnectIfConfigured()
                }
        }
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Mirror") {
                    // Open pane picker or bring main window to front
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Close All Mirrors") {
                    windowManager?.closeAll()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // View menu
            CommandMenu("View") {
                Button("Refresh Pane List") {
                    // Will be handled by main view's refresh
                    NotificationCenter.default.post(name: .refreshPaneList, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Toggle("Show Status Bar", isOn: Bindable(settings).showStatusBar)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Window menu additions
            CommandGroup(after: .windowList) {
                Divider()

                ForEach(windowManager?.mirroredTargets ?? [], id: \.self) { target in
                    Button(target) {
                        windowManager?.bringToFront(target: target)
                    }
                }
            }
        }

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
                .environment(pairingManager ?? createPairingManager())
                .environment(externalServerClient)
        }
    }

    // MARK: - Service Creation

    private func createWindowManager() -> MirrorWindowManager {
        let manager = MirrorWindowManager(settings: settings, tmuxService: tmuxService)
        Task { @MainActor in
            windowManager = manager

            // Set up session state handler now that we have the manager
            setupSessionStateHandler(manager: manager)

            // Forward hook events to window manager AND external server
            await hookServer.setEventHandler { [weak manager, weak externalServerClient] event in
                // Handle locally
                await manager?.handleHookEvent(event)
                // Forward to iOS via external server
                await externalServerClient?.sendHookEvent(event)
            }
        }
        return manager
    }

    private func createPairingManager() -> PairingManager {
        let manager = PairingManager(settings: settings)
        Task { @MainActor in
            pairingManager = manager
        }
        return manager
    }

    // MARK: - External Server Setup

    private func setupExternalServerClient() async {
        // Create command executor
        let executor = TmuxCommandExecutor(tmuxService: tmuxService)
        commandExecutor = executor

        // Set up command handler - called when iOS sends a command
        externalServerClient.setCommandHandler { [executor] command in
            await executor.execute(command)
        }

        // Session state handler needs to be set up after windowManager is created
        // It will be set up in createWindowManager instead
    }

    private func setupSessionStateHandler(manager: MirrorWindowManager) {
        externalServerClient.setSessionStateHandler { [settings, weak manager] in
            guard let manager else {
                return SessionStateMessage(pairId: "", sessions: [:], activePanes: [])
            }
            // Access @MainActor properties
            let pairId = await settings.pairId ?? ""
            let sessions = await manager.activeSessions
            let targets = await Array(manager.mirroredTargets)
            return SessionStateMessage(
                pairId: pairId,
                sessions: sessions,
                activePanes: targets
            )
        }
    }

    private func autoConnectIfConfigured() async {
        // Auto-connect to relay server if configured and paired
        guard settings.autoConnectToServer,
              let pairId = settings.pairId,
              let serverURL = URL(string: settings.externalServerURL)
        else {
            return
        }

        await externalServerClient.connect(
            serverURL: serverURL,
            pairId: pairId,
            deviceId: settings.deviceId,
            deviceName: Host.current().localizedName ?? "Mac"
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
}
