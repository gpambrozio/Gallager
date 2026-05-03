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

    /// The custom description for this session (from the active window)
    public var customDescription: String? {
        activeWindow?.customDescription
    }

    /// The custom color for this session (from the active window)
    public var customColor: SessionColor? {
        activeWindow?.customColor
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
