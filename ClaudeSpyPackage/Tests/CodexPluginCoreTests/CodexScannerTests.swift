import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Points the scanner at a temp `sessions/YYYY/MM/DD/*.jsonl` fixture tree and
/// asserts the produced `[AgentProject]`. Also covers the defensive paths
/// (missing / malformed rollout) that must never trap.
@Suite("CodexScanner")
struct CodexScannerTests {
    private let fileManager = FileManager.default

    /// Creates a throwaway sessions root and returns its URL.
    private func makeTempSessions() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-scan-\(UUID().uuidString)")
            .appendingPathComponent("sessions")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a rollout `.jsonl` whose first line is a session-meta record with
    /// the given `cwd` / `started_at`, under `sessions/2026/05/21/`.
    @discardableResult
    private func seedRollout(
        sessionsRoot: URL,
        cwd: String,
        startedAt: String = "2026-05-21T10:00:00Z",
        day: (String, String, String) = ("2026", "05", "21"),
        fileName: String = "rollout-\(UUID().uuidString).jsonl"
    ) throws -> URL {
        let dayDir = sessionsRoot
            .appendingPathComponent(day.0)
            .appendingPathComponent(day.1)
            .appendingPathComponent(day.2)
        try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = """
        {"cwd": "\(cwd)", "started_at": "\(startedAt)", "session_id": "sess-\(UUID().uuidString)"}
        {"type": "message", "role": "user"}
        """
        let url = dayDir.appendingPathComponent(fileName)
        try Data(meta.utf8).write(to: url)
        return url
    }

    @Test("discovers a project from a rollout cwd and tags it with the plugin id")
    func discoversProject() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        // A real project directory the rollout points at.
        let projDir = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-proj-\(UUID().uuidString)")
            .appendingPathComponent("AlphaCodex")
        try fileManager.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projDir.deletingLastPathComponent()) }

        try seedRollout(sessionsRoot: sessions, cwd: projDir.path)

        let projects = CodexScanner().scan(sessionsRoot: sessions)
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.name == "AlphaCodex")
        #expect(project.path == projDir.standardizedFileURL.path)
        #expect(project.pluginID == CodexPluginCore.pluginID)
        #expect(project.configDir == nil)
        #expect(project.lastUsed != nil)
    }

    @Test("skips rollouts whose cwd directory does not exist")
    func skipsMissingDirs() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        try seedRollout(sessionsRoot: sessions, cwd: "/this/does/not/exist-\(UUID().uuidString)")

        let projects = CodexScanner().scan(sessionsRoot: sessions)
        #expect(projects.isEmpty)
    }

    @Test("the home directory itself is never a project")
    func excludesHome() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let home = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-home-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        try seedRollout(sessionsRoot: sessions, cwd: home.path)

        let projects = CodexScanner().scan(sessionsRoot: sessions, home: home)
        #expect(projects.isEmpty)
    }

    @Test("aggregates multiple rollouts for the same project and keeps the newest started_at")
    func aggregatesByProject() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let projDir = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-proj-\(UUID().uuidString)")
            .appendingPathComponent("BetaCodex")
        try fileManager.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projDir.deletingLastPathComponent()) }

        try seedRollout(sessionsRoot: sessions, cwd: projDir.path, startedAt: "2026-05-21T09:00:00Z")
        try seedRollout(sessionsRoot: sessions, cwd: projDir.path, startedAt: "2026-05-21T12:00:00Z")

        let projects = CodexScanner().scan(sessionsRoot: sessions)
        #expect(projects.count == 1)
        let newest = ISO8601DateFormatter().date(from: "2026-05-21T12:00:00Z")
        #expect(projects.first?.lastUsed == newest)
    }

    @Test("sorts most-recently-used first across projects")
    func sortsByRecency() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let base = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-proj-\(UUID().uuidString)")
        let older = base.appendingPathComponent("Older")
        let newer = base.appendingPathComponent("Newer")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        try seedRollout(sessionsRoot: sessions, cwd: older.path, startedAt: "2026-05-20T10:00:00Z")
        try seedRollout(sessionsRoot: sessions, cwd: newer.path, startedAt: "2026-05-21T10:00:00Z")

        let projects = CodexScanner().scan(sessionsRoot: sessions)
        #expect(projects.map(\.name) == ["Newer", "Older"])
    }

    // MARK: - Defensive (never traps)

    @Test("a missing sessions directory yields an empty list")
    func missingSessions() {
        let ghost = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-ghost-\(UUID().uuidString)")
            .appendingPathComponent("sessions")
        #expect(CodexScanner().scan(sessionsRoot: ghost).isEmpty)
    }

    @Test("a malformed rollout is skipped without trapping")
    func malformedRollout() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let dayDir = sessions
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("21")
        try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try Data("{ this is not json\nplus more garbage".utf8)
            .write(to: dayDir.appendingPathComponent("rollout-bad.jsonl"))

        #expect(CodexScanner().scan(sessionsRoot: sessions).isEmpty)
    }

    @Test("a rollout with no cwd is skipped")
    func rolloutWithoutCwd() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let dayDir = sessions
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("21")
        try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try Data(#"{"started_at": "2026-05-21T10:00:00Z"}"#.utf8)
            .write(to: dayDir.appendingPathComponent("rollout-nocwd.jsonl"))

        #expect(CodexScanner().scan(sessionsRoot: sessions).isEmpty)
    }

    @Test("falls back to a recursive scan when the YYYY/MM/DD layout is absent")
    func recursiveFallback() throws {
        let sessions = try makeTempSessions()
        defer { try? fileManager.removeItem(at: sessions.deletingLastPathComponent()) }

        let projDir = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-proj-\(UUID().uuidString)")
            .appendingPathComponent("FlatLayout")
        try fileManager.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projDir.deletingLastPathComponent()) }

        // Rollout placed directly under sessions/ (no date partitions).
        let meta = #"{"cwd": "\#(projDir.path)", "started_at": "2026-05-21T10:00:00Z"}"#
        try Data(meta.utf8).write(to: sessions.appendingPathComponent("rollout-flat.jsonl"))

        let projects = CodexScanner().scan(sessionsRoot: sessions)
        #expect(projects.map(\.name) == ["FlatLayout"])
    }
}
