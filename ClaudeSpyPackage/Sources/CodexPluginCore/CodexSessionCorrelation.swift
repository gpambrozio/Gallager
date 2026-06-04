import Foundation

/// Core-internal pane↔session correlation store for Codex (spec §12).
///
/// On a session-start event that carries a `TMUX_PANE`, the core persists
/// `<root>/<tmux_pane>.json` containing the Codex session id (plus cwd and
/// timestamp for diagnostics), so a later event that only carries a session id
/// can be resolved back to its pane. The default root is
/// `~/.claudespy/codex-sessions/`. This is core-internal — the app never reads
/// it.
///
/// Trap-free per spec §13: all reads/decodes tolerate missing or malformed
/// files. The root is injected so the write/read round-trip is unit-testable
/// against a temp directory.
struct CodexSessionCorrelation: Sendable {
    /// Directory holding the per-pane correlation files. Defaults to
    /// `~/.claudespy/codex-sessions/`.
    let root: URL

    /// `FileManager.default` is used inline (not stored) so the value stays a
    /// trivially-`Sendable` immutable struct — it's handed to the core actor and
    /// also held by the test, so it must cross isolation safely.
    private var fileManager: FileManager { .default }

    /// The default store rooted at `~/.claudespy/codex-sessions/`.
    static func live(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexSessionCorrelation {
        CodexSessionCorrelation(
            root: home
                .appendingPathComponent(".claudespy")
                .appendingPathComponent("codex-sessions")
        )
    }

    // MARK: - Record

    /// The persisted correlation record (snake_case on disk to match the
    /// language-agnostic bridge convention).
    struct Record: Codable, Equatable {
        let sessionID: String
        let cwd: String?
        let startedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case startedAt = "started_at"
        }
    }

    // MARK: - Write

    /// Persists `<root>/<tmuxPane>.json` for a session start. Best-effort and
    /// never throws (a write failure must not break event handling); returns
    /// `true` on success so callers/tests can assert.
    @discardableResult
    func record(sessionID: String, tmuxPane: String, cwd: String?, startedAt: Date? = Date()) -> Bool {
        guard !tmuxPane.isEmpty else { return false }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let record = Record(sessionID: sessionID, cwd: cwd, startedAt: startedAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: tmuxPane), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Read

    /// Reads the correlation record for a pane, or `nil` if absent/malformed.
    func record(forPane tmuxPane: String) -> Record? {
        guard !tmuxPane.isEmpty else { return nil }
        let url = fileURL(for: tmuxPane)
        guard
            let data = try? Data(contentsOf: url),
            !data.isEmpty
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    /// Every pane id that currently has a correlation file — i.e. a Codex session
    /// the core has recorded. Used by the session-end monitor to know which panes
    /// to watch for process exit. Returns the on-disk (sanitized) pane ids; tmux
    /// pane ids (`%N`) contain no path separators so they round-trip unchanged.
    func allPanes() -> Set<String> {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return Set(
            files
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    /// Resolves the tmux pane that owns a Codex session id, scanning the stored
    /// correlation files. `nil` when no file maps to that session id.
    func pane(forSessionID sessionID: String) -> String? {
        guard !sessionID.isEmpty else { return nil }
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let record = try? decoder.decode(Record.self, from: data),
                record.sessionID == sessionID
            else { continue }
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    // MARK: - Delete

    /// Deletes the correlation file for a pane (best-effort; called when the
    /// session ends so a future pane reuse starts clean). Never throws.
    func remove(pane tmuxPane: String) {
        guard !tmuxPane.isEmpty else { return }
        try? fileManager.removeItem(at: fileURL(for: tmuxPane))
    }

    // MARK: - Helpers

    /// Path of the correlation file for a pane. The pane id (e.g. `%3`) is
    /// sanitized so it is always a safe single path component.
    private func fileURL(for tmuxPane: String) -> URL {
        root.appendingPathComponent("\(Self.sanitize(tmuxPane)).json")
    }

    /// Replaces path separators in a pane id so it can't escape `root`.
    static func sanitize(_ pane: String) -> String {
        pane
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}
