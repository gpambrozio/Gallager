#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// A dependency for scanning the local filesystem to discover Claude projects.
    ///
    /// Wraps filesystem access so it can be controlled in tests.
    /// Use `@Dependency(ClaudeProjectScanner.self)` to access it.
    @DependencyClient
    public struct ClaudeProjectScanner: Sendable {
        /// Scans for Claude projects and returns a list sorted by most recently used.
        public var scanProjects: @Sendable () async -> [ClaudeProjectInfo] = { [] }
    }

    // MARK: - In-Memory

    public extension ClaudeProjectScanner {
        static func inMemory(projects: [ClaudeProjectInfo] = [
            ClaudeProjectInfo(name: "AlphaProject", path: "/Users/test/AlphaProject"),
            ClaudeProjectInfo(name: "BetaProject", path: "/Users/test/BetaProject"),
            ClaudeProjectInfo(name: "GammaService", path: "/Users/test/GammaService"),
            ClaudeProjectInfo(name: "DeltaApp", path: "/Users/test/DeltaApp"),
        ]) -> ClaudeProjectScanner {
            ClaudeProjectScanner(scanProjects: { projects })
        }
    }

    // MARK: - DependencyKey

    extension ClaudeProjectScanner: DependencyKey {
        public static var previewValue: ClaudeProjectScanner {
            .inMemory()
        }

        public static var liveValue: ClaudeProjectScanner {
            let scanner = LiveClaudeProjectScanner()

            return ClaudeProjectScanner(
                scanProjects: {
                    await scanner.scanProjects()
                }
            )
        }
    }

    // MARK: - Live Implementation

    /// Actor that scans the filesystem for Claude projects.
    private actor LiveClaudeProjectScanner {
        private let logger = Logger(label: "com.claudespy.projectscanner")
        private let fileManager = FileManager.default

        private var claudeConfigPath: URL {
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        }

        private var claudeProjectsPath: URL {
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")
        }

        init() { }

        func scanProjects() async -> [ClaudeProjectInfo] {
            logger.debug("Scanning for Claude projects")

            guard let projectsData = readClaudeConfig() else {
                logger.info("No Claude config found or no projects in config")
                return []
            }

            var projects: [ClaudeProjectInfo] = []
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

            for (path, data) in projectsData {
                let projectURL = URL(fileURLWithPath: path).standardizedFileURL

                if projectURL == homeDirectory {
                    continue
                }

                if let project = validateProject(at: projectURL, data: data) {
                    projects.append(project)
                }
            }

            projects.sort { lhs, rhs in
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (nil, .some):
                    return false
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

        private func validateProject(at url: URL, data: [String: Any]) -> ClaudeProjectInfo? {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("Project directory does not exist: \(url.path)")
                return nil
            }

            let claudeDir = url.appendingPathComponent(".claude")
            guard
                fileManager.fileExists(atPath: claudeDir.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("No .claude directory in project: \(url.path)")
                return nil
            }

            let name = url.lastPathComponent
            let lastUsed = getLastUsedTimestamp(projectPath: url.path)

            return ClaudeProjectInfo(name: name, path: url.path, lastUsed: lastUsed)
        }

        private func getLastUsedTimestamp(projectPath: String) -> Date? {
            let folderName = projectPath.replacingOccurrences(of: "/", with: "-")
            let projectSessionDir = claudeProjectsPath.appendingPathComponent(folderName)

            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: projectSessionDir.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("No session directory for project: \(projectPath)")
                return nil
            }

            return mostRecentSessionDate(in: projectSessionDir)
        }

        private func mostRecentSessionDate(in directory: URL) -> Date? {
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                ) else {
                return nil
            }

            return contents
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> Date? in
                    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }
                .max()
        }
    }

#endif
