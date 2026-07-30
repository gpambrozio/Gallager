import ClaudeSpyNetworking
import Foundation

/// Groups tmux windows that belong to the same session.
///
/// Used on iOS to group remote windows by session, and available on macOS
/// for remote host display. For local tmux sessions on macOS, see `LocalTmuxSession`.
public struct TmuxSession: Identifiable, Sendable {
    /// Unique identifier: the session name
    public let sessionName: String

    /// Windows in this session, sorted by window index
    public let windows: [TmuxWindow]

    public var id: String {
        sessionName
    }

    /// The active window in the tmux session, or the first window
    public var activeWindow: TmuxWindow? {
        windows.first(where: \.isWindowActive) ?? windows.first
    }

    /// Whether any window in this session has a Claude session
    public var hasClaude: Bool {
        windows.contains(where: \.hasClaude)
    }

    /// The manual state override propagated from the host, if any pane in the
    /// session has one set (issue #695). See `customDescription` for the same
    /// any-pane scan rationale.
    public var cliSessionState: CLISessionState? {
        windows.lazy.flatMap(\.panes).compactMap(\.cliSessionState).first
    }

    /// The first agent session across the session's panes, if any.
    public var agentSession: AgentSession? {
        windows.lazy.flatMap(\.panes).compactMap(\.agentSession).first
    }

    /// The state bucket currently shown on the sidebar (manual override, else
    /// agent-derived), used to check the current item in the "Set State" menu.
    /// `nil` when the session shows the plain terminal glyph (issue #695).
    public var displayedState: CLISessionState? {
        CLISessionState.displayed(override: cliSessionState, agentState: agentSession?.state)
    }

    /// The custom description for this session.
    ///
    /// Persisted at session scope via the `@gallager-description` tmux user
    /// option, so every pane in the session reports the same value. We scan
    /// any pane in any window so a partial refresh on the active window
    /// doesn't briefly flip the value to nil.
    public var customDescription: String? {
        windows.compactMap(\.customDescription).first
    }

    /// The custom color for this session.
    ///
    /// Persisted at session scope via the `@gallager-color` tmux user option;
    /// see `customDescription` for the same any-pane fallback rationale.
    public var customColor: SessionColor? {
        windows.compactMap(\.customColor).first
    }

    /// The custom emoji icon for this session.
    ///
    /// Persisted at session scope via the `@gallager-emoji` tmux user option;
    /// see `customDescription` for the same any-pane fallback rationale.
    public var customEmoji: String? {
        windows.compactMap(\.customEmoji).first
    }

    /// Groups windows by session and returns sorted sessions
    public static func groupWindows(_ windows: [TmuxWindow]) -> [TmuxSession] {
        let grouped = Dictionary(grouping: windows) { $0.sessionName }

        return grouped.map { name, sessionWindows in
            TmuxSession(
                sessionName: name,
                windows: sessionWindows.sorted { $0.windowIndex < $1.windowIndex }
            )
        }
        .sorted { $0.sessionName < $1.sessionName }
    }
}
