#if os(macOS)
    import ClaudeSpyCommon
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
        public var scanProjects: @Sendable () async -> [AgentProject] = { [] }
    }

    // MARK: - In-Memory

    public extension ClaudeProjectScanner {
        static func inMemory(projects: [AgentProject] = [
            AgentProject(name: "AlphaProject", path: "/Users/test/AlphaProject"),
            AgentProject(name: "BetaProject", path: "/Users/test/BetaProject"),
            AgentProject(name: "GammaService", path: "/Users/test/GammaService"),
            AgentProject(name: "DeltaApp", path: "/Users/test/DeltaApp"),
            AgentProject(name: "EpsilonHub", path: "/Users/test/EpsilonHub"),
            AgentProject(name: "IotaWeb", path: "/Users/test/IotaWeb"),
            AgentProject(name: "KappaCli", path: "/Users/test/KappaCli"),
            AgentProject(name: "MuShell", path: "/Users/test/MuShell"),
            AgentProject(name: "NuRunner", path: "/Users/test/NuRunner"),
            AgentProject(name: "SigmaLib", path: "/Users/test/SigmaLib"),
            AgentProject(name: "TauNode", path: "/Users/test/TauNode"),
            AgentProject(name: "ZetaCore", path: "/Users/test/ZetaCore"),
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
            @Dependency(PreferencesService.self) var preferences
            let scanner = LiveClaudeProjectScanner(preferences: preferences)

            return ClaudeProjectScanner(
                scanProjects: {
                    await scanner.scanProjects()
                }
            )
        }
    }

    // MARK: - Live Implementation

    /// Actor that scans the filesystem for Claude projects.
    ///
    /// Scans the default home directory plus any additional folders configured
    /// in preferences, merging and deduplicating results by project path.
    private actor LiveClaudeProjectScanner {
        private let logger = Logger(label: "com.claudespy.projectscanner")
        private let fileManager = FileManager.default
        private let preferences: PreferencesService

        init(preferences: PreferencesService) {
            self.preferences = preferences
        }

        func scanProjects() async -> [AgentProject] {
            logger.debug("Scanning for Claude projects")

            let scanRoots = allScanRoots()
            var projectsByPath: [String: AgentProject] = [:]
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

            for scanRoot in scanRoots {
                guard let projectsData = readClaudeConfig(at: scanRoot.configPath) else {
                    logger.debug("No Claude config found at \(scanRoot.configPath.path)")
                    continue
                }

                for (path, data) in projectsData {
                    let projectURL = URL(fileURLWithPath: path).standardizedFileURL

                    if projectURL == homeDirectory {
                        continue
                    }

                    if
                        let project = validateProject(
                            at: projectURL,
                            data: data,
                            sessionBasePath: scanRoot.sessionBasePath,
                            claudeConfigDir: scanRoot.claudeConfigDir
                        ) {
                        if let existing = projectsByPath[project.path] {
                            // Keep the entry with the most recent lastUsed date
                            if shouldReplace(existing: existing, with: project) {
                                projectsByPath[project.path] = project
                            }
                        } else {
                            projectsByPath[project.path] = project
                        }
                    }
                }
            }

            var projects = Array(projectsByPath.values)

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

            logger.info("Found \(projects.count) Claude projects across \(scanRoots.count) root(s)")
            return projects
        }

        // MARK: - Private Methods

        /// A root folder to scan, with its config and session paths.
        private struct ScanRoot {
            let configPath: URL
            let sessionBasePath: URL
            /// The value to use for `CLAUDE_CONFIG_DIR` when launching a project
            /// discovered under this root. `nil` for the default home location.
            let claudeConfigDir: String?
        }

        /// Returns all root folders to scan: the home directory plus any additional configured folders.
        ///
        /// The home directory uses `~/.claude.json` and `~/.claude/projects/`.
        /// Additional folders use `<folder>/.claude.json` and `<folder>/projects/`,
        /// matching the layout Claude Code uses when `CLAUDE_CONFIG_DIR=<folder>`.
        private func allScanRoots() -> [ScanRoot] {
            let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
            var roots = [
                ScanRoot(
                    configPath: home.appendingPathComponent(".claude.json"),
                    sessionBasePath: home
                        .appendingPathComponent(".claude")
                        .appendingPathComponent("projects"),
                    claudeConfigDir: nil
                ),
            ]

            if
                let data = preferences.data(AppSettings.Keys.additionalClaudeFolders.rawValue),
                let additional = try? JSONDecoder().decode([String].self, from: data) {
                for path in additional {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    let root = ScanRoot(
                        configPath: url.appendingPathComponent(".claude.json"),
                        sessionBasePath: url.appendingPathComponent("projects"),
                        claudeConfigDir: url.path
                    )
                    if !roots.contains(where: { $0.configPath == root.configPath }) {
                        roots.append(root)
                    }
                }
            }

            return roots
        }

        /// Whether a candidate project should replace an existing one (newer lastUsed wins).
        private func shouldReplace(existing: AgentProject, with candidate: AgentProject) -> Bool {
            switch (existing.lastUsed, candidate.lastUsed) {
            case let (existingDate?, candidateDate?):
                return candidateDate > existingDate
            case (nil, .some):
                return true
            default:
                return false
            }
        }

        private func readClaudeConfig(at configPath: URL) -> [String: [String: Any]]? {
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

        private func validateProject(
            at url: URL,
            data: [String: Any],
            sessionBasePath: URL,
            claudeConfigDir: String?
        ) -> AgentProject? {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("Project directory does not exist: \(url.path)")
                return nil
            }

            let name = url.lastPathComponent
            let lastUsed = getLastUsedTimestamp(projectPath: url.path, sessionBasePath: sessionBasePath)

            return AgentProject(
                name: name,
                path: url.path,
                lastUsed: lastUsed,
                claudeConfigDir: claudeConfigDir
            )
        }

        private func getLastUsedTimestamp(projectPath: String, sessionBasePath: URL) -> Date? {
            let folderName = projectPath.replacingOccurrences(of: "/", with: "-")
            let projectSessionDir = sessionBasePath.appendingPathComponent(folderName)

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
