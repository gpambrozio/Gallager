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

/// Complete session state for sync between Mac and iOS
public struct SessionStateMessage: Codable, Sendable {
    public let pairId: String
    public let sessions: [String: ClaudeSession]
    public let activePanes: [String]

    public init(pairId: String, sessions: [String: ClaudeSession], activePanes: [String]) {
        self.pairId = pairId
        self.sessions = sessions
        self.activePanes = activePanes
    }
}

// MARK: - Pane Info for iOS

/// Simplified pane information for iOS display
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
        isActive: Bool
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
    }
}

// MARK: - Push Notification Token

/// Message from iOS to register a push notification token
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

// MARK: - Device Connection Notifications

/// Message sent when a paired device connects, includes public key for E2EE session establishment
public struct DeviceConnectedMessage: Codable, Sendable {
    /// Base64-encoded public key of the connecting device
    public let publicKey: String

    /// Unique identifier for the public key
    public let publicKeyId: String

    public init(publicKey: String, publicKeyId: String) {
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
    }
}
