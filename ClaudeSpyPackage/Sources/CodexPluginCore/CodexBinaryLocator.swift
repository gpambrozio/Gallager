#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// A dependency for locating the `codex` CLI binary.
    ///
    /// Modeled on `ClaudeBinaryLocator` from `ClaudeCodePluginCore`. We do
    /// not share a single "binary locator" abstraction across plugins yet —
    /// per the Task 11 plan, "for v1 a simple copy is fine".
    ///
    /// Searches a curated set of common install locations because macOS
    /// apps launched from the Finder/Dock inherit a minimal `PATH` that
    /// excludes Homebrew, asdf, volta, etc. — exactly the places Codex is
    /// usually installed.
    @DependencyClient
    public struct CodexBinaryLocator: Sendable {
        /// Searches common paths for the codex binary.
        /// Returns the first valid executable path found, or nil.
        ///
        /// Async so disk probing happens off the main thread.
        public var find: @Sendable () async -> String? = { nil }
    }

    // MARK: - DependencyKey

    extension CodexBinaryLocator: DependencyKey {
        public static var previewValue: CodexBinaryLocator {
            CodexBinaryLocator(find: { "/opt/homebrew/bin/codex" })
        }

        public static var liveValue: CodexBinaryLocator {
            CodexBinaryLocator(
                find: {
                    await Task.detached {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        // Walk the app's PATH first (whatever Foundation
                        // hands the process), then a curated set of paths
                        // that catches Homebrew + version managers when
                        // PATH is minimal.
                        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                            .split(separator: ":")
                            .map(String.init)
                        let fallbacks = [
                            "/opt/homebrew/bin",
                            "/usr/local/bin",
                            "/usr/bin",
                            "\(home)/.local/bin",
                            "\(home)/.cargo/bin",
                            "\(home)/.npm-global/bin",
                            "\(home)/.volta/bin",
                            "\(home)/.bun/bin",
                        ]
                        for dir in pathDirs + fallbacks {
                            let candidate = (dir as NSString).appendingPathComponent("codex")
                            if FileManager.default.isExecutableFile(atPath: candidate) {
                                return candidate
                            }
                        }
                        return nil
                    }.value
                }
            )
        }
    }
#endif
