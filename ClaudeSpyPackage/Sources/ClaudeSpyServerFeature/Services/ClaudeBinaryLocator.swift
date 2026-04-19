#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// A dependency for locating the `claude` CLI binary.
    ///
    /// Searches the common locations where Claude Code's installer
    /// (`curl -fsSL https://claude.ai/install.sh | bash`) and package
    /// managers place the binary. Wraps filesystem access so it can be
    /// controlled in tests. Use `@Dependency(ClaudeBinaryLocator.self)` to
    /// access it.
    @DependencyClient
    public struct ClaudeBinaryLocator: Sendable {
        /// Searches common paths for the claude binary.
        /// Returns the first valid executable path found, or nil.
        public var find: @Sendable () -> String? = { nil }
    }

    // MARK: - DependencyKey

    extension ClaudeBinaryLocator: DependencyKey {
        public static var previewValue: ClaudeBinaryLocator {
            ClaudeBinaryLocator(find: { "/opt/homebrew/bin/claude" })
        }

        public static var liveValue: ClaudeBinaryLocator {
            ClaudeBinaryLocator(
                find: {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    let paths = [
                        "\(home)/.claude/local/claude",
                        "/opt/homebrew/bin/claude",
                        "/usr/local/bin/claude",
                        "\(home)/.local/bin/claude",
                        "/usr/bin/claude",
                    ]
                    return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
                }
            )
        }
    }
#endif
