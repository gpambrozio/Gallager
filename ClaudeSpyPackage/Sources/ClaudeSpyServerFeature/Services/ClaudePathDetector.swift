#if os(macOS)
    import Foundation

    /// Shared utility for detecting the Claude CLI path.
    ///
    /// Used by both `PluginService` and `AppSettings` to avoid duplication
    /// of path detection logic.
    public enum ClaudePathDetector {
        /// Common installation paths for Claude Code
        public static let commonPaths: [String] = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSString("~/.local/bin/claude").expandingTildeInPath,
            NSString("~/.claude/local/claude").expandingTildeInPath,
        ]

        /// Attempts to detect the claude command path using common locations and `which`
        public static func detectPath() -> String? {
            let fileManager = FileManager.default

            // Check common paths first
            for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
                return path
            }

            // Try using `which` command as fallback
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["claude"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if
                        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !path.isEmpty {
                        return path
                    }
                }
            } catch {
                // which failed, return nil
            }

            return nil
        }
    }
#endif
