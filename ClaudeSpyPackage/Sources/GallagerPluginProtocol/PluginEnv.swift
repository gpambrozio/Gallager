import ClaudeSpyNetworking
import Foundation

// MARK: - Supporting value types for the plugin contract (spec §4)

/// The environment handed to a core at `initialize`.
public struct PluginEnv: Sendable {
    /// `Resources/plugins/<id>/` — read-only bundled plugin assets (manifest, icon).
    public let pluginRoot: URL
    /// `~/.gallager/state/plugins/<id>/` — writable per-plugin scratch/state.
    public let stateDir: URL
    /// The host app's marketing version.
    public let appVersion: String
    /// Current `settings.json` bytes (may be empty). This is the **authoritative
    /// initial settings value** the core decodes during `initialize`; the app does
    /// not call `applySettings` right after `initialize` (spec §11).
    public let settings: Data

    /// The on-disk marketplace source dir for this plugin's agent CLI install
    /// (e.g. `<app>/Contents/Resources/plugin` for Claude). Passed to
    /// `<agent> plugin marketplace add`.
    public let marketplaceSource: URL

    /// The base URL of the Mac-local OTLP/JSON receiver the host is listening on
    /// (e.g. `http://127.0.0.1:24318`), or `nil` when no receiver is running.
    /// The port is whatever the receiver ACTUALLY bound this launch — it probes
    /// fallback candidates when its preferred port is taken — so cores must use
    /// this value verbatim and never assume a fixed port.
    ///
    /// Cores whose agent reads `OTEL_*` env vars (Claude Code) ignore this — the
    /// host injects those vars directly into the pane. Cores whose agent is
    /// configured only through its own config (Codex CLI, which does not read
    /// `OTEL_*`) use this to point the agent's OTLP export at the receiver
    /// (issue #602). One-way push, signal-specific paths are appended by the
    /// core (`/v1/logs`).
    public let otlpReceiverEndpoint: URL?

    public init(
        pluginRoot: URL,
        stateDir: URL,
        appVersion: String,
        settings: Data,
        marketplaceSource: URL,
        otlpReceiverEndpoint: URL? = nil
    ) {
        self.pluginRoot = pluginRoot
        self.stateDir = stateDir
        self.appVersion = appVersion
        self.settings = settings
        self.marketplaceSource = marketplaceSource
        self.otlpReceiverEndpoint = otlpReceiverEndpoint
    }
}

/// What a core returns from `commandForLaunch` to auto-start its agent in a pane.
public struct LaunchCommand: Sendable, Codable {
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

/// Result of `install()`.
public enum InstallResult: Sendable, Codable {
    case installed(message: String)
    case alreadyInstalled
}

/// Snapshot of whether the agent's plugin is installed for a given config root.
/// Transient `installing` / `failed` states are view state, not core state.
public enum PluginInstallStatus: Sendable, Codable, Equatable {
    case installed(version: String?)
    case notInstalled
    /// The agent's CLI binary could not be located / run.
    case agentUnavailable
}

/// Result of `applySettings(_:)`. `.error` surfaces inline in the settings form.
public enum SettingsResult: Sendable, Codable {
    case applied
    case error(field: String?, message: String)
}

/// A structured log line appended to the plugin's log file and surfaced in
/// Settings → View Logs (spec §15).
public struct LogLine: Sendable, Codable {
    public let level: LogLevel
    public let message: String

    public init(level: LogLevel, message: String) {
        self.level = level
        self.message = message
    }
}

/// Severity for `LogLine` and per-plugin settings. Codable so a core's typed
/// settings struct can persist it. `Comparable` (debug < info < warn < error) so
/// a core / sink can drop lines below a configured threshold.
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug
    case info
    case warn
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        guard
            let lhsIndex = allCases.firstIndex(of: lhs),
            let rhsIndex = allCases.firstIndex(of: rhs)
        else { return false }
        return lhsIndex < rhsIndex
    }
}

/// The closed key vocabulary a core emits via `PluginHost.sendKeys`. Aliased to
/// the shared `TmuxKey` so the contract reuses one durable key model rather than
/// duplicating it.
public typealias PluginTmuxKey = TmuxKey
