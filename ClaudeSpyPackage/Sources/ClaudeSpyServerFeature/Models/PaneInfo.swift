import ClaudeSpyNetworking
import Foundation

/// Information about a tmux pane
public struct PaneInfo: Identifiable, Sendable, Hashable {
    /// The tmux pane ID (e.g., "%5") - note: may not be unique across linked sessions
    public let paneId: String
    /// The full target string (e.g., "mysession:0.1") - used as unique identifier
    public let target: String

    /// Unique identifier for Identifiable conformance (uses target since paneId can repeat in linked sessions)
    public var id: String {
        target
    }

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
    /// The terminal title set via OSC escape sequences (empty string means default/unset)
    public let paneTitle: String
    /// The tmux window layout string (e.g., "d0c6,191x50,0,0{95x50,0,0,5,95x50,96,0,6}")
    public let windowLayout: String
    /// The tmux window name
    public let windowName: String
    /// Whether this pane's window is the active window in its session
    public let isWindowActive: Bool
    /// Custom description set via the tmux `@gallager-description` user option,
    /// resolved with tmux's window-over-session inheritance. `nil` if unset.
    public let customDescription: String?
    /// Custom color set via the tmux `@gallager-color` user option, resolved
    /// with tmux's window-over-session inheritance. `nil` if unset or if the
    /// stored value isn't a recognised `SessionColor` case.
    public let customColor: SessionColor?

    /// Window identifier combining session name and window index (e.g., "mysession:0")
    public var windowId: String {
        "\(sessionName):\(windowIndex)"
    }

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
        isActive: Bool,
        paneTitle: String = "",
        windowLayout: String = "",
        windowName: String = "",
        isWindowActive: Bool = false,
        customDescription: String? = nil,
        customColor: SessionColor? = nil
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
        self.paneTitle = paneTitle
        self.windowLayout = windowLayout
        self.windowName = windowName
        self.isWindowActive = isWindowActive
        self.customDescription = customDescription
        self.customColor = customColor
    }
}

public extension PaneInfo {
    /// Creates a PaneInfo from tmux format output
    /// Expected format: id|session|window|pane|command|path|width|height|active|title|layout|windowName|windowActive|customColor|customDescription
    /// `customColor` is a single token (no `|`) so it sits before `customDescription`,
    /// which may contain `|` and is rejoined from the trailing components.
    init?(fromTmuxOutput line: String) {
        let components = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 9 else { return nil }

        guard
            let windowIndex = Int(components[2]),
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
        self.paneTitle = components.count >= 10 ? components[9] : ""
        self.windowLayout = components.count >= 11 ? components[10] : ""
        self.windowName = components.count >= 12 ? components[11] : ""
        self.isWindowActive = components.count >= 13 ? components[12] == "1" : false
        if components.count >= 14 {
            // tmux only ever stores the canonical `rawValue` we wrote via
            // `set-option @gallager-color`, so go straight from rawValue
            // here. `parse(_:)` accepts CLI/API aliases like "violet" → purple
            // and would silently bridge them to a color tmux never persisted,
            // blurring the distinction between input parsing and storage.
            let raw = components[13]
            self.customColor = raw.isEmpty ? nil : SessionColor(rawValue: raw.lowercased())
        } else {
            self.customColor = nil
        }
        if components.count >= 15 {
            // Descriptions may contain `|`, so rejoin everything past the fixed fields
            // instead of only taking components[14].
            let description = components[14...].joined(separator: "|")
            self.customDescription = description.isEmpty ? nil : description
        } else {
            self.customDescription = nil
        }
        self.target = "\(sessionName):\(windowIndex).\(paneIndex)"
    }

    /// Creates a new PaneState from this pane's metadata.
    /// Claude session, terminal title, and yolo mode are left at defaults.
    func makePaneState() -> PaneState {
        PaneState(
            paneId: paneId,
            target: target,
            sessionName: sessionName,
            windowIndex: windowIndex,
            paneIndex: paneIndex,
            command: command,
            currentPath: currentPath,
            width: width,
            height: height,
            isActive: isActive,
            windowLayout: windowLayout,
            windowName: windowName,
            isWindowActive: isWindowActive,
            customDescription: customDescription,
            customColor: customColor
        )
    }

    /// Updates the tmux metadata fields of an existing PaneState, preserving
    /// Claude session, terminal title, yolo mode, and other runtime state.
    func updateMetadata(of state: inout PaneState) {
        state.target = target
        state.sessionName = sessionName
        state.windowIndex = windowIndex
        state.paneIndex = paneIndex
        state.command = command
        state.currentPath = currentPath
        state.width = width
        state.height = height
        state.isActive = isActive
        state.windowLayout = windowLayout
        state.windowName = windowName
        state.isWindowActive = isWindowActive
        state.customDescription = customDescription
        state.customColor = customColor
    }
}
