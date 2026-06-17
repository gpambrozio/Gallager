import Foundation
import GallagerPluginProtocol

/// Typed, Codable settings for the Codex plugin core. Persisted to
/// `~/.gallager/state/plugins/codex/settings.json` with snake_case keys (spec §11).
public struct CodexSettings: Codable, Sendable, Equatable {
    /// Path to the `codex` command (full path or just `codex` if on PATH).
    public var commandPath: String
    /// Whether to auto-launch Codex when a project is opened.
    public var autoRun: Bool
    /// Verbosity of the plugin's log sink.
    public var logLevel: LogLevel
    /// When true (and the agent exited cleanly at the prompt), the pane closes
    /// on session end. Per-agent; the app honors the core's eligibility flag.
    public var closePaneOnSessionEnd: Bool
    /// Extra `CODEX_HOME` roots to scan/install beyond the default. Mirrors
    /// ClaudeCodeSettings.additionalConfigFolders.
    public var additionalConfigFolders: [String]

    /// When true (default), app-launched Codex panes get `-c otel.…` launch
    /// overrides pointing Codex's OTLP log export at the Mac-local receiver
    /// (issue #602), so the session's token/latency/model surface in the UI.
    /// One-way push; no prompt/tool content leaves the process
    /// (`log_user_prompt = false`). Opt-out for users who manage their own
    /// `[otel]` config or want zero telemetry from Gallager-launched panes.
    public var exportTelemetry: Bool

    public init(
        commandPath: String = "codex",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        closePaneOnSessionEnd: Bool = false,
        additionalConfigFolders: [String] = [],
        exportTelemetry: Bool = true
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
        self.additionalConfigFolders = additionalConfigFolders
        self.exportTelemetry = exportTelemetry
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
        case additionalConfigFolders = "additional_config_folders"
        case exportTelemetry = "export_telemetry"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "codex"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.closePaneOnSessionEnd = try container
            .decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false
        self.additionalConfigFolders = try container
            .decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
        self.exportTelemetry = try container.decodeIfPresent(Bool.self, forKey: .exportTelemetry) ?? true
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> CodexSettings {
        guard !data.isEmpty else { return CodexSettings() }
        return (try? JSONDecoder().decode(CodexSettings.self, from: data)) ?? CodexSettings()
    }
}
