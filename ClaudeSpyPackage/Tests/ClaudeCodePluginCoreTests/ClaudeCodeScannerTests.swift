import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Points the scanner at a temp fixture (`.claude.json` + `.claude/projects/`)
/// and asserts the produced `[AgentProject]`. Also covers the defensive paths
/// (missing / malformed config) that must never trap.
@Suite("ClaudeCodeScanner")
struct ClaudeCodeScannerTests {
    private let fileManager = FileManager.default

    /// Creates a throwaway home directory and returns its URL.
    private func makeTempHome() throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cc-scan-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Writes `~/.claude.json` with the given project paths and creates each
    /// project directory + an optional transcript so it validates.
    private func seed(
        home: URL,
        projectPaths: [String],
        createDirs: Bool = true,
        withTranscript: Bool = false
    ) throws {
        var projects: [String: [String: String]] = [:]
        for path in projectPaths {
            projects[path] = ["lastCost": "0"]
            if createDirs {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: path),
                    withIntermediateDirectories: true
                )
            }
            if withTranscript {
                let encoded = path.replacingOccurrences(of: "/", with: "-")
                let sessionDir = home
                    .appendingPathComponent(".claude")
                    .appendingPathComponent("projects")
                    .appendingPathComponent(encoded)
                try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: sessionDir.appendingPathComponent("session.jsonl"))
            }
        }
        let json = try JSONSerialization.data(withJSONObject: ["projects": projects])
        try json.write(to: home.appendingPathComponent(".claude.json"))
    }

    @Test("discovers projects from .claude.json and tags them with the plugin id")
    func discoversProjects() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }

        let projDir = home.appendingPathComponent("Work").appendingPathComponent("Alpha").path
        try seed(home: home, projectPaths: [projDir])

        let scanner = ClaudeCodeScanner()
        let projects = scanner.scan(home: home)

        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.name == "Alpha")
        #expect(project.path == URL(fileURLWithPath: projDir).standardizedFileURL.path)
        #expect(project.pluginID == ClaudeCodePluginCore.pluginID)
        #expect(project.configDir == nil) // default home root
    }

    @Test("skips project entries whose directory does not exist")
    func skipsMissingDirs() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }

        let realDir = home.appendingPathComponent("Real").path
        let ghostDir = home.appendingPathComponent("Ghost").path
        try seed(home: home, projectPaths: [realDir]) // create Real
        // Add Ghost to the config but don't create its directory.
        try seed(home: home, projectPaths: [realDir, ghostDir], createDirs: false)
        // Recreate Real (second seed used createDirs:false).
        try fileManager.createDirectory(at: URL(fileURLWithPath: realDir), withIntermediateDirectories: true)

        let projects = ClaudeCodeScanner().scan(home: home)
        #expect(projects.map(\.name).sorted() == ["Real"])
    }

    @Test("the home directory itself is never a project")
    func excludesHome() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }
        try seed(home: home, projectPaths: [home.path])
        let projects = ClaudeCodeScanner().scan(home: home)
        #expect(projects.isEmpty)
    }

    @Test("uses the most recent transcript mtime for lastUsed")
    func lastUsedFromTranscript() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }

        let projDir = home.appendingPathComponent("Timed").path
        try seed(home: home, projectPaths: [projDir], withTranscript: true)

        let projects = ClaudeCodeScanner().scan(home: home)
        #expect(projects.first?.lastUsed != nil)
    }

    @Test("additional config folders set configDir and are scanned")
    func additionalConfigFolders() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }

        // Extra root: <extra>/.claude.json + <extra>/projects.
        let extra = try makeTempHome()
        defer { try? fileManager.removeItem(at: extra) }
        let extraProjDir = extra.appendingPathComponent("Beta").path
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: extraProjDir),
            withIntermediateDirectories: true
        )
        let json = try JSONSerialization.data(
            withJSONObject: ["projects": [extraProjDir: ["lastCost": "0"]]]
        )
        try json.write(to: extra.appendingPathComponent(".claude.json"))

        // Empty default home config.
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let projects = ClaudeCodeScanner().scan(home: home, additionalConfigFolders: [extra.path])
        let beta = try #require(projects.first { $0.name == "Beta" })
        #expect(beta.configDir == extra.standardizedFileURL.path)
    }

    // MARK: - Defensive (never traps)

    @Test("missing .claude.json yields an empty list")
    func missingConfig() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }
        #expect(ClaudeCodeScanner().scan(home: home).isEmpty)
    }

    @Test("malformed .claude.json yields an empty list without trapping")
    func malformedConfig() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }
        try Data("{ this is not json".utf8).write(to: home.appendingPathComponent(".claude.json"))
        #expect(ClaudeCodeScanner().scan(home: home).isEmpty)
    }

    @Test(".claude.json without a projects key yields an empty list")
    func noProjectsKey() throws {
        let home = try makeTempHome()
        defer { try? fileManager.removeItem(at: home) }
        let json = try JSONSerialization.data(withJSONObject: ["other": "value"])
        try json.write(to: home.appendingPathComponent(".claude.json"))
        #expect(ClaudeCodeScanner().scan(home: home).isEmpty)
    }
}
