#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol

    // MARK: - CodexLaunchCommand

    /// The launch spec the Mac uses when auto-spawning Codex into a fresh
    /// tmux pane. Returned by `command_for_launch`. Mirrors
    /// `ClaudeCodeLaunchCommand`; per Task 11 we keep the per-plugin types
    /// distinct rather than collapsing them into a shared abstraction.
    public struct CodexLaunchCommand: Sendable, Equatable {
        /// Absolute path to the resolved `codex` binary.
        public let command: String

        /// CLI arguments. Empty in v1 — Codex's default vanilla launch
        /// takes no flags.
        public let args: [String]

        /// Extra environment variables to inject into the tmux pane. Codex
        /// has no per-project env (no equivalent of `CLAUDE_CONFIG_DIR`),
        /// so this is empty today; the field is here for symmetry with
        /// `ClaudeCodeLaunchCommand` and future-proofing.
        public let env: [String: String]

        public init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }
    }

    // MARK: - Resolver

    /// Resolves a `CodexLaunchCommand` for a given settings + project.
    public struct CodexLaunchCommandResolver: Sendable {
        private let locator: CodexBinaryLocator

        public init(locator: CodexBinaryLocator = .liveValue) {
            self.locator = locator
        }

        /// Resolve a launch command for the given settings.
        ///
        /// - If `settings.commandPath` is an absolute path that exists and
        ///   is executable, use it verbatim.
        /// - Otherwise (e.g. bare `"codex"`), defer to `CodexBinaryLocator`
        ///   which probes the user's PATH plus a curated list of install
        ///   locations.
        ///
        /// Throws `ResolveError.binaryNotFound` if neither path nor locator
        /// can produce an executable.
        public func resolve(
            settings: CodexSettings,
            projectPath _: String? = nil
        ) async throws -> CodexLaunchCommand {
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

            return CodexLaunchCommand(command: resolved, args: [], env: [:])
        }

        public enum ResolveError: Error, Equatable, CustomStringConvertible {
            case binaryNotFound(String)
            case invalidSettings(CodexSettings.ValidationError)

            public var description: String {
                switch self {
                case let .binaryNotFound(name):
                    "Could not find Codex binary for command '\(name)'."
                case let .invalidSettings(error):
                    "Invalid Codex settings: \(error)"
                }
            }
        }
    }
#endif
