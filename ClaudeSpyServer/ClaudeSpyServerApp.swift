import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyServerFeature
import Logging
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var windowManager: MirrorWindowManager?
    @State private var e2eeService: E2EEService?
    @State private var pairingManager: PairingManager?
    @State private var externalServerClient = ExternalServerClient()
    @State private var commandExecutor: TmuxCommandExecutor?
    @State private var activeStreams: [String: PaneStream] = [:]

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
        let manager = MirrorWindowManager(settings: settings, tmuxService: tmuxService)
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

        // Set up command handler - called when iOS sends a command
        // Capture tmuxService and externalServerClient for snapshot handling
        let service = tmuxService
        let serverClient = externalServerClient
        externalServerClient.setCommandHandler { [executor, service, serverClient, weak self] command in
            // Handle snapshot commands specially - requires MainActor for tmuxService access
            if case let .captureSnapshot(scrollbackMultiplier) = command.command {
                // handleSnapshotCommand is @MainActor, so this call will hop to main actor
                return await handleSnapshotCommand(command, scrollbackMultiplier: scrollbackMultiplier, tmuxService: service, serverClient: serverClient)
            }

            // Handle stream commands specially - requires stream lifecycle management
            if case .startStream = command.command {
                return await handleStartStreamCommand(
                    command,
                    tmuxService: service,
                    serverClient: serverClient,
                    activeStreams: { await self?.activeStreams ?? [:] },
                    setActiveStream: { paneId, stream in
                        await MainActor.run { self?.activeStreams[paneId] = stream }
                    }
                )
            }

            if case .stopStream = command.command {
                return await handleStopStreamCommand(
                    command,
                    activeStreams: { await self?.activeStreams ?? [:] },
                    removeActiveStream: { paneId in
                        await MainActor.run { self?.activeStreams.removeValue(forKey: paneId) }
                    }
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
/// Snapshot commands are handled specially because:
/// 1. The captured terminal content is large and sent via a separate message
/// 2. The command response is sent immediately for acknowledgment
/// 3. The actual snapshot data follows asynchronously
@MainActor
private func handleSnapshotCommand(
    _ command: CommandMessage,
    scrollbackMultiplier: Int,
    tmuxService: TmuxService,
    serverClient: ExternalServerClient
) async -> CommandResponseMessage {
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

        // Create and send the snapshot
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

        return .success(for: command.id)
    } catch {
        logger.error("Snapshot capture failed: \(error.localizedDescription)")
        return .failure(for: command.id, error: error.localizedDescription)
    }
}

// MARK: - Stream Command Handlers

/// Handles start stream commands from iOS devices.
///
/// Creates a PaneStream for the requested pane and sets up data forwarding
/// to iOS via the external server client.
@MainActor
private func handleStartStreamCommand(
    _ command: CommandMessage,
    tmuxService: TmuxService,
    serverClient: ExternalServerClient,
    activeStreams: @escaping () async -> [String: PaneStream],
    setActiveStream: @escaping (String, PaneStream) async -> Void
) async -> CommandResponseMessage {
    let logger = Logger(label: "com.claudespy.stream")
    logger.info("handleStartStreamCommand started", metadata: ["paneId": "\(command.paneId)"])

    // Check if stream already exists for this pane
    let existingStreams = await activeStreams()
    if existingStreams[command.paneId] != nil {
        logger.info("Stream already active for pane, ignoring duplicate request")
        return .success(for: command.id)
    }

    // Create a new PaneStream
    let paneStream = PaneStream(target: command.paneId, tmuxService: tmuxService)

    // Set up data forwarding callback
    paneStream.onData = { [weak serverClient] data in
        guard let serverClient else { return }

        // First message will include initial content handled separately via streamStarted
        // Subsequent messages are incremental updates
        let message = TerminalStreamDataMessage(paneId: command.paneId, data: data)
        Task {
            await serverClient.sendTerminalStreamData(message)
        }
    }

    // Set up dimension change callback
    paneStream.onDimensionChange = { [weak serverClient] newWidth, newHeight in
        guard let serverClient else { return }

        let message = TerminalStreamDimensionChangeMessage(
            paneId: command.paneId,
            width: newWidth,
            height: newHeight
        )
        Task {
            await serverClient.sendTerminalStreamDimensionChange(message)
        }
    }

    do {
        // Connect starts streaming - this will call onData with initial content
        try await paneStream.connect()

        // Store the active stream
        await setActiveStream(command.paneId, paneStream)

        // Send stream started notification with dimensions
        // Note: Initial content is already sent via onData callback during connect()
        let startedMessage = TerminalStreamStartedMessage(
            paneId: command.paneId,
            width: paneStream.width,
            height: paneStream.height,
            initialContent: Data() // Empty - initial content sent via onData
        )
        await serverClient.sendTerminalStreamStarted(startedMessage)

        logger.info("Stream started successfully", metadata: [
            "paneId": "\(command.paneId)",
            "width": "\(paneStream.width)",
            "height": "\(paneStream.height)",
        ])

        return .success(for: command.id)
    } catch {
        logger.error("Failed to start stream: \(error.localizedDescription)")

        // Send stream stopped with error
        let stoppedMessage = TerminalStreamStoppedMessage(
            paneId: command.paneId,
            reason: error.localizedDescription
        )
        await serverClient.sendTerminalStreamStopped(stoppedMessage)

        return .failure(for: command.id, error: error.localizedDescription)
    }
}

/// Handles stop stream commands from iOS devices.
///
/// Stops the active PaneStream for the requested pane and cleans up resources.
@MainActor
private func handleStopStreamCommand(
    _ command: CommandMessage,
    activeStreams: @escaping () async -> [String: PaneStream],
    removeActiveStream: @escaping (String) async -> Void
) async -> CommandResponseMessage {
    let logger = Logger(label: "com.claudespy.stream")
    logger.info("handleStopStreamCommand started", metadata: ["paneId": "\(command.paneId)"])

    // Get and remove the active stream
    let existingStreams = await activeStreams()
    guard let paneStream = existingStreams[command.paneId] else {
        logger.info("No active stream for pane, ignoring stop request")
        return .success(for: command.id)
    }

    // Disconnect the stream
    await paneStream.disconnect()
    await removeActiveStream(command.paneId)

    logger.info("Stream stopped successfully", metadata: ["paneId": "\(command.paneId)"])
    return .success(for: command.id)
}

// MARK: - Notifications

extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
}
