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
    /// When true (and the agent exited cleanly at the prompt), the pane closes
    /// on session end. Per-agent; the app honors the core's eligibility flag.
    public var closePaneOnSessionEnd: Bool
    /// When true, a `Stop` hook that arrives while background tasks or crons are
    /// still in flight is checked with the on-device Apple Intelligence model: if
    /// the last message reads like the agent is still waiting, the premature
    /// "Done" is suppressed (issue #644). Falls back to honoring the Stop wherever
    /// Apple Intelligence is unavailable, so it is safe to leave on by default.
    public var detectFalseStops: Bool

    public init(
        commandPath: String = "claude",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        additionalConfigFolders: [String] = [],
        closePaneOnSessionEnd: Bool = false,
        detectFalseStops: Bool = true
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.additionalConfigFolders = additionalConfigFolders
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
        self.detectFalseStops = detectFalseStops
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case additionalConfigFolders = "additional_config_folders"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
        case detectFalseStops = "detect_false_stops"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "claude"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.additionalConfigFolders = try container
            .decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
        self.closePaneOnSessionEnd = try container
            .decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false
        self.detectFalseStops = try container
            .decodeIfPresent(Bool.self, forKey: .detectFalseStops) ?? true
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> ClaudeCodeSettings {
        guard !data.isEmpty else { return ClaudeCodeSettings() }
        return (try? JSONDecoder().decode(ClaudeCodeSettings.self, from: data)) ?? ClaudeCodeSettings()
    }
}
