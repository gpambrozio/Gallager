import Foundation

/// Represents a tmux window containing one or more panes
public struct TmuxWindow: Identifiable, Sendable, Hashable {
    /// Unique identifier: "session:windowIndex"
    public let id: String
    /// The name of the session containing this window
    public let sessionName: String
    /// The window index within the session
    public let windowIndex: Int
    /// The name of the window (e.g., "bash", "vim")
    public let windowName: String
    /// The tmux layout string describing pane arrangement
    public let windowLayout: String
    /// The panes in this window, sorted by pane index
    public let panes: [PaneInfo]

    /// Whether this window has only a single pane
    public var isSinglePane: Bool { panes.count == 1 }

    /// The active pane in this window (the one marked as active by tmux)
    public var activePane: PaneInfo? { panes.first(where: \.isActive) ?? panes.first }

    /// Creates a TmuxWindow by grouping panes that share the same session and window index
    public init(sessionName: String, windowIndex: Int, windowName: String, windowLayout: String, panes: [PaneInfo]) {
        self.id = "\(sessionName):\(windowIndex)"
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.windowName = windowName
        self.windowLayout = windowLayout
        self.panes = panes.sorted { $0.paneIndex < $1.paneIndex }
    }

    /// Groups a flat list of panes into windows
    public static func groupPanes(_ panes: [PaneInfo]) -> [TmuxWindow] {
        let grouped = Dictionary(grouping: panes) { $0.windowId }
        return grouped.values.compactMap { windowPanes -> TmuxWindow? in
            guard let first = windowPanes.first else { return nil }
            return TmuxWindow(
                sessionName: first.sessionName,
                windowIndex: first.windowIndex,
                windowName: first.windowName,
                windowLayout: first.windowLayout,
                panes: windowPanes
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
