import Foundation

/// API representation of a tmux session.
public struct APISessionInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let windowCount: Int
    public let isAttached: Bool

    public init(id: String, name: String, windowCount: Int, isAttached: Bool) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
    }

    /// Encode this model into a JSONValue dictionary for JSON-RPC responses.
    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string(name),
            "window_count": .int(windowCount),
            "is_attached": .bool(isAttached),
        ]
    }
}

/// API representation of a tmux window.
public struct APIWindowInfo: Codable, Sendable {
    public let id: String
    public let index: Int
    public let name: String
    public let paneCount: Int
    public let isActive: Bool
    public let sessionId: String

    public init(id: String, index: Int, name: String, paneCount: Int, isActive: Bool, sessionId: String) {
        self.id = id
        self.index = index
        self.name = name
        self.paneCount = paneCount
        self.isActive = isActive
        self.sessionId = sessionId
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "index": .int(index),
            "name": .string(name),
            "pane_count": .int(paneCount),
            "is_active": .bool(isActive),
            "session_id": .string(sessionId),
        ]
    }
}

/// API representation of a tmux pane.
public struct APIPaneInfo: Codable, Sendable {
    public let id: String
    public let index: Int
    public let isActive: Bool
    public let command: String?
    public let cwd: String?
    public let width: Int
    public let height: Int
    public let windowId: String
    public let hasClaudeSession: Bool

    public init(
        id: String,
        index: Int,
        isActive: Bool,
        command: String?,
        cwd: String?,
        width: Int,
        height: Int,
        windowId: String,
        hasClaudeSession: Bool
    ) {
        self.id = id
        self.index = index
        self.isActive = isActive
        self.command = command
        self.cwd = cwd
        self.width = width
        self.height = height
        self.windowId = windowId
        self.hasClaudeSession = hasClaudeSession
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "index": .int(index),
            "is_active": .bool(isActive),
            "command": command.map { .string($0) } ?? .null,
            "cwd": cwd.map { .string($0) } ?? .null,
            "width": .int(width),
            "height": .int(height),
            "window_id": .string(windowId),
            "has_claude_session": .bool(hasClaudeSession),
        ]
    }
}

/// API response for the identify command.
public struct APIIdentifyInfo: Codable, Sendable {
    public let session: APISessionInfo?
    public let window: APIWindowInfo?
    public let pane: APIPaneInfo?

    public init(session: APISessionInfo?, window: APIWindowInfo?, pane: APIPaneInfo?) {
        self.session = session
        self.window = window
        self.pane = pane
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "session": session.map { .object($0.toJSONValue()) } ?? .null,
            "window": window.map { .object($0.toJSONValue()) } ?? .null,
            "pane": pane.map { .object($0.toJSONValue()) } ?? .null,
        ]
    }
}
