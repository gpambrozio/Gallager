import Foundation
import GallagerPluginProtocol

/// Typed, Codable settings for the Claude Code plugin core. Persisted to
/// `~/.gallager/state/plugins/claude-code/settings.json` with snake_case keys
/// (spec §11). The Mac renders these via a hand-written `PluginSettingsForm`
/// switching on plugin id; iOS stays read-only "Configured by Mac".
public struct ClaudeCodeSettings: Codable, Sendable, Equatable {
    /// Path to the `claude` command (full path or just `claude` if on PATH).
    public var commandPath: String
    /// Whether to auto-launch Claude when a project is opened (gates
    /// `commandForLaunch`).
    public var autoRun: Bool
    /// Verbosity of the plugin's log sink.
    public var logLevel: LogLevel
    /// Extra `.claude` config folders to scan beyond `~/.claude`.
    public var additionalConfigFolders: [String]

    public init(
        commandPath: String = "claude",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        additionalConfigFolders: [String] = []
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.additionalConfigFolders = additionalConfigFolders
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case additionalConfigFolders = "additional_config_folders"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "claude"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.additionalConfigFolders = try container
            .decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> ClaudeCodeSettings {
        guard !data.isEmpty else { return ClaudeCodeSettings() }
        return (try? JSONDecoder().decode(ClaudeCodeSettings.self, from: data)) ?? ClaudeCodeSettings()
    }
}
