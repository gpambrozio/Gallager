import Foundation
import GallagerPluginProtocol

/// Generic, Codable settings for a folder-dropped / URL-installed sidecar plugin
/// that doesn't ship its own typed settings struct (unlike the bundled
/// `ClaudeCodeSettings` / `CodexSettings`). The Agents settings tab renders these
/// for any non-bundled plugin so its toggles persist and reach the sidecar via
/// `apply_settings`. Keys are snake_case to match the sidecar wire contract
/// (spec §11) — a sidecar reads `command_path`, `auto_run`, etc. directly.
///
/// `commandPath` defaults to empty (no agent-specific default); a sidecar treats
/// an empty value as "use my own launch command" (`command_for_launch`).
public struct SidecarPluginSettings: Codable, Sendable, Equatable {
    public var commandPath: String
    public var autoRun: Bool
    public var logLevel: LogLevel
    public var additionalConfigFolders: [String]
    public var closePaneOnSessionEnd: Bool

    public init(
        commandPath: String = "",
        autoRun: Bool = true,
        logLevel: LogLevel = .info,
        additionalConfigFolders: [String] = [],
        closePaneOnSessionEnd: Bool = false
    ) {
        self.commandPath = commandPath
        self.autoRun = autoRun
        self.logLevel = logLevel
        self.additionalConfigFolders = additionalConfigFolders
        self.closePaneOnSessionEnd = closePaneOnSessionEnd
    }

    private enum CodingKeys: String, CodingKey {
        case commandPath = "command_path"
        case autoRun = "auto_run"
        case logLevel = "log_level"
        case additionalConfigFolders = "additional_config_folders"
        case closePaneOnSessionEnd = "close_pane_on_session_end"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.commandPath = try c.decodeIfPresent(String.self, forKey: .commandPath) ?? ""
        self.autoRun = try c.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
        self.logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        self.additionalConfigFolders = try c.decodeIfPresent([String].self, forKey: .additionalConfigFolders) ?? []
        self.closePaneOnSessionEnd = try c.decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false
    }

    /// Decode from raw `settings.json` bytes, falling back to defaults on empty or
    /// malformed data (never traps on hostile on-disk data).
    public static func decode(from data: Data) -> SidecarPluginSettings {
        guard !data.isEmpty else { return SidecarPluginSettings() }
        return (try? JSONDecoder().decode(SidecarPluginSettings.self, from: data)) ?? SidecarPluginSettings()
    }
}
