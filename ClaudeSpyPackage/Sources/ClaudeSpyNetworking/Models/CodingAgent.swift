import Foundation

/// Identifies which coding-agent CLI a project or session belongs to.
///
/// ClaudeSpy originally targeted only Claude Code; this enum is the
/// hinge point for adding Codex CLI (and future agents) as additional
/// first-class backends. The raw values are stable on the wire and
/// must not be renumbered.
public enum CodingAgent: String, Codable, Sendable, CaseIterable, Hashable {
    /// Anthropic's Claude Code CLI (`claude`).
    case claudeCode = "claude-code"

    /// OpenAI's Codex CLI (`codex`).
    case codex

    /// Human-readable name used in notifications and UI copy.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Short label for the agent (e.g. "Claude", "Codex") used in tighter copy.
    public var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    /// Default CLI command (looked up on `PATH`) for launching this agent.
    public var defaultCommand: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }
}
