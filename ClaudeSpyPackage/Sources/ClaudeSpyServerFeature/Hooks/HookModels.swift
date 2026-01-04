import Foundation
import Vapor

// MARK: - Hook Request Query Parameters

struct HookQueryParams: Content {
    let projectPath: String?
    let tmuxPane: String?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case tmuxPane = "tmux_pane"
    }
}

// MARK: - Hook Response

struct HookResponse: Content {
    let decision: HookDecision
    let reason: String?

    enum HookDecision: String, Codable, Sendable {
        case approve
        case block
    }

    init(decision: HookDecision = .approve, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }

    static let approved = HookResponse(decision: .approve)
}

// MARK: - Hook Body Protocol

protocol HookBodyProtocol: Codable, Sendable {
    var sessionId: String { get }
    var hookEventName: String { get }
}

// MARK: - Common Hook Fields

/// Fields common to all hook payloads from Claude Code
struct CommonHookFields: Codable, Sendable {
    let sessionId: String
    let transcriptPath: String?
    let cwd: String?
    let hookEventName: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
    }
}

// MARK: - Hook Body Types

public struct SessionStartBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case source
    }
}

public struct PreToolUseBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let toolName: String?
    public let toolInput: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }
}

public struct SessionEndBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let stopHookActive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case stopHookActive = "stop_hook_active"
    }
}

// MARK: - Hook Action Enum

public enum HookAction: Sendable {
    case sessionStart(SessionStartBody)
    case preToolUse(PreToolUseBody)
    case sessionEnd(SessionEndBody)
    case unknown(String, Data)

    public var eventName: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .preToolUse: "PreToolUse"
        case .sessionEnd: "SessionEnd"
        case let .unknown(name, _): name
        }
    }

    public var sessionId: String {
        switch self {
        case let .sessionStart(body): body.sessionId
        case let .preToolUse(body): body.sessionId
        case let .sessionEnd(body): body.sessionId
        case .unknown: "unknown"
        }
    }

    /// Parse hook action from JSON data by reading hook_event_name
    static func from(jsonData: Data) throws -> HookAction {
        let decoder = JSONDecoder()

        // First, extract the hook_event_name to determine the type
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
        default:
            return .unknown(common.hookEventName, jsonData)
        }
    }
}

// MARK: - Hook Event (for storage/observation)

/// Represents a received hook event with metadata
public struct HookEvent: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: HookAction
    public let projectPath: String?
    public let tmuxPane: String?

    init(
        action: HookAction,
        projectPath: String?,
        tmuxPane: String?
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.action = action
        self.projectPath = projectPath
        self.tmuxPane = tmuxPane
    }
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for handling arbitrary JSON values
public struct AnyCodable: Codable, Sendable {
    public let value: AnyCodableValue

    init(_ value: Any) {
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
public enum AnyCodableValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])

    init(_ value: Any) {
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

    func encode(to container: inout SingleValueEncodingContainer) throws {
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
