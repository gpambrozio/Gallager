import ClaudeSpyNetworking
import Foundation

// MARK: - PluginCore

/// The agent-specific contract — the single seam between the agent-blind core
/// and per-agent logic (spec §4). One conformer per agent module. In v1 every
/// conformer is an in-process `actor`; v2 adds a transport-adapter conformer
/// (`SidecarPluginCore`) without changing anything upstream.
///
/// The app drives these methods; the plugin calls back through the `PluginHost`
/// it receives at `initialize`.
public protocol PluginCore: Actor {
    /// Called once after construction. `host` is the callback channel. THROW to
    /// enter failed-init (left disabled, error surfaced in Settings). Identity,
    /// presentation, and pane-detection data come from the MANIFEST (§10), not
    /// the core — so `initialize` returns nothing. `env.settings` is the
    /// authoritative initial settings value (§11).
    func initialize(_ env: PluginEnv, host: any PluginHost) async throws

    /// A raw host-agent payload arrived on the app-owned ingress socket tagged
    /// with this plugin's id. Translate into a `PluginEvent`, or return `nil` to
    /// drop (log-and-ignore). The app dispatches the returned envelope.
    func handleIngress(_ frame: IngressFrame) async -> PluginEvent?

    /// iOS submitted an `AgentResponse` for a request this core previously
    /// emitted (matched by `requestID`). The core looks up the retained context
    /// and drives delivery to the host agent — typically `host.sendText` /
    /// `host.sendKeys`.
    func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async

    /// The user clicked "refresh projects". The core SHOULD rescan and call
    /// `host.setProjects`; it MAY no-op if its data is already fresh.
    func refreshProjects() async

    /// Gallager is about to auto-launch the agent in a tmux pane for a project.
    /// Return the command/env/args, or `nil` to decline. Gated upstream by the
    /// plugin's `autoRun` setting.
    func commandForLaunch(projectPath: String) async -> LaunchCommand?

    /// Register the host-agent hook bridge (writes into the agent's own hook
    /// config, e.g. `~/.claude/.../hooks.json`), baking in this plugin's id and
    /// the well-known socket path (spec §8.1).
    func install() async throws -> InstallResult

    /// Remove the host-agent hook bridge.
    func uninstall() async throws

    /// Query whether the hook bridge is registered.
    func isInstalled() async -> Bool

    /// Apply user settings (raw JSON from `settings.json`). The core decodes its
    /// typed struct and runs semantic validation; return `.error` to surface
    /// inline (spec §11).
    func applySettings(_ raw: Data) async -> SettingsResult

    /// Graceful teardown (stop FSEvents watchers, flush). Called on disable/quit.
    func shutdown() async
}

// MARK: - PluginHost

/// The callback channel the app hands each core at `initialize`. `Sendable` so a
/// core actor can hold and call it. Every method is `async` so the app can
/// serialize/route without the core caring how (spec §4).
public protocol PluginHost: Sendable {
    /// Replace the app's project list for this plugin (full list, not
    /// incremental). Push-based — the app never asks.
    func setProjects(_ projects: [AgentProject]) async

    /// Push a `PluginEvent` into the session pipeline (used when the core
    /// generates events without an incoming ingress frame — e.g. an FSEvents tick).
    func emit(_ event: PluginEvent) async

    /// Write text to the tmux pane backing this session (verbatim, no key
    /// processing). Used to deliver prompt/reply text or free-text answers.
    func sendText(sessionID: String, _ text: String) async

    /// Send a key sequence to the pane (e.g. `[.down, .down, .space, .enter]`).
    /// Used to drive in-terminal menus (AskUserQuestion, permission prompts).
    func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async

    /// Structured log line, appended to the plugin's log file and surfaced in
    /// Settings → View Logs.
    func log(_ line: LogLine) async
}
