import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyServerFeature
import Logging
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var windowManager: MirrorWindowManager
    @State private var e2eeService: E2EEService?
    @State private var pairingManager: PairingManager?
    @State private var externalServerClient = ExternalServerClient()
    @State private var commandExecutor: TmuxCommandExecutor?
    @State private var isServiceSetupComplete = false

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

        // Create window manager upfront so MenuBarExtra can access it immediately
        let manager = MirrorWindowManager(settings: initialSettings, tmuxService: service)
        _windowManager = State(initialValue: manager)

        // CRITICAL: Load E2EEService synchronously from Keychain BEFORE any view rendering.
        // This prevents createPairingManager() from generating temporary keys.
        if let e2ee = try? E2EEService.loadFromKeychainSync() {
            _e2eeService = State(initialValue: e2ee)
        }
    }

    var body: some Scene {
        // Main panes window - can be shown via menu bar "Show Panes Window"
        Window("Panes", id: "panes") {
            ContentView()
                .environment(settings)
                .environment(tmuxService)
                .environment(windowManager)
                .environment(pairingManager ?? createPairingManager())
                .environment(externalServerClient)
                .environment(\.e2eeService, e2eeService)
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Mirror") {
                    // Open pane picker or bring main window to front
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Close All Mirrors") {
                    windowManager.closeAll()
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

                ForEach(windowManager.mirroredTargets, id: \.self) { target in
                    Button(target) {
                        windowManager.bringToFront(target: target)
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

        // Menu bar extra - always visible, main entry point to the app
        MenuBarExtra {
            MenuBarExtraView()
                .environment(windowManager)
        } label: {
            MenuBarLabel(pendingCount: windowManager.pendingSessionCount)
                .task {
                    await setupAllServices()
                }
        }
    }

    // MARK: - Service Setup

    /// Sets up all services. Called once when the app starts via MenuBarLabel's .task modifier.
    private func setupAllServices() async {
        guard !isServiceSetupComplete else { return }
        isServiceSetupComplete = true

        // Set up session state handler for external server
        setupSessionStateHandler(manager: windowManager)

        // Forward hook events to window manager AND external server
        await hookServer.setEventHandler { [weak windowManager, weak externalServerClient] event in
            // Handle locally
            await windowManager?.handleHookEvent(event)

            guard event.action.body.shouldSendToServer else { return }
            // Forward to iOS via external server
            await externalServerClient?.sendHookEvent(event)
        }

        await initializeServices()
        await hookServer.startServer()
        await setupExternalServerClient()
        await autoConnectIfConfigured()
    }

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

        // Set up command handler - called when iOS sends a command
        // Capture tmuxService and externalServerClient for snapshot handling
        let service = tmuxService
        let serverClient = externalServerClient
        externalServerClient.setCommandHandler { [executor, service, serverClient] command in
            // Handle snapshot commands specially - requires MainActor for tmuxService access
            if case let .captureSnapshot(spec) = command.command {
                // handleSnapshotCommand is @MainActor, so this call will hop to main actor
                return await handleSnapshotCommand(command, scrollbackMultiplier: spec.scrollbackMultiplier, tmuxService: service, serverClient: serverClient)
            }
            // Regular commands execute on the actor executor (background)
            return await executor.execute(command)
        }

        // Set up partner key handler to persist keys to settings
        externalServerClient.setPartnerKeyHandler { [settings] publicKey, publicKeyId in
            settings.partnerPublicKey = publicKey
            settings.partnerPublicKeyId = publicKeyId
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

// MARK: - Snapshot Command Handler

/// Handles snapshot capture commands from iOS devices.
///
/// Snapshot commands are handled specially because the captured terminal content
/// is sent as a TerminalSnapshotMessage rather than a CommandResponseMessage.
/// Returns nil on success (the snapshot message is the response), or an error response on failure.
@MainActor
private func handleSnapshotCommand(
    _ command: CommandMessage,
    scrollbackMultiplier: Int,
    tmuxService: TmuxService,
    serverClient: ExternalServerClient
) async -> CommandResponseMessage? {
    let logger = Logger(label: "com.claudespy.snapshot")
    logger.info("handleSnapshotCommand started", metadata: ["paneId": "\(command.paneId)"])

    do {
        // Get pane dimensions first
        let (width, height) = try await tmuxService.getPaneDimensions(command.paneId)

        let (rawContent, totalLines) = try await tmuxService.capturePaneWithScrollback(
            command.paneId,
            scrollbackMultiplier: scrollbackMultiplier
        )

        // Add cursor positioning to each line (like capturePaneWithPositioning)
        let contentString = String(data: rawContent, encoding: .utf8) ?? ""
        let lines = contentString.split(separator: "\n", omittingEmptySubsequences: false)

        var positionedContent = "\u{1b}[H" // Cursor home
        for (index, line) in lines.enumerated() {
            positionedContent += "\u{1b}[\(index + 1);1H" // Move to row, col 1
            positionedContent += "\u{1b}[2K" // Clear line
            positionedContent += line
        }

        let content = positionedContent.data(using: .utf8) ?? Data()

        logger.info("Pane captured with scrollback", metadata: [
            "width": "\(width)",
            "height": "\(height)",
            "totalLines": "\(totalLines)",
            "contentBytes": "\(content.count)",
        ])

        // Create and send the snapshot - this IS the response
        let snapshot = TerminalSnapshotMessage(
            commandId: command.id,
            paneId: command.paneId,
            width: width,
            height: height,
            totalLines: totalLines,
            content: content
        )

        logger.debug("Sending snapshot via WebSocket")
        await serverClient.sendTerminalSnapshot(snapshot)
        logger.info("Snapshot sent successfully")

        // Return nil - the TerminalSnapshotMessage is the response
        return nil
    } catch {
        logger.error("Snapshot capture failed: \(error.localizedDescription)")
        return .failure(for: command.id, error: error.localizedDescription)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
}
