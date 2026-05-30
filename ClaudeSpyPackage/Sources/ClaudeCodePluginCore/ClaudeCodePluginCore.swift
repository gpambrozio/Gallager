import ClaudeSpyCommon
import ClaudeSpyNetworking
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
    private var env: PluginEnv?
    private var settings = ClaudeCodeSettings()

    private let scanner = ClaudeCodeScanner()

    /// Per-`requestID` context retained from `handleIngress` so `deliverResponse`
    /// can translate the structured answer into keystrokes (spec §7.1).
    private var pendingRequests: [String: PendingRequest] = [:]

    #if os(macOS)
        private var watcher: ClaudeCodeProjectsWatcher?
    #endif

    public init() { }

    // MARK: - Lifecycle

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        self.env = env
        self.host = host
        // `env.settings` is the authoritative initial settings value (spec §11).
        settings = ClaudeCodeSettings.decode(from: env.settings)
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
    /// durable `HookEvent` / `HookEventMessage` semantics for working/attention/
    /// notification (additive phase — those types still live in networking).
    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
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
                contextProjectDir: frame.context["CLAUDE_PROJECT_DIR"]
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

    // MARK: - Hook-bridge install

    public func install() async throws -> InstallResult {
        try installer().install()
    }

    public func uninstall() async throws {
        try installer().uninstall()
    }

    public func isInstalled() async -> Bool {
        installer().isInstalled()
    }

    // MARK: - Settings

    public func applySettings(_ raw: Data) async -> SettingsResult {
        settings = ClaudeCodeSettings.decode(from: raw)
        return .applied
    }

    // MARK: - Private helpers

    /// Builds the installer rooted at the plugin state dir (falls back to a
    /// temp-dir-less default if `initialize` hasn't run yet — defensive).
    private func installer() -> ClaudeCodeInstaller {
        let stateDir = env?.stateDir
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gallager-claude-code")
        return ClaudeCodeInstaller.live(stateDir: stateDir)
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
        await host?.log(LogLine(level: level, message: message))
    }
}
