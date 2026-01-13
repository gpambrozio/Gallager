import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyServerFeature
import Logging
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var paneStreamManager: PaneStreamManager
    @State private var windowManager: MirrorWindowManager?
    @State private var e2eeService: E2EEService?
    @State private var pairingManager: PairingManager?
    @State private var externalServerClient = ExternalServerClient()
    @State private var commandExecutor: TmuxCommandExecutor?
    @State private var remoteStreamManager: RemoteTerminalStreamManager?

    private let hookServer = HookServerService()

    init() {
        // Disable macOS automatic window restoration to prevent duplicate windows on launch
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        let initialSettings = AppSettings()
        _settings = State(initialValue: initialSettings)

        let service = TmuxService(
            tmuxPath: initialSettings.tmuxPath,
            socketPath: initialSettings.tmuxSocket.isEmpty ? nil : initialSettings.tmuxSocket
        )
        _tmuxService = State(initialValue: service)

        // Create PaneStreamManager once in init to ensure single instance
        let streamManager = PaneStreamManager(tmuxService: service)
        _paneStreamManager = State(initialValue: streamManager)
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
                .environment(\.e2eeService, e2eeService)
                .environment(paneStreamManager)
                .task {
                    await initializeServices()
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
                .environment(\.e2eeService, e2eeService)
        }
    }

    // MARK: - Service Creation

    private func initializeServices() async {
        // Create E2EEService if not already created
        if e2eeService == nil {
            do {
                e2eeService = try await E2EEService()
            } catch {
                // Log error but continue - encryption won't work
                Logger(label: "com.claudespy.app").error("Failed to create E2EEService: \(error)")
            }
        }

        // Ensure PairingManager has the E2EEService
        if let service = e2eeService, pairingManager == nil {
            pairingManager = PairingManager(settings: settings, e2eeService: service)
        }
    }

    private func createWindowManager() -> MirrorWindowManager {
        let manager = MirrorWindowManager(
            settings: settings,
            tmuxService: tmuxService,
            paneStreamManager: paneStreamManager
        )
        windowManager = manager

        // Set up session state handler synchronously to avoid race with autoConnectIfConfigured
        setupSessionStateHandler(manager: manager)

        // Forward hook events to window manager AND external server (async setup is fine here)
        Task { @MainActor in
            await hookServer.setEventHandler { [weak manager, weak externalServerClient] event in
                // Handle locally
                await manager?.handleHookEvent(event)

                guard event.action.body.shouldSendToServer else { return }
                // Forward to iOS via external server
                await externalServerClient?.sendHookEvent(event)
            }
        }
        return manager
    }

    private func createPairingManager() -> PairingManager {
        // Create E2EEService synchronously with a generated key pair
        // This will be properly initialized with keychain persistence in initializeServices()
        let service: E2EEService
        if let existingService = e2eeService {
            service = existingService
        } else {
            // Generate a temporary key pair for initial setup
            let keyPair = StoredKeyPair.generateNew()
            service = E2EEService(keyPair: keyPair)
            e2eeService = service
        }

        let manager = PairingManager(settings: settings, e2eeService: service)
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

        // Create remote stream manager for terminal streaming to iOS
        let streamManager = RemoteTerminalStreamManager(
            paneStreamManager: paneStreamManager,
            tmuxService: tmuxService
        )
        remoteStreamManager = streamManager

        // Set up stream manager's send callback to use the external server client
        let serverClient = externalServerClient
        streamManager.setSendCallback { message in
            await serverClient.sendEncryptedMessage(message)
        }

        // Set up command handler - called when iOS sends a command
        externalServerClient.setCommandHandler { [executor, serverClient, streamManager] command in
            // Handle start terminal stream command
            if case .startTerminalStream = command.command {
                return await handleStartStreamCommand(
                    command,
                    streamManager: streamManager,
                    serverClient: serverClient
                )
            }

            // Handle stop terminal stream command
            if case .stopTerminalStream = command.command {
                return await handleStopStreamCommand(
                    command,
                    streamManager: streamManager
                )
            }

            // Regular commands execute on the actor executor (background)
            return await executor.execute(command)
        }

        // Session state handler needs to be set up after windowManager is created
        // It will be set up in createWindowManager instead

        // Set up partner key handler to persist keys to settings
        externalServerClient.setPartnerKeyHandler { [settings] publicKey, publicKeyId in
            settings.partnerPublicKey = publicKey
            settings.partnerPublicKeyId = publicKeyId
        }

        // Stop all streams when iOS disconnects
        externalServerClient.setIOSDisconnectedHandler { [streamManager] in
            await streamManager.stopAllStreams(reason: "ios_disconnected")
        }
    }

    private func setupSessionStateHandler(manager: MirrorWindowManager) {
        externalServerClient.setSessionStateHandler { [settings, weak manager] in
            guard let manager else {
                return SessionStateMessage(pairId: "", sessions: [:], activePanes: [])
            }
            // Access @MainActor properties
            let pairId = await settings.pairId ?? ""
            let sessions = await manager.activeSessions
            // Use active session pane IDs, not window targets
            let activePaneIds = await Array(manager.activeSessions.keys)
            return SessionStateMessage(
                pairId: pairId,
                sessions: sessions,
                activePanes: activePaneIds
            )
        }
    }

    private func autoConnectIfConfigured() async {
        // Auto-connect to relay server if configured and paired
        guard settings.autoConnectToServer,
              let pairId = settings.pairId,
              let serverURL = URL(string: settings.externalServerURL),
              let manager = pairingManager,
              let e2eeService
        else {
            return
        }

        let keyInfo = manager.publicKeyInfo
        await externalServerClient.connect(
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
}

// MARK: - Stream Command Handlers

/// Handles start terminal stream commands from iOS devices.
///
/// Returns nil on success (the TerminalStreamStartedMessage is the response),
/// or an error response on failure.
@MainActor
private func handleStartStreamCommand(
    _ command: CommandMessage,
    streamManager: RemoteTerminalStreamManager,
    serverClient: ExternalServerClient
) async -> CommandResponseMessage? {
    let logger = Logger(label: "com.claudespy.stream")
    logger.info("handleStartStreamCommand started", metadata: ["paneId": "\(command.paneId)"])

    guard let startedMessage = await streamManager.startStream(paneId: command.paneId, commandId: command.id) else {
        logger.error("Failed to start terminal stream")
        return .failure(for: command.id, error: "Failed to start terminal stream")
    }

    // Send the started message - this IS the response
    await serverClient.sendTerminalStreamStarted(startedMessage)
    logger.info("Terminal stream started successfully")

    // Return nil - the TerminalStreamStartedMessage is the response
    return nil
}

/// Handles stop terminal stream commands from iOS devices.
@MainActor
private func handleStopStreamCommand(
    _ command: CommandMessage,
    streamManager: RemoteTerminalStreamManager
) async -> CommandResponseMessage? {
    let logger = Logger(label: "com.claudespy.stream")
    logger.info("handleStopStreamCommand started", metadata: ["paneId": "\(command.paneId)"])

    await streamManager.stopStream(paneId: command.paneId, reason: "user_requested")
    logger.info("Terminal stream stopped")

    return .success(for: command.id)
}

// MARK: - Notifications

extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
}
