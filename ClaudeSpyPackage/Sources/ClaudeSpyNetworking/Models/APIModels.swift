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

/// API representation of a Claude project discovered on the host.
public struct APIProjectInfo: Codable, Sendable {
    /// Shared ISO8601 formatter to avoid per-call allocation in `toJSONValue()`.
    /// Note: `nonisolated(unsafe)` is safe here because we never mutate the formatter after creation.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public let id: String
    public let name: String
    public let path: String
    public let lastUsed: Date?
    public let agent: CodingAgent

    public init(id: String, name: String, path: String, lastUsed: Date?, agent: CodingAgent = .claudeCode) {
        self.id = id
        self.name = name
        self.path = path
        self.lastUsed = lastUsed
        self.agent = agent
    }

    public init(_ info: AgentProject) {
        self.id = info.id
        self.name = info.name
        self.path = info.path
        self.lastUsed = info.lastUsed
        // The CLI's wire shape still uses the legacy `agent` field — map
        // the plugin id back to a CodingAgent so existing scripts keep
        // working. Unknown plugin ids fall back to .claudeCode (the CLI
        // historically only saw `.claudeCode` / `.codex`).
        self.agent = CodingAgent(rawValue: info.pluginID) ?? .claudeCode
    }

    public func toJSONValue() -> [String: JSONValue] {
        var dict: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "path": .string(path),
            "agent": .string(agent.rawValue),
        ]
        if let lastUsed {
            dict["last_used"] = .string(Self.iso8601.string(from: lastUsed))
        } else {
            dict["last_used"] = .null
        }
        return dict
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
