import Foundation

/// Groups panes that belong to the same tmux window
public struct TmuxWindow: Identifiable, Sendable, Hashable {
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
    /// Panes in this window, sorted by pane index
    public let panes: [PaneInfo]

    /// Whether this window has only a single pane
    public var isSinglePane: Bool { panes.count == 1 }

    /// The active pane in this window, or the first pane if none is active
    public var activePane: PaneInfo? {
        panes.first(where: \.isActive) ?? panes.first
    }

    /// Groups panes by window and returns sorted windows
    public static func groupPanes(_ panes: [PaneInfo]) -> [TmuxWindow] {
        let grouped = Dictionary(grouping: panes) { $0.windowId }

        return grouped.compactMap { windowId, windowPanes -> TmuxWindow? in
            guard let first = windowPanes.first else { return nil }
            let sortedPanes = windowPanes.sorted { $0.paneIndex < $1.paneIndex }
            return TmuxWindow(
                id: windowId,
                sessionName: first.sessionName,
                windowIndex: first.windowIndex,
                windowName: first.windowName,
                windowLayout: first.windowLayout,
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
