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
    private let configReader = CodexConfigReader()

    @Dependency(ProcessRunner.self) private var processRunner

    private var marketplaceSource = URL(fileURLWithPath: "/")
    private var command = "codex"

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]

    /// Per-session reviewer snapshots (issue #585, multi-session divergence):
    /// what the session's CODEX_HOME `config.toml` said when the session
    /// started — the same value Codex itself loaded. `approvals_reviewer` is a
    /// GLOBAL file but a PER-SESSION runtime value: a TUI "Approve for me"
    /// toggle overrides only the toggling session's turn context while
    /// persisting the new value globally, so with two live sessions the file
    /// and a session's actual posture can diverge. See
    /// `approvalsReviewer(for:)` for how the snapshot gates suppression.
    private var reviewerSnapshots: [String: CodexApprovalsReviewer] = [:]

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

        // Maintain the per-session reviewer snapshots: a session start is the
        // moment Codex itself loads `config.toml`, so capture what it read; a
        // session end (synthesized by the pane poll today, honored here too in
        // case the bridge ever forwards a real one) drops the entry.
        switch action {
        case let .sessionStart(body):
            recordReviewerSnapshot(sessionID: body.sessionId, transcriptPath: body.transcriptPath)
        case let .sessionEnd(body):
            reviewerSnapshots.removeValue(forKey: body.sessionId)
        default:
            break
        }

        let reviewer = await approvalsReviewer(for: action)
        guard
            let output = CodexTranslator.translate(
                action: action,
                pluginID: frame.pluginID,
                tmuxPane: tmuxPane,
                contextProjectDir: frame.context["CODEX_PROJECT_DIR"],
                closePaneOnSessionEnd: settings.closePaneOnSessionEnd,
                approvalsReviewer: reviewer
            )
        else {
            return nil
        }

        if output.guardianHandled {
            await log(
                .debug,
                "Guardian (auto_review) will decide this permission request — suppressing notification and form"
            )
        }

        // Retain the per-request context keyed by requestID so a later
        // `deliverResponse` can build the right keystrokes. The open form rides
        // the state's `awaiting*` case; `deliverResponse` clears the entry once
        // answered (a non-awaiting state simply opens no form, so nothing to
        // retract here).
        if let form = output.event.state?.openForm, let pending = output.pending {
            pendingRequests[form.requestID] = pending
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

    // MARK: - Approvals-reviewer posture (issue #585)

    /// The effective reviewer posture governing this event's session.
    ///
    /// The hook's `transcript_path` (the rollout file, which lives under
    /// `<CODEX_HOME>/sessions/`) attributes the session to a known root, and
    /// that root's `config.toml` is read **fresh on every permission request**
    /// — permission requests are rare and human-paced, the file is tiny.
    ///
    /// The fresh value alone is NOT the session's posture, though. Codex loads
    /// `config.toml` once at session start; a mid-session TUI "Approve for me"
    /// toggle overrides only the toggling session's runtime context while
    /// persisting the new value globally — other live sessions keep their
    /// start-time posture (verified against codex-rs `event_dispatch.rs`
    /// `UpdateApprovalsReviewer`; nothing per-session is observable from hooks
    /// or on disk). So suppression requires the fresh value AND the session's
    /// start snapshot to agree on `auto_review`. When they disagree, SOME
    /// session toggled and we cannot attribute which → fail safe to `.user`
    /// (notify): a still-`user` session can never have a real prompt eaten,
    /// at the cost of notify-noise for still-guardian sessions until the file
    /// returns to their snapshot value (or they restart).
    ///
    /// Suppression also requires positive attribution: an event with no
    /// transcript path, or one under a CODEX_HOME we don't track, resolves to
    /// `.user`. Both sides of the prefix match are symlink-resolved so
    /// `/var/…` vs `/private/var/…` spellings (or a symlinked CODEX_HOME)
    /// still match.
    private func approvalsReviewer(for action: HookAction) async -> CodexApprovalsReviewer {
        guard
            case let .permissionRequest(body) = action,
            let transcript = body.transcriptPath,
            let root = codexHomeRoot(forTranscriptPath: transcript)
        else { return .user }

        let fresh = configReader.approvalsReviewer(codexHome: root)
        let snapshot = reviewerSnapshot(sessionID: body.sessionId, root: root, transcriptPath: transcript)
        guard fresh == snapshot else {
            await log(
                .debug,
                "approvals_reviewer changed since session \(body.sessionId) started "
                    + "(config.toml says \(fresh), session started under \(snapshot)) — "
                    + "cannot attribute the toggle, notifying"
            )
            return .user
        }
        return fresh
    }

    /// Captures the session's start-time reviewer posture (what Codex itself
    /// just loaded). Re-recorded on every session start, so resumed sessions —
    /// which re-read `config.toml` — refresh their snapshot.
    private func recordReviewerSnapshot(sessionID: String, transcriptPath: String?) {
        guard
            let transcriptPath,
            let root = codexHomeRoot(forTranscriptPath: transcriptPath)
        else { return }
        reviewerSnapshots[sessionID] = configReader.approvalsReviewer(codexHome: root)
    }

    /// The session's start snapshot, reconstructing one when the session
    /// started before this app did (no SessionStart hook was seen).
    private func reviewerSnapshot(
        sessionID: String,
        root: URL,
        transcriptPath: String
    ) -> CodexApprovalsReviewer {
        if let known = reviewerSnapshots[sessionID] { return known }
        let reconstructed = reconstructedSnapshot(root: root, transcriptPath: transcriptPath)
        reviewerSnapshots[sessionID] = reconstructed
        return reconstructed
    }

    /// Reconstructs a missed start snapshot from file timestamps: if
    /// `config.toml` hasn't been modified since the session's rollout file was
    /// created, the current file value is exactly what the session loaded at
    /// startup. Otherwise — a write happened during the session's lifetime, or
    /// either file can't be dated — the posture is ambiguous → `.user`.
    private func reconstructedSnapshot(root: URL, transcriptPath: String) -> CodexApprovalsReviewer {
        let fileManager = FileManager.default
        let configPath = root.appendingPathComponent("config.toml").path
        guard
            let rolloutCreated = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[
                .creationDate
            ] as? Date,
            let configModified = (try? fileManager.attributesOfItem(atPath: configPath))?[
                .modificationDate
            ] as? Date,
            configModified < rolloutCreated
        else { return .user }
        return configReader.approvalsReviewer(codexHome: root)
    }

    /// Attributes a hook `transcript_path` to one of the tracked CODEX_HOME
    /// roots (the rollout lives under `<CODEX_HOME>/sessions/`), or nil when
    /// it belongs to none of them.
    private func codexHomeRoot(forTranscriptPath transcript: String) -> URL? {
        let transcriptPath = URL(fileURLWithPath: transcript).resolvingSymlinksInPath().path
        for root in codexHomeRoots() {
            let sessionsPrefix = root.appendingPathComponent("sessions")
                .resolvingSymlinksInPath().path + "/"
            if transcriptPath.hasPrefix(sessionsPrefix) {
                return root
            }
        }
        return nil
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
                    // Correlation files only — NOT reviewer snapshots. Orphan
                    // correlations are leftovers from a PREVIOUS app run, and
                    // the in-memory snapshot map starts empty, so there is
                    // nothing of theirs to drop; a snapshot recorded since
                    // launch belongs to a live session (its pane merely has no
                    // codex process yet — e.g. synthetic E2E sessions) and
                    // must survive this reconcile.
                    correlation.remove(pane: orphan)
                }
                previouslyAlivePanes = alive
                return
            }

            let ended = previouslyAlivePanes.subtracting(alive)
            for pane in ended {
                await emitSessionEnded(pane: pane)
                removeReviewerSnapshot(pane: pane)
                correlation.remove(pane: pane)
            }
            previouslyAlivePanes = alive
        }

        /// Drops the reviewer snapshot for the session correlated to an ended
        /// pane (the snapshot map is keyed by session id; the poll only knows
        /// panes). Must run before `correlation.remove(pane:)`.
        private func removeReviewerSnapshot(pane: String) {
            guard let sessionID = correlation.record(forPane: pane)?.sessionID else { return }
            reviewerSnapshots.removeValue(forKey: sessionID)
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
        // Honor the per-plugin "Log level" setting (Settings → Agents): drop lines
        // below the configured threshold instead of writing every line.
        guard level >= settings.logLevel else { return }
        await host?.log(LogLine(level: level, message: message))
    }
}
