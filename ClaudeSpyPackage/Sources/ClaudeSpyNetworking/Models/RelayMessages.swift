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
    public let sessions: [String: ClaudeSession]
    public let activePanes: [String]
    /// All tmux panes (including those without Claude sessions)
    public let panes: [PaneInfoMessage]?
    /// Discovered Claude projects on the host
    public let claudeProjects: [ClaudeProjectInfo]?
    /// Pane IDs with yolo mode enabled on the host
    public let yoloModePanes: [String]?

    public init(
        pairId: String,
        sessions: [String: ClaudeSession],
        activePanes: [String],
        panes: [PaneInfoMessage]? = nil,
        claudeProjects: [ClaudeProjectInfo]? = nil,
        yoloModePanes: [String]? = nil
    ) {
        self.pairId = pairId
        self.sessions = sessions
        self.activePanes = activePanes
        self.panes = panes
        self.claudeProjects = claudeProjects
        self.yoloModePanes = yoloModePanes
    }
}

// MARK: - Pane Info for Viewer

/// Simplified pane information for viewer display
public struct PaneInfoMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let target: String
    public let sessionName: String
    public let windowIndex: Int
    public let paneIndex: Int
    public let command: String?
    public let currentPath: String?
    public let width: Int
    public let height: Int
    public let isActive: Bool
    public let windowLayout: String?
    public let windowName: String?

    public init(
        id: String,
        target: String,
        sessionName: String,
        windowIndex: Int,
        paneIndex: Int,
        command: String? = nil,
        currentPath: String? = nil,
        width: Int,
        height: Int,
        isActive: Bool,
        windowLayout: String? = nil,
        windowName: String? = nil
    ) {
        self.id = id
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
