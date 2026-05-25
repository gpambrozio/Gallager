import Foundation
import GallagerPluginProtocol

// MARK: - IngressContext + Claude Code accessors

/// Claude-specific convenience accessors over `IngressContext.envMap`.
/// Codex's plugin core defines its own equivalents reading `CODEX_*` env
/// vars; the struct itself stays agent-blind in `GallagerPluginProtocol`.
public extension IngressContext {
    /// Project directory the agent was launched in. Sourced from
    /// `CLAUDE_PROJECT_DIR` — Claude Code injects this into the hook
    /// process env so the bridge can forward it verbatim.
    var projectPath: String? {
        envMap["CLAUDE_PROJECT_DIR"]
    }

    /// Claude Code session id, when supplied via env (rare — most hook
    /// payloads carry it in `body.session_id` instead).
    var sessionID: String? {
        envMap["CLAUDE_SESSION_ID"]
    }
}
