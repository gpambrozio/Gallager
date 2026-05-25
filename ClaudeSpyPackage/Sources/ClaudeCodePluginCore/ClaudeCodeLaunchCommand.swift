#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol

    // MARK: - ClaudeCodeLaunchCommand

    /// The launch spec the Mac uses when auto-spawning Claude Code into a
    /// fresh tmux pane. Returned by `command_for_launch`.
    public struct ClaudeCodeLaunchCommand: Sendable, Equatable {
        /// Absolute path to the resolved `claude` binary.
        public let command: String

        /// CLI arguments. Empty in v1 — Claude takes no flags for the
        /// vanilla project launch path.
        public let args: [String]

        /// Extra environment variables to inject into the tmux pane (e.g.
        /// `CLAUDE_CONFIG_DIR` when the project lives under an
        /// additional Claude folder).
        public let env: [String: String]

        public init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }
    }

    // MARK: - Resolver

    /// Resolves a `ClaudeCodeLaunchCommand` for a given settings + project.
    ///
    /// Wraps `ClaudeBinaryLocator` so disk probing is overridable in tests.
    /// Mirrors the launch logic that lives inline in `AppCoordinator`
    /// today (Task 15 ports the call site).
    public struct ClaudeCodeLaunchCommandResolver: Sendable {
        private let locator: ClaudeBinaryLocator

        public init(locator: ClaudeBinaryLocator = .liveValue) {
            self.locator = locator
        }

        /// Resolve a launch command for the given settings + project path.
        ///
        /// - If `settings.commandPath` is an absolute path that exists and is
        ///   executable, use it verbatim.
        /// - Otherwise (e.g. bare `"claude"`), defer to `ClaudeBinaryLocator`
        ///   which probes a curated list of install locations.
        /// - When `claudeConfigDir` is non-nil, populate `CLAUDE_CONFIG_DIR`
        ///   in the env so Claude finds the right sessions folder.
        ///
        /// Throws `ResolveError.binaryNotFound` if neither path nor locator
        /// can produce an executable.
        public func resolve(
            settings: ClaudeCodeSettings,
            projectPath _: String? = nil,
            claudeConfigDir: String? = nil
        ) async throws -> ClaudeCodeLaunchCommand {
            if let error = settings.validate() {
                throw ResolveError.invalidSettings(error)
            }

            let candidate = settings.commandPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: String
            if candidate.hasPrefix("/") {
                guard FileManager.default.isExecutableFile(atPath: candidate) else {
                    throw ResolveError.binaryNotFound(candidate)
                }
                resolved = candidate
            } else {
                guard let found = await locator.find() else {
                    throw ResolveError.binaryNotFound(candidate)
                }
                resolved = found
            }

            var env: [String: String] = [:]
            if let configDir = claudeConfigDir, !configDir.isEmpty {
                env["CLAUDE_CONFIG_DIR"] = configDir
            }

            return ClaudeCodeLaunchCommand(command: resolved, args: [], env: env)
        }

        public enum ResolveError: Error, Equatable, CustomStringConvertible {
            case binaryNotFound(String)
            case invalidSettings(ClaudeCodeSettings.ValidationError)

            public var description: String {
                switch self {
                case let .binaryNotFound(name):
                    "Could not find Claude Code binary for command '\(name)'."
                case let .invalidSettings(error):
                    "Invalid Claude Code settings: \(error)"
                }
            }
        }
    }
#endif
