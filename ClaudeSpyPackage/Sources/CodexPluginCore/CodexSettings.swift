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

    public init(
        commandPath: String = "codex",
        autoRun: Bool = true,
        logLevel: LogLevel = .info
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "codex"
        self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults when the
    /// data is empty or malformed (never traps on hostile on-disk data — §13).
    public static func decode(from data: Data) -> CodexSettings {
        guard !data.isEmpty else { return CodexSettings() }
        return (try? JSONDecoder().decode(CodexSettings.self, from: data)) ?? CodexSettings()
    }
}
