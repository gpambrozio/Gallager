#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Common paths where tmux may be installed.
    private let tmuxSearchPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// Common Homebrew installation paths.
    private let brewSearchPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// MacPorts binary path.
    private let macPortsPath = "/opt/local/bin/port"

    /// A dependency for locating tmux and related package manager binaries.
    ///
    /// Wraps filesystem access so it can be controlled in tests.
    /// Use `@Dependency(TmuxBinaryLocator.self)` to access it.
    @DependencyClient
    public struct TmuxBinaryLocator: Sendable {
        /// Searches common paths for the tmux binary.
        /// Returns the first valid executable path found, or nil.
        public var find: @Sendable () -> String? = { nil }

        /// Whether Homebrew is available on this system.
        public var hasHomebrew: @Sendable () -> Bool = { false }

        /// Whether MacPorts is available on this system.
        public var hasMacPorts: @Sendable () -> Bool = { false }
    }

    // MARK: - DependencyKey

    extension TmuxBinaryLocator: DependencyKey {
        public static var previewValue: TmuxBinaryLocator {
            TmuxBinaryLocator(
                find: { "/opt/homebrew/bin/tmux" },
                hasHomebrew: { true },
                hasMacPorts: { false }
            )
        }

        public static var liveValue: TmuxBinaryLocator {
            TmuxBinaryLocator(
                find: {
                    tmuxSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
                },
                hasHomebrew: {
                    brewSearchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
                },
                hasMacPorts: {
                    FileManager.default.isExecutableFile(atPath: macPortsPath)
                }
            )
        }
    }
#endif
