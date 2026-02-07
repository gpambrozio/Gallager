#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    /// Coordinates app-level services and their interactions for the macOS app.
    ///
    /// This class centralizes all service initialization, event wiring, and state synchronization
    /// that was previously scattered in the App struct. The App entry point should create this
    /// coordinator and use its public properties for environment injection.
    @Observable
    @MainActor
    final public class AppCoordinator {
        // MARK: - Public Services (for environment injection)

        /// App settings
        public let settings: AppSettings

        /// Tmux interaction service
        public let tmuxService: TmuxService

        /// Window manager for pane mirroring
        public let windowManager: MirrorWindowManager

        /// Connected viewer manager for multiple viewer connections
        public private(set) var connectedViewerManager: ConnectedViewerManager?

        /// Viewer connection manager for connecting to remote hosts (viewer mode)
        public private(set) var viewerConnectionManager: ViewerConnectionManager?

        /// Session store for remote host sessions (viewer mode)
        public private(set) var remoteSessionStore: SessionStore?

        /// Error message if service setup failed (e.g., E2EE initialization)
        public private(set) var setupError: String?

        /// Terminal stream service for viewer live streaming
        public let terminalStreamService: TerminalStreamService

        /// Pane stream manager for sharing streams between UI and streaming
        public let paneStreamManager: PaneStreamManager

        /// Control client manager for tmux control mode connections
        public let controlClientManager: TmuxControlClientManager

        /// Device pairing manager
        public private(set) var pairingManager: PairingManager?

        /// E2EE service for encryption
        public private(set) var e2eeService: E2EEService?

        /// Stored key pair for E2EE
        public private(set) var keyPair: StoredKeyPair?

        /// Plugin service for Claude Code plugin management
        public let pluginService: PluginService

        /// Dock icon visibility manager
        public let dockIconManager: DockIconManager

        /// Sleep prevention manager
        public let sleepPreventionManager: SleepPreventionManager

        // MARK: - Private Services

        private let hookServer: HookServerService

        /// Claude project scanner for discovering Claude Code projects
        public let projectScanner: ClaudeProjectScanner
        private var commandExecutor: TmuxCommandExecutor?
        private var isServiceSetupComplete = false

        /// Task for observing system wake notifications.
        @ObservationIgnored
        private var wakeObserverTask: Task<Void, Never>?

        private let logger = Logger(label: "com.claudespy.coordinator")

        // MARK: - Initialization

        /// Creates the AppCoordinator with default or provided settings.
        ///
        /// Synchronous initialization sets up core services. Call `setupAllServices()` asynchronously
        /// to complete service initialization and start connections.
        public init(settings: AppSettings = AppSettings()) {
            // Disable macOS automatic window restoration to prevent duplicate windows on launch
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

            self.settings = settings

            // Create tmux service
            self.tmuxService = TmuxService(
                tmuxPath: settings.tmuxPath,
                socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
            )

            // Create control client manager for tmux control mode
            self.controlClientManager = TmuxControlClientManager(
                tmuxPath: settings.tmuxPath,
                socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
            )

            // Create pane stream manager with control client manager
            self.paneStreamManager = PaneStreamManager(
                tmuxService: tmuxService,
                controlClientManager: controlClientManager
            )

            // Create window manager
            self.windowManager = MirrorWindowManager(
                settings: settings,
                tmuxService: tmuxService,
                paneStreamManager: paneStreamManager
            )

            // Create terminal stream service
            self.terminalStreamService = TerminalStreamService()

            // Create hook server
            self.hookServer = HookServerService()

            // Create project scanner
            self.projectScanner = ClaudeProjectScanner()

            // Create dock icon manager
            self.dockIconManager = DockIconManager()

            // Create sleep prevention manager
            self.sleepPreventionManager = SleepPreventionManager()

            // Create plugin service
            self.pluginService = PluginService()

            // CRITICAL: Load E2EEService synchronously from Keychain BEFORE any view rendering.
            // This prevents createPairingManager() from generating temporary keys.
            if let e2ee = try? E2EEService.loadFromKeychainSync() {
                self.e2eeService = e2ee
                self.keyPair = e2ee.storedKeyPair
            }
        }

        // MARK: - Public API

        /// Creates or returns the pairing manager.
        ///
        /// This is useful for SwiftUI views that need a PairingManager before async setup completes.
        /// It will create a temporary one if needed, which will be properly initialized later.
        public func getOrCreatePairingManager() -> PairingManager {
            if let manager = pairingManager {
                return manager
            }

            let manager = createPairingManager()
            return manager
        }

        /// Sets up all services. Call this once when the app starts (e.g., from a .task modifier).
        public func setupAllServices() async {
            guard !isServiceSetupComplete else { return }
            isServiceSetupComplete = true

            // Start dock icon management (hides dock icon initially, shows when windows open)
            dockIconManager.startObserving()

            // Forward hook events to window manager AND all connected iOS devices
            await hookServer.setEventHandler { [weak self] event in
                guard let self else { return }
                // Handle locally
                await windowManager.handleHookEvent(event)

                // Update sleep prevention based on new session count
                await updateSleepPrevention()

                guard event.action.body.shouldSendToServer else { return }
                // Forward to all connected viewers
                await connectedViewerManager?.sendHookEventToAll(event)
            }

            await initializeServices()
            await hookServer.startServer()
            await setupConnectedViewerManager()
            await setupViewerConnectionManager()
            await autoConnectIfConfigured()

            // Start periodic validation to clean up stale sessions
            windowManager.startPeriodicSessionValidation()

            // Initial sleep prevention update (in case there are already sessions)
            updateSleepPrevention()

            // Start observing system wake notifications for reconnection
            startWakeObserver()
        }

        // MARK: - Private Setup Methods

        private func initializeServices() async {
            // Create E2EEService if not already created
            if e2eeService == nil {
                do {
                    let e2ee = try await E2EEService()
                    e2eeService = e2ee
                    keyPair = e2ee.storedKeyPair
                } catch {
                    logger.error("Failed to create E2EEService: \(error)")
                }
            }

            // Ensure PairingManager has the E2EEService
            if let service = e2eeService, pairingManager == nil {
                let manager = PairingManager(settings: settings, e2eeService: service)
                pairingManager = manager

                // Set up callback for when new viewers are paired
                manager.onViewerPaired = { [weak self] viewer in
                    Task { @MainActor in
                        await self?.connectToNewlyPairedViewer(viewer)
                    }
                }
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
                let newKeyPair = StoredKeyPair.generateNew()
                service = E2EEService(keyPair: newKeyPair)
                e2eeService = service
                keyPair = newKeyPair
            }

            let manager = PairingManager(settings: settings, e2eeService: service)
            pairingManager = manager

            // Set up callback for when new viewers are paired
            manager.onViewerPaired = { [weak self] viewer in
                Task { @MainActor in
                    await self?.connectToNewlyPairedViewer(viewer)
                }
            }

            return manager
        }

        private func setupConnectedViewerManager() async {
            guard let e2eeService, let keyPair else {
                let errorMsg = "Remote access unavailable: encryption failed to initialize"
                logger.error("Cannot set up ConnectedViewerManager: E2EE not initialized")
                setupError = errorMsg
                return
            }

            let connectionManager = ConnectedViewerManager(
                settings: settings,
                e2eeService: e2eeService,
                keyPair: keyPair
            )
            connectedViewerManager = connectionManager

            // Configure terminal stream service with connection manager
            terminalStreamService.configureWithConnectionManager(
                connectionManager: connectionManager,
                paneStreamManager: paneStreamManager
            )

            // Connect pane stream manager to window manager for view injection
            windowManager.paneStreamManager = paneStreamManager

            // Set up real-time session cleanup when panes change
            let winManager = windowManager
            let tmuxForCleanup = tmuxService
            let terminalStreaming = terminalStreamService
            controlClientManager.setOnPanesChanged { [weak self] in
                Task {
                    let panes = await tmuxForCleanup.refreshPanes()
                    winManager.cleanupStaleSessions(currentPanes: panes)
                    await terminalStreaming.stopStreamsForClosedPanes(currentPanes: panes)
                    self?.updateSleepPrevention()
                }
            }

            // Create command executor
            let executor = TmuxCommandExecutor(tmuxService: tmuxService)
            commandExecutor = executor

            // Set up command handler - called when any viewer sends a command
            let streamService = terminalStreamService
            let tmux = tmuxService
            let appSettings = settings
            connectionManager.onCommand = { [executor, streamService, tmux, appSettings] command in
                // Handle stream commands
                if case .startTerminalStream = command.command {
                    return await Self.handleStartStream(
                        command: command,
                        streamService: streamService
                    )
                }
                if case .stopTerminalStream = command.command {
                    await streamService.stopStreaming(paneId: command.paneId)
                    return .success(for: command.id)
                }

                // Handle create session command
                if case let .createTmuxSession(spec) = command.command {
                    return await Self.handleCreateSession(
                        command: command,
                        spec: spec,
                        tmuxService: tmux,
                        settings: appSettings
                    )
                }

                // Regular commands execute on the actor executor
                return await executor.execute(command)
            }

            // Set up session state handler
            let scanner = projectScanner
            connectionManager.onSessionStateRequest = { [weak windowManager, tmuxService, scanner] in
                guard let windowManager else {
                    return SessionStateMessage(pairId: "", sessions: [:], activePanes: [], panes: [])
                }
                let sessions = await windowManager.activeSessions
                let activePaneIds = await Array(windowManager.activeSessions.keys)
                let allPanes = await tmuxService.refreshPanes()
                let paneMessages = allPanes.map { $0.asPaneInfoMessage }
                let claudeProjects = await scanner.scanProjects()

                // Note: pairId in SessionStateMessage is per-connection, will be set by individual connections
                return SessionStateMessage(
                    pairId: "",
                    sessions: sessions,
                    activePanes: activePaneIds,
                    panes: paneMessages,
                    claudeProjects: claudeProjects
                )
            }

            // Set up partner key handler to persist keys to settings
            connectionManager.onPartnerKeyReceived = { [weak self] deviceId, publicKey, publicKeyId in
                self?.pairingManager?.updatePartnerPublicKey(
                    deviceId: deviceId,
                    publicKey: publicKey,
                    publicKeyId: publicKeyId
                )
            }

            // Set up unpair handler - called when a viewer notifies that it has unpaired.
            // Note: No E2EE key cleanup needed here — the host uses a single key pair
            // (not per-viewer session keys), unlike iOS which stores per-host session keys.
            connectionManager.onUnpaired = { [weak self] viewerId in
                guard let self else { return }
                self.logger.info("Viewer unpaired remotely", metadata: ["viewerId": "\(viewerId)"])
                self.settings.removePairing(id: viewerId)
            }

            // Push session state to all viewers whenever panes change
            tmuxService.setPanesChangedHandler { [weak connectionManager] in
                await connectionManager?.pushSessionStateToAll()
            }
        }

        /// Updates sleep prevention based on current session count.
        /// Called after hook events and session cleanup.
        private func updateSleepPrevention() {
            sleepPreventionManager.updateForSessionCount(
                windowManager.activeSessions.count,
                isEnabled: settings.preventSleepDuringSessions
            )
        }

        /// Starts observing system wake notifications to trigger immediate reconnection.
        ///
        /// When the host wakes from sleep, network connections are often stale or broken.
        /// This triggers an immediate reconnection attempt instead of waiting for the
        /// next scheduled retry.
        private func startWakeObserver() {
            wakeObserverTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: NSWorkspace.didWakeNotification
                )
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    await self?.connectedViewerManager?.reconnectAllImmediately()
                    await self?.viewerConnectionManager?.reconnectAllImmediately()
                }
            }
        }

        deinit {
            wakeObserverTask?.cancel()
        }

        private static func handleStartStream(
            command: CommandMessage,
            streamService: TerminalStreamService
        ) async -> CommandResponseMessage? {
            let paneId = command.paneId
            let paneTarget = paneId

            do {
                try await streamService.startStreaming(
                    paneId: paneId,
                    target: paneTarget
                )

                return .success(for: command.id)
            } catch {
                return .failure(for: command.id, error: error.localizedDescription)
            }
        }

        private static func handleCreateSession(
            command: CommandMessage,
            spec: CreateTmuxSession,
            tmuxService: TmuxService,
            settings: AppSettings
        ) async -> CommandResponseMessage {
            do {
                let runCommand: String? = if spec.workingDirectory != nil && settings.autoRunClaudeInProjects {
                    settings.claudeCommandPath
                } else {
                    nil
                }

                let workingDirectory = spec.workingDirectory
                    ?? FileManager.default.homeDirectoryForCurrentUser.path()

                let (_, paneId) = try await tmuxService.createSession(
                    baseName: spec.sessionName,
                    width: spec.width,
                    height: spec.height,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand
                )

                try? await Task.sleep(for: .milliseconds(500))

                return .success(for: command.id, paneId: paneId)
            } catch {
                return .failure(for: command.id, error: error.localizedDescription)
            }
        }

        /// Sets up the viewer connection manager for connecting to remote Mac hosts.
        private func setupViewerConnectionManager() async {
            guard keyPair != nil else {
                logger.error("Cannot set up ViewerConnectionManager: no key pair")
                return
            }

            do {
                let keyManager = KeyManager()
                let manager = try await ViewerConnectionManager(keyManager: keyManager)
                viewerConnectionManager = manager

                // Create session store for remote sessions
                let store = SessionStore()
                remoteSessionStore = store

                // Wire hook events from remote hosts
                manager.onHookEvent = { [weak store] event in
                    store?.handleEvent(event)
                }

                // Wire session state updates from remote hosts
                manager.onSessionState = { [weak store] state in
                    store?.handleStateUpdate(state)
                }

                // Wire partner key received to persist in settings
                manager.onPartnerKeyReceived = { [weak self] hostId, publicKey, publicKeyId in
                    guard let self else { return }
                    guard let host = settings.getHostPairing(id: hostId) else { return }
                    let updatedHost = PairedHost(
                        id: host.id,
                        hostName: host.hostName,
                        username: host.username,
                        partnerPublicKey: publicKey,
                        partnerPublicKeyId: publicKeyId,
                        pairedAt: host.pairedAt,
                        customName: host.customName
                    )
                    settings.updateHostPairing(updatedHost)
                }

                // Wire unpair notification handler
                manager.onUnpaired = { [weak self] hostId in
                    guard let self else { return }
                    self.logger.info("Host unpaired remotely", metadata: ["hostId": "\(hostId)"])
                    self.remoteSessionStore?.clearSessions(for: hostId)
                    self.settings.removeHostPairing(id: hostId)
                }

                logger.info("ViewerConnectionManager set up successfully")
            } catch {
                logger.error("Failed to set up ViewerConnectionManager: \(error)")
            }
        }

        /// Connect to a newly paired host after the pairing code flow.
        public func connectToNewlyPairedHost(_ host: PairedHost) async {
            guard let manager = viewerConnectionManager else {
                logger.warning("Cannot connect to new host: viewer connection manager not initialized")
                return
            }

            guard let serverURL = URL(string: settings.externalServerURL) else {
                logger.error("Invalid server URL for host connection")
                return
            }

            logger.info("Connecting to newly paired host: \(host.displayName)")
            await manager.connect(
                to: host,
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: Host.current().localizedName ?? "Mac"
            )
        }

        private func autoConnectIfConfigured() async {
            // Auto-connect to all paired viewers if configured (host mode)
            if
                settings.autoConnectToServer,
                settings.isPaired,
                let connectionManager = connectedViewerManager {
                await connectionManager.connectAll()
            }

            // Auto-connect to all paired hosts if configured (viewer mode)
            if
                settings.autoConnectToServer,
                settings.hasRemoteHosts,
                let manager = viewerConnectionManager,
                let serverURL = URL(string: settings.externalServerURL) {
                await manager.connectAll(
                    pairedHosts: settings.pairedHosts,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: Host.current().localizedName ?? "Mac"
                )
            }
        }

        /// Connect to a newly paired viewer
        private func connectToNewlyPairedViewer(_ viewer: PairedViewer) async {
            guard let connectionManager = connectedViewerManager else {
                logger.warning("Cannot connect to new viewer: connection manager not initialized")
                return
            }

            logger.info("Connecting to newly paired viewer: \(viewer.displayName)")
            await connectionManager.connect(to: viewer)
        }
    }
#endif
