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
