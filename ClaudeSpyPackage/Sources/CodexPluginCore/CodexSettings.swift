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

    public init(
        commandPath: String = "codex",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        closePaneOnSessionEnd: Bool = false,
        additionalConfigFolders: [String] = []
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
        self.additionalConfigFolders = additionalConfigFolders
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
        case additionalConfigFolders = "additional_config_folders"
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
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> CodexSettings {
        guard !data.isEmpty else { return CodexSettings() }
        return (try? JSONDecoder().decode(CodexSettings.self, from: data)) ?? CodexSettings()
    }
}
