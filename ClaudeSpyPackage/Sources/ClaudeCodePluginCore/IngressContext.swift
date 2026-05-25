import Foundation

// MARK: - IngressContext

/// Context the bridge script attaches to every raw hook payload.
///
/// The bridge writes a length-prefixed JSON frame onto the sidecar's
/// ingress socket; the `context` member is a `[String: String]` env-var
/// snapshot harvested from the host agent's process (`TMUX_PANE`,
/// `CLAUDE_PROJECT_DIR`, `CLAUDE_SESSION_ID`, etc.). The translator
/// consults the convenience accessors below to populate `PluginEvent`
/// fields that don't live in the raw payload (specifically the per-event
/// `sessionID`, which is derived from the payload's `session_id` field,
/// and the per-event `projectPath` used inside notification copy).
public struct IngressContext: Sendable, Equatable {
    /// Raw environment map shipped by the bridge script. Keys are
    /// uppercase env-var names (e.g. `"TMUX_PANE"`); values are the
    /// literal env-var values.
    public let envMap: [String: String]

    public init(envMap: [String: String]) {
        self.envMap = envMap
    }

    /// Project directory the agent was launched in. Sourced from
    /// `CLAUDE_PROJECT_DIR` — Claude Code injects this into the hook
    /// process env so the bridge can forward it verbatim.
    public var projectPath: String? {
        envMap["CLAUDE_PROJECT_DIR"]
    }

    /// tmux pane id the agent is running inside. Sourced from
    /// `TMUX_PANE`.
    public var tmuxPane: String? {
        envMap["TMUX_PANE"]
    }

    /// Claude Code session id, when supplied via env (rare — most hook
    /// payloads carry it in `body.session_id` instead).
    public var sessionID: String? {
        envMap["CLAUDE_SESSION_ID"]
    }
}
