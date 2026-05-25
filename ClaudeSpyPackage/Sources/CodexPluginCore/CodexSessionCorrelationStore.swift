import ClaudeSpyNetworking
import Dependencies
import DependenciesMacros
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - CodexCorrelationError

/// Errors thrown by `CodexSessionCorrelationStore.record(...)`. The
/// translator surfaces these as decoding errors so the sidecar can log
/// and continue without crashing on disk-write failures.
public enum CodexCorrelationError: Error, LocalizedError, Sendable, Equatable {
    /// Unconfigured dependency: the test fixture forgot to override the
    /// dependency before exercising the translator. Mirrors the
    /// `reportIssue` pattern used by other `@DependencyClient`s.
    case unimplemented

    /// Wrapped underlying error (typically a `FileManager` failure).
    /// We model it as a string so the type stays `Sendable` + `Equatable`.
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unimplemented:
            "CodexSessionCorrelationStore.record was not implemented"
        case let .ioFailed(message):
            "CodexSessionCorrelationStore.record failed: \(message)"
        }
    }
}

// MARK: - CodexSessionCorrelationStore

/// Per Spec §17.2 Codex audit footnote: when the Codex sidecar parses a
/// `SessionStart`, it also writes a sidecar correlation file at
/// `~/.claudespy/codex-sessions/<tmux_pane>.json`. The Mac app reads this
/// to correlate a Codex session id back to the tmux pane it lives in.
///
/// This client is the abstraction layer over the actual disk write so tests
/// can supply a recording mock without touching the user's `~/.claudespy/`
/// directory.
@DependencyClient
public struct CodexSessionCorrelationStore: Sendable {
    /// Writes the JSON payload Codex emits on `SessionStart` to disk at
    /// `~/.claudespy/codex-sessions/<tmuxPane>.json`. `tmuxPane` is the
    /// pane id reported via `TMUX_PANE` (e.g. `%7`). The payload is
    /// stored verbatim (whatever shape the bridge script forwarded) so
    /// future readers can pull out `session_id` / `cwd` / `pid` /
    /// `started_at`.
    public var record: @Sendable (
        _ tmuxPane: String,
        _ payload: JSONValue
    ) async throws -> Void = { _, _ in
        reportIssue("record")
        throw CodexCorrelationError.unimplemented
    }
}

// MARK: - DependencyKey

extension CodexSessionCorrelationStore: DependencyKey {
    public static let liveValue: Self = .live(rootOverride: nil)

    public static var previewValue: Self {
        .init(record: { _, _ in })
    }

    /// Configurable variant used by tests that need to point the live
    /// implementation at a temporary directory instead of `~/.claudespy/`.
    public static func live(rootOverride: URL? = nil) -> Self {
        let logger = Logger(label: "com.claudespy.codex.correlation")
        return CodexSessionCorrelationStore(
            record: { tmuxPane, payload in
                let dir = rootOverride
                    ?? FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".claudespy", isDirectory: true)
                    .appendingPathComponent("codex-sessions", isDirectory: true)
                try await Task.detached(priority: .utility) { () throws in
                    do {
                        try FileManager.default.createDirectory(
                            at: dir,
                            withIntermediateDirectories: true
                        )
                        let fileName = sanitizedFileName(for: tmuxPane)
                        let url = dir.appendingPathComponent(fileName)
                        let data = try JSONEncoder().encode(payload)
                        try data.write(to: url, options: [.atomic])
                        logger.debug(
                            "Wrote Codex correlation",
                            metadata: ["pane": .string(tmuxPane), "path": .string(url.path)]
                        )
                    } catch {
                        throw CodexCorrelationError.ioFailed(String(describing: error))
                    }
                }.value
            }
        )
    }

    /// Replaces `%`-prefixed pane ids with safe filenames. tmux pane ids
    /// look like `%7`; on disk we store them as `pct7.json` to avoid
    /// shell-expansion footguns. Any other characters that aren't
    /// alphanumeric, `-`, or `_` are URL-percent-encoded as a fallback.
    private static func sanitizedFileName(for tmuxPane: String) -> String {
        var sanitized = tmuxPane
        if sanitized.hasPrefix("%") {
            sanitized = "pct" + String(sanitized.dropFirst())
        }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let escaped = sanitized.addingPercentEncoding(withAllowedCharacters: allowed) ?? sanitized
        return "\(escaped).json"
    }
}
