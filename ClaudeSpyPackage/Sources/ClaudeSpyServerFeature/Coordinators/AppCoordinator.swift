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

        /// External relay server client
        public let externalServerClient: ExternalServerClient

        /// Terminal stream service for iOS live streaming
        public let terminalStreamService: TerminalStreamService

        /// Pane stream manager for sharing streams between UI and streaming
        public let paneStreamManager: PaneStreamManager

        /// Control client manager for tmux control mode connections
        public let controlClientManager: TmuxControlClientManager

        /// Device pairing manager
        public private(set) var pairingManager: PairingManager?

        /// E2EE service for encryption
        public private(set) var e2eeService: E2EEService?

        /// Plugin service for Claude Code plugin management
        public let pluginService: PluginService

        /// Dock icon visibility manager
        public let dockIconManager: DockIconManager

        /// Sleep prevention manager
        public let sleepPreventionManager: SleepPreventionManager

        // MARK: - Private Services

        private let hookServer: HookServerService
        private let projectScanner: ClaudeProjectScanner
        private var commandExecutor: TmuxCommandExecutor?
        private var isServiceSetupComplete = false

        /// Task for observing system wake notifications
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

            // Create external server client
            self.externalServerClient = ExternalServerClient()

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

            // Set up session state handler for external server
            setupSessionStateHandler()

            // Push session state to iOS whenever panes change
            setupPanesChangedHandler()

            // Forward hook events to window manager AND external server
            await hookServer.setEventHandler { [weak self] event in
                guard let self else { return }
                // Handle locally
                await windowManager.handleHookEvent(event)

                // Update sleep prevention based on new session count
                await updateSleepPrevention()

                guard event.action.body.shouldSendToServer else { return }
                // Forward to iOS via external server
                await externalServerClient.sendHookEvent(event)
            }

            await initializeServices()
            await hookServer.startServer()
            await setupExternalServerClient()
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
                    e2eeService = try await E2EEService()
                } catch {
                    logger.error("Failed to create E2EEService: \(error)")
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
            pairingManager = manager
            return manager
        }

        private func setupExternalServerClient() async {
            // Configure terminal stream service with pane stream manager
            terminalStreamService.configure(
                serverClient: externalServerClient,
                paneStreamManager: paneStreamManager
            )

            // Connect pane stream manager to window manager for view injection
            windowManager.paneStreamManager = paneStreamManager

            // Set up real-time session cleanup when panes change
            // When a pane exits or session disconnects, refresh panes and clean up stale sessions
            let winManager = windowManager
            let tmuxForCleanup = tmuxService
            let terminalStreaming = terminalStreamService
            controlClientManager.setOnPanesChanged { [weak self] in
                Task {
                    let panes = await tmuxForCleanup.refreshPanes()
                    winManager.cleanupStaleSessions(currentPanes: panes)
                    // Stop iOS streams for panes that no longer exist (sends streamEnd to iOS)
                    await terminalStreaming.stopStreamsForClosedPanes(currentPanes: panes)
                    // Update sleep prevention after session cleanup
                    self?.updateSleepPrevention()
                }
            }

            // Create command executor
            let executor = TmuxCommandExecutor(tmuxService: tmuxService)
            commandExecutor = executor

            // Set up command handler - called when iOS sends a command
            let streamService = terminalStreamService
            let tmux = tmuxService
            let appSettings = settings
            externalServerClient.setCommandHandler { [executor, streamService, tmux, appSettings] command in
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

            // Set up partner key handler to persist keys to settings
            externalServerClient.setPartnerKeyHandler { [settings] publicKey, publicKeyId in
                settings.partnerPublicKey = publicKey
                settings.partnerPublicKeyId = publicKeyId
            }
        }

        private func setupSessionStateHandler() {
            let scanner = projectScanner
            externalServerClient.setSessionStateHandler { [settings, weak windowManager, tmuxService, scanner] in
                guard let windowManager else {
                    return SessionStateMessage(pairId: "", sessions: [:], activePanes: [], panes: [])
                }
                let pairId = await settings.pairId ?? ""
                let sessions = await windowManager.activeSessions
                let activePaneIds = await Array(windowManager.activeSessions.keys)

                // Refresh and include all panes for iOS to display
                let allPanes = await tmuxService.refreshPanes()
                let paneMessages = allPanes.map { $0.asPaneInfoMessage }

                // Scan for Claude projects
                let claudeProjects = await scanner.scanProjects()

                return SessionStateMessage(
                    pairId: pairId,
                    sessions: sessions,
                    activePanes: activePaneIds,
                    panes: paneMessages,
                    claudeProjects: claudeProjects
                )
            }
        }

        private func setupPanesChangedHandler() {
            let serverClient = externalServerClient
            tmuxService.setPanesChangedHandler { [serverClient] in
                await serverClient.pushSessionState()
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
        /// When the Mac wakes from sleep, network connections are often stale or broken.
        /// This triggers an immediate reconnection attempt instead of waiting for the
        /// next scheduled retry.
        private func startWakeObserver() {
            let serverClient = externalServerClient
            wakeObserverTask = Task {
                // Using nil as object is valid - we only care about the notification name
                let notifications = NotificationCenter.default.notifications(
                    named: NSWorkspace.didWakeNotification
                )
                for await _ in notifications {
                    await serverClient.reconnectImmediately()
                }
            }
        }

        private static func handleStartStream(
            command: CommandMessage,
            streamService: TerminalStreamService
        ) async -> CommandResponseMessage? {
            let paneId = command.paneId
            let paneTarget = paneId // paneId is the tmux target (e.g., "%1")

            do {
                // Start streaming - TerminalStreamService subscribes to PaneStreamManager
                // which captures initial content atomically with the subscription,
                // ensuring no timing gap between initial state and live updates
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
                // If creating in a project folder and auto-run is enabled, run the configured command
                let runCommand: String? = if spec.workingDirectory != nil && settings.autoRunClaudeInProjects {
                    settings.claudeCommandPath
                } else {
                    nil
                }

                // Create the session - TmuxService.createSession calls refreshPanes(),
                // which triggers the panes changed handler to push state to iOS
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: spec.sessionName,
                    width: spec.width,
                    height: spec.height,
                    workingDirectory: spec.workingDirectory,
                    runCommand: runCommand
                )

                // Brief delay to let tmux fully initialize the pane before iOS starts mirroring
                try? await Task.sleep(for: .milliseconds(500))

                return .success(for: command.id, paneId: paneId)
            } catch {
                return .failure(for: command.id, error: error.localizedDescription)
            }
        }

        private func autoConnectIfConfigured() async {
            // Auto-connect to relay server if configured and paired
            guard
                settings.autoConnectToServer,
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
#endif
