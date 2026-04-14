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

    /// A dependency for locating the tmux binary on the filesystem.
    ///
    /// Wraps filesystem access so it can be controlled in tests.
    /// Use `@Dependency(TmuxBinaryLocator.self)` to access it.
    @DependencyClient
    public struct TmuxBinaryLocator: Sendable {
        /// Searches common paths for the tmux binary.
        /// Returns the first valid executable path found, or nil.
        public var find: @Sendable () -> String? = { nil }
    }

    // MARK: - DependencyKey

    extension TmuxBinaryLocator: DependencyKey {
        public static var previewValue: TmuxBinaryLocator {
            TmuxBinaryLocator(find: { "/opt/homebrew/bin/tmux" })
        }

        public static var liveValue: TmuxBinaryLocator {
            TmuxBinaryLocator(
                find: {
                    tmuxSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
                }
            )
        }
    }
#endif
