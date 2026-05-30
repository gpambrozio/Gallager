import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

/// Discovers Claude Code projects by scanning `~/.claude.json` +
/// `~/.claude/projects/` (plus any extra `.claude` config folders from
/// settings), producing agent-blind `AgentProject` entries tagged with this
/// plugin's id.
///
/// Ported faithfully from the legacy `ClaudeProjectScanner` /
/// `LiveClaudeProjectScanner` in `ClaudeSpyServerFeature/Services/`. As mandated
/// by spec §13 it parses real-world, possibly-hostile on-disk data, so every
/// read/decode is wrapped in `do/try/catch` with no force-unwraps — a malformed
/// `~/.claude.json` skips, it never traps.
///
/// `Sendable` value type with no stored state, so it is safe to use from the
/// `ClaudeCodePluginCore` actor and trivially unit-testable: the home directory
/// and extra folders are passed in, so a test can point it at a fixture dir.
struct ClaudeCodeScanner {
    private let fileManager = FileManager.default

    /// Scans `home` (and `additionalConfigFolders`) for Claude projects.
    ///
    /// - Parameters:
    ///   - home: The home directory whose `~/.claude.json` + `~/.claude/projects`
    ///     are scanned. Injected so tests can point at a temp fixture.
    ///   - additionalConfigFolders: Extra `.claude` config roots (from settings).
    /// - Returns: Discovered projects, most-recently-used first.
    func scan(home: URL, additionalConfigFolders: [String] = []) -> [AgentProject] {
        let homeStandardized = home.standardizedFileURL
        let scanRoots = roots(home: homeStandardized, additionalConfigFolders: additionalConfigFolders)

        var projectsByPath: [String: AgentProject] = [:]

        for scanRoot in scanRoots {
            guard let projectsData = readClaudeConfig(at: scanRoot.configPath) else { continue }

            for (path, data) in projectsData {
                let projectURL = URL(fileURLWithPath: path).standardizedFileURL

                // The home directory itself is never a project.
                if projectURL == homeStandardized { continue }

                guard
                    let project = validateProject(
                        at: projectURL,
                        data: data,
                        sessionBasePath: scanRoot.sessionBasePath,
                        configDir: scanRoot.configDir
                    )
                else { continue }

                if let existing = projectsByPath[project.path] {
                    if shouldReplace(existing: existing, with: project) {
                        projectsByPath[project.path] = project
                    }
                } else {
                    projectsByPath[project.path] = project
                }
            }
        }

        return Array(projectsByPath.values).sortedByLastUsed()
    }

    // MARK: - Scan roots

    /// A root folder to scan, with its config + session paths. `configDir` is the
    /// value surfaced on `AgentProject.configDir` (== legacy `CLAUDE_CONFIG_DIR`)
    /// for non-default roots; `nil` for the default `~/.claude` location.
    private struct ScanRoot {
        let configPath: URL
        let sessionBasePath: URL
        let configDir: String?
    }

    /// The default home root (`~/.claude.json` + `~/.claude/projects/`) plus any
    /// additional configured `.claude` folders. Additional folders use
    /// `<folder>/.claude.json` + `<folder>/projects/`, matching the layout Claude
    /// Code uses when `CLAUDE_CONFIG_DIR=<folder>`.
    private func roots(home: URL, additionalConfigFolders: [String]) -> [ScanRoot] {
        var roots = [
            ScanRoot(
                configPath: home.appendingPathComponent(".claude.json"),
                sessionBasePath: home
                    .appendingPathComponent(".claude")
                    .appendingPathComponent("projects"),
                configDir: nil
            ),
        ]

        for path in additionalConfigFolders {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let root = ScanRoot(
                configPath: url.appendingPathComponent(".claude.json"),
                sessionBasePath: url.appendingPathComponent("projects"),
                configDir: url.path
            )
            if !roots.contains(where: { $0.configPath == root.configPath }) {
                roots.append(root)
            }
        }

        return roots
    }

    /// Newer `lastUsed` wins when the same project path appears under two roots.
    private func shouldReplace(existing: AgentProject, with candidate: AgentProject) -> Bool {
        switch (existing.lastUsed, candidate.lastUsed) {
        case let (existingDate?, candidateDate?):
            candidateDate > existingDate
        case (nil, .some):
            true
        default:
            false
        }
    }

    // MARK: - Parsing (defensive — never traps)

    /// Reads the `projects` dictionary from a `.claude.json` file, tolerating a
    /// missing file, non-JSON content, or a missing `projects` key.
    private func readClaudeConfig(at configPath: URL) -> [String: [String: Any]]? {
        guard fileManager.fileExists(atPath: configPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: configPath)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let projectsDict = json["projects"] as? [String: [String: Any]] else {
                return nil
            }
            return projectsDict
        } catch {
            return nil
        }
    }

    /// Validates that a project path exists and is a directory, returning an
    /// `AgentProject` with its most-recent session timestamp.
    private func validateProject(
        at url: URL,
        data _: [String: Any],
        sessionBasePath: URL,
        configDir: String?
    ) -> AgentProject? {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        let lastUsed = lastUsedTimestamp(projectPath: url.path, sessionBasePath: sessionBasePath)

        return AgentProject(
            name: url.lastPathComponent,
            path: url.path,
            lastUsed: lastUsed,
            configDir: configDir,
            pluginID: ClaudeCodePluginCore.pluginID
        )
    }

    /// The mtime of the most recent `.jsonl` transcript for the project, or `nil`
    /// when no session directory / transcripts exist.
    private func lastUsedTimestamp(projectPath: String, sessionBasePath: URL) -> Date? {
        // Claude Code encodes the project path by replacing "/" with "-".
        let folderName = projectPath.replacingOccurrences(of: "/", with: "-")
        let projectSessionDir = sessionBasePath.appendingPathComponent(folderName)

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: projectSessionDir.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        return mostRecentSessionDate(in: projectSessionDir)
    }

    private func mostRecentSessionDate(in directory: URL) -> Date? {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )
        else { return nil }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> Date? in
                try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .max()
    }
}
