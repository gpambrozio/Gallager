import Foundation

// MARK: - Date Parsing

/// Private date formatter for parsing ISO8601 timestamps
private enum ISO8601Parser {
    /// ISO8601 formatter for parsing timestamps like "2026-01-03T19:00:56.425838"
    /// Note: nonisolated(unsafe) is safe here because we never mutate the formatter after creation
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return formatter.date(from: string)
    }
}

// MARK: - Claude Session

/// Tracks a Claude Code session and its recent hook events
public struct ClaudeSession: Codable, Sendable {
    /// Maximum number of events to retain per session
    private static let maxEvents = 5

    /// The pane ID this session is associated with
    public let paneId: String

    /// Recent hook events, newest first, limited to last 5
    public private(set) var events: [HookEvent] = []

    public init(paneId: String) {
        self.paneId = paneId
    }

    /// Adds an event to the session, keeping only the last 5
    public mutating func addEvent(_ event: HookEvent) {
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast()
        }
    }

    /// The most recent event, if any
    public var latestEvent: HookEvent? {
        events.first
    }
}

// MARK: - Hook Event

/// Represents a received hook event with metadata
public struct HookEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: HookAction
    public let projectPath: String?
    public let tmuxPane: String?

    public init(
        action: HookAction,
        projectPath: String?,
        tmuxPane: String?
    ) {
        self.id = UUID()
        // Use timestamp from action if available, otherwise fall back to current time
        self.timestamp = action.timestamp ?? Date()
        self.action = action
        self.projectPath = projectPath
        self.tmuxPane = tmuxPane
    }
}

// MARK: - Hook Body Protocol

public protocol HookBodyProtocol: Codable, Sendable {
    var sessionId: String { get }
    var hookEventName: String { get }
    var timestamp: String? { get }
}

// MARK: - Common Hook Fields

/// Fields common to all hook payloads from Claude Code
public struct CommonHookFields: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
    }
}

// MARK: - Hook Body Types

public struct SessionStartBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case source
    }
}

public struct PreToolUseBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)

        // Decode tool_input based on tool_name
        if container.contains(.toolInput) {
            toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            toolInput = nil
        }
    }
}

public struct SessionEndBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let stopHookActive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case stopHookActive = "stop_hook_active"
    }
}

public struct PermissionRequestBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let permissionMode: String?
    public let toolName: String?
    public let toolInput: AnyCodable?
    public let permissionSuggestions: [PermissionSuggestion]?
    public let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
        case timestamp
    }
}

// MARK: - Permission Suggestion Types

public struct PermissionSuggestion: Codable, Sendable {
    public let type: String?
    public let rules: [PermissionRule]?
    public let behavior: String?
    public let destination: String?
}

public struct PermissionRule: Codable, Sendable {
    public let toolName: String?
    public let ruleContent: String?

    enum CodingKeys: String, CodingKey {
        case toolName
        case ruleContent
    }
}

// MARK: - Hook Action Enum

public enum HookAction: Codable, Sendable {
    case sessionStart(SessionStartBody)
    case preToolUse(PreToolUseBody)
    case sessionEnd(SessionEndBody)
    case permissionRequest(PermissionRequestBody)
    case unknown(CommonHookFields)

    private enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    private enum ActionType: String, Codable {
        case sessionStart
        case preToolUse
        case sessionEnd
        case permissionRequest
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .sessionStart:
            let body = try container.decode(SessionStartBody.self, forKey: .body)
            self = .sessionStart(body)
        case .preToolUse:
            let body = try container.decode(PreToolUseBody.self, forKey: .body)
            self = .preToolUse(body)
        case .sessionEnd:
            let body = try container.decode(SessionEndBody.self, forKey: .body)
            self = .sessionEnd(body)
        case .permissionRequest:
            let body = try container.decode(PermissionRequestBody.self, forKey: .body)
            self = .permissionRequest(body)
        case .unknown:
            let body = try container.decode(CommonHookFields.self, forKey: .body)
            self = .unknown(body)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .sessionStart(body):
            try container.encode(ActionType.sessionStart, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .preToolUse(body):
            try container.encode(ActionType.preToolUse, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .sessionEnd(body):
            try container.encode(ActionType.sessionEnd, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .permissionRequest(body):
            try container.encode(ActionType.permissionRequest, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .unknown(body):
            try container.encode(ActionType.unknown, forKey: .type)
            try container.encode(body, forKey: .body)
        }
    }

    /// Returns the underlying hook body for accessing common fields
    public var body: any HookBodyProtocol {
        switch self {
        case let .sessionStart(body): body
        case let .preToolUse(body): body
        case let .sessionEnd(body): body
        case let .permissionRequest(body): body
        case let .unknown(body): body
        }
    }

    public var eventName: String {
        body.hookEventName
    }

    public var sessionId: String {
        body.sessionId
    }

    /// The raw timestamp string from the hook event
    public var timestampString: String? {
        body.timestamp
    }

    /// The parsed timestamp as a Date, or nil if parsing fails
    public var timestamp: Date? {
        ISO8601Parser.parse(timestampString)
    }

    /// Parse hook action from JSON data by reading hook_event_name
    public static func from(jsonData: Data) throws -> HookAction {
        let decoder = JSONDecoder()

        // First, extract common fields to determine the type
        let common = try decoder.decode(CommonHookFields.self, from: jsonData)

        switch common.hookEventName {
        case "SessionStart":
            let body = try decoder.decode(SessionStartBody.self, from: jsonData)
            return .sessionStart(body)
        case "PreToolUse":
            let body = try decoder.decode(PreToolUseBody.self, from: jsonData)
            return .preToolUse(body)
        case "SessionEnd":
            let body = try decoder.decode(SessionEndBody.self, from: jsonData)
            return .sessionEnd(body)
        case "PermissionRequest":
            let body = try decoder.decode(PermissionRequestBody.self, from: jsonData)
            return .permissionRequest(body)
        default:
            return .unknown(common)
        }
    }
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for handling arbitrary JSON values
public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: AnyCodableValue

    public init(_ value: Any) {
        self.value = AnyCodableValue(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            value = .array(array.map(\.value))
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = .dictionary(dictionary.mapValues { $0.value })
        } else if container.decodeNil() {
            value = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try value.encode(to: &container)
    }
}

/// Sendable-safe value representation for AnyCodable
public enum AnyCodableValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])

    public init(_ value: Any) {
        switch value {
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { AnyCodableValue($0) })
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues { AnyCodableValue($0) })
        default:
            self = .null
        }
    }

    public func encode(to container: inout SingleValueEncodingContainer) throws {
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values.map { AnyCodable(wrapping: $0) })
        case let .dictionary(values):
            try container.encode(values.mapValues { AnyCodable(wrapping: $0) })
        }
    }
}

extension AnyCodable {
    fileprivate init(wrapping value: AnyCodableValue) {
        self.value = value
    }
}
