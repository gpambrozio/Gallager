import Foundation

// MARK: - IngressContext

/// Context the bridge script attaches to every raw hook payload.
///
/// The bridge writes a length-prefixed JSON frame onto the sidecar's
/// ingress socket; the `context` member is a `[String: String]` env-var
/// snapshot harvested from the host agent's process (`TMUX_PANE` plus
/// any agent-specific keys like `CLAUDE_PROJECT_DIR` or `CODEX_SESSION_ID`).
/// The translator consults the convenience accessors below to populate
/// `PluginEvent` fields that don't live in the raw payload.
///
/// This type is agent-blind: only the `TMUX_PANE` accessor lives here.
/// Per-agent accessors (e.g. `projectPath` reading `CLAUDE_PROJECT_DIR`)
/// are added as extensions in each plugin's core module.
public struct IngressContext: Sendable, Equatable {
    /// Raw environment map shipped by the bridge script. Keys are
    /// uppercase env-var names (e.g. `"TMUX_PANE"`); values are the
    /// literal env-var values.
    public let envMap: [String: String]

    public init(envMap: [String: String]) {
        self.envMap = envMap
    }

    /// tmux pane id the agent is running inside. Sourced from
    /// `TMUX_PANE` — every agent's bridge script forwards this verbatim.
    public var tmuxPane: String? {
        envMap["TMUX_PANE"]
    }
}
