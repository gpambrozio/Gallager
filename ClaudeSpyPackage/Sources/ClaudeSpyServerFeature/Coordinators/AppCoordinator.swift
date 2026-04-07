#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Logging

    /// A pending selection set by the menu bar to be consumed by MainView.
    public enum PendingMenuBarSelection: Equatable {
        case local(paneId: String)
        case remote(hostId: String, hostName: String, paneId: String)
    }

    /// Coordinates app-level services and their interactions for the macOS app.
    ///
    /// This class centralizes all service initialization, event wiring, and state synchronization
    /// that was previously scattered in the App struct. The App entry point should create this
    /// coordinator and use its public properties for environment injection.
    @Observable
    @MainActor
    final public class AppCoordinator {
        // MARK: - Public Services (for environment injection)

        /// Set by menu bar clicks to tell MainView which session to select when the panes window opens.
        public var pendingMenuBarSelection: PendingMenuBarSelection?

        /// App settings
        public let settings: AppSettings

        /// Tmux interaction service
        public let tmuxService: TmuxService

        /// Pane state and session tracking manager
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

        /// Editor session manager for Ctrl-G prompt editing
        public let editorSessionManager: EditorSessionManager

        // MARK: - Private Services

        private let editorSocketServer: EditorSocketServer
        private var commandExecutor: TmuxCommandExecutor?
        private var isServiceSetupComplete = false

        @ObservationIgnored
        @Dependency(TerminalNotificationService.self) private var terminalNotificationService

        /// Task for observing system wake notifications.
        @ObservationIgnored
        private var wakeObserverTask: Task<Void, Never>?

        @ObservationIgnored
        @Dependency(PreferencesService.self) private var preferences

        @ObservationIgnored
        @Dependency(DockIconService.self) private var dockIconService

        @ObservationIgnored
        @Dependency(SleepPreventionService.self) private var sleepPreventionService

        @ObservationIgnored
        @Dependency(HookServerService.self) private var hookServer

        @ObservationIgnored
        @Dependency(ClaudeProjectScanner.self) private var projectScanner

        private let logger = Logger(label: "com.claudespy.coordinator")

        // MARK: - Initialization

        /// Creates the AppCoordinator with default or provided settings.
        ///
        /// Synchronous initialization sets up core services. Call `setupAllServices()` asynchronously
        /// to complete service initialization and start connections.
        public init(settings: AppSettings = AppSettings()) {
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

            // Create plugin service
            self.pluginService = PluginService()

            // Create editor socket server and session manager (server is started later in setupAllServices)
            let server = EditorSocketServer()
            self.editorSocketServer = server
            let editorManager = EditorSessionManager(socketServer: server)
            self.editorSessionManager = editorManager

            // Inject editor session manager into window manager for mirror windows
            self.windowManager.editorSessionManager = editorManager

            // CRITICAL: Load E2EEService synchronously from Keychain BEFORE any view rendering.
            // This prevents createPairingManager() from generating temporary keys.
            if let e2ee = try? E2EEService.loadFromKeychainSync() {
                self.e2eeService = e2ee
                self.keyPair = e2ee.storedKeyPair
            }

            // Disable macOS automatic window restoration to prevent duplicate windows on launch
            preferences.setBool(false, "NSQuitAlwaysKeepsWindows")
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

        /// Scans for Claude projects using the project scanner dependency.
        public func scanProjects() async -> [ClaudeProjectInfo] {
            await projectScanner.scanProjects()
        }

        /// Sets up all services. Call this once when the app starts (e.g., from a .task modifier).
        public func setupAllServices() async {
            guard !isServiceSetupComplete else { return }
            isServiceSetupComplete = true

            // Clean up any stale pipe-pane FIFOs from previous crashes
            PipePaneReader.cleanupStaleFifos()

            // Start dock icon management (hides dock icon initially, shows when windows open)
            await dockIconService.startObserving()

            // Forward hook events to window manager AND all connected iOS devices
            await hookServer.setEventHandler(handler: { [weak self] event in
                guard let self else { return }
                // Handle locally
                await windowManager.handleHookEvent(event)

                // Update sleep prevention based on new session count
                await updateSleepPrevention()

                guard event.action.body.shouldSendToServer else { return }
                // Skip push notifications for auto-approvable events in yolo mode
                let skipPush: Bool
                if
                    let paneId = event.tmuxPane,
                    case let .permissionRequest(body) = event.action,
                    body.isYoloAutoApprovable,
                    await windowManager.isYoloModeEnabled(for: paneId) {
                    skipPush = true
                } else {
                    skipPush = false
                }
                // Forward to all connected viewers
                await connectedViewerManager?.sendHookEventToAll(event, skipPushNotification: skipPush)
            })

            await initializeServices()
            await hookServer.startServer()
            await setupEditorSocketServer()
            await setupConnectedViewerManager()
            await setupViewerConnectionManager()
            await autoConnectIfConfigured()

            // Start periodic validation to clean up stale sessions
            windowManager.startPeriodicSessionValidation()

            // Initial sleep prevention update (in case there are already sessions)
            updateSleepPrevention()

            // Start observing system wake notifications for reconnection
            startWakeObserver()

            // Wire terminal notification tap handling
            setupNotificationTapHandler()
        }

        // MARK: - Private Setup Methods

        /// Starts the editor socket server and configures the VISUAL env var on TmuxService.
        private func setupEditorSocketServer() async {
            let manager = editorSessionManager

            // When editor sessions change, push updated state to viewers
            manager.onSessionChanged = { [weak self] in
                await self?.connectedViewerManager?.pushSessionStateToAll()
            }

            // When a CLI connects, create an editor session
            let server = editorSocketServer
            await server.setOnEditRequest { [weak manager] (request: EditorRequest) in
                manager?.handleEditRequest(request)
            }

            do {
                try await server.start()
            } catch {
                logger.error("Failed to start editor socket server: \(error)")
                return
            }

            // Set the VISUAL env var on TmuxService so new sessions use our editor CLI.
            // The CLI is expected to be in the app bundle's MacOS directory.
            if let editorURL = Bundle.main.url(forAuxiliaryExecutable: "GallagerEditor") {
                tmuxService.editorCLIPath = editorURL.path
                logger.info("Editor CLI path: \(editorURL.path)")
            } else {
                logger.warning("GallagerEditor CLI not found in app bundle")
            }
        }

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

            // Wire terminal notification display (fires for any monitored pane, regardless of streaming)
            let notificationService = terminalNotificationService
            paneStreamManager.onNotification = { paneId, notification in
                notificationService.showNotification(paneId, notification)
            }

            // Wire title changes from background notification readers to window manager
            let wm = windowManager
            paneStreamManager.onTitleChange = { paneId, _, title in
                wm.updateTerminalTitle(paneId: paneId, title: title)
            }

            // Start notification-only readers for all discovered panes
            let initialPanes = await tmuxService.refreshPanes()
            windowManager.updatePaneStates(from: initialPanes)
            await paneStreamManager.startNotificationMonitoring(panes: initialPanes)
            paneStreamManager.startPeriodicPaneRefresh(tmuxService: tmuxService)

            // Detect Claude Code instances already running in tmux panes
            let claudePanes = await tmuxService.detectClaudePanes()
            if !claudePanes.isEmpty {
                windowManager.markDetectedClaudeSessions(claudePanes)
                logger.info("Detected running Claude Code in panes: \(claudePanes.keys.sorted())")
            }

            // Connect pane stream manager to window manager for view injection
            windowManager.paneStreamManager = paneStreamManager

            // Set up real-time session cleanup when panes change
            let winManager = windowManager
            let tmuxForCleanup = tmuxService
            let terminalStreaming = terminalStreamService
            let paneStreaming = paneStreamManager
            controlClientManager.setOnPanesChanged { [weak self] in
                Task {
                    let panes = await tmuxForCleanup.refreshPanes()
                    winManager.updatePaneStates(from: panes)
                    await terminalStreaming.stopStreamsForClosedPanes(currentPanes: panes)
                    await paneStreaming.updateNotificationMonitoring(panes: panes)
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
            let editorManager = editorSessionManager
            connectionManager.onCommand = { [executor, streamService, tmux, appSettings, winManager, editorManager, weak connectionManager] command in
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

                // Handle yolo mode toggle
                if case let .setYoloMode(spec) = command.command {
                    winManager.setYoloMode(enabled: spec.enabled, for: command.paneId)
                    await connectionManager?.pushSessionStateToAll()
                    return .success(for: command.id)
                }

                // Handle mark session as handled
                if case .markHandled = command.command {
                    let wasNeeding = winManager.paneStates[command.paneId]?.claudeSession?.needsAttention == true
                    winManager.markSessionHandled(paneId: command.paneId)
                    if wasNeeding {
                        await connectionManager?.pushSessionStateToAll()
                    }
                    return .success(for: command.id)
                }

                // Handle window description
                if case let .setWindowDescription(spec) = command.command {
                    winManager.setWindowDescription(spec.description, for: spec.windowId)
                    await connectionManager?.pushSessionStateToAll()
                    return .success(for: command.id)
                }

                // Handle split pane (needs state refresh after split)
                if case .splitTmuxPane = command.command {
                    let response = await executor.execute(command)
                    if response.success {
                        let allPanes = await tmux.refreshPanes()
                        winManager.updatePaneStates(from: allPanes)
                        await connectionManager?.pushSessionStateToAll()
                    }
                    return response
                }

                // Handle select pane (needs state refresh to update active pane)
                // Note: no pushSessionStateToAll — active pane is host-local state,
                // iOS viewers don't render it, so pushing would just add chatter.
                if case .selectTmuxPane = command.command {
                    let response = await executor.execute(command)
                    if response.success {
                        let allPanes = await tmux.refreshPanes()
                        winManager.updatePaneStates(from: allPanes)
                    }
                    return response
                }

                // Handle select window (switch to a tmux window)
                if case .selectTmuxWindow = command.command {
                    let response = await executor.execute(command)
                    if response.success {
                        let allPanes = await tmux.refreshPanes()
                        winManager.updatePaneStates(from: allPanes)
                    }
                    return response
                }

                // Handle create window (new window in existing session)
                if case let .createTmuxWindow(spec) = command.command {
                    return await Self.handleCreateWindow(
                        command: command,
                        spec: spec,
                        tmuxService: tmux,
                        windowManager: winManager,
                        connectionManager: connectionManager
                    )
                }

                // Handle remote editor submit
                if case let .submitEditorContent(spec) = command.command {
                    editorManager.handleRemoteSubmit(paneId: command.paneId, content: spec.content)
                    return .success(for: command.id)
                }

                // Handle remote editor cancel
                if case .cancelEditorSession = command.command {
                    editorManager.handleRemoteCancel(paneId: command.paneId)
                    return .success(for: command.id)
                }

                // Regular commands execute on the actor executor
                return await executor.execute(command)
            }

            // Set up session state handler
            let scanner = projectScanner
            connectionManager.onSessionStateRequest = { [weak windowManager, tmuxService, scanner, editorManager] in
                guard let windowManager else {
                    return SessionStateMessage(pairId: "", paneStates: [:])
                }
                // Refresh panes to ensure metadata is current
                let allPanes = await tmuxService.refreshPanes()
                await windowManager.updatePaneStates(from: allPanes)
                var paneStates = await windowManager.paneStates

                // Inject active editor sessions into pane states
                for (paneId, var state) in paneStates {
                    state.editorSession = await editorManager.editorSessionInfo(for: paneId)
                    paneStates[paneId] = state
                }

                let claudeProjects = await scanner.scanProjects()

                // Note: pairId in SessionStateMessage is per-connection, will be set by individual connections
                return SessionStateMessage(
                    pairId: "",
                    paneStates: paneStates,
                    claudeProjects: claudeProjects,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
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

            // Handle unpair notifications from viewers
            connectionManager.onUnpaired = { [weak self] pairId in
                guard let self else { return }
                self.logger.info("Viewer unpaired remotely", metadata: ["pairId": "\(pairId)"])
                self.settings.removePairing(id: pairId)
            }

            // Push session state to all viewers whenever panes change
            tmuxService.setPanesChangedHandler { [weak connectionManager] in
                await connectionManager?.pushSessionStateToAll()
            }

            // Push session state when window descriptions change locally
            windowManager.onDescriptionChanged = { [weak connectionManager] in
                await connectionManager?.pushSessionStateToAll()
            }
        }

        /// Updates sleep prevention based on current session count.
        /// Called after hook events and session cleanup.
        private func updateSleepPrevention() {
            let sessionCount = windowManager.activeSessionPaneIds.count
            let isEnabled = settings.preventSleepDuringSessions
            Task {
                await sleepPreventionService.updateForSessionCount(sessionCount, isEnabled)
            }
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

        /// Wires the notification tap handler on the delegate directly.
        /// Always opens the panes view with the tapped session selected.
        private func setupNotificationTapHandler() {
            ForegroundNotificationDelegate.shared.onTapped = { [weak self] paneId in
                guard let self else { return }

                NSApp.setActivationPolicy(.regular)
                self.pendingMenuBarSelection = .local(paneId: paneId)
                NotificationCenter.default.post(
                    name: .openPanesWindow,
                    object: nil
                )

                Self.forceActivate()
            }
        }

        /// Force-activates the app from a non-interactive context (e.g., notification tap).
        /// Retries activation multiple times to overcome macOS focus-stealing prevention.
        private static func forceActivate() {
            Task { @MainActor in
                for delay in [100, 300, 500] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.isVisible && window.level == .normal {
                        window.orderFrontRegardless()
                    }
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

        private static func handleCreateWindow(
            command: CommandMessage,
            spec: CreateTmuxWindow,
            tmuxService: TmuxService,
            windowManager: MirrorWindowManager,
            connectionManager: ConnectedViewerManager?
        ) async -> CommandResponseMessage {
            do {
                let paneId = try await tmuxService.newWindow(
                    sessionName: spec.sessionName,
                    workingDirectory: spec.workingDirectory
                )

                let allPanes = await tmuxService.refreshPanes()
                windowManager.updatePaneStates(from: allPanes)
                await connectionManager?.pushSessionStateToAll()

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
                let manager = try await ViewerConnectionManager()
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

                // Clear sessions when a remote host disconnects
                manager.onHostDisconnected = { [weak store] hostId in
                    store?.clearSessions(for: hostId)
                }

                // Handle unpair notifications from remote hosts
                manager.onUnpaired = { [weak self] hostId in
                    guard let self else { return }
                    self.logger.info("Host unpaired remotely", metadata: ["hostId": "\(hostId)"])
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
