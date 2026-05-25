#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    // MARK: - ClaudeCodeSettings

    /// Per-plugin user settings for the Claude Code plugin.
    ///
    /// Stored on disk at `~/.gallager/state/plugins/claude-code/settings.json`
    /// and applied via the sidecar's `apply_settings` RPC. Mirrors the field
    /// IDs declared in `PluginBundles/claude-code/ui/settings.json` (Spec §17.3).
    ///
    /// Decoding accepts both the snake-case wire form (`command_path`,
    /// `auto_run`, `log_level`) the JSON settings file uses, and the
    /// lower-camel Swift form so tests can construct values inline. Missing
    /// keys fall back to the defaults declared in `init(...)` — the same
    /// defaults as the JSON schema's `default` field, so a fresh install
    /// behaves identically whether the file is missing or empty.
    public struct ClaudeCodeSettings: Codable, Sendable, Equatable {
        /// Path or `$PATH`-discoverable command name for the `claude` CLI.
        public var commandPath: String

        /// Whether Gallager should auto-launch the `claude` CLI in newly
        /// created tmux panes for projects that this plugin owns.
        public var autoRun: Bool

        /// Verbosity level for the sidecar's own log file.
        public var logLevel: LogLevel

        public enum LogLevel: String, Codable, Sendable, CaseIterable, Equatable {
            case debug
            case info
            case warn
            case error
        }

        public init(
            commandPath: String = "claude",
            autoRun: Bool = true,
            logLevel: LogLevel = .info
        ) {
            self.commandPath = commandPath
            self.autoRun = autoRun
            self.logLevel = logLevel
        }

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case commandPath = "command_path"
            case autoRun = "auto_run"
            case logLevel = "log_level"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "claude"
            self.autoRun = try container.decodeIfPresent(Bool.self, forKey: .autoRun) ?? true
            self.logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(commandPath, forKey: .commandPath)
            try container.encode(autoRun, forKey: .autoRun)
            try container.encode(logLevel, forKey: .logLevel)
        }

        // MARK: - JSONValue bridge

        /// Decode from the raw `JSONValue` blob the runtime hands us via
        /// `apply_settings`. The runtime keeps settings in the agnostic
        /// `JSONValue` shape; we only become typed here.
        public static func decode(from json: JSONValue) throws -> ClaudeCodeSettings {
            let encoder = JSONEncoder()
            let data = try encoder.encode(json)
            return try JSONDecoder().decode(ClaudeCodeSettings.self, from: data)
        }

        /// Encode for persistence to `settings.json`.
        public func encodedJSON() throws -> JSONValue {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }

        // MARK: - Validation

        /// Semantic validation. Returns `nil` when the settings are sane;
        /// otherwise a human-readable reason the apply_settings RPC can
        /// surface back to the UI.
        public func validate() -> ValidationError? {
            let trimmed = commandPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .emptyCommandPath
            }
            return nil
        }

        public enum ValidationError: Sendable, Equatable, Error, CustomStringConvertible {
            case emptyCommandPath

            public var description: String {
                switch self {
                case .emptyCommandPath:
                    "Claude CLI command must not be empty."
                }
            }
        }
    }
#endif
