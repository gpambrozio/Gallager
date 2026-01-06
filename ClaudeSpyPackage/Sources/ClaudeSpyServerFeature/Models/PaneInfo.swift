import Foundation

/// Information about a tmux pane
public struct PaneInfo: Identifiable, Sendable, Hashable {
    /// The tmux pane ID (e.g., "%5") - note: may not be unique across linked sessions
    public let paneId: String
    /// The full target string (e.g., "mysession:0.1") - used as unique identifier
    public let target: String

    /// Unique identifier for Identifiable conformance (uses target since paneId can repeat in linked sessions)
    public var id: String { target }
    /// The name of the session containing this pane
    public let sessionName: String
    /// The window index within the session
    public let windowIndex: Int
    /// The pane index within the window
    public let paneIndex: Int
    /// The command currently running in the pane
    public let command: String
    /// The current working directory of the pane
    public let currentPath: String
    /// Width of the pane in columns
    public let width: Int
    /// Height of the pane in rows
    public let height: Int
    /// Whether this pane is the active pane in its window
    public let isActive: Bool

    public init(
        paneId: String,
        target: String,
        sessionName: String,
        windowIndex: Int,
        paneIndex: Int,
        command: String,
        currentPath: String,
        width: Int,
        height: Int,
        isActive: Bool
    ) {
        self.paneId = paneId
        self.target = target
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
        self.command = command
        self.currentPath = currentPath
        self.width = width
        self.height = height
        self.isActive = isActive
    }
}

extension PaneInfo {
    /// Creates a PaneInfo from tmux format output
    /// Expected format: id|session|window|pane|command|path|width|height|active
    public init?(fromTmuxOutput line: String) {
        let components = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 9 else { return nil }

        guard let windowIndex = Int(components[2]),
              let paneIndex = Int(components[3]),
              let width = Int(components[6]),
              let height = Int(components[7])
        else { return nil }

        self.paneId = components[0]
        self.sessionName = components[1]
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
        self.command = components[4]
        self.currentPath = components[5]
        self.width = width
        self.height = height
        self.isActive = components[8] == "1"
        self.target = "\(sessionName):\(windowIndex).\(paneIndex)"
    }
}
