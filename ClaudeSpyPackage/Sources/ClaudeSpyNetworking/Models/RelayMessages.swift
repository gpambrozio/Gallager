import Foundation

// MARK: - Hook Event Relay

/// A hook event wrapped for relay through the external server
public struct HookEventMessage: Codable, Sendable {
    public let pairId: String
    public let event: HookEvent

    public init(pairId: String, event: HookEvent) {
        self.pairId = pairId
        self.event = event
    }

    /// Project name extracted from the event's project path
    public var projectName: String? {
        guard let projectPath = event.projectPath, !projectPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }
}

// MARK: - Session State

/// Complete session state for sync between host and viewer
public struct SessionStateMessage: Codable, Sendable {
    public let pairId: String
    /// Unified per-pane state keyed by pane ID
    public let paneStates: [String: PaneState]
    /// Discovered Claude projects on the host
    public let claudeProjects: [ClaudeProjectInfo]?

    public init(
        pairId: String,
        paneStates: [String: PaneState],
        claudeProjects: [ClaudeProjectInfo]? = nil
    ) {
        self.pairId = pairId
        self.paneStates = paneStates
        self.claudeProjects = claudeProjects
    }
}

// MARK: - Pane State

/// Unified per-pane state combining tmux metadata, Claude session info, and runtime flags.
/// Used both locally on macOS and over the wire for iOS viewer sync.
public struct PaneState: Codable, Sendable, Identifiable {
    // MARK: - Tmux Pane Identity & Metadata

    /// The tmux pane ID (e.g., "%0", "%5")
    public let paneId: String

    /// The full target string (e.g., "mysession:0.1")
    public var target: String

    /// The session name containing this pane
    public var sessionName: String

    /// The window index within the session
    public var windowIndex: Int

    /// The pane index within the window
    public var paneIndex: Int

    /// The command currently running in the pane
    public var command: String?

    /// The current working directory of the pane
    public var currentPath: String?

    /// Width of the pane in columns
    public var width: Int

    /// Height of the pane in rows
    public var height: Int

    /// Whether this pane is the active pane in its window
    public var isActive: Bool

    /// The tmux window layout string for this pane's window
    public var windowLayout: String

    /// The tmux window name for this pane's window
    public var windowName: String

    /// Whether this pane's window is the active window in its session
    public var isWindowActive: Bool

    // MARK: - Custom Description

    /// User-defined description for this window, shown prominently in the sidebar
    public var customDescription: String?

    // MARK: - Terminal State

    /// Terminal title detected via OSC escape sequences
    public var terminalTitle: String?

    // MARK: - Claude Session

    /// The Claude Code session running in this pane, if any
    public var claudeSession: ClaudeSession?

    // MARK: - Behavior Flags

    /// Whether yolo mode is enabled (auto-approve permissions)
    public var yoloMode: Bool

    // MARK: - Computed Properties

    public var id: String { paneId }

    /// Window identifier combining session name and window index (e.g., "mysession:0")
    public var windowId: String { "\(sessionName):\(windowIndex)" }

    public init(
        paneId: String,
        target: String = "",
        sessionName: String = "",
        windowIndex: Int = 0,
        paneIndex: Int = 0,
        command: String? = nil,
        currentPath: String? = nil,
        width: Int = 80,
        height: Int = 24,
        isActive: Bool = false,
        windowLayout: String = "",
        windowName: String = "",
        isWindowActive: Bool = false,
        customDescription: String? = nil,
        terminalTitle: String? = nil,
        claudeSession: ClaudeSession? = nil,
        yoloMode: Bool = false
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
        self.windowLayout = windowLayout
        self.windowName = windowName
        self.isWindowActive = isWindowActive
        self.customDescription = customDescription
        self.terminalTitle = terminalTitle
        self.claudeSession = claudeSession
        self.yoloMode = yoloMode
    }
}

// MARK: - Push Notification Token

/// Message from viewer to register a push notification token
public struct RegisterPushTokenMessage: Codable, Sendable {
    /// The APNs device token as a hex string
    public let deviceToken: String

    public init(deviceToken: String) {
        self.deviceToken = deviceToken
    }
}

/// Server response to push token registration
public struct PushTokenRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}

// MARK: - Claude Projects

/// Information about a discovered Claude project
public struct ClaudeProjectInfo: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (based on path)
    public var id: String { path }

    /// Project name (last component of path)
    public let name: String

    /// Full path to project directory
    public let path: String

    /// Timestamp of last activity in this project (for sorting by recency)
    public let lastUsed: Date?

    public init(name: String, path: String, lastUsed: Date? = nil) {
        self.name = name
        self.path = path
        self.lastUsed = lastUsed
    }
}

// MARK: - Viewer Connection Notifications

/// Message sent when a paired viewer connects, includes public key for E2EE session establishment
public struct ViewerConnectedMessage: Codable, Sendable {
    /// Base64-encoded public key of the connecting viewer
    public let publicKey: String

    /// Unique identifier for the public key
    public let publicKeyId: String

    public init(publicKey: String, publicKeyId: String) {
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
    }
}
