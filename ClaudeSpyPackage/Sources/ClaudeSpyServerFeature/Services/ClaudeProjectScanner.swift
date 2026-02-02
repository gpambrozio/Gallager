#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    // MARK: - Claude Project Scanner

    /// Scans the local filesystem to discover Claude projects.
    ///
    /// Reads `~/.claude.json` to find projects that have been used with Claude Code.
    /// A valid project must have a `.claude` subdirectory. Projects are sorted by
    /// most recently used first, based on session timestamps.
    public actor ClaudeProjectScanner {
        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.projectscanner")
        private let fileManager = FileManager.default

        /// Path to the Claude configuration file
        private var claudeConfigPath: URL {
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        }

        /// Path to the Claude projects data folder
        private var claudeProjectsPath: URL {
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
        }

        // MARK: - Initialization

        public init() { }

        // MARK: - Public API

        /// Scans for Claude projects and returns a list sorted by most recently used.
        /// - Returns: Array of discovered Claude projects, sorted by last used timestamp (most recent first)
        public func scanProjects() async -> [ClaudeProjectInfo] {
            logger.debug("Scanning for Claude projects")

            guard let projectsData = readClaudeConfig() else {
                logger.info("No Claude config found or no projects in config")
                return []
            }

            var projects: [ClaudeProjectInfo] = []
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

            for (path, data) in projectsData {
                let projectURL = URL(fileURLWithPath: path).standardizedFileURL

                // Skip the home directory entry (represents global config, not a project)
                if projectURL == homeDirectory {
                    continue
                }

                // Validate the project and get timestamp
                if let project = validateProject(at: projectURL, data: data) {
                    projects.append(project)
                }
            }

            // Sort by last used timestamp (most recent first), then by name for projects without timestamps
            projects.sort { lhs, rhs in
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (nil, .some):
                    return false // Projects with timestamps come first
                case (.some, nil):
                    return true
                case (nil, nil):
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }

            logger.info("Found \(projects.count) Claude projects")
            return projects
        }

        // MARK: - Private Methods

        /// Reads the Claude config file and extracts project data.
        /// - Returns: Dictionary mapping project paths to their config data, or nil if config doesn't exist
        private func readClaudeConfig() -> [String: [String: Any]]? {
            let configPath = claudeConfigPath

            guard fileManager.fileExists(atPath: configPath.path) else {
                logger.debug("Claude config file not found at \(configPath.path)")
                return nil
            }

            do {
                let data = try Data(contentsOf: configPath)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    logger.warning("Claude config is not a valid JSON object")
                    return nil
                }

                // The "projects" key contains a dictionary where keys are project paths
                guard let projectsDict = json["projects"] as? [String: [String: Any]] else {
                    logger.debug("No 'projects' key in Claude config")
                    return nil
                }

                return projectsDict
            } catch {
                logger.error("Failed to read Claude config: \(error)")
                return nil
            }
        }

        /// Validates a project directory and creates a ClaudeProjectInfo if valid.
        /// - Parameters:
        ///   - url: The URL of the project directory
        ///   - data: The project's configuration data from ~/.claude.json
        /// - Returns: A ClaudeProjectInfo if the project is valid, nil otherwise
        private func validateProject(at url: URL, data: [String: Any]) -> ClaudeProjectInfo? {
            // Check if directory exists
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("Project directory does not exist: \(url.path)")
                return nil
            }

            // Check for .claude subdirectory
            let claudeDir = url.appendingPathComponent(".claude")
            guard
                fileManager.fileExists(atPath: claudeDir.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("No .claude directory in project: \(url.path)")
                return nil
            }

            // Extract project name from path
            let name = url.lastPathComponent

            // Try to get the last used timestamp from the session file
            let lastUsed = getLastUsedTimestamp(projectPath: url.path, data: data)

            return ClaudeProjectInfo(name: name, path: url.path, lastUsed: lastUsed)
        }

        /// Gets the last used timestamp for a project by reading its most recent session file.
        /// - Parameters:
        ///   - projectPath: The full path to the project directory
        ///   - data: The project's configuration data containing lastSessionId
        /// - Returns: The timestamp of the last activity, or nil if unavailable
        private func getLastUsedTimestamp(projectPath: String, data: [String: Any]) -> Date? {
            // Get the lastSessionId from project config
            guard let sessionId = data["lastSessionId"] as? String else {
                logger.debug("No lastSessionId for project: \(projectPath)")
                return nil
            }

            // Convert project path to folder name format (replace "/" with "-")
            let folderName = projectPath.replacingOccurrences(of: "/", with: "-")
            let sessionFilePath = claudeProjectsPath
                .appendingPathComponent(folderName)
                .appendingPathComponent("\(sessionId).jsonl")

            guard fileManager.fileExists(atPath: sessionFilePath.path) else {
                logger.debug("Session file not found: \(sessionFilePath.path)")
                return nil
            }

            // Read the last few lines of the session file to find a timestamp
            return readLastTimestamp(from: sessionFilePath)
        }

        /// Reads the last timestamp from a session JSONL file.
        /// - Parameter url: The URL of the session file
        /// - Returns: The timestamp from the last line containing one, or nil if not found
        private func readLastTimestamp(from url: URL) -> Date? {
            guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
                return nil
            }
            defer { try? fileHandle.close() }

            // Read the last portion of the file (last ~10KB should be plenty)
            let fileSize = fileHandle.seekToEndOfFile()
            let readSize: UInt64 = min(fileSize, 10_240)
            fileHandle.seek(toFileOffset: fileSize - readSize)

            guard
                let data = try? fileHandle.readToEnd(),
                let content = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            // Parse lines in reverse order to find the most recent timestamp
            let lines = content.components(separatedBy: .newlines).reversed()

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for line in lines where !line.isEmpty {
                let lineData = Data(line.utf8)
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Try top-level timestamp first (regular messages)
                if
                    let timestampString = json["timestamp"] as? String,
                    let date = dateFormatter.date(from: timestampString) {
                    return date
                }

                // Try nested timestamp in snapshot entries (file-history-snapshot)
                if
                    let snapshot = json["snapshot"] as? [String: Any],
                    let timestampString = snapshot["timestamp"] as? String,
                    let date = dateFormatter.date(from: timestampString) {
                    return date
                }
            }

            return nil
        }
    }

    // MARK: - SwiftUI Environment Support

    import SwiftUI

    /// Environment key for ClaudeProjectScanner
    private struct ClaudeProjectScannerKey: EnvironmentKey {
        static let defaultValue: ClaudeProjectScanner? = nil
    }

    public extension EnvironmentValues {
        /// The Claude project scanner for discovering Claude Code projects
        var claudeProjectScanner: ClaudeProjectScanner? {
            get { self[ClaudeProjectScannerKey.self] }
            set { self[ClaudeProjectScannerKey.self] = newValue }
        }
    }

    public extension View {
        /// Sets the Claude project scanner for this view hierarchy
        func claudeProjectScanner(_ scanner: ClaudeProjectScanner) -> some View {
            environment(\.claudeProjectScanner, scanner)
        }
    }
#endif
