#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
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

        /// Editor session manager for Ctrl-G prompt editing
        public let editorSessionManager: EditorSessionManager

        /// Persists in-progress edits for remote viewer editor overlays, keyed by session UUID.
        public let remoteEditorContentStore: RemoteEditorContentStore

        /// Holds "Claude wrote a markdown file — open it?" prompts per tmux session.
        public let markdownOpenSuggestionStore: MarkdownOpenSuggestionStore

        // MARK: - Editor Override (issue #591)

        /// Result of this launch's `$VISUAL`-survival probe, or nil until it
        /// finishes. Read by the consent dialog and the Settings status line.
        public private(set) var editorOverrideProbeResult: VisualProbeResult?

        /// Drives the consent dialog sheet. Set true on the first session creation
        /// when the probe found a conflict and the mode is still `.ask`.
        public var isShowingEditorOverrideDialog = false

        /// Latches once the consent dialog has been offered this launch so it
        /// isn't re-presented on every subsequent session creation.
        @ObservationIgnored
        private var hasPresentedEditorOverrideDialogThisLaunch = false

        // MARK: - In-Process Plugin Runtime (additive; coexists with HookServerService)

        /// On-disk layout for the in-process plugin runtime. Built in
        /// `setupAllServices()` from `--gallager-state-root` (E2E isolation) or
        /// the default `~/.gallager` tree.
        ///
        /// `internal` (not `private`) so `@testable import` tests can inject a
        /// temp-dir `GallagerPaths` without calling `setupAllServices()`.
        @ObservationIgnored
        var gallagerPaths: GallagerPaths?

        /// Owns the plugin factory table + enabled-core lifecycle.
        ///
        /// `internal` (not `private`) so `@testable import` tests can inject a
        /// pre-configured `PluginRegistry` without calling `setupAllServices()`.
        @ObservationIgnored
        var pluginRegistry: PluginRegistry?

        /// The single agent-blind event dispatcher; its sinks are wired to the
        /// local adapter methods (status/notification/app-action) below.
        @ObservationIgnored
        private var pluginDispatcher: PluginEventDispatcher?

        /// The one app-owned ingress socket server. Coexists with
        /// `hookServer`; in normal runs no frames reach it (hook bridges aren't
        /// installed to it), so the new path is exercised only by E2E/tests.
        @ObservationIgnored
        private var ingressSocketServer: IngressSocketServer?

        /// Mac-local OTLP/JSON receiver for Claude Code telemetry (issue #597).
        /// Loopback-only; accumulates per-session token/cost/latency and emits
        /// milestone / mode-change events. Additive to the hook channel.
        @ObservationIgnored
        private var otlpReceiver: OTLPReceiver?

        /// Durable cross-session cost/usage aggregation (issue #598). Persists
        /// per-(project, day) totals under the gallager state tree so they outlive
        /// session end and app restarts. Fed from telemetry updates; finalized on
        /// session end.
        @ObservationIgnored
        private var usageStore: UsageAggregationStore?

        /// Latest cross-session usage rollup for the host's own surfaces (the menu
        /// bar today-total, issue #598). Observable so those views refresh; `nil`
        /// until there's something worth showing. Viewers get their copy via
        /// `SessionStateMessage.usageOverview`, not this property.
        public private(set) var usageOverview: UsageOverview?

        /// Per-plugin log sinks (one per active plugin), retained so the host's
        /// `log()` calls keep landing in the right file.
        @ObservationIgnored
        private var pluginLogSinks: [String: PluginLogSink] = [:]

        /// Latest project list each plugin pushed via `PluginHost.setProjects`.
        /// Merged across plugins into `SessionStateMessage.agentProjects` by
        /// `currentAgentProjects()` on each session-state push.
        @ObservationIgnored
        private var pluginProjects: [String: [AgentProject]] = [:]

        #if DEBUG
            /// When `true` (E2E `--e2e-seed-projects`), `scanProjects()` returns
            /// the deterministic seed verbatim and never invokes the real cores'
            /// `refreshProjects()` — which would otherwise re-scan the host's real
            /// `~/.claude/projects` / `~/.codex/sessions` and clobber the seed when
            /// the project picker opens (`loadProjects` → `scanProjects`).
            @ObservationIgnored
            private var e2eSeededProjects = false
        #endif

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

        /// Trailing-edge throttle for `OSC 9;4` progress pushes to viewers. Each
        /// new progress arrival cancels the pending task and schedules a fresh
        /// 150ms delay, so a stream stepping 0 → 100% in 1% increments collapses
        /// into a single relay send carrying the latest `PaneState.progress`.
        @ObservationIgnored
        private var pendingProgressPush: Task<Void, Never>?

        /// Throttle handle for OTEL telemetry pushes to viewers (issue #597). A
        /// true trailing throttle (not a debounce): the first event opens a 1s
        /// window and later events fold into a single push at its end (carrying
        /// the latest pane state), so a sustained burst still flushes ~1/sec
        /// instead of starving. The host's own sidebar updates synchronously via
        /// the `paneStates` assignment; only the cross-device push is throttled.
        @ObservationIgnored
        private var pendingTelemetryPush: Task<Void, Never>?

        @ObservationIgnored
        @Dependency(PreferencesService.self) private var preferences

        @ObservationIgnored
        @Dependency(DockIconService.self) private var dockIconService

        @ObservationIgnored
        @Dependency(SleepPreventionService.self) private var sleepPreventionService

        @ObservationIgnored
        @Dependency(DeviceNameClient.self) private var deviceNameClient

        private let logger = Logger(label: "com.claudespy.coordinator")

        // MARK: - Initialization

        /// Creates the AppCoordinator with default or provided settings.
        ///
        /// Synchronous initialization sets up core services. Call `setupAllServices()` asynchronously
        /// to complete service initialization and start connections.
        public init(settings: AppSettings = AppSettings()) {
            self.settings = settings

            #if canImport(AppKit) && DEBUG
                // Expose live settings to the E2E test server so a scenario can
                // opt into off-by-default sidebar fields (e.g. Token Usage).
                TestAccessibilityServer.liveSettings = settings
            #endif

            // Create tmux service
            self.tmuxService = TmuxService(
                tmuxPath: settings.tmuxPath,
                socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
            )
            // Let the tmux service's `default-command` wrapper bake the
            // user's currently-selected mirror theme into the OSC 10/11
            // setters it emits. Read live so theme changes take effect for
            // the next-spawned shell without restarting the app.
            tmuxService.setThemeProvider { [settings] in settings.theme }

            // Mirror the persisted editor-override choice onto the tmux service so
            // injection is active from the first pane if the user already opted in
            // on a prior launch (issue #591).
            tmuxService.overrideVisualInShellPanes = settings.editorOverrideMode == .overrideInGallagerSessions

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

        /// Asks every active plugin to rescan, then returns the merged project
        /// list each plugin pushed via `host.setProjects` (spec §12). The plugin
        /// cores own scanning now (the legacy Swift scanners were deleted).
        public func scanProjects() async -> [AgentProject] {
            #if DEBUG
                // E2E determinism: return the seeded set without re-scanning the
                // host's real project dirs (which would clobber the seed).
                if e2eSeededProjects {
                    return mergedPluginProjects()
                }
            #endif
            if let registry = pluginRegistry {
                for id in Array(registry.active.keys) {
                    await registry.core(id)?.refreshProjects()
                }
            }
            return mergedPluginProjects()
        }

        /// Flattens the per-plugin project lists into one recency-sorted list.
        private func mergedPluginProjects() -> [AgentProject] {
            pluginProjects.values.flatMap { $0 }.sortedByLastUsed()
        }

        /// Sets up all services. Call this once when the app starts (e.g., from a .task modifier).
        public func setupAllServices() async {
            guard !isServiceSetupComplete else { return }
            isServiceSetupComplete = true

            // Pre-fill the editor list on first launch with whatever is installed
            // on the host. Done here rather than in `init` so the Launch Services
            // lookups don't block app startup on MainActor; subsequent launches
            // read the persisted list (which the user may have edited), so this
            // is a one-shot.
            @Dependency(EditorClient.self) var editorClient
            await settings.seedEditorsIfEmpty(using: editorClient)

            // Clean up any stale pipe-pane FIFOs from previous crashes
            PipePaneReader.cleanupStaleFifos()

            // Sweep any leftover `gallager-drop-*` directories from prior
            // sessions. Each remote drop drops a per-UUID subdir under
            // `$TMPDIR`, normally short-lived: the inner pane app reads
            // the file before the user moves on. macOS does its own lazy
            // pruning, but a long-running session benefits from explicit
            // cleanup at launch so the host doesn't accumulate hundreds
            // of small folders.
            sweepStaleDropDirectories()

            // Start dock icon management (hides dock icon initially, shows when windows open)
            await dockIconService.startObserving()

            // Hook ingestion now flows through the in-process plugin runtime
            // (ingress socket → core → dispatcher → sinks). The legacy
            // HTTP `HookServerService` path is gone (spec §16).
            await initializeServices()
            await setupPluginRuntime()
            await setupAPIServer()
            await setupConnectedViewerManager()
            await setupViewerConnectionManager()
            await autoConnectIfConfigured()

            // Probe whether the user's rc files clobber Gallager's `$VISUAL`
            // (issue #591). Detached so the ~1–10s probe never blocks launch; any
            // dialog it triggers is deferred to the first session anyway.
            switch settings.editorOverrideMode {
            case .ask:
                // Decision still pending: probe so the dialog can offer on a
                // detected conflict at the first session.
                Task { await runEditorConflictProbe() }
            case .overrideInGallagerSessions:
                // Already injecting. Re-check whether the conflict that justified
                // it still exists — if the user has since removed `export VISUAL`
                // from their rc, the injection is now redundant and is dropped.
                Task { await reconcileOverrideAgainstProbe() }
            case .useMyEditor:
                // Never overriding, never asking — nothing to probe for.
                break
            }

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

            // Tear down the in-process plugin runtime: stop accepting ingress
            // frames, then `shutdown()` each active core via the registry.
            await ingressSocketServer?.stop()
            await otlpReceiver?.stop()
            if let registry = pluginRegistry {
                for id in Array(registry.active.keys) {
                    await registry.disable(id)
                }
            }
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

        // MARK: - Editor Override (issue #591)

        /// Runs the `$VISUAL`-survival probe and caches the result. Invoked once at
        /// startup and again from the Settings "re-check" affordance.
        func runEditorConflictProbe() async {
            let result = await tmuxService.probeVisualConflict()
            editorOverrideProbeResult = result
        }

        /// Re-runs the probe on demand (Settings "re-check now"), and — if the
        /// conflict has since been resolved (e.g. the user edited their rc files
        /// per Option 1) — clears the latch so a future genuine conflict can ask
        /// again. Also drops a now-redundant override (see
        /// `dropRedundantOverrideIfConflictResolved`).
        public func reprobeEditorConflict() async {
            await runEditorConflictProbe()
            dropRedundantOverrideIfConflictResolved()
            if editorOverrideProbeResult?.isConflict != true {
                hasPresentedEditorOverrideDialogThisLaunch = false
            }
        }

        /// Startup reconciliation for override mode: probe, then drop the override
        /// if the conflict it was opted into for is gone (issue #591).
        private func reconcileOverrideAgainstProbe() async {
            await runEditorConflictProbe()
            dropRedundantOverrideIfConflictResolved()
        }

        /// If we're injecting `export VISUAL=…` (override mode) but the probe
        /// positively confirmed the rc conflict is gone (`.intact`), the
        /// injection is redundant — Gallager's `-e VISUAL` already wins — so fall
        /// back to `.ask` and stop typing it into every pane. A `.skipped` probe
        /// isn't proof the conflict is gone, so the override is left untouched
        /// (issue #591).
        private func dropRedundantOverrideIfConflictResolved() {
            guard
                EditorOverride.shouldDropRedundantOverride(
                    mode: settings.editorOverrideMode,
                    probe: editorOverrideProbeResult
                ) else { return }
            setEditorOverrideMode(.ask)
        }

        /// Whether the consent dialog should be offered: a conflict was detected
        /// and the user hasn't yet made a durable choice (still `.ask`), and we
        /// haven't already asked this launch.
        public var shouldOfferEditorOverrideDialog: Bool {
            settings.editorOverrideMode == .ask
                && editorOverrideProbeResult?.isConflict == true
                && !hasPresentedEditorOverrideDialogThisLaunch
        }

        /// Presents the consent dialog if it's warranted. Called whenever a
        /// session appears or the probe finishes, so it shows on whichever
        /// happens last — but only once there's a local session, so "Ctrl-G" has
        /// context (issue #591 §2).
        public func maybePresentEditorOverrideDialog() {
            guard shouldOfferEditorOverrideDialog else { return }
            guard !tmuxService.sessions.isEmpty else { return }
            hasPresentedEditorOverrideDialogThisLaunch = true
            isShowingEditorOverrideDialog = true
        }

        /// Applies a durable editor-override choice (from the dialog or Settings):
        /// persists it and reflects it onto the tmux service, injecting into
        /// existing shell panes when turning the override on.
        public func setEditorOverrideMode(_ mode: EditorOverrideMode) {
            settings.editorOverrideMode = mode
            let active = mode == .overrideInGallagerSessions
            tmuxService.overrideVisualInShellPanes = active
            if active {
                Task { await tmuxService.injectVisualOverrideIntoExistingShellPanes() }
            } else {
                tmuxService.clearInjectedOverrideTracking()
            }
        }

        #if DEBUG
            /// Preview/test seam: seed the probe result without running the live
            /// tmux probe, so SwiftUI previews can render the consent dialog
            /// (`EditorOverrideDialog`) in a realistic conflict state (issue #591).
            func setEditorOverrideProbeResultForPreview(_ result: VisualProbeResult?) {
                editorOverrideProbeResult = result
            }
        #endif

        // MARK: - In-Process Plugin Runtime Setup (additive)

        /// Constructs and starts the agent-blind in-process plugin runtime
        /// alongside the existing `HookServerService` path (spec §4–§9). This
        /// path is ADDITIVE: both ingestion paths coexist. In normal runs no
        /// frames hit the ingress socket (hook bridges aren't installed to it),
        /// so there is no double-processing; the new path is exercised only by
        /// E2E/tests writing to the socket.
        ///
        /// Wires the dispatcher's local sinks (state → `MirrorWindowManager`,
        /// notification → `TerminalNotificationService`, auto-approve → the owning
        /// core's `deliverResponse`, app actions → markdown suggestions / pane
        /// close) and the host's send sinks (text/keys → `TmuxService`, projects →
        /// `pluginProjects`). The open response form rides `AgentSession.state`, so
        /// it travels in the `agent_session_status` push and the `SessionStateMessage`
        /// snapshot automatically — there is no separate form transport. The inbound
        /// `agent_response_submission` routes back to the owning core's
        /// `deliverResponse` (wired in `setupConnectedViewerManager`). State forwards
        /// as `agent_session_status` and notifications forward to the iOS push path.
        private func setupPluginRuntime() async {
            let paths = GallagerPaths(stateRootOverride: Self.parseGallagerStateRoot())
            paths.ensureBaseDirectories()
            gallagerPaths = paths

            // One-shot migration of legacy per-agent settings → per-plugin
            // settings.json, before cores read them via PluginEnv.settings (§11).
            PluginSettingsMigration.runIfNeeded(paths: paths, preferences: preferences)

            // Dispatcher: fan PluginEvents out to local app behavior.
            let dispatcher = PluginEventDispatcher(
                onState: { [weak self] pluginID, sessionID, state, tmuxPane, projectPath, permissionMode in
                    await self?.handlePluginState(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        state: state,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath,
                        permissionMode: permissionMode
                    )
                    // (handlePluginState also forwards agent_session_status to iOS;
                    // the open form rides AgentSession.state so it's in the snapshot.)
                },
                onNotification: { [weak self] _, paneID, notification in
                    await self?.handlePluginNotification(notification, paneId: paneID)
                    // (handlePluginNotification also forwards the push to iOS.)
                },
                onAutoApprove: { [weak self] pluginID, sessionID, requestID in
                    // Yolo auto-approve (spec §6): the dispatcher already decided the
                    // permission is auto-approvable on a yolo pane, kept the session
                    // working, and suppressed the notification. Deliver the approval
                    // to the owning core.
                    await self?.pluginRegistry?.core(pluginID)?.deliverResponse(
                        sessionID: sessionID,
                        requestID: requestID,
                        .permission(decision: .allow, appliedSuggestionID: nil)
                    )
                },
                onAppAction: { [weak self] action in
                    await self?.handlePluginAppAction(action)
                },
                isYoloModeEnabled: { [weak self] paneID in
                    guard let self else { return false }
                    return await self.windowManager.isYoloModeEnabled(for: paneID)
                }
            )
            pluginDispatcher = dispatcher

            // Registry + per-plugin enable.
            let registry = PluginRegistry()
            pluginRegistry = registry

            var pluginIDs = ["claude-code", "codex"]
            #if DEBUG
                if CommandLine.arguments.contains("--e2e-test") {
                    pluginIDs.append("echo")
                }
            #endif

            for id in pluginIDs {
                paths.ensurePluginStateDir(id)
                let host = makePluginHost(id: id, dispatcher: dispatcher, paths: paths)
                let env = makePluginEnv(id: id, registry: registry, paths: paths)

                await registry.enable(id, host: host, env: env)
                if let failure = registry.failedInit[id] {
                    logger.warning("Plugin '\(id)' left disabled: \(failure)")
                }
            }

            // Ingress socket: route frames by pluginID to the enabled core.
            let server = IngressSocketServer(
                socketPath: paths.ingressSocketPath.path,
                coreLookup: { [weak registry] pluginID in
                    await MainActor.run { registry?.core(pluginID) }
                },
                dispatcher: dispatcher
            )
            ingressSocketServer = server
            do {
                try await server.start()
                logger.info("Plugin ingress socket listening at \(paths.ingressSocketPath.path)")
            } catch {
                logger.error("Failed to start plugin ingress socket: \(error)")
            }

            // OTEL telemetry receiver (issue #597): a loopback OTLP/JSON listener
            // that augments the hook channel with per-session token/cost/latency,
            // commit/PR milestones, and permission-mode changes. Failure to bind
            // (e.g. the port is taken) is non-fatal — the hook channel is
            // unaffected and the meter simply stays empty.
            await setupOTLPReceiver()

            // E2E project-list determinism (spec §17.3). The per-agent in-memory
            // scanners that used to seed a fixed project set were deleted in the
            // plugin-system flip; restore the same deterministic set via the
            // plugin path by pushing it through the host's setProjects sink so
            // project-list / project-search scenarios stay stable. Gated to
            // DEBUG + `--e2e-test --e2e-seed-projects`; never affects real runs.
            #if DEBUG
                if
                    CommandLine.arguments.contains("--e2e-test"),
                    CommandLine.arguments.contains("--e2e-seed-projects") {
                    seedE2EDeterministicProjects()
                }
            #endif
        }

        #if DEBUG
            /// Seed the fixed E2E project set through the plugin path, tagged by
            /// pluginID exactly as the live scanners would (one Codex-tagged
            /// project sorting first + twelve Claude projects). Sorting is by
            /// name (all `lastUsed == nil`), matching the scenarios' expectations.
            /// The Codex project name avoids the substring "Codex" so the picker's
            /// "Codex" badge assertion can't match the project name itself.
            private func seedE2EDeterministicProjects() {
                let claudeNames = [
                    "AlphaProject", "BetaProject", "GammaService", "DeltaApp",
                    "EpsilonHub", "IotaWeb", "KappaCli", "MuShell",
                    "NuRunner", "SigmaLib", "TauNode", "ZetaCore",
                ]
                let claudeProjects = claudeNames.map { name in
                    AgentProject(name: name, path: "/Users/test/\(name)", pluginID: "claude-code")
                }
                pluginProjects["claude-code"] = claudeProjects
                pluginProjects["codex"] = [
                    AgentProject(
                        name: "AaaOpenAIApp",
                        path: "/Users/test/AaaOpenAIApp",
                        pluginID: "codex"
                    ),
                ]
                e2eSeededProjects = true
            }
        #endif

        /// Builds the `LivePluginHost` for `id`, retaining its log sink so the
        /// host's `log()` calls keep landing in the right file. Shared by initial
        /// startup and the CLI `plugin enable` re-enable path.
        private func makePluginHost(
            id: String,
            dispatcher: PluginEventDispatcher,
            paths: GallagerPaths
        ) -> LivePluginHost {
            let logSink = PluginLogSink(logFileURL: paths.pluginLogPath(id))
            pluginLogSinks[id] = logSink
            return LivePluginHost(
                pluginID: id,
                dispatcher: dispatcher,
                logSink: logSink,
                onSetProjects: { [weak self] pluginID, projects in
                    await self?.handlePluginSetProjects(pluginID: pluginID, projects: projects)
                },
                onSendText: { [weak self] _, sessionID, text in
                    await self?.handlePluginSendText(sessionID: sessionID, text: text)
                },
                onSendKeys: { [weak self] _, sessionID, keys in
                    await self?.handlePluginSendKeys(sessionID: sessionID, keys: keys)
                },
                onAgentPanes: { [weak self] pluginID in
                    await self?.handlePluginAgentPanes(pluginID: pluginID) ?? []
                }
            )
        }

        /// Backs `PluginHost.agentPanes()` — the tmux panes currently running
        /// `pluginID`'s agent process (manifest `process_names`). A core uses this
        /// to detect its agent exiting a pane without a lifecycle hook (Codex has
        /// no `SessionEnd`). Reuses the same detection the SessionEnd kill-poll
        /// trusts, scoped to the calling plugin so it stays agent-blind.
        private func handlePluginAgentPanes(pluginID: String) async -> [String] {
            guard let names = pluginRegistry?.processNamesByPlugin[pluginID] else { return [] }
            let detected = await tmuxService.detectAgentPanes(processNamesByPlugin: [pluginID: names])
            return Array(detected.keys)
        }

        /// Builds the `PluginEnv` for `id`. `pluginRoot` is the bundled
        /// `plugins/<id>` directory; falls back to the state dir when a plugin
        /// (e.g. echo) ships no manifest so `enable` can still construct the core
        /// via the factory table.
        private func makePluginEnv(
            id: String,
            registry: PluginRegistry,
            paths: GallagerPaths
        ) -> PluginEnv {
            let pluginRoot = registry.pluginRoot(id) ?? paths.pluginStateDir(id)
            let settingsData = (try? Data(contentsOf: paths.pluginSettingsPath(id))) ?? Data()
            // Bundled marketplace dirs live in the app's main bundle Resources:
            //   plugin/       → Claude marketplace
            //   plugin/codex/ → Codex marketplace
            let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
            let marketplaceSource: URL = switch id {
            case "codex": resources.appendingPathComponent("plugin/codex")
            default: resources.appendingPathComponent("plugin")
            }
            return PluginEnv(
                pluginRoot: pluginRoot,
                stateDir: paths.pluginStateDir(id),
                appVersion: VersionCompatibility.currentAppVersion,
                settings: settingsData,
                marketplaceSource: marketplaceSource
            )
        }

        // MARK: - Plugin runtime CLI support (spec §14)

        /// Enable a plugin by id (CLI `plugin enable`). Constructs + initializes
        /// the core via the registry, building a fresh host/env. Returns `nil`
        /// when `id` isn't a registered plugin; otherwise the resulting enabled
        /// state. Idempotent: a no-op when already enabled.
        func enablePluginViaCLI(_ id: String) async -> Bool? {
            guard
                let registry = pluginRegistry,
                let dispatcher = pluginDispatcher,
                let paths = gallagerPaths
            else {
                return nil
            }
            guard registry.isRegistered(id) else { return nil }
            paths.ensurePluginStateDir(id)
            let host = makePluginHost(id: id, dispatcher: dispatcher, paths: paths)
            let env = makePluginEnv(id: id, registry: registry, paths: paths)
            await registry.enable(id, host: host, env: env)
            // The enabled-plugin set changed; re-push the complete presentation
            // set to all connected viewers (spec §7.2/§7.3).
            await connectedViewerManager?.pushPluginPresentationsToAll(registry.presentations())
            return registry.isEnabled(id)
        }

        /// Disable a plugin by id (CLI `plugin disable`). `shutdown()`s the core
        /// and leaves files in place. Returns `nil` for an unregistered id;
        /// otherwise the resulting enabled state (always `false`).
        func disablePluginViaCLI(_ id: String) async -> Bool? {
            guard let registry = pluginRegistry else { return nil }
            guard registry.isRegistered(id) else { return nil }
            await registry.disable(id)
            // Drop the disabled plugin's last-pushed projects so they stop
            // surfacing in the iOS sidebar / New Session picker (`mergedPluginProjects`
            // flattens every entry, with no active-plugin check).
            pluginProjects.removeValue(forKey: id)
            // The enabled-plugin set changed; re-push the complete presentation
            // set to all connected viewers (spec §7.2/§7.3), then push session
            // state so viewers see the now-removed projects immediately.
            await connectedViewerManager?.pushPluginPresentationsToAll(registry.presentations())
            await connectedViewerManager?.pushSessionStateToAll()
            return registry.isEnabled(id)
        }

        /// Build the `plugin.info` envelope for `id` (CLI `plugin info`). Returns
        /// `nil` for an unregistered id.
        func pluginInfoViaCLI(_ id: String) async -> [String: JSONValue]? {
            guard let registry = pluginRegistry, registry.isRegistered(id) else { return nil }
            let manifest = registry.manifest(id)
            let logPath = gallagerPaths?.pluginLogPath(id).path ?? ""
            let stateBytes = gallagerPaths.map { Self.directorySize($0.pluginStateDir(id)) } ?? 0

            var result: [String: JSONValue] = [
                "id": .string(id),
                "version": .string(manifest?.version ?? ""),
                "enabled": .bool(registry.isEnabled(id)),
                "failedInit": registry.failedInitError(id).map { .string($0) } ?? .null,
                "source": .string("bundled"),
                "logPath": .string(logPath),
                "stateDirBytes": .int(stateBytes),
            ]
            if let manifest {
                result["manifest"] = Self.manifestJSON(manifest)
            }
            return result
        }

        /// Build the `plugin.logs` envelope for `id` (CLI `plugin logs`). Returns
        /// the last `lines` lines of the plugin's log file (all lines when
        /// `lines` is `nil`), or `nil` for an unregistered id. A missing log file
        /// yields an empty `lines` array (not an error) — the plugin simply
        /// hasn't logged yet.
        func pluginLogsViaCLI(_ id: String, lines: Int?) async -> [String: JSONValue]? {
            guard let registry = pluginRegistry, registry.isRegistered(id) else { return nil }
            guard let paths = gallagerPaths else {
                return ["logPath": .string(""), "lines": .array([])]
            }
            let logURL = paths.pluginLogPath(id)
            let allLines: [String]
            if let content = try? String(contentsOf: logURL, encoding: .utf8) {
                // Drop a single trailing empty element from the final newline so a
                // 3-line file reports 3 lines, not 4.
                var split = content.components(separatedBy: "\n")
                if split.last == "" { split.removeLast() }
                allLines = split
            } else {
                allLines = []
            }
            let tail: [String]
            if let lines, lines >= 0, lines < allLines.count {
                tail = Array(allLines.suffix(lines))
            } else {
                tail = allLines
            }
            return [
                "logPath": .string(logURL.path),
                "lines": .array(tail.map { .string($0) }),
            ]
        }

        /// Dispatch a direct core-method `call` (CLI `plugin call`). `enable` and
        /// `disable` are handled here (they need the app-built host/env); all
        /// other methods route into the active core via the registry.
        func pluginCallViaCLI(
            _ id: String,
            method: String,
            json _: String?,
            configRoot: String? = nil
        ) async -> LiveAPIRequestRouter.PluginCallResult {
            guard let registry = pluginRegistry, registry.isRegistered(id) else {
                return .unknownPlugin
            }
            switch method {
            case "enable":
                let enabled = await enablePluginViaCLI(id) ?? false
                return .ok(result: enabled ? "enabled" : "failed-init")
            case "disable":
                _ = await disablePluginViaCLI(id)
                return .ok(result: "disabled")
            default:
                switch await registry.callCore(id, method: method, configRoot: configRoot) {
                case let .ok(result): return .ok(result: result)
                case .notEnabled: return .notEnabled
                case let .unknownMethod(name): return .unknownMethod(name)
                case let .failed(message): return .failed(message)
                }
            }
        }

        /// Recursively sum the byte sizes of regular files under `url`.
        /// Best-effort and trap-free; an unreadable tree reports `0`.
        private static func directorySize(_ url: URL) -> Int {
            let fm = FileManager.default
            guard
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
                )
            else {
                return 0
            }
            var total = 0
            for case let fileURL as URL in enumerator {
                guard
                    let values = try? fileURL.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    ),
                    values.isRegularFile == true,
                    let size = values.fileSize
                else {
                    continue
                }
                total += size
            }
            return total
        }

        /// Encode a `PluginManifest` into a JSONValue tree for the `plugin.info`
        /// response (snake_case keys matching the on-disk manifest schema §10).
        private static func manifestJSON(_ manifest: PluginManifest) -> JSONValue {
            var ui: [String: JSONValue] = ["color": .string(manifest.color)]
            if let icon = manifest.ui.icon {
                ui["icon"] = .string(icon)
            }
            return .object([
                "schema_version": .int(manifest.schemaVersion),
                "id": .string(manifest.id),
                "display_name": .string(manifest.displayName),
                "short_name": .string(manifest.shortName),
                "version": .string(manifest.version),
                "process_names": .array(manifest.processNames.map { .string($0) }),
                "runtime": .string(manifest.runtime.rawValue),
                "ui": .object(ui),
            ])
        }

        /// Parses the optional `--gallager-state-root <path>` launch argument
        /// (E2E state isolation). Returns the override URL, or `nil` for the
        /// default `~/.gallager` layout.
        private static func parseGallagerStateRoot() -> URL? {
            let args = CommandLine.arguments
            guard
                let flagIndex = args.firstIndex(of: "--gallager-state-root"),
                flagIndex + 1 < args.count
            else {
                return nil
            }
            let path = args[flagIndex + 1]
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        // MARK: - Agents settings tab support

        /// One row of the segmented agent picker. `Identifiable` so the settings
        /// tab can drive it directly through `ForEach` (P2-T5).
        public struct AgentPluginEntry: Identifiable, Sendable, Equatable {
            public let id: String
            public let name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        // The id of the test-only `echo` reference plugin. `EchoPluginCore` lives
        // behind `#if DEBUG`, so its id is mirrored as a literal for Release where
        // echo is never registered anyway (the filter is then a harmless no-op).
        #if DEBUG
            private static let echoPluginID = EchoPluginCore.pluginID
        #else
            private static let echoPluginID = "echo"
        #endif

        /// Display rows for the segmented agent picker, sorted by id. Excludes
        /// `echo`, the test-only reference plugin (DEBUG/E2E builds only).
        public func agentPluginList() -> [AgentPluginEntry] {
            guard let registry = pluginRegistry else { return [] }
            return registry.registeredIDs
                .filter { $0 != Self.echoPluginID }
                .map { AgentPluginEntry(id: $0, name: registry.manifest($0)?.displayName ?? $0) }
        }

        /// Raw settings.json bytes for a plugin (empty Data if none yet).
        public func pluginSettingsData(id: String) -> Data {
            guard let paths = gallagerPaths else { return Data() }
            return (try? Data(contentsOf: paths.pluginSettingsPath(id))) ?? Data()
        }

        /// Persist a plugin's settings.json and, only on a successful write, push
        /// the new settings live to the enabled core (if any). Returns `nil` on
        /// success or an error string on failure — surfacing a failed write so the
        /// live core never diverges from disk (which would silently revert on the
        /// next launch).
        @discardableResult
        public func setPluginSettings(id: String, _ data: Data) async -> String? {
            guard let paths = gallagerPaths else { return "Plugin state not initialised" }
            let url = paths.pluginSettingsPath(id)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                return String(describing: error)
            }
            // SettingsResult.error surfacing is deferred to the settings UI (P2-T5).
            _ = await pluginRegistry?.core(id)?.applySettings(data)
            return nil
        }

        /// Deterministic install-status overrides for `--e2e-test`, keyed by
        /// `"<id>|<configRoot>"`. Keeps the Agents tab side-effect-free and stable
        /// in e2e (no real `claude`/`codex plugin` shell-out against the tester's
        /// own config). Empty / unused in production.
        private var e2eInstallStatus: [String: PluginInstallStatus] = [:]
        private let isE2ETest = CommandLine.arguments.contains("--e2e-test")

        private func e2eInstallKey(_ id: String, _ configRoot: String?) -> String {
            "\(id)|\(configRoot ?? "")"
        }

        /// Ensure a plugin's core is enabled, then query its install status for
        /// the given config root (nil = default location).
        public func pluginInstallStatus(id: String, configRoot: String?) async -> PluginInstallStatus {
            if isE2ETest { return e2eInstallStatus[e2eInstallKey(id, configRoot)] ?? .notInstalled }
            guard let core = await enabledCore(id) else { return .agentUnavailable }
            return await core.installStatus(configRoot: configRoot)
        }

        /// Install a plugin for a config root via the enabled core.
        /// Returns `nil` on success, or an error string on failure.
        public func installPlugin(id: String, configRoot: String?) async -> String? {
            if isE2ETest {
                e2eInstallStatus[e2eInstallKey(id, configRoot)] = .installed(version: "e2e")
                return nil
            }
            guard let core = await enabledCore(id) else { return "Plugin not available" }
            do {
                _ = try await core.install(configRoot: configRoot)
                return nil
            } catch {
                return String(describing: error)
            }
        }

        /// Uninstall a plugin for a config root via the enabled core.
        /// Returns `nil` on success, or an error string on failure.
        public func uninstallPlugin(id: String, configRoot: String?) async -> String? {
            if isE2ETest {
                e2eInstallStatus[e2eInstallKey(id, configRoot)] = .notInstalled
                return nil
            }
            guard let core = await enabledCore(id) else { return "Plugin not available" }
            do {
                try await core.uninstall(configRoot: configRoot)
                return nil
            } catch {
                return String(describing: error)
            }
        }

        /// Returns the already-enabled core for `id`, enabling it on demand when
        /// it isn't active yet (plugins are normally enabled at startup; this is
        /// defensive for the rare case where startup enable failed). Enabling via
        /// `enablePluginViaCLI` also re-pushes the plugin presentation set to all
        /// connected viewers as a side effect of the enabled-set change.
        private func enabledCore(_ id: String) async -> (any PluginCore)? {
            guard let registry = pluginRegistry else { return nil }
            if let core = registry.core(id) { return core }
            _ = await enablePluginViaCLI(id)
            return registry.core(id)
        }

        // MARK: - Plugin Runtime Local Sinks

        /// StateSink → reflect the plugin's `AgentState` onto the pane's session
        /// (the sole state driver), then forward a high-frequency
        /// `agent_session_status` push to iOS and refresh the full session state.
        /// The open response form rides `state`, so it travels in both pushes
        /// without a separate transport.
        private func handlePluginState(
            pluginID: String,
            sessionID: String,
            state: AgentState,
            tmuxPane: String?,
            projectPath: String?,
            permissionMode: String?
        ) async {
            windowManager.applyState(
                pluginID: pluginID,
                sessionID: sessionID,
                state: state,
                tmuxPane: tmuxPane,
                projectPath: projectPath,
                permissionMode: permissionMode
            )
            // Issue #598: when the agent finishes a turn, snapshot a recap card
            // from the accumulated telemetry. Only when there's real telemetry to
            // show; `applyState` already cleared any prior recap if a new turn
            // started instead.
            if
                let paneId = tmuxPane, !paneId.isEmpty,
                case let .doneWorking(summary) = state,
                let telemetry = windowManager.paneStates[paneId]?.telemetry,
                telemetry.tokensUsed > 0 {
                let recap = SessionRecap(
                    telemetry: telemetry,
                    projectName: windowManager.paneStates[paneId]?.agentSession?.displayName,
                    summary: summary,
                    isFinal: false
                )
                windowManager.applyRecap(recap, forPane: paneId)
            }
            updateSleepPrevention()

            // High-frequency per-session update to iOS (spec §7.2). Keyed by the
            // pane, matching how the session is keyed locally.
            if let paneId = tmuxPane, !paneId.isEmpty {
                await connectedViewerManager?.sendAgentSessionStatusToAll(
                    sessionId: paneId,
                    pluginId: pluginID,
                    state: state
                )
            }
            await connectedViewerManager?.pushSessionStateToAll()
            // The two pushes above only reach *connected* viewers over the live
            // WebSocket. When this state change CLEARS attention (the agent
            // resumed on its own, or the user answered in the Mac terminal while
            // the app was backgrounded), a disconnected phone gets nothing — so
            // its app-icon badge would stay stuck at the old count. Send the
            // lowered badge over the silent-push path so APNs carries it down.
            await broadcastBadgeDecreaseIfNeeded()
        }

        /// Pushes the host's pending-attention count to viewers as a silent
        /// badge update *only when it has dropped* (see
        /// `MirrorWindowManager.pendingCountDecrease`). Needs-attention increases
        /// ride their own notification's alert push; a clear has no notification,
        /// so this is the only signal that brings the iOS badge back down.
        func broadcastBadgeDecreaseIfNeeded() async {
            guard let badge = windowManager.pendingCountDecrease() else { return }
            await connectedViewerManager?.broadcastBadgeUpdate(badge: badge)
        }

        /// NotificationSink → show a Mac desktop notification using the
        /// core-baked title/body, and forward it to paired iOS viewers via the
        /// encrypted-push path (falls back to APNs when a viewer is offline).
        private func handlePluginNotification(_ notification: NotificationSpec, paneId: String?) async {
            let macNotification = TerminalStreamMessage.TerminalNotification(
                title: notification.title,
                body: notification.body
            )
            // Stamp the real pane id so tapping the banner navigates to the
            // originating session; fall back to "system" only when the event
            // carries no pane (e.g. a gallager-cli notify with no target).
            terminalNotificationService.showNotification(paneId ?? "system", macNotification)
            await connectedViewerManager?.sendCustomPushNotificationToAll(
                title: notification.title,
                body: notification.body,
                paneId: paneId
            )
        }

        // MARK: - OTEL Telemetry (issue #597)

        /// Builds the Mac-local OTLP receiver and starts it, wiring its three
        /// content-free signals into the app: telemetry → stamp the joined pane,
        /// milestones → one-shot notifications, mode changes → stamp the pane.
        private func setupOTLPReceiver() async {
            // Durable cross-session usage store (issue #598). Lives in the gallager
            // state tree so it shares the E2E redirect and survives restarts.
            let stateRoot = (gallagerPaths ?? GallagerPaths()).stateRoot
            let store = UsageAggregationStore(
                fileURL: stateRoot.appendingPathComponent("usage-aggregates.json")
            )
            usageStore = store
            usageOverview = await currentUsageOverview()

            let receiver = OTLPReceiver(
                port: OTLPReceiver.resolvedPort,
                onTelemetry: { [weak self] sessionID, telemetry in
                    await self?.handleTelemetry(sessionID: sessionID, telemetry: telemetry)
                },
                onMilestone: { [weak self] milestone in
                    await self?.handleTelemetryMilestone(milestone)
                },
                onModeChange: { [weak self] change in
                    await self?.handleTelemetryModeChange(change)
                }
            )
            otlpReceiver = receiver
            do {
                try await receiver.start()
            } catch {
                logger.error("Failed to start OTLP telemetry receiver: \(error)")
            }
        }

        /// Stamps accumulated telemetry onto the joined pane (the host sidebar
        /// updates synchronously), then throttles the cross-device push to at
        /// most once per second.
        private func handleTelemetry(sessionID: String, telemetry: SessionTelemetry) async {
            guard windowManager.applyTelemetry(telemetry, forClaudeSessionID: sessionID) != nil else {
                return // no pane bound to this session id yet
            }
            // Fold this snapshot into the durable per-project/day store (issue
            // #598) and refresh the host's own overview surfaces. Keyed by the
            // pane's detected project; skipped when none is known (can't attribute).
            if let usageStore, let projectPath = windowManager.detectedProjectPath(forClaudeSessionID: sessionID) {
                await usageStore.record(
                    projectPath: projectPath,
                    sessionID: sessionID,
                    telemetry: telemetry,
                    date: Date()
                )
                usageOverview = await currentUsageOverview()
            }
            guard let connectionManager = connectedViewerManager else { return }
            // Trailing throttle, not a debounce: if a push is already scheduled
            // this window, fold into it (it reads the latest pane state when it
            // fires). A debounce would cancel-and-reschedule on every event and
            // starve viewers during a sustained burst; this guarantees a flush
            // every ~1s while telemetry keeps arriving.
            guard pendingTelemetryPush == nil else { return }
            pendingTelemetryPush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.pendingTelemetryPush = nil
                await connectionManager.pushSessionStateToAll()
            }
        }

        /// Turns a commit / PR milestone into exactly one notification per export
        /// tick, routed to the originating pane. Skipped when no pane is bound
        /// (the milestone can't be attributed to a visible session).
        private func handleTelemetryMilestone(_ milestone: TelemetryMilestone) async {
            guard let paneId = windowManager.paneId(forClaudeSessionID: milestone.sessionID) else { return }
            let project = windowManager.projectName(forClaudeSessionID: milestone.sessionID) ?? "your project"
            let spec = Self.milestoneNotification(milestone, project: project)
            await handlePluginNotification(spec, paneId: paneId)
        }

        /// Formats a milestone notification. The body adapts when more than one
        /// occurred within a single export window.
        private static func milestoneNotification(
            _ milestone: TelemetryMilestone,
            project: String
        ) -> NotificationSpec {
            switch milestone.kind {
            case .commit:
                let title = "Committed"
                let body = milestone.count > 1
                    ? "Claude made \(milestone.count) commits in \(project)"
                    : "Claude committed in \(project)"
                return NotificationSpec(title: title, body: body)
            case .pullRequest:
                let title = "Pull Request"
                let body = milestone.count > 1
                    ? "Claude opened \(milestone.count) pull requests in \(project)"
                    : "Claude opened a pull request in \(project)"
                return NotificationSpec(title: title, body: body)
            }
        }

        /// Formats the one-shot end-of-session recap notification (issue #598).
        /// The body reuses the shared recap formatter so the push reads identically
        /// to the recap card.
        private static func recapNotification(_ recap: SessionRecap) -> NotificationSpec {
            let title = recap.projectName.map { "Done — \($0)" } ?? "Session complete"
            return NotificationSpec(title: title, body: recapDetailLine(recap))
        }

        /// The current durable usage rollup, or `nil` when nothing has accrued yet
        /// (so a host with no usage doesn't push an empty overview or render an
        /// empty header). Recomputed from the store on demand.
        private func currentUsageOverview() async -> UsageOverview? {
            guard let usageStore else { return nil }
            let overview = await usageStore.overview(asOf: Date())
            return overview.isEmpty ? nil : overview
        }

        /// On session end (issue #598): fold the pane's final telemetry into the
        /// durable usage store, push a one-shot end-of-session recap, then evict the
        /// session's live state from both the store baselines and the OTLP receiver
        /// (#597). Reads the pane state before `endAgentSession` clears it. No-op
        /// when the pane never carried a Claude session id.
        private func finalizeEndedSession(paneId: String) async {
            guard let claudeSessionID = windowManager.paneStates[paneId]?.claudeSessionID else { return }
            let pane = windowManager.paneStates[paneId]
            if let telemetry = pane?.telemetry {
                if
                    let usageStore,
                    let projectPath = pane?.agentSession?.detectedProjectPath,
                    !projectPath.isEmpty {
                    await usageStore.record(
                        projectPath: projectPath,
                        sessionID: claudeSessionID,
                        telemetry: telemetry,
                        date: Date()
                    )
                    await usageStore.evictSession(claudeSessionID)
                    usageOverview = await currentUsageOverview()
                }
                if telemetry.tokensUsed > 0 {
                    var summary: String?
                    if case let .doneWorking(lastMessage) = pane?.agentSession?.state {
                        summary = lastMessage
                    }
                    let recap = SessionRecap(
                        telemetry: telemetry,
                        projectName: pane?.agentSession?.displayName,
                        summary: summary,
                        isFinal: true
                    )
                    await handlePluginNotification(Self.recapNotification(recap), paneId: paneId)
                }
            }
            await otlpReceiver?.evictSession(claudeSessionID)
        }

        /// Records a permission-mode change on the joined pane and pushes it (mode
        /// flips are rare, so this isn't throttled).
        private func handleTelemetryModeChange(_ change: TelemetryModeChange) async {
            let stamped = windowManager.applyPermissionMode(
                change.toMode,
                trigger: change.trigger,
                forClaudeSessionID: change.sessionID
            )
            guard stamped != nil else { return }
            await connectedViewerManager?.pushSessionStateToAll()
        }

        /// AppActionSink → drive the matching agent-blind Mac feature (spec §6).
        private func handlePluginAppAction(_ action: AppAction) async {
            switch action {
            case let .openFileSuggestion(sessionID, path, displayName, isPlan, projectDir):
                // `sessionID` is the plugin's opaque session id; resolve it to a
                // tmux session name when it names a known pane, otherwise use it
                // verbatim (the markdown store keys purely by name).
                let sessionName = resolveSessionName(forPaneId: sessionID) ?? sessionID
                // Root the opened file tab at the project dir when the core knew
                // it (so the tree / relative-path header use the project root);
                // otherwise fall back to the file's immediate parent.
                let directoryPath = projectDir ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
                markdownOpenSuggestionStore.suggest(MarkdownOpenSuggestion(
                    filePath: path,
                    directoryPath: directoryPath,
                    sessionName: sessionName,
                    isPlan: isPlan
                ))
                _ = displayName // label is derived from the path in the UI

            case let .dismissFileSuggestions(sessionID):
                // Mirrors the legacy `userPromptSubmit` path: start the 30s
                // auto-dismiss timer rather than clearing immediately, so the
                // suggestion lingers briefly after the user sends a new prompt.
                let sessionName = resolveSessionName(forPaneId: sessionID) ?? sessionID
                markdownOpenSuggestionStore.userSubmittedPrompt(sessionName: sessionName)

            case let .sessionEnded(sessionID, closePaneEligible):
                // `sessionID` carries the pane id in the plugin path. A session end
                // (any reason) resets the pane's session-scoped Mac state so a fresh
                // session doesn't inherit it.
                var sessionStateChanged = false
                // Yolo is per-pane app state the core never sees — clear it here.
                // Context compaction sends no SessionEnd, so yolo correctly survives
                // a compaction restart (issue #193).
                if windowManager.isYoloModeEnabled(for: sessionID) {
                    windowManager.setYoloMode(enabled: false, for: sessionID)
                    sessionStateChanged = true
                }
                // Snapshot the final recap and fold the session's last telemetry
                // into the durable store (issue #598), then evict its live state
                // from the store and the OTLP receiver (issue #597) — all before
                // `endAgentSession` clears the pane's join key and telemetry.
                await finalizeEndedSession(paneId: sessionID)
                // Remove the agent session so the pane reverts from the idle moon
                // glyph to a plain terminal (the legacy `claudeSession = nil` on
                // SessionEnd). The status path set working=false earlier in this
                // same envelope; dispatch fans status out before app actions, so
                // this clear is the last write and wins. Process detection re-adds
                // sessions only at startup, so it won't resurrect this one.
                if windowManager.endAgentSession(forPane: sessionID) {
                    sessionStateChanged = true
                }
                if sessionStateChanged {
                    await connectedViewerManager?.pushSessionStateToAll()
                }
                // A session that was needing attention when it ended lowers the
                // pending count without any notification — clear the iOS badge.
                await broadcastBadgeDecreaseIfNeeded()
                // Close the pane when the core signals eligibility (the core folds
                // in both the clean-exit check and the per-agent pref).
                guard closePaneEligible else { return }
                // The SessionEnd hook fires while the agent is still mid-exit, so
                // killing the pane now would truncate its final output. Mirror the
                // legacy `closePaneWhenClaudeExits`: poll until the agent process
                // has left the pane (up to 30s), then a 1s grace, before killing.
                // Detached so the sink returns immediately.
                let processNames = pluginRegistry?.processNamesByPlugin ?? [:]
                Task { [tmuxService] in
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .seconds(1))
                        let panes = await tmuxService.detectAgentPanes(processNamesByPlugin: processNames)
                        if panes[sessionID] == nil {
                            try? await Task.sleep(for: .seconds(1))
                            try? await tmuxService.killPane(sessionID)
                            return
                        }
                    }
                }
            }
        }

        // MARK: - Plugin Runtime Host Send Sinks

        /// Resolve a plugin `sessionID` to a tmux pane target. The plugin path
        /// carries the pane id as the session id; if it doesn't name a tracked
        /// pane we still pass it through so a freshly-created pane works.
        private func resolvePluginPaneTarget(_ sessionID: String) -> String {
            if windowManager.paneStates[sessionID] != nil { return sessionID }
            if let pane = tmuxService.panes.first(where: { $0.paneId == sessionID }) {
                return pane.paneId
            }
            return sessionID
        }

        /// SendTextSink → write verbatim text to the pane backing the session.
        private func handlePluginSendText(sessionID: String, text: String) async {
            guard !text.isEmpty else { return }
            let target = resolvePluginPaneTarget(sessionID)
            do {
                try await tmuxService.sendKeys(target, keys: text, literal: true)
            } catch {
                logger.warning("Plugin sendText failed for \(target): \(error)")
            }
        }

        /// SendKeysSink → send a key sequence to the pane backing the session.
        /// Reuses the shared `TmuxKey` vocabulary (`PluginTmuxKey` is its alias)
        /// and the batching `send-keys` path (`TmuxService.sendKeystrokes`).
        private func handlePluginSendKeys(sessionID: String, keys: [PluginTmuxKey]) async {
            guard !keys.isEmpty else { return }
            let target = resolvePluginPaneTarget(sessionID)
            do {
                try await tmuxService.sendKeystrokes(target, keys: keys)
            } catch {
                logger.warning("Plugin sendKeys failed for \(target): \(error)")
            }
        }

        /// SetProjectsSink → store the plugin's project list and push the merged
        /// set to viewers via the existing `SessionStateMessage.agentProjects`
        /// payload (spec §7.2).
        private func handlePluginSetProjects(pluginID: String, projects: [AgentProject]) async {
            #if DEBUG
                // E2E: once a deterministic project set is seeded, it is authoritative —
                // ignore the cores' real `~/.claude.json` / `~/.codex` scans so the
                // project-list / sidebar / new-session screenshots stay stable.
                guard !e2eSeededProjects else { return }
            #endif
            pluginProjects[pluginID] = projects
            await connectedViewerManager?.pushSessionStateToAll()
        }

        /// The merged per-plugin project list for the iOS session-state push.
        /// Read by `ConnectedViewerManager` when building `SessionStateMessage`.
        public func currentAgentProjects() -> [AgentProject] {
            mergedPluginProjects()
        }

        /// Resolve the auto-launch command for a project from its owning plugin
        /// core (`commandForLaunch`, gated on the plugin's auto-run setting),
        /// flattened to the shell command line + extra env strings the local
        /// "create from project" flow needs. `runCommand == nil` means launch a
        /// bare shell. Returned as primitives so `MainView` needn't import the
        /// plugin protocol's `LaunchCommand` type.
        public func resolveLaunch(
            forPluginID pluginID: String,
            projectPath: String
        ) async -> (runCommand: String?, extraEnvironment: [String]) {
            guard let launch = await pluginRegistry?.core(pluginID)?.commandForLaunch(projectPath: projectPath) else {
                return (nil, [])
            }
            let runCommand = launch.args.isEmpty
                ? launch.command
                : ([launch.command] + launch.args).joined(separator: " ")
            let env = launch.env.map { "\($0.key)=\($0.value)" }
            return (runCommand, env)
        }

        // MARK: - Private Setup Methods

        /// Error type for API request handling.
        enum APIError: Error, LocalizedError {
            case notFound(String)
            case invalidParams(String)
            var errorDescription: String? {
                switch self {
                case let .notFound(msg),
                     let .invalidParams(msg): msg
                }
            }
        }

        /// Resolves the session a `set_title` / `set_color` request should
        /// target. Window/pane targeting is intentionally unsupported — the
        /// CLI flags only expose `--session`, and `paneId` (when present) is
        /// just used to look up the calling pane's session.
        fileprivate static func resolveSessionTarget(
            sessionId: String?,
            paneId: String?,
            tmux: TmuxService,
            method: String
        ) async throws -> String {
            if let sessionId {
                guard await tmux.sessionExists(named: sessionId) else {
                    throw APIError.notFound("Session not found: \(sessionId)")
                }
                return sessionId
            }
            let panes = await tmux.refreshPanes()
            if
                let paneId,
                let pane = panes.first(where: { $0.paneId == paneId }) {
                return pane.sessionName
            }
            let attached = await MainActor.run { tmux.attachedSessionNames }
            if
                let activeSession = panes.first(where: {
                    attached.contains($0.sessionName)
                })?.sessionName {
                return activeSession
            }
            throw APIError.notFound("No resolvable session target for \(method)")
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
                onSessionSelect: { [tmux, weak self] sessionId in
                    // Point tmux's current window at the session. This also
                    // validates the id — a bad session throws and surfaces as a
                    // CLI error. `=` forces exact session-name matching;
                    // without it tmux prefix-matches, so a nonexistent
                    // "foo" would silently resolve to a session named
                    // "foo-bar". Trailing `:` resolves to the session's
                    // current window; `:!` would fail with "can't find
                    // window: !" on sessions without prior window-switch
                    // history.
                    try await tmux.selectWindow("=\(sessionId):")
                    // Drive the app's sidebar/detail selection so the UI
                    // actually switches to the requested session. `select-window`
                    // alone only moves tmux's active window *within* a session;
                    // MainView's follow-active-window logic is scoped to the
                    // already-selected session and never crosses to a different
                    // one, so without this the app stays on the old session.
                    await self?.revealLocalSession(sessionId)
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
                onSessionSetTitle: { [tmux, winManager] title, sessionId, paneId in
                    // Always applies at session scope. `paneId` (typically
                    // forwarded from $TMUX_PANE) is used solely to look up the
                    // session that pane belongs to; the option is then written
                    // on that session.
                    let resolvedSession = try await Self.resolveSessionTarget(
                        sessionId: sessionId,
                        paneId: paneId,
                        tmux: tmux,
                        method: "session.set_title"
                    )
                    await MainActor.run {
                        winManager.setSessionDescription(title, for: resolvedSession)
                    }
                },
                onSessionSetColor: { [tmux, winManager] color, sessionId, paneId in
                    let resolvedSession = try await Self.resolveSessionTarget(
                        sessionId: sessionId,
                        paneId: paneId,
                        tmux: tmux,
                        method: "session.set_color"
                    )
                    await MainActor.run {
                        winManager.setSessionColor(color, for: resolvedSession)
                    }
                },
                onSessionSetEmoji: { [tmux, winManager] emoji, sessionId, paneId in
                    let resolvedSession = try await Self.resolveSessionTarget(
                        sessionId: sessionId,
                        paneId: paneId,
                        tmux: tmux,
                        method: "session.set_emoji"
                    )
                    await MainActor.run {
                        winManager.setSessionEmoji(emoji, for: resolvedSession)
                    }
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
                onWindowCreate: { [tmux] sessionId, path, paneId, name in
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
                onWindowSetName: { [tmux] windowId, name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw APIError.invalidParams("name cannot be empty")
                    }
                    try await tmux.renameWindow(target: windowId, name: trimmed)
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
                            let hasSession = winManager.paneStates[pane.paneId]?.agentSession != nil
                            return APIPaneInfo(
                                id: pane.paneId,
                                index: pane.paneIndex,
                                isActive: pane.isActive,
                                command: pane.command,
                                cwd: pane.currentPath,
                                width: pane.width,
                                height: pane.height,
                                windowId: pane.windowId,
                                hasAgentSession: hasSession
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
                    // `refreshPanes()` early-returns the stale cached list when a
                    // periodic refresh is already in flight, so the freshly-split
                    // pane can be missing on the first try (more likely on a slow
                    // machine). The pane definitely exists — `split-window` just
                    // returned its id — so retry the refresh until it shows up.
                    var newPane: PaneInfo?
                    for attempt in 0..<PaneSurfaceRetry.attempts {
                        let panes = await tmux.refreshPanes()
                        await MainActor.run { winManager.updatePaneStates(from: panes) }
                        if let found = panes.first(where: { $0.paneId == newPaneId }) {
                            newPane = found
                            break
                        }
                        if attempt < PaneSurfaceRetry.attempts - 1 {
                            try await Task.sleep(for: PaneSurfaceRetry.delay)
                        }
                    }
                    guard let newPane else {
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
                        hasAgentSession: false
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
                onPaneSetProgress: { [tmux, winManager, weak self] state, paneId in
                    // Resolve the target pane: use the explicit ID, otherwise
                    // fall back to the globally active pane. The CLI fills
                    // `pane_id` from `$TMUX_PANE` when no `--pane` flag is
                    // given, so most calls already arrive with an explicit ID.
                    let panes = await tmux.refreshPanes()
                    let target: String? = await MainActor.run {
                        if
                            let paneId,
                            panes.contains(where: { $0.paneId == paneId }) {
                            return paneId
                        }
                        return panes.first(where: { $0.isActive && $0.isWindowActive })?.paneId
                    }
                    guard let target else {
                        throw APIError.notFound("No matching pane found")
                    }
                    // `applyProgressUpdate` is the same path `OSC 9;4` updates
                    // travel through, so a CLI override and an OSC sequence
                    // both write to `PaneState.progress` and last-write-wins.
                    let resolved: TerminalProgressState = state ?? .removed
                    await MainActor.run {
                        // Reconcile pane state first so a freshly-created pane
                        // (not yet in `paneStates`) survives the early-exit
                        // guard inside `setPaneProgress`.
                        winManager.updatePaneStates(from: panes)
                        self?.applyProgressUpdate(paneId: target, state: resolved)
                    }
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
                onNotify: { [weak self, notificationService] title, body, paneId, push in
                    let notification = TerminalStreamMessage.TerminalNotification(
                        title: title,
                        body: body
                    )
                    let targetPane = paneId ?? "system"
                    notificationService.showNotification(targetPane, notification)

                    // Forward to paired iOS viewers when --push is requested.
                    // Reuses the encrypted-push path that hook events go through,
                    // so the notification falls back to APNs whenever the viewer
                    // isn't connected via WebSocket.
                    if push, let manager = await self?.connectedViewerManager {
                        await manager.sendCustomPushNotificationToAll(
                            title: title,
                            body: body,
                            paneId: paneId
                        )
                    }
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

                        let hasSession = winManager.paneStates[pane.paneId]?.agentSession != nil
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
                                hasAgentSession: hasSession
                            )
                        ).toJSONValue()
                    }
                },
                onProjectList: { [weak self] in
                    // Refresh then return the merged per-plugin project list (the
                    // cores own scanning now — spec §12).
                    let projects = await self?.scanProjects() ?? []
                    return projects.map { APIProjectInfo($0).toJSONValue() }
                },
                onProjectStart: { [tmux, weak self] path, args, pluginID in
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                        isDirectory.boolValue
                    else {
                        throw APIError.notFound("Path does not exist or is not a directory: \(path)")
                    }
                    // Resolve the launch command from the owning plugin core
                    // (`commandForLaunch`); fall back to the pluginID as the
                    // command when no core/launch command is available.
                    let launch = await self?.pluginRegistry?.core(pluginID)?.commandForLaunch(projectPath: url.path)
                    let commandPath = launch?.command ?? pluginID
                    let launchArgs = args.isEmpty ? (launch?.args ?? []) : args
                    let runCommand: String
                    if launchArgs.isEmpty {
                        runCommand = commandPath.posixSingleQuoted
                    } else {
                        let quoted = launchArgs.map(\.posixSingleQuoted).joined(separator: " ")
                        runCommand = "\(commandPath.posixSingleQuoted) \(quoted)"
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
                    [tmux, winManager, weak self] config, rebuild, detach, dryRun, lenient, requireCreate, configPath in
                    let parser = LayoutConfigParser(
                        lenient: lenient,
                        environment: ProcessInfo.processInfo.environment
                    )
                    let parsed = try parser.parse(config)
                    let driver = LayoutDriver(
                        tmuxAccessor: { tmux },
                        descriptionApplier: { description, sessionName in
                            await MainActor.run {
                                winManager.setSessionDescription(description, for: sessionName)
                            }
                        },
                        colorApplier: { color, sessionName in
                            await MainActor.run {
                                winManager.setSessionColor(color, for: sessionName)
                            }
                        },
                        progressApplier: { [weak self] progress, paneId in
                            // Reconcile pane state first so newly-created
                            // panes are tracked before `setPaneProgress` runs.
                            // `applyProgressUpdate` then drives the same
                            // MirrorWindowManager → viewer push the OSC 9;4
                            // reader uses, so initial-progress in YAML lands
                            // identically to a runtime CLI call.
                            let panes = await tmux.refreshPanes()
                            await MainActor.run {
                                winManager.updatePaneStates(from: panes)
                                self?.applyProgressUpdate(
                                    paneId: paneId,
                                    state: progress ?? .removed
                                )
                            }
                        }
                    )
                    let configDir = configPath.map { (URL(fileURLWithPath: $0).deletingLastPathComponent()).path }
                    // Read the command path straight from the claude-code plugin's
                    // settings.json (independent of auto-run) so the layout driver
                    // honors the user's configured `claude` command for `agent:` panes.
                    let claudeCommandPath = await ClaudeCodeSettings
                        .decode(from: self?.pluginSettingsData(id: "claude-code") ?? Data())
                        .commandPath
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
                },
                onPluginList: { [weak self] in
                    guard let registry = await self?.pluginRegistry else { return [] }
                    return await MainActor.run {
                        registry.listEntries().map { entry in
                            [
                                "id": .string(entry.id),
                                "version": .string(entry.version),
                                "enabled": .bool(entry.enabled),
                                "source": .string(entry.source),
                            ] as [String: JSONValue]
                        }
                    }
                },
                onPluginInfo: { [weak self] id in
                    await self?.pluginInfoViaCLI(id)
                },
                onPluginEnable: { [weak self] id in
                    guard let self else { return nil }
                    guard let enabled = await self.enablePluginViaCLI(id) else { return nil }
                    return ["id": .string(id), "enabled": .bool(enabled)]
                },
                onPluginDisable: { [weak self] id in
                    guard let self else { return nil }
                    guard let enabled = await self.disablePluginViaCLI(id) else { return nil }
                    return ["id": .string(id), "enabled": .bool(enabled)]
                },
                onPluginLogs: { [weak self] id, lines in
                    await self?.pluginLogsViaCLI(id, lines: lines)
                },
                onPluginCall: { [weak self] id, method, json, configRoot in
                    guard let self else { return .unknownPlugin }
                    return await self.pluginCallViaCLI(
                        id,
                        method: method,
                        json: json,
                        configRoot: configRoot
                    )
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

            // Outgoing pushes carry the host's current needs-attention count as
            // the iOS app icon badge. The same provider feeds silent badge
            // updates broadcast on markSessionHandled.
            connectionManager.pendingSessionCountProvider = { [windowManager] in
                windowManager.pendingSessionCount
            }

            // Plugin runtime ↔ iOS bridge (additive, in-process plugin path):
            // route an inbound plugin response submission to the owning core's
            // `deliverResponse`, and feed the enabled-plugin presentation set so
            // each viewer receives it on connect.
            connectionManager.onAgentResponseSubmission = { [weak self] submission in
                await self?.pluginRegistry?.core(submission.pluginId)?.deliverResponse(
                    sessionID: submission.sessionId,
                    requestID: submission.requestId,
                    submission.response
                )
            }
            connectionManager.presentationsProvider = { [weak self] in
                self?.pluginRegistry?.presentations() ?? []
            }

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

            // Wire OSC 9;4 progress updates to the sidebar progress bar.
            paneStreamManager.onProgress = { [weak self] paneId, state in
                self?.applyProgressUpdate(paneId: paneId, state: state)
            }

            // Start notification-only readers for all discovered panes
            let initialPanes = await tmuxService.refreshPanes()
            windowManager.updatePaneStates(from: initialPanes)
            await windowManager.refreshGitBranches()
            await paneStreamManager.startMonitoring(panes: initialPanes)
            paneStreamManager.startPeriodicPaneRefresh(tmuxService: tmuxService)

            // Detect coding-agent instances already running in tmux panes, using
            // each enabled plugin's manifest `process_names` (spec §6).
            let processNames = pluginRegistry?.processNamesByPlugin ?? [:]
            let agentPanes = await tmuxService.detectAgentPanes(processNamesByPlugin: processNames)
            if !agentPanes.isEmpty {
                windowManager.markDetectedAgentSessions(agentPanes)
                logger.info("Detected running agents in panes: \(agentPanes.keys.sorted())")
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
                    await paneStreaming.updateMonitoring(panes: panes)
                    self?.updateSleepPrevention()
                }
            }

            // Create command executor
            let executor = TmuxCommandExecutor(tmuxService: tmuxService)
            commandExecutor = executor

            // Set up command handler - called when any viewer sends a command
            let streamService = terminalStreamService
            let tmux = tmuxService
            let editorManager = editorSessionManager
            connectionManager.onCommand = { [weak self, executor, streamService, tmux, winManager, editorManager, weak connectionManager] command in
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
                    // Resolve the launch command from the owning plugin core when
                    // this is a "create from project" request (a working dir is
                    // supplied); `commandForLaunch` already gates on the plugin's
                    // auto-run setting and returns nil to launch a bare shell.
                    let launch: LaunchCommand?
                    let defaultCommand: String?
                    if spec.workingDirectory != nil {
                        launch = await self?.pluginRegistry?.core(spec.pluginID)?
                            .commandForLaunch(projectPath: spec.workingDirectory ?? "")
                        // The plugin's CLI binary name (manifest `process_names`),
                        // used to label the tab when auto-run is off and `launch`
                        // is nil — e.g. "claude" rather than the "claude-code" id.
                        defaultCommand = self?.pluginRegistry?.manifest(spec.pluginID)?.processNames.first
                    } else {
                        launch = nil
                        defaultCommand = nil
                    }
                    return await Self.handleCreateSession(
                        command: command,
                        spec: spec,
                        launch: launch,
                        defaultCommand: defaultCommand,
                        tmuxService: tmux
                    )
                }

                // Handle yolo mode toggle
                if case let .setYoloMode(spec) = command.command {
                    winManager.setYoloMode(enabled: spec.enabled, for: command.paneId)
                    // #315: enabling yolo immediately approves a permission form that
                    // was already open (it arrived before yolo was on). The pending
                    // approval is read from the session's `state` — an
                    // `awaitingPermission` that's auto-approvable. Deliver the
                    // approval to the owning core and move the session to `.working`,
                    // which retracts the form (a non-awaiting state IS the retract).
                    if
                        spec.enabled,
                        let session = winManager.paneStates[command.paneId]?.agentSession,
                        case let .awaitingPermission(permission, requestID) = session.state,
                        permission.isAutoApprovable {
                        await self?.pluginRegistry?.core(session.pluginID)?.deliverResponse(
                            sessionID: command.paneId,
                            requestID: requestID,
                            .permission(decision: .allow, appliedSuggestionID: nil)
                        )
                        winManager.applyState(
                            pluginID: session.pluginID,
                            sessionID: command.paneId,
                            state: .working,
                            tmuxPane: command.paneId,
                            projectPath: nil
                        )
                    }
                    await connectionManager?.pushSessionStateToAll()
                    // Auto-approving an open permission above clears its attention
                    // without a notification — bring the iOS badge down with it.
                    if let badge = winManager.pendingCountDecrease() {
                        await connectionManager?.broadcastBadgeUpdate(badge: badge)
                    }
                    return .success(for: command.id)
                }

                // Handle mark session as handled
                if case .markHandled = command.command {
                    let wasNeeding = winManager.paneStates[command.paneId]?.agentSession?.needsAttention == true
                    winManager.markSessionHandled(paneId: command.paneId)
                    if wasNeeding {
                        await connectionManager?.pushSessionStateToAll()
                        // Route through the shared high-water mark so this clear
                        // and the agent-driven ones in `handlePluginState` don't
                        // double-push the same badge.
                        if let badge = winManager.pendingCountDecrease() {
                            await connectionManager?.broadcastBadgeUpdate(badge: badge)
                        }
                    }
                    return .success(for: command.id)
                }

                // Handle session description (applied to every pane in the session)
                // pushSessionStateToAll() runs via onSessionMetadataChanged, not here.
                if case let .setSessionDescription(spec) = command.command {
                    winManager.setSessionDescription(spec.description, for: spec.sessionName)
                    return .success(for: command.id)
                }

                // Handle session color (applied to every pane in the session).
                // pushSessionStateToAll() runs via onSessionMetadataChanged, not here.
                if case let .setSessionColor(spec) = command.command {
                    winManager.setSessionColor(spec.color, for: spec.sessionName)
                    return .success(for: command.id)
                }

                // Handle session emoji (applied to every pane in the session).
                // pushSessionStateToAll() runs via onSessionMetadataChanged, not here.
                if case let .setSessionEmoji(spec) = command.command {
                    winManager.setSessionEmoji(spec.emoji, for: spec.sessionName)
                    return .success(for: command.id)
                }

                // Handle window reorder — rewrites tmux indices via the same
                // two-phase park-then-place path used locally, then pushes
                // the refreshed session state so every viewer sees the new
                // tab order.
                if case let .moveTmuxWindows(spec) = command.command {
                    do {
                        try await tmux.moveWindows(in: spec.sessionName, to: spec.windowIds)
                        let allPanes = await tmux.refreshPanes()
                        winManager.updatePaneStates(from: allPanes)
                        await connectionManager?.pushSessionStateToAll()
                        return .success(for: command.id)
                    } catch {
                        return .failure(for: command.id, error: error.localizedDescription)
                    }
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

                // Handle remote file drop or image paste: save each file into
                // $TMPDIR under a per-drop subdirectory and paste the resolved
                // paths into the target tmux pane via the bracketed-paste
                // buffer. Image pastes ride this flow too — the viewer wraps
                // the clipboard image as a single synthetic `DroppedFile`.
                if case let .sendDroppedFiles(spec) = command.command {
                    return await Self.handleSendDroppedFiles(
                        command: command,
                        spec: spec,
                        tmuxService: tmux
                    )
                }

                // Regular commands execute on the actor executor
                return await executor.execute(command)
            }

            // Set up session state handler
            connectionManager.onSessionStateRequest = {
                [weak self, weak windowManager, tmuxService, editorManager] in
                guard let windowManager else {
                    return SessionStateMessage(pairId: "", paneStates: [:])
                }
                // Refresh panes to ensure metadata is current
                let allPanes = await tmuxService.refreshPanes()
                await windowManager.updatePaneStates(from: allPanes)
                var paneStates = await windowManager.paneStates

                // Inject active editor sessions into pane states.
                for (paneId, var state) in paneStates {
                    state.editorSession = await editorManager.editorSessionInfo(for: paneId)
                    paneStates[paneId] = state
                }

                // The merged per-plugin project list (the cores own scanning now).
                let agentProjects = await self?.currentAgentProjects() ?? []

                // Cross-session cost/usage rollup (issue #598). Computed fresh so a
                // viewer connecting or refreshing gets current totals; `nil` when
                // empty, so an older viewer sees no field at all (graceful skew).
                let usageOverview = await self?.currentUsageOverview()

                // Open response forms ride `AgentSession.state` in `paneStates`, so a
                // viewer connecting after a form opened still renders it from the
                // snapshot — no separate form field is needed.
                // Note: pairId in SessionStateMessage is per-connection, will be set by individual connections
                return SessionStateMessage(
                    pairId: "",
                    paneStates: paneStates,
                    agentProjects: agentProjects,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                    usageOverview: usageOverview
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

            // Persist viewer device name updates received over the WebSocket so
            // renaming the iOS device propagates to the macOS settings UI.
            connectionManager.onPartnerDeviceNameReceived = { [weak self] pairId, deviceName in
                self?.pairingManager?.updateViewerDeviceName(
                    pairId: pairId,
                    deviceName: deviceName
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

            // Push session state when session metadata (description, color,
            // emoji) changes locally.
            windowManager.onSessionMetadataChanged = { [weak connectionManager] in
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
                self?.revealLocalPane(paneId)
            }
        }

        /// Brings the panes window forward with `paneId` selected and the app
        /// activated. Shared by the notification-tap handler and the CLI
        /// `select-session` command so both surface a local session the same way.
        private func revealLocalPane(_ paneId: String) {
            NSApp.setActivationPolicy(.regular)
            pendingMenuBarSelection = .local(paneId: paneId)
            NotificationCenter.default.post(name: .openPanesWindow, object: nil)
            Self.forceActivate()
        }

        /// Reveals a local tmux session by resolving its active window's active
        /// pane and revealing that. No-ops if the session isn't currently
        /// tracked (e.g. it was closed between the request and now). Used by the
        /// CLI `select-session` command, which targets a session by name.
        @MainActor
        private func revealLocalSession(_ sessionName: String) {
            guard
                let pane = tmuxService.sessions
                    .first(where: { $0.sessionName == sessionName })?
                    .activeWindow?.activePane else { return }
            revealLocalPane(pane.paneId)
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
            launch: LaunchCommand?,
            defaultCommand: String?,
            tmuxService: TmuxService
        ) async -> CommandResponseMessage {
            do {
                // The owning plugin core resolved `launch` (gated on its auto-run
                // setting); a nil launch means "open in a bare shell".
                let runCommand: String? = launch.map { command in
                    if command.args.isEmpty {
                        return command.command.posixSingleQuoted
                    }
                    let quoted = command.args.map(\.posixSingleQuoted).joined(separator: " ")
                    return "\(command.command.posixSingleQuoted) \(quoted)"
                }

                let workingDirectory = spec.workingDirectory
                    ?? FileManager.default.homeDirectoryForCurrentUser.path()

                // Pass through any config-dir + plugin-provided env the launch
                // command carries (e.g. CLAUDE_CONFIG_DIR for a non-default folder).
                var extraEnvironment: [String] = []
                if let configDir = spec.configDir {
                    extraEnvironment.append("CLAUDE_CONFIG_DIR=\(configDir)")
                }
                for (key, value) in launch?.env ?? [:] {
                    extraEnvironment.append("\(key)=\(value)")
                }

                // A non-nil `spec.workingDirectory` means this was a
                // "create from project" request — that's the only flow today
                // that supplies a directory. Name the first window after the
                // launch command so the tab matches what's running; when
                // auto-run is off (`launch` is nil) fall back to the plugin's
                // CLI binary name ("claude") rather than the dashed plugin id.
                let firstWindowName = spec.workingDirectory != nil
                    ? (launch?.command ?? defaultCommand ?? spec.pluginID)
                    : "terminal 1"
                let (_, paneId) = try await tmuxService.createSession(
                    baseName: spec.sessionName,
                    width: spec.width,
                    height: spec.height,
                    workingDirectory: workingDirectory,
                    runCommand: runCommand,
                    extraEnvironment: extraEnvironment,
                    firstWindowName: firstWindowName
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

                // `refreshPanes()` early-returns the stale cached list when a
                // periodic refresh is already in flight, so the freshly-created
                // window can be missing on the first try (more likely on a slow
                // machine). If we push that stale state, the viewer's remote tab
                // bar never gains the new window. The pane definitely exists —
                // `new-window` just returned its id — so retry the refresh until
                // it shows up before pushing. Mirrors the split-window and
                // create-session paths.
                for attempt in 0..<PaneSurfaceRetry.attempts {
                    let allPanes = await tmuxService.refreshPanes()
                    windowManager.updatePaneStates(from: allPanes)
                    if allPanes.contains(where: { $0.paneId == paneId }) {
                        break
                    }
                    if attempt < PaneSurfaceRetry.attempts - 1 {
                        try? await Task.sleep(for: PaneSurfaceRetry.delay)
                    }
                }
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

        /// Removes any `$TMPDIR/gallager-drop-*` directories left over
        /// from a previous run. Called once at startup so the host doesn't
        /// accumulate per-drop landing directories indefinitely after
        /// crashes or unexpected shutdowns. Only matches our own
        /// `gallager-drop-` prefix so unrelated `$TMPDIR` content is left
        /// alone. Failures are silent — best-effort cleanup.
        private func sweepStaleDropDirectories() {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            let fm = FileManager.default
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: tmp,
                    includingPropertiesForKeys: nil
                )
            else { return }
            for entry in entries where entry.lastPathComponent.hasPrefix("gallager-drop-") {
                try? fm.removeItem(at: entry)
            }
        }

        /// Saves each file in `spec.files` to a unique subdirectory of
        /// `$TMPDIR`, builds the same shell-escaped path string the local
        /// drop path produces, then loads + pastes it into `command.paneId`
        /// via tmux's bracketed-paste buffer. The subdirectory is named
        /// `gallager-drop-<UUID>` so concurrent drops can't clobber each
        /// other; the original filename is preserved inside so
        /// downstream readers (Claude Code, vim, etc.) see a useful name.
        private static func handleSendDroppedFiles(
            command: CommandMessage,
            spec: SendDroppedFiles,
            tmuxService: TmuxService
        ) async -> CommandResponseMessage {
            guard !spec.files.isEmpty else {
                return .failure(for: command.id, error: "No files in drop payload")
            }

            // Decode each file's bytes once into a local array. `DroppedFile.data`
            // base64-decodes on every access, so reading it for both the size
            // check and the write below would do the work twice per file.
            var decoded: [(name: String, data: Data)] = []
            decoded.reserveCapacity(spec.files.count)
            var totalBytes = 0
            for file in spec.files {
                guard let data = file.data else {
                    return .failure(for: command.id, error: "File '\(file.name)' had no data")
                }
                totalBytes += data.count
                decoded.append((file.name, data))
            }

            // Defence-in-depth size cap. The viewer enforces the same limit
            // before the upload starts; this catches a structurally-valid
            // payload that bypasses the viewer check.
            guard totalBytes <= SendDroppedFiles.maxRawBytes else {
                return .failure(for: command.id, error: "Dropped files exceed maximum size")
            }

            // Verify the target pane still exists before writing files to
            // disk. If the pane was killed between the user's drop and this
            // handler we'd otherwise leave orphan files in $TMPDIR.
            let panes = await tmuxService.refreshPanes()
            guard panes.contains(where: { $0.paneId == command.paneId }) else {
                return .failure(for: command.id, error: "Pane \(command.paneId) not found")
            }

            // Save each file under a dedicated subdirectory so duplicate
            // names across drops can't collide.
            let dropDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-drop-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dropDir,
                    withIntermediateDirectories: true
                )
            } catch {
                return .failure(
                    for: command.id,
                    error: "Failed to create drop directory: \(error.localizedDescription)"
                )
            }

            // Within a single drop two files can share `lastPathComponent` (e.g.
            // two `README.md` from different folders). Track names already used
            // in this drop and append a counter suffix on collision so the
            // second `.atomic` write doesn't silently clobber the first.
            var usedNames: Set<String> = []
            var savedURLs: [URL] = []
            for entry in decoded {
                // Sanitize the filename — `lastPathComponent` returns `..`,
                // `.`, `/`, and NUL-bearing names verbatim, so an explicit
                // reject list is needed to keep writes confined to
                // `dropDir`. Anything that fails the check gets replaced
                // with a UUID so the drop still completes (and we don't
                // leak the invalid name through an error message).
                let baseName = (entry.name as NSString).lastPathComponent
                let isInvalid = baseName.isEmpty
                    || baseName == "."
                    || baseName == ".."
                    || baseName.contains("/")
                    || baseName.contains("\0")
                let candidate = isInvalid ? UUID().uuidString : baseName
                let safeName = Self.uniqueDropName(candidate, in: &usedNames)
                let target = dropDir.appendingPathComponent(safeName)
                do {
                    try entry.data.write(to: target, options: .atomic)
                } catch {
                    return .failure(
                        for: command.id,
                        error: "Failed to write \(safeName): \(error.localizedDescription)"
                    )
                }
                savedURLs.append(target)
            }

            guard let content = DroppedPathFormatter.format(urls: savedURLs) else {
                return .failure(for: command.id, error: "No valid paths after saving files")
            }

            do {
                // Per-drop buffer name — see TerminalContainerView for why
                // a stable name can lose drops under rapid double-drop.
                try await tmuxService.loadAndPasteBuffer(
                    target: command.paneId,
                    content: content,
                    bufferName: "gallager-drop-\(UUID().uuidString.prefix(8))"
                )
                return .success(for: command.id)
            } catch {
                return .failure(for: command.id, error: error.localizedDescription)
            }
        }

        /// Returns `name` unchanged on first use, otherwise inserts a `-N`
        /// counter before the extension until a free slot is found. Mutates
        /// `usedNames` so the caller can reuse it across the iteration.
        private static func uniqueDropName(
            _ name: String,
            in usedNames: inout Set<String>
        ) -> String {
            if usedNames.insert(name).inserted {
                return name
            }
            let ns = name as NSString
            let stem = ns.deletingPathExtension
            let ext = ns.pathExtension
            var index = 1
            while true {
                let candidate = ext.isEmpty
                    ? "\(stem)-\(index)"
                    : "\(stem)-\(index).\(ext)"
                if usedNames.insert(candidate).inserted {
                    return candidate
                }
                index += 1
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

                // Wire per-session status updates from remote hosts (the plugin
                // status path replaces the old hook-event forwarding).
                manager.onAgentSessionStatus = { [weak store] status in
                    store?.handleAgentStatus(status)
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
                deviceName: deviceNameClient.current()
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
                    deviceName: deviceNameClient.current()
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

        /// Applies an `OSC 9;4` progress update from `PaneStreamManager`.
        /// Stores the value on `MirrorWindowManager.paneStates` so the host
        /// sidebar and viewers (iOS, Mac-as-viewer) read from one source of
        /// truth. The host UI updates synchronously through the assignment.
        /// Pushing to viewers is coalesced with a 150ms trailing throttle so a
        /// determinate stream stepping 0 → 100% in 1% increments collapses
        /// into a single relay send instead of 100 — value-equality alone
        /// only drops repeats, not actual change rate.
        private func applyProgressUpdate(paneId: String, state: TerminalProgressState) {
            let changed = windowManager.setPaneProgress(state, for: paneId)
            guard changed, let connectionManager = connectedViewerManager else { return }
            pendingProgressPush?.cancel()
            pendingProgressPush = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await connectionManager.pushSessionStateToAll()
            }
        }
    }
#endif
