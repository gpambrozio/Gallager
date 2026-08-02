import ClaudeSpyNetworking
import Foundation

public extension PaneState {
    /// The menu-row title for an agent-owning pane: the user's session
    /// description when one is set (a session-scoped tmux option, so every
    /// sibling pane reports the same value), else the agent's project-derived
    /// display name. `nil` for a plain terminal — terminal-only rows title
    /// themselves via `TerminalOnlySession.displayTitle`. Lives here rather
    /// than on the wire model: it's menu-presentation logic, layered like its
    /// sibling `TerminalOnlySession+DisplayTitle`.
    var agentRowTitle: String? {
        guard let agentSession else { return nil }
        if let customDescription, !customDescription.isEmpty {
            return customDescription
        }
        return agentSession.displayName
    }
}
