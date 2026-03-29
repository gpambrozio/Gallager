import ClaudeSpyNetworking
import Foundation

/// Groups pane states that belong to the same tmux window.
///
/// Used on iOS to group remote pane states by window, and available on macOS
/// for remote host display. For local tmux windows on macOS, see `LocalTmuxWindow`.
public struct TmuxWindow: Identifiable, Sendable {
    /// Unique identifier: "sessionName:windowIndex"
    public let id: String
    /// The session name
    public let sessionName: String
    /// The window index within the session
    public let windowIndex: Int
    /// The tmux window name
    public let windowName: String
    /// The tmux window layout string
    public let windowLayout: String
    /// Whether this is the active window in its session
    public let isWindowActive: Bool
    /// Pane states in this window, sorted by pane index
    public let panes: [PaneState]

    /// Whether this window has only a single pane
    public var isSinglePane: Bool { panes.count == 1 }

    /// The active pane in this window, or the first pane if none is active
    public var activePane: PaneState? {
        panes.first(where: \.isActive) ?? panes.first
    }

    /// Whether any pane in this window has a Claude session
    public var hasClaude: Bool {
        panes.contains { $0.claudeSession != nil }
    }

    /// The custom description for this window (from any pane, since descriptions are per-window)
    public var customDescription: String? {
        panes.first(where: { $0.customDescription != nil })?.customDescription
    }

    /// Groups pane states by window and returns sorted windows
    public static func groupPanes(_ paneStates: [PaneState]) -> [TmuxWindow] {
        let grouped = Dictionary(grouping: paneStates) { $0.windowId }

        return grouped.compactMap { windowId, windowPanes -> TmuxWindow? in
            guard let first = windowPanes.first else { return nil }
            let sortedPanes = windowPanes.sorted { $0.paneIndex < $1.paneIndex }
            return TmuxWindow(
                id: windowId,
                sessionName: first.sessionName,
                windowIndex: first.windowIndex,
                windowName: first.windowName,
                windowLayout: first.windowLayout,
                isWindowActive: first.isWindowActive,
                panes: sortedPanes
            )
        }
        .sorted { lhs, rhs in
            if lhs.sessionName != rhs.sessionName {
                return lhs.sessionName < rhs.sessionName
            }
            return lhs.windowIndex < rhs.windowIndex
        }
    }
}
