#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    // MARK: - CodexSettings

    /// Per-plugin user settings for the Codex plugin.
    ///
    /// Stored on disk at `~/.gallager/state/plugins/codex/settings.json`
    /// and applied via the sidecar's `apply_settings` RPC. Mirrors the
    /// field IDs declared in `PluginBundles/codex/ui/settings.json`
    /// (Spec §17.3) — same shape as `ClaudeCodeSettings`, only the
    /// `commandPath` default differs.
    public struct CodexSettings: Codable, Sendable, Equatable {
        /// Path or `$PATH`-discoverable command name for the `codex` CLI.
        public var commandPath: String

        /// Whether Gallager should auto-launch the `codex` CLI in newly
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
            commandPath: String = "codex",
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
            self.commandPath = try container.decodeIfPresent(String.self, forKey: .commandPath) ?? "codex"
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
        /// `apply_settings`.
        public static func decode(from json: JSONValue) throws -> CodexSettings {
            let encoder = JSONEncoder()
            let data = try encoder.encode(json)
            return try JSONDecoder().decode(CodexSettings.self, from: data)
        }

        /// Encode for persistence to `settings.json`.
        public func encodedJSON() throws -> JSONValue {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }

        // MARK: - Validation

        /// Semantic validation. Returns `nil` when the settings are sane.
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
                    "Codex CLI command must not be empty."
                }
            }
        }
    }
#endif
