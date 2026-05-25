import Foundation
import GallagerPluginProtocol

// MARK: - IngressContext + Codex accessors

/// Codex-specific convenience accessors over `IngressContext.envMap`.
/// Symmetric to `IngressContext+ClaudeCode`. Codex's bridge script injects
/// the same shape of context (a `[String: String]` env map) so only the
/// recognized keys differ.
public extension IngressContext {
    /// Project directory the Codex CLI was launched in. Sourced from
    /// `CODEX_PROJECT_DIR` (Codex's env vocabulary differs from Claude's
    /// per `docs/codex-cli-integration-plan.md` §5). Falls back to `CWD`
    /// when Codex hasn't set the project-dir variable.
    var codexProjectPath: String? {
        if let value = envMap["CODEX_PROJECT_DIR"], !value.isEmpty {
            return value
        }
        return envMap["CWD"]
    }

    /// Codex session id, when supplied via env. Most hook payloads carry
    /// it in `body.session_id` instead.
    var codexSessionID: String? {
        envMap["CODEX_SESSION_ID"]
    }
}
