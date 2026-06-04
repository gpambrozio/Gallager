import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol

/// The Claude Code agent, behind the agent-blind `PluginCore` contract (spec §4).
/// An in-process actor constructed from the compile-time registry.
///
/// All Claude-specific behavior lives here: project scanning, the host-agent
/// hook bridge install, the raw-hook → `PluginEvent` translation (the 30→5 event
/// mapping), keystroke building for response delivery, and notification copy.
/// The per-event behavioral contract is documented in `docs/plugins/claude-code.md`.
///
/// Defensive by mandate (spec §13): this core parses real-world on-disk data
/// (`~/.claude.json`, transcripts) and hook payloads, so it must never trap —
/// `do/try/catch` around every decode, no force-unwraps, skip-and-log malformed
/// entries.
public actor ClaudeCodePluginCore: PluginCore {
    public static let pluginID = "claude-code"

    private var host: (any PluginHost)?
    private var settings = ClaudeCodeSettings()

    private let scanner = ClaudeCodeScanner()

    @Dependency(ProcessRunner.self) private var processRunner

    private var marketplaceSource = URL(fileURLWithPath: "/")
    private var command = "claude"

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]

    #if os(macOS)
        private var watcher: ClaudeCodeProjectsWatcher?
    #endif

    public init() { }

    // MARK: - Lifecycle

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        self.host = host
        // `env.settings` is the authoritative initial settings value (spec §11).
        settings = ClaudeCodeSettings.decode(from: env.settings)
        marketplaceSource = env.marketplaceSource
        command = settings.commandPath
        await refreshProjects()
        startWatcher()
    }

    public func shutdown() async {
        #if os(macOS)
            watcher?.stop()
            watcher = nil
        #endif
        host = nil
    }

    // MARK: - Ingress translation

    /// Parse the raw Claude hook payload and translate it into a `PluginEvent`.
    /// Returns `nil` to drop frames that produce no state change (the dispatcher
    /// no-ops). Reuses `HookAction.from(jsonData:)` for the 30-case parse and the
    /// durable `HookEvent` / `HookEventMessage` semantics for working state and
    /// notification copy (additive phase — those types still live in networking).
    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        // Drop subagent (`Task`) hook events — those carrying an `agent_id` — the
        // way the legacy shared `HookServerService` did for every agent. They
        // describe a subagent's lifecycle, not the main agent's, and must not drive
        // the main session's status: a trailing `SubagentStop` fires ~seconds AFTER
        // the main `Stop` and would flip the just-stopped session back to "Working".
        // `PermissionRequest` is the sole exception. Shared with Codex so neither
        // core can drift (see `CommonHookFields.droppableSubagentEventName`).
        if let dropped = CommonHookFields.droppableSubagentEventName(payload: frame.payload) {
            await log(.debug, "Ignoring subagent hook event: \(dropped)")
            return nil
        }

        let action: HookAction
        do {
            action = try HookAction.from(jsonData: frame.payload)
        } catch {
            await log(.warn, "Dropping unparseable Claude hook payload: \(error)")
            return nil
        }

        guard
            let output = ClaudeCodeTranslator.translate(
                action: action,
                pluginID: frame.pluginID,
                tmuxPane: frame.tmuxPane,
                contextProjectDir: frame.context["CLAUDE_PROJECT_DIR"],
                closePaneOnSessionEnd: settings.closePaneOnSessionEnd
            )
        else {
            return nil
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

    // MARK: - Response delivery

    /// Translate the structured `AgentResponse` into Claude keystrokes and drive
    /// delivery through the host, then clear the retained context for the request.
    public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
        guard let host else { return }

        let pending = pendingRequests[requestID]
        let deliveries = ClaudeCodeKeystrokes.deliveries(for: response, pending: pending)

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

    /// Rescan `~/.claude.json` + `~/.claude/projects/` (and extra config folders)
    /// and push the agent-blind project list to the host.
    public func refreshProjects() async {
        guard let host else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = scanner.scan(
            home: home,
            additionalConfigFolders: settings.additionalConfigFolders
        )
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
        let decoded = ClaudeCodeSettings.decode(from: raw)
        settings = decoded
        command = decoded.commandPath
        return .applied
    }

    // MARK: - Private helpers

    private func cliInstaller() -> ClaudeCodeCLIInstaller {
        ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: command,
            marketplaceSource: marketplaceSource
        )
    }

    private func startWatcher() {
        #if os(macOS)
            guard watcher == nil else { return }
            let projectsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
                .path
            let created = ClaudeCodeProjectsWatcher(path: projectsPath) { [weak self] in
                Task { [weak self] in
                    await self?.refreshProjects()
                }
            }
            created.start()
            watcher = created
        #endif
    }

    private func log(_ level: LogLevel, _ message: String) async {
        // Honor the per-plugin "Log level" setting (Settings → Agents): drop lines
        // below the configured threshold instead of writing every line.
        guard level >= settings.logLevel else { return }
        await host?.log(LogLine(level: level, message: message))
    }
}
