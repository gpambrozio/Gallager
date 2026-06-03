import ClaudeCodePluginCore
import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol

/// The OpenAI Codex CLI agent, behind the agent-blind `PluginCore` contract.
/// An in-process actor constructed from the compile-time registry.
///
/// All Codex-specific behavior lives here: project scanning of
/// `~/.codex/sessions/` rollout files, the pane↔session correlation file at
/// `~/.claudespy/codex-sessions/<tmux_pane>.json` (core-internal — spec §12),
/// the hook-bridge install, the raw-hook → `PluginEvent` translation, and
/// keystroke building. The per-event behavioral contract is documented in
/// `docs/plugins/codex.md`.
///
/// Defensive by mandate (spec §13): never trap on hostile on-disk data.
public actor CodexPluginCore: PluginCore {
    public static let pluginID = "codex"

    private var host: (any PluginHost)?
    private var settings = CodexSettings()

    private let scanner = CodexScanner()
    private let correlation: CodexSessionCorrelation

    @Dependency(ProcessRunner.self) private var processRunner

    private var marketplaceSource = URL(fileURLWithPath: "/")
    private var command = "codex"

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]

    #if os(macOS)
        private var watchers: [CodexSessionsWatcher] = []

        /// Panes confirmed running a `codex` process on the previous monitor tick.
        /// A recorded pane dropping out of this set means its Codex process exited.
        private var previouslyAlivePanes: Set<String> = []
        /// On its first tick the monitor reconciles correlation files left over
        /// from a prior app run instead of reporting them as fresh session ends.
        private var didReconcileOrphans = false
        private var sessionEndMonitor: Task<Void, Never>?

        /// How often to poll for Codex process exits (seconds). Codex CLI emits no
        /// `SessionEnd` hook, so this poll is the only end signal.
        private static let sessionEndPollSeconds: Double = 5
    #endif

    public init() {
        self.correlation = .live()
    }

    /// Test seam: inject the pane↔session correlation store so a test can point
    /// it at a temp directory instead of the real `~/.claudespy/codex-sessions/`.
    init(correlation: CodexSessionCorrelation) {
        self.correlation = correlation
    }

    // MARK: - Lifecycle

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        self.host = host
        // `env.settings` is the authoritative initial settings value (spec §11).
        settings = CodexSettings.decode(from: env.settings)
        marketplaceSource = env.marketplaceSource
        command = settings.commandPath
        await refreshProjects()
        #if os(macOS)
            startWatchers()
            startSessionEndMonitor()
        #endif
    }

    public func shutdown() async {
        #if os(macOS)
            stopWatchers()
            stopSessionEndMonitor()
        #endif
        host = nil
    }

    // MARK: - Ingress translation

    /// Parse the raw Codex hook payload and translate it into a `PluginEvent`.
    /// Returns `nil` to drop frames that produce no state change (the dispatcher
    /// no-ops). Codex routes through the SAME `HookAction.from(jsonData:)` parse
    /// and the durable `HookEvent` / `HookEventMessage` semantics as Claude
    /// Code, so the parser is reused (additive phase).
    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        // Drop subagent (`Task`) hook events the way the legacy shared
        // `HookServerService` did for every agent. Codex's bridge forwards
        // SubagentStart/SubagentStop, and a trailing SubagentStop after the main
        // `Stop` would otherwise flip a just-stopped session back to "Working".
        // `PermissionRequest` is the sole exception. Shared with Claude Code so
        // neither core can drift (see `CommonHookFields.droppableSubagentEventName`).
        if let dropped = CommonHookFields.droppableSubagentEventName(payload: frame.payload) {
            await log(.debug, "Ignoring subagent hook event: \(dropped)")
            return nil
        }

        let action: HookAction
        do {
            action = try HookAction.from(jsonData: frame.payload)
        } catch {
            await log(.warn, "Dropping unparseable Codex hook payload: \(error)")
            return nil
        }

        // Resolve the pane: prefer the frame's TMUX_PANE; on a session start
        // persist the pane↔session correlation; otherwise, if the frame has no
        // pane, fall back to the correlation file by session id (spec §12).
        let tmuxPane = resolvePane(action: action, frame: frame)

        guard
            let output = CodexTranslator.translate(
                action: action,
                pluginID: frame.pluginID,
                tmuxPane: tmuxPane,
                contextProjectDir: frame.context["CODEX_PROJECT_DIR"],
                closePaneOnSessionEnd: settings.closePaneOnSessionEnd
            )
        else {
            return nil
        }

        // Retain (or retract) the per-request context keyed by requestID so a
        // later `deliverResponse` can build the right keystrokes.
        if let payload = output.event.responseRequest {
            if payload.request == nil {
                pendingRequests.removeValue(forKey: payload.requestID)
            } else {
                pendingRequests[payload.requestID] = output.pending
            }
        }

        return output.event
    }

    /// Resolve the tmux pane for an event. On a session start with a pane,
    /// persist the correlation file so later events that only carry a session id
    /// can still be routed. When the frame omits the pane, look it up by session
    /// id from the correlation store.
    private func resolvePane(action: HookAction, frame: IngressFrame) -> String? {
        if let pane = frame.tmuxPane, !pane.isEmpty {
            if CodexTranslator.isSessionStart(action) {
                correlation.record(
                    sessionID: action.sessionId,
                    tmuxPane: pane,
                    cwd: CodexTranslator.cwd(of: action),
                    startedAt: action.timestamp ?? Date()
                )
            }
            return pane
        }
        return correlation.pane(forSessionID: action.sessionId)
    }

    // MARK: - Response delivery

    /// Translate the structured `AgentResponse` into Codex keystrokes and drive
    /// delivery through the host, then clear the retained context for the request.
    public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
        guard let host else { return }

        let pending = pendingRequests[requestID]
        let deliveries = CodexKeystrokes.deliveries(for: response, pending: pending)

        for delivery in deliveries {
            switch delivery {
            case let .text(text):
                await host.sendText(sessionID: sessionID, text)
            case let .keys(keys):
                await host.sendKeys(sessionID: sessionID, keys)
            }
        }

        pendingRequests.removeValue(forKey: requestID)
    }

    // MARK: - Projects

    /// Rescan all configured CODEX_HOME roots (default + additionalConfigFolders)
    /// for rollout files and push the agent-blind project list to the host.
    public func refreshProjects() async {
        guard let host else { return }
        let projects = scanner.scan(codexHomeRoots: codexHomeRoots())
        await host.setProjects(projects)
    }

    // MARK: - Auto-launch

    public func commandForLaunch(projectPath _: String) async -> LaunchCommand? {
        guard settings.autoRun else { return nil }
        return LaunchCommand(command: settings.commandPath)
    }

    // MARK: - CLI-based plugin install

    public func install(configRoot: String?) async throws -> InstallResult {
        try await cliInstaller().install(configRoot: configRoot)
    }

    public func uninstall(configRoot: String?) async throws {
        try await cliInstaller().uninstall(configRoot: configRoot)
    }

    public func installStatus(configRoot: String?) async -> PluginInstallStatus {
        await cliInstaller().installStatus(configRoot: configRoot)
    }

    // MARK: - Settings

    public func applySettings(_ raw: Data) async -> SettingsResult {
        let decoded = CodexSettings.decode(from: raw)
        let foldersChanged = decoded.additionalConfigFolders != settings.additionalConfigFolders
        settings = decoded
        command = decoded.commandPath
        #if os(macOS)
            if foldersChanged {
                stopWatchers()
                startWatchers()
            }
        #endif
        return .applied
    }

    // MARK: - Private helpers

    private func cliInstaller() -> CodexCLIInstaller {
        CodexCLIInstaller(
            processRunner: processRunner,
            command: command,
            marketplaceSource: marketplaceSource
        )
    }

    /// Returns all CODEX_HOME roots to scan/watch: the default root plus any
    /// additional roots from settings.
    private func codexHomeRoots() -> [URL] {
        [CodexScanner.defaultCodexHome()] + settings.additionalConfigFolders.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    // MARK: - Session-end monitor (no Codex `SessionEnd` hook)

    #if os(macOS)
        /// Codex CLI emits no `SessionEnd` event, so the core can't learn from a
        /// hook when a session ends. Instead poll which panes still run a `codex`
        /// process and synthesize a `.sessionEnded` (via `host.emit`) for any
        /// recorded session whose process has exited — reusing the app's existing
        /// yolo-reset + pane-close handling. The `ps`-walking `host.agentPanes()`
        /// is only called while there are recorded sessions to watch.
        private func startSessionEndMonitor() {
            guard sessionEndMonitor == nil else { return }
            sessionEndMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(CodexPluginCore.sessionEndPollSeconds))
                    if Task.isCancelled { return }
                    await self?.pollSessionEnds()
                }
            }
        }

        private func stopSessionEndMonitor() {
            sessionEndMonitor?.cancel()
            sessionEndMonitor = nil
        }

        /// One monitor tick. Internal (not `private`) so tests can drive it
        /// deterministically instead of waiting on the timer.
        func pollSessionEnds() async {
            guard let host else { return }
            let known = correlation.allPanes()
            // Nothing recorded and nothing was live → skip the ps walk entirely.
            guard !known.isEmpty || !previouslyAlivePanes.isEmpty else { return }

            let alive = Set(await host.agentPanes()).intersection(known)

            // First tick after launch: a recorded pane whose process is already
            // gone is an orphan from a previous run (its session ended while we
            // were down). Drop the stale file silently — a late pane-kill now would
            // be useless and could target an unrelated, reused pane.
            if !didReconcileOrphans {
                didReconcileOrphans = true
                for orphan in known.subtracting(alive) {
                    correlation.remove(pane: orphan)
                }
                previouslyAlivePanes = alive
                return
            }

            let ended = previouslyAlivePanes.subtracting(alive)
            for pane in ended {
                await emitSessionEnded(pane: pane)
                correlation.remove(pane: pane)
            }
            previouslyAlivePanes = alive
        }

        /// Synthesize the `.sessionEnded` the missing Codex `SessionEnd` hook would
        /// have produced. `closePaneEligible` folds in the per-agent pref the same
        /// way `CodexTranslator` does for the hook path; we only emit once the
        /// process is actually gone, which is the clean-exit condition.
        private func emitSessionEnded(pane: String) async {
            guard let host else { return }
            await log(.debug, "Codex process exited; synthesizing session end for pane \(pane)")
            await host.emit(PluginEvent(
                pluginID: CodexPluginCore.pluginID,
                sessionID: pane,
                appActions: [.sessionEnded(
                    sessionID: pane,
                    closePaneEligible: settings.closePaneOnSessionEnd
                )],
                tmuxPane: pane
            ))
        }

        private func startWatchers() {
            guard watchers.isEmpty else { return }
            for root in codexHomeRoots() {
                let sessionsPath = root.appendingPathComponent("sessions").path
                let watcher = CodexSessionsWatcher(path: sessionsPath) { [weak self] in
                    Task { [weak self] in
                        await self?.refreshProjects()
                    }
                }
                watcher.start()
                watchers.append(watcher)
            }
        }

        private func stopWatchers() {
            for watcher in watchers {
                watcher.stop()
            }
            watchers = []
        }
    #endif

    private func log(_ level: LogLevel, _ message: String) async {
        await host?.log(LogLine(level: level, message: message))
    }
}
