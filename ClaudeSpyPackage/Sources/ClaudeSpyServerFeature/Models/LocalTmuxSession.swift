import Foundation

/// Groups local tmux windows (LocalTmuxWindow) that belong to the same session.
///
/// Used by the macOS app for local tmux session management. For the shared
/// cross-platform session grouping (using TmuxWindow), see `TmuxSession` in ClaudeSpyCommon.
public struct LocalTmuxSession: Identifiable, Sendable, Hashable {
    /// Unique identifier: the session name
    public let sessionName: String

    /// Windows in this session, sorted by window index
    public let windows: [LocalTmuxWindow]

    public var id: String {
        sessionName
    }

    /// The active window in the tmux session, or the first window
    public var activeWindow: LocalTmuxWindow? {
        windows.first(where: \.isWindowActive) ?? windows.first
    }

    /// The window to show in the left pane, given the window ids currently
    /// parked on the right side of a split.
    ///
    /// Prefers the tmux-active window so an opened session lands on the window
    /// the user last used in tmux — not merely the window that happens to hold
    /// the agent pane (issue #653). Falls back to the first remaining left-side
    /// window, then the session's active window when every window is parked on
    /// the right.
    public func leftPaneWindow(excludingRightSide rightSideIds: Set<String>) -> LocalTmuxWindow? {
        let leftCandidates = windows.filter { !rightSideIds.contains($0.id) }
        return leftCandidates.first(where: \.isWindowActive)
            ?? leftCandidates.first
            ?? activeWindow
    }

    /// Groups windows by session and returns sorted sessions
    public static func groupWindows(_ windows: [LocalTmuxWindow]) -> [LocalTmuxSession] {
        let grouped = Dictionary(grouping: windows) { $0.sessionName }

        return grouped.map { name, sessionWindows in
            LocalTmuxSession(
                sessionName: name,
                windows: sessionWindows.sorted { $0.windowIndex < $1.windowIndex }
            )
        }
        .sorted { $0.sessionName < $1.sessionName }
    }
}
