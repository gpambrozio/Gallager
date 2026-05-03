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

    /// POSIX-shell single-quote a string so it survives word-splitting and expansion.
    /// Wraps the value in single quotes and escapes embedded single quotes via `'\''`.
    @Sendable
    private func shellQuoteSingle(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

        /// Persists in-progress edits for remote viewer editor overlays, keyed by session UUID.
        public let remoteEditorContentStore: RemoteEditorContentStore

        /// Holds "Claude wrote a markdown file — open it?" prompts per tmux session.
        public let markdownOpenSuggestionStore: MarkdownOpenSuggestionStore

        // MARK: - Private Services

        @ObservationIgnored
        @Dependency(APISocketServer.self) private var apiSocketServer

        /// Live router instance, created during API server setup.
        private var liveRouter: LiveAPIRequestRouter?

        private var commandExecutor: TmuxCommandExecutor?
        private var isServiceSetupComplete = false

        @ObservationIgnored
        @Dependency(TerminalNotificationService.self) private var terminalNotificationService

        /// Task for observing system wake notifications.
        @ObservationIgnored
        private var wakeObserverTask: Task<Void, Never>?
        @ObservationIgnored
        private var e2eReconnectObserverTask: Task<Void, Never>?

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

            // Create terminal stream service
            self.terminalStreamService = TerminalStreamService()

            // Create plugin service
            self.pluginService = PluginService()

            // Create editor session manager (API server is started later in setupAllServices)
            let editorManager = EditorSessionManager()
            self.editorSessionManager = editorManager
            self.remoteEditorContentStore = RemoteEditorContentStore()
            self.markdownOpenSuggestionStore = MarkdownOpenSuggestionStore()

            // Create window manager with editor session manager
            self.windowManager = MirrorWindowManager(
                settings: settings,
                tmuxService: tmuxService,
                paneStreamManager: paneStreamManager,
                editorSessionManager: editorManager
            )

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

            return createPairingManager()
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

                if let paneId = event.tmuxPane {
                    let sessionName = await resolveSessionName(forPaneId: paneId)
                    if let sessionName, !sessionName.isEmpty {
                        await markdownOpenSuggestionStore.handleHookEvent(event, sessionName: sessionName)
                    }
                }

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
            await setupAPIServer()
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

            // E2E only: listen for test-driven "reconnect" requests that follow a
            // simulated version-override change.
            #if DEBUG
                if CommandLine.arguments.contains("--e2e-test") {
                    startE2EReconnectObserver()
                }
            #endif
        }

        /// Tears down resources that need explicit cleanup before the app
        /// exits. Disconnects all pane streams (sends `pipe-pane -t` so tmux
        /// kills the `cat > FIFO` subprocesses) and terminates every active
        /// `tmux -C` control-mode client subprocess so AppKit shutdown
        /// doesn't reparent them to launchd. See `AppShutdownDelegate` for
        /// how this is invoked.
        public func shutdown() async {
            logger.info("App shutdown: disconnecting pane streams and control clients")
            await paneStreamManager.disconnectAll()
            await controlClientManager.disconnectAll()
        }

        /// Resolves the tmux session name for a pane. Tries `paneStates` first
        /// (populated for panes the windowManager has already seen), then falls
        /// back to the live `tmuxService.panes` snapshot so events that arrive
        /// before the pane has been mirrored still get matched to a session.
        private func resolveSessionName(forPaneId paneId: String) -> String? {
            if let name = windowManager.paneStates[paneId]?.sessionName, !name.isEmpty {
                return name
            }
            return tmuxService.panes.first(where: { $0.paneId == paneId })?.sessionName
        }

        // MARK: - Private Setup Methods

        /// Error type for API request handling.
        enum APIError: Error, LocalizedError {
            case notFound(String)
            var errorDescription: String? {
                switch self {
                case let .notFound(msg): msg
                }
            }
        }

        /// Starts the API socket server, wires router callbacks, and configures env vars.
        private func setupAPIServer() async {
            let manager = editorSessionManager

            // When editor sessions change, push updated state to viewers
            manager.onSessionChanged = { [weak self] in
                await self?.connectedViewerManager?.pushSessionStateToAll()
            }

            // Wire router callbacks to services
            let tmux = tmuxService
            let winManager = windowManager
            let editorManager = editorSessionManager
            let notificationService = terminalNotificationService
            let scanner = projectScanner
            let claudeCommandPath = settings.claudeCommandPath

            let router = LiveAPIRequestRouter(
                onSessionList: { [tmux] in
                    await MainActor.run {
                        let panes = tmux.panes
                        let attached = tmux.attachedSessionNames
                        let allWindows = LocalTmuxWindow.groupPanes(panes)
                        let grouped = LocalTmuxSession.groupWindows(allWindows)
                        return grouped.map { session in
                            APISessionInfo(
                                id: session.sessionName,
                                name: session.sessionName,
                                windowCount: session.windows.count,
                                isAttached: attached.contains(session.sessionName)
                            ).toJSONValue()
                        }
                    }
                },
                onSessionCreate: { [tmux, winManager] name, path, title, color, ifMissing in
                    let baseName = name ?? "main"
                    // Honor `if_missing`: when the requested name already exists,
                    // return its info with `created: false` so callers can skip
                    // populating panes they didn't just create.
                    if
                        ifMissing, let requestedName = name,
                        await tmux.sessionExists(named: requestedName) {
                        let panes = await tmux.refreshPanes()
                        let attached = await MainActor.run { tmux.attachedSessionNames }
                        let windowCount = LocalTmuxWindow.groupPanes(panes)
                            .filter { $0.sessionName == requestedName }.count
                        await MainActor.run {
                            if let title {
                                winManager.setSessionDescription(title, for: requestedName)
                            }
                            if let color {
                                winManager.setSessionColor(color, for: requestedName)
                            }
                        }
                        return LiveAPIRequestRouter.SessionCreateResult(
                            info: APISessionInfo(
                                id: requestedName,
                                name: requestedName,
                                windowCount: max(windowCount, 1),
                                isAttached: attached.contains(requestedName)
                            ).toJSONValue(),
                            created: false
                        )
                    }
                    let workingDirectory = path ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let (sessionName, _) = try await tmux.createSession(
                        baseName: baseName,
                        width: 200,
                        height: 50,
                        workingDirectory: workingDirectory
                    )
                    await MainActor.run {
                        if let title {
                            winManager.setSessionDescription(title, for: sessionName)
                        }
                        if let color {
                            winManager.setSessionColor(color, for: sessionName)
                        }
                    }
                    return LiveAPIRequestRouter.SessionCreateResult(
                        info: APISessionInfo(
                            id: sessionName,
                            name: sessionName,
                            windowCount: 1,
                            isAttached: false
                        ).toJSONValue(),
                        created: true
                    )
                },
                onSessionSelect: { [tmux] sessionId in
                    try await tmux.selectWindow("\(sessionId):!")
                },
                onSessionCurrent: { [tmux] in
                    await MainActor.run {
                        let panes = tmux.panes
                        let attached = tmux.attachedSessionNames
                        guard
                            let firstAttached = panes.first(where: {
                                attached.contains($0.sessionName)
                            }) else { return nil }
                        let allWindows = LocalTmuxWindow.groupPanes(panes)
                        let windowCount = allWindows.filter { $0.sessionName == firstAttached.sessionName }.count
                        return APISessionInfo(
                            id: firstAttached.sessionName,
                            name: firstAttached.sessionName,
                            windowCount: windowCount,
                            isAttached: true
                        ).toJSONValue()
                    }
                },
                onSessionClose: { [tmux] sessionId in
                    try await tmux.killSession(sessionId)
                },
                onSessionSetState: { [tmux, winManager, weak self] state, paneId, sessionId in
                    guard let parsed = CLISessionState.parse(state) else {
                        throw APIError.notFound(
                            "Unknown state '\(state)'. Use working, idle, waiting, or clear."
                        )
                    }
                    let override: CLISessionState? = switch parsed {
                    case let .set(value): value
                    case .clear: nil
                    }
                    let panes = await tmux.refreshPanes()
                    return await MainActor.run { () -> Int in
                        // Reconcile pane metadata so setCLISessionState finds tracked
                        // entries (sessionName etc.) for hook-driven sibling clearing.
                        winManager.updatePaneStates(from: panes)

                        let targets: [String]
                        if let paneId, panes.contains(where: { $0.paneId == paneId }) {
                            targets = [paneId]
                        } else if let sessionId {
                            let matching = panes.filter { $0.sessionName == sessionId }
                            targets = matching.map(\.paneId)
                        } else {
                            let active = panes.first(where: { $0.isActive && $0.isWindowActive })
                            targets = active.map { [$0.paneId] } ?? []
                        }
                        var applied = 0
                        for target in targets where winManager.setCLISessionState(override, for: target) {
                            applied += 1
                        }
                        if applied > 0 {
                            Task {
                                await self?.connectedViewerManager?.pushSessionStateToAll()
                            }
                        }
                        return applied
                    }
                },
                onSessionSetTitle: { [tmux, winManager] title, sessionId, windowId, paneId in
                    // Resolve the target scope. Window scope wins when a
                    // window_id or pane_id is given so the caller can override
                    // the session-wide value for that window only.
                    let panes = await tmux.refreshPanes()

                    // Window targeting: prefer the cached pane lookup, but
                    // fall back to splitting "sessionName:index" so detached
                    // windows (not currently in `panes`) are still reachable.
                    if let windowId {
                        if let pane = panes.first(where: { $0.windowId == windowId }) {
                            await MainActor.run {
                                winManager.setWindowDescription(
                                    title,
                                    sessionName: pane.sessionName,
                                    windowIndex: pane.windowIndex
                                )
                            }
                            return "window"
                        }
                        let parts = windowId.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2, let index = Int(parts[1]) {
                            await MainActor.run {
                                winManager.setWindowDescription(
                                    title,
                                    sessionName: parts[0],
                                    windowIndex: index
                                )
                            }
                            return "window"
                        }
                        throw APIError.notFound("Window not found: \(windowId)")
                    }
                    if
                        let paneId,
                        let pane = panes.first(where: { $0.paneId == paneId }) {
                        // Pane points at a window within its (possibly
                        // detached) session. Apply at session scope so the
                        // caller's intent — "set this for the calling
                        // pane's session" — is preserved even when no
                        // session is currently attached.
                        await MainActor.run {
                            winManager.setSessionDescription(title, for: pane.sessionName)
                        }
                        return "session"
                    }
                    if let sessionId {
                        // Verify the session actually exists so a bad name
                        // surfaces as `not_found` rather than a 200/OK with
                        // no real side effect.
                        guard await tmux.sessionExists(named: sessionId) else {
                            throw APIError.notFound("Session not found: \(sessionId)")
                        }
                        await MainActor.run {
                            winManager.setSessionDescription(title, for: sessionId)
                        }
                        return "session"
                    }
                    // No explicit target — fall back to the active session.
                    let attached = await MainActor.run { tmux.attachedSessionNames }
                    if
                        let activeSession = panes.first(where: {
                            attached.contains($0.sessionName)
                        })?.sessionName {
                        await MainActor.run {
                            winManager.setSessionDescription(title, for: activeSession)
                        }
                        return "session"
                    }
                    throw APIError.notFound("No resolvable target for session.set_title")
                },
                onSessionSetColor: { [tmux, winManager] color, sessionId, windowId, paneId in
                    // Mirrors `onSessionSetTitle`: window scope wins when a
                    // window or pane is named, otherwise apply at session scope
                    // so detached sessions still pick up the color.
                    let panes = await tmux.refreshPanes()

                    if let windowId {
                        if let pane = panes.first(where: { $0.windowId == windowId }) {
                            await MainActor.run {
                                winManager.setWindowColor(
                                    color,
                                    sessionName: pane.sessionName,
                                    windowIndex: pane.windowIndex
                                )
                            }
                            return "window"
                        }
                        let parts = windowId.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2, let index = Int(parts[1]) {
                            await MainActor.run {
                                winManager.setWindowColor(
                                    color,
                                    sessionName: parts[0],
                                    windowIndex: index
                                )
                            }
                            return "window"
                        }
                        throw APIError.notFound("Window not found: \(windowId)")
                    }
                    if
                        let paneId,
                        let pane = panes.first(where: { $0.paneId == paneId }) {
                        await MainActor.run {
                            winManager.setSessionColor(color, for: pane.sessionName)
                        }
                        return "session"
                    }
                    if let sessionId {
                        guard await tmux.sessionExists(named: sessionId) else {
                            throw APIError.notFound("Session not found: \(sessionId)")
                        }
                        await MainActor.run {
                            winManager.setSessionColor(color, for: sessionId)
                        }
                        return "session"
                    }
                    let attached = await MainActor.run { tmux.attachedSessionNames }
                    if
                        let activeSession = panes.first(where: {
                            attached.contains($0.sessionName)
                        })?.sessionName {
                        await MainActor.run {
                            winManager.setSessionColor(color, for: activeSession)
                        }
                        return "session"
                    }
                    throw APIError.notFound("No resolvable target for session.set_color")
                },
                onWindowList: { [tmux] sessionId, paneId in
                    let panes = await tmux.refreshPanes()
                    let allWindows = LocalTmuxWindow.groupPanes(panes)
                    let resolvedSessionId = sessionId
                        ?? paneId.flatMap { id in panes.first(where: { $0.paneId == id })?.sessionName }
                    let filtered = if let resolvedSessionId {
                        allWindows.filter { $0.sessionName == resolvedSessionId }
                    } else {
                        allWindows
                    }
                    return filtered.map { window in
                        APIWindowInfo(
                            id: window.id,
                            index: window.windowIndex,
                            name: window.windowName,
                            paneCount: window.panes.count,
                            isActive: window.isWindowActive,
                            sessionId: window.sessionName
                        ).toJSONValue()
                    }
                },
                onWindowCreate: { [tmux, winManager] sessionId, path, paneId, title, name in
                    let targetSession: String = await MainActor.run {
                        if let sessionId { return sessionId }
                        let panes = tmux.panes
                        if let paneId, let match = panes.first(where: { $0.paneId == paneId }) {
                            return match.sessionName
                        }
                        let attached = tmux.attachedSessionNames
                        return panes.first(where: {
                            attached.contains($0.sessionName)
                        })?.sessionName ?? panes.first?.sessionName ?? "main"
                    }
                    let workingDirectory = path ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let newPaneId = try await tmux.newWindow(
                        sessionName: targetSession,
                        workingDirectory: workingDirectory,
                        windowName: name
                    )
                    let panes = await tmux.refreshPanes()
                    guard let newPane = panes.first(where: { $0.paneId == newPaneId }) else {
                        throw APIError.notFound("New window pane not found")
                    }
                    if let title {
                        await MainActor.run {
                            winManager.setWindowDescription(
                                title,
                                sessionName: newPane.sessionName,
                                windowIndex: newPane.windowIndex
                            )
                        }
                    }
                    return APIWindowInfo(
                        id: newPane.windowId,
                        index: newPane.windowIndex,
                        name: newPane.windowName,
                        paneCount: 1,
                        isActive: true,
                        sessionId: newPane.sessionName
                    ).toJSONValue()
                },
                onWindowSelect: { [tmux] windowId in
                    try await tmux.selectWindow(windowId)
                },
                onWindowClose: { [tmux] windowId in
                    try await tmux.killWindow(windowId)
                },
                onPaneList: { [tmux, winManager] windowId, paneId in
                    let panes = await tmux.refreshPanes()
                    return await MainActor.run {
                        let resolvedWindowId = windowId
                            ?? paneId.flatMap { id in panes.first(where: { $0.paneId == id })?.windowId }
                        let filtered = if let resolvedWindowId {
                            panes.filter { $0.windowId == resolvedWindowId }
                        } else {
                            panes
                        }
                        return filtered.map { pane in
                            let hasSession = winManager.paneStates[pane.paneId]?.claudeSession != nil
                            return APIPaneInfo(
                                id: pane.paneId,
                                index: pane.paneIndex,
                                isActive: pane.isActive,
                                command: pane.command,
                                cwd: pane.currentPath,
                                width: pane.width,
                                height: pane.height,
                                windowId: pane.windowId,
                                hasClaudeSession: hasSession
                            ).toJSONValue()
                        }
                    }
                },
                onPaneSplit: { [tmux, winManager] paneId, direction, path, shellCommand in
                    let horizontal = direction == "right" || direction == "horizontal"
                    let target: String = await MainActor.run {
                        paneId ?? tmux.panes.first(where: { $0.isActive && $0.isWindowActive })?.paneId ?? "%0"
                    }
                    let workingDirectory = path ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let newPaneId = try await tmux.splitPane(
                        target,
                        horizontal: horizontal,
                        workingDirectory: workingDirectory,
                        shellCommand: shellCommand
                    )
                    let panes = await tmux.refreshPanes()
                    await MainActor.run { winManager.updatePaneStates(from: panes) }
                    guard let newPane = panes.first(where: { $0.paneId == newPaneId }) else {
                        throw APIError.notFound("New pane not found after split")
                    }
                    return APIPaneInfo(
                        id: newPane.paneId,
                        index: newPane.paneIndex,
                        isActive: newPane.isActive,
                        command: newPane.command,
                        cwd: newPane.currentPath,
                        width: newPane.width,
                        height: newPane.height,
                        windowId: newPane.windowId,
                        hasClaudeSession: false
                    ).toJSONValue()
                },
                onPaneSelect: { [tmux] paneId in
                    try await tmux.selectPane(paneId)
                },
                onPaneCapture: { [tmux] paneId, scrollback in
                    let target: String = await MainActor.run {
                        paneId ?? tmux.panes.first(where: { $0.isActive && $0.isWindowActive })?.paneId ?? "%0"
                    }
                    return try await tmux.capturePaneText(target, scrollback: scrollback)
                },
                onPaneSetLayout: { [tmux] target, layout in
                    try await tmux.selectLayout(target: target, layout: layout)
                },
                onSendText: { [tmux] text, paneId, appendEnter in
                    let target: String = await MainActor.run {
                        paneId ?? tmux.panes.first(where: { $0.isActive && $0.isWindowActive })?.paneId ?? "%0"
                    }
                    // Skip the literal write when there's nothing to type so that
                    // `send "" --enter` (just hit Enter) doesn't spawn an extra
                    // tmux subprocess for a no-op.
                    if !text.isEmpty {
                        try await tmux.sendKeys(target, keys: text, literal: true)
                    }
                    if appendEnter {
                        // Send Enter as a keyname (not literal) so tmux generates
                        // a real Enter keypress for the running shell/program.
                        try await tmux.sendKeys(target, keys: "Enter")
                    }
                },
                onSendKey: { [tmux] key, paneId in
                    let target: String = await MainActor.run {
                        paneId ?? tmux.panes.first(where: { $0.isActive && $0.isWindowActive })?.paneId ?? "%0"
                    }
                    try await tmux.sendKeys(target, keys: key)
                },
                onNotify: { [notificationService] title, body, subtitle, paneId in
                    let notification = TerminalStreamMessage.TerminalNotification(
                        title: subtitle ?? title,
                        body: body
                    )
                    let targetPane = paneId ?? "system"
                    notificationService.showNotification(targetPane, notification)
                },
                onEditorOpen: { [editorManager] paneId, filePath in
                    await editorManager.handleAPIEditRequest(paneId: paneId, filePath: filePath)
                },
                onIdentify: { [tmux, winManager] paneId in
                    let panes = await tmux.refreshPanes()
                    return await MainActor.run { () -> [String: JSONValue]? in
                        guard
                            let pane = paneId.flatMap({ id in panes.first(where: { $0.paneId == id }) })
                            ?? panes.first(where: { $0.isActive && $0.isWindowActive })
                        else { return nil }

                        let hasSession = winManager.paneStates[pane.paneId]?.claudeSession != nil
                        let attached = tmux.attachedSessionNames
                        return APIIdentifyInfo(
                            session: APISessionInfo(
                                id: pane.sessionName,
                                name: pane.sessionName,
                                windowCount: LocalTmuxWindow.groupPanes(panes)
                                    .filter { $0.sessionName == pane.sessionName }.count,
                                isAttached: attached.contains(pane.sessionName)
                            ),
                            window: APIWindowInfo(
                                id: pane.windowId,
                                index: pane.windowIndex,
                                name: pane.windowName,
                                paneCount: panes.filter { $0.windowId == pane.windowId }.count,
                                isActive: pane.isWindowActive,
                                sessionId: pane.sessionName
                            ),
                            pane: APIPaneInfo(
                                id: pane.paneId,
                                index: pane.paneIndex,
                                isActive: pane.isActive,
                                command: pane.command,
                                cwd: pane.currentPath,
                                width: pane.width,
                                height: pane.height,
                                windowId: pane.windowId,
                                hasClaudeSession: hasSession
                            )
                        ).toJSONValue()
                    }
                },
                onProjectList: { [scanner] in
                    let projects = await scanner.scanProjects()
                    return projects.map { APIProjectInfo($0).toJSONValue() }
                },
                onProjectStart: { [tmux, claudeCommandPath] path, args in
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                        isDirectory.boolValue
                    else {
                        throw APIError.notFound("Path does not exist or is not a directory: \(path)")
                    }
                    let runCommand: String
                    if args.isEmpty {
                        runCommand = shellQuoteSingle(claudeCommandPath)
                    } else {
                        let quoted = args.map(shellQuoteSingle).joined(separator: " ")
                        runCommand = "\(shellQuoteSingle(claudeCommandPath)) \(quoted)"
                    }
                    let (sessionName, _) = try await tmux.createSession(
                        baseName: url.lastPathComponent,
                        width: 200,
                        height: 50,
                        workingDirectory: url.path,
                        runCommand: runCommand
                    )
                    return APISessionInfo(
                        id: sessionName,
                        name: sessionName,
                        windowCount: 1,
                        isAttached: false
                    ).toJSONValue()
                },
                onSetEnvironment: { [tmux] sessionId, vars in
                    for (name, value) in vars {
                        try await tmux.setSessionEnvironment(
                            sessionName: sessionId,
                            name: name,
                            value: value
                        )
                    }
                },
                onLayoutApply: {
                    [tmux, winManager, claudeCommandPath] config, rebuild, detach, dryRun, lenient, requireCreate, configPath in
                    let parser = LayoutConfigParser(
                        lenient: lenient,
                        environment: ProcessInfo.processInfo.environment
                    )
                    let parsed = try parser.parse(config)
                    let driver = LayoutDriver(
                        tmuxAccessor: { tmux },
                        descriptionApplier: { description, sessionName, windowSession, windowIndex in
                            await MainActor.run {
                                if let sessionName {
                                    winManager.setSessionDescription(description, for: sessionName)
                                } else if let windowSession, let windowIndex {
                                    winManager.setWindowDescription(
                                        description,
                                        sessionName: windowSession,
                                        windowIndex: windowIndex
                                    )
                                }
                            }
                        },
                        colorApplier: { color, sessionName in
                            await MainActor.run {
                                winManager.setSessionColor(color, for: sessionName)
                            }
                        }
                    )
                    let configDir = configPath.map { (URL(fileURLWithPath: $0).deletingLastPathComponent()).path }
                    let result = try await driver.apply(
                        parsed,
                        rebuild: rebuild,
                        detach: detach,
                        dryRun: dryRun,
                        requireCreate: requireCreate,
                        configDirectory: configDir,
                        claudeCommandPath: claudeCommandPath
                    )
                    return [
                        "session_name": .string(result.sessionName),
                        "created": .bool(result.created),
                        "warnings": .array(result.warnings.map { .string($0) }),
                        "planned_actions": .array(result.plannedActions.map { .string($0) }),
                    ]
                }
            )
            liveRouter = router

            // Set the router as the request handler on the socket server
            await apiSocketServer.setRequestHandler(router.handleRequest)

            // Start the socket server (use separate path in E2E to avoid conflicts)
            let isE2E = CommandLine.arguments.contains("--e2e-test")
            let socketPath = NSTemporaryDirectory() + (isE2E ? "gallager-e2e.sock" : "gallager.sock")
            do {
                try await apiSocketServer.start(socketPath)
            } catch {
                logger.error("Failed to start API socket server: \(error)")
                return
            }

            // Set the VISUAL env var on TmuxService so new sessions use our CLI.
            // The CLI is expected to be in the app bundle's MacOS directory.
            if let editorURL = Bundle.main.url(forAuxiliaryExecutable: "GallagerCLI") {
                tmuxService.editorCLIPath = editorURL.path
                tmuxService.apiSocketPath = socketPath
                logger.info("GallagerCLI path: \(editorURL.path)")
            } else {
                logger.warning("GallagerCLI not found in app bundle")
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
            await windowManager.refreshGitBranches()
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

                // Handle session description (applied to every pane in the session)
                // pushSessionStateToAll() runs via onDescriptionChanged, not here.
                if case let .setSessionDescription(spec) = command.command {
                    winManager.setSessionDescription(spec.description, for: spec.sessionName)
                    return .success(for: command.id)
                }

                // Handle session color (applied to every pane in the session).
                // pushSessionStateToAll() runs via onDescriptionChanged, not here.
                if case let .setSessionColor(spec) = command.command {
                    winManager.setSessionColor(spec.color, for: spec.sessionName)
                    return .success(for: command.id)
                }

                // Handle window rename — pushes updated state so connected
                // viewers see the new tab name.
                if case let .setWindowName(spec) = command.command {
                    let trimmed = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return .failure(for: command.id, error: "Window name must not be empty")
                    }
                    do {
                        try await tmux.renameWindow(target: spec.windowId, name: trimmed)
                        let allPanes = await tmux.refreshPanes()
                        winManager.updatePaneStates(from: allPanes)
                        await connectionManager?.pushSessionStateToAll()
                        return .success(for: command.id)
                    } catch {
                        return .failure(for: command.id, error: error.localizedDescription)
                    }
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

                // Handle check running processes (for remote close confirmation)
                if case let .checkRunningProcesses(spec) = command.command {
                    return await Self.handleCheckRunningProcesses(
                        command: command,
                        spec: spec,
                        tmuxService: tmux
                    )
                }

                // Handle kill window
                if case let .killTmuxWindow(spec) = command.command {
                    return await Self.handleKillWindow(
                        command: command,
                        spec: spec,
                        tmuxService: tmux,
                        windowManager: winManager,
                        connectionManager: connectionManager
                    )
                }

                // Handle kill session
                if case let .killTmuxSession(spec) = command.command {
                    return await Self.handleKillSession(
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

        /// E2E only: observe `com.claudespy.e2e.reconnectViewers`, posted by
        /// `TestAccessibilityServer` after a test-driven version-override change.
        /// Forwards to the host-role connection manager so the host can rejoin
        /// the relay after `handleVersionMismatch` closed its WebSocket.
        ///
        /// Viewer-role retry now goes through the explicit Retry affordance on
        /// the version-mismatch row UI; scenarios drive that instead of relying
        /// on this listener.
        private func startE2EReconnectObserver() {
            e2eReconnectObserverTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: .init("com.claudespy.e2e.reconnectViewers")
                )
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    await self?.connectedViewerManager?.enableReconnectAndRetryAll()
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
            e2eReconnectObserverTask?.cancel()
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

                let extraEnvironment: [String] = if let configDir = spec.claudeConfigDir {
                    ["CLAUDE_CONFIG_DIR=\(configDir)"]
                } else {
                    []
                }

                // A non-nil `spec.workingDirectory` means this was a
                // "create from Claude project" request — that's the only flow
                // today that supplies a directory. Other entry points (empty
                // session) leave it nil, so we treat presence as the project
                // marker and name the first window "claude" accordingly.
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: spec.sessionName,
                    width: spec.width,
                    height: spec.height,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand,
                    extraEnvironment: extraEnvironment,
                    isClaudeProject: spec.workingDirectory != nil
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

        private static func handleCheckRunningProcesses(
            command: CommandMessage,
            spec: CheckRunningProcesses,
            tmuxService: TmuxService
        ) async -> CommandResponseMessage {
            let processes: [TmuxService.RunningProcess]
            switch spec.target {
            case let .window(windowId):
                processes = await tmuxService.runningProcesses(inWindow: windowId)
            case let .session(sessionName):
                processes = await tmuxService.runningProcesses(inSession: sessionName)
            }

            let processInfos = processes.map {
                RunningProcessInfo(paneIndex: $0.paneIndex, name: $0.name, isForeground: $0.isForeground)
            }
            return .success(for: command.id, runningProcesses: processInfos)
        }

        private static func handleKillWindow(
            command: CommandMessage,
            spec: KillTmuxWindow,
            tmuxService: TmuxService,
            windowManager: MirrorWindowManager,
            connectionManager: ConnectedViewerManager?
        ) async -> CommandResponseMessage {
            do {
                // killWindow internally refreshes panes
                try await tmuxService.killWindow(spec.windowId)
                windowManager.updatePaneStates(from: tmuxService.panes)
                await connectionManager?.pushSessionStateToAll()
                return .success(for: command.id)
            } catch {
                return .failure(for: command.id, error: error.localizedDescription)
            }
        }

        private static func handleKillSession(
            command: CommandMessage,
            spec: KillTmuxSession,
            tmuxService: TmuxService,
            windowManager: MirrorWindowManager,
            connectionManager: ConnectedViewerManager?
        ) async -> CommandResponseMessage {
            do {
                // killSession internally refreshes panes
                try await tmuxService.killSession(spec.sessionName)
                windowManager.updatePaneStates(from: tmuxService.panes)
                await connectionManager?.pushSessionStateToAll()
                return .success(for: command.id)
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

                // Wire session state updates from remote hosts.
                // After applying the update, prune any remote-editor edits whose
                // sessions the host has ended — otherwise those entries leak until quit.
                manager.onSessionState = { [weak store, weak remoteEditorContentStore] state in
                    store?.handleStateUpdate(state)
                    guard let remoteEditorContentStore, let panes = store?.panes else { return }
                    let activeIds = Set(panes.compactMap { $0.editorSession?.sessionId })
                    remoteEditorContentStore.retainOnly(activeSessionIds: activeIds)
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
