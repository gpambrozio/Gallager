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
    public let toolInput: ToolInput?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)

        // Decode tool_input based on tool_name
        if container.contains(.toolInput) {
            toolInput = try ToolInput.decode(
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
    public let stopHookActive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
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

public enum HookAction: Sendable {
    case sessionStart(SessionStartBody)
    case preToolUse(PreToolUseBody)
    case sessionEnd(SessionEndBody)
    case permissionRequest(PermissionRequestBody)
    case unknown(String, Data)

    public var eventName: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .preToolUse: "PreToolUse"
        case .sessionEnd: "SessionEnd"
        case .permissionRequest: "PermissionRequest"
        case let .unknown(name, _): name
        }
    }

    public var sessionId: String {
        switch self {
        case let .sessionStart(body): body.sessionId
        case let .preToolUse(body): body.sessionId
        case let .sessionEnd(body): body.sessionId
        case let .permissionRequest(body): body.sessionId
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
        case "PermissionRequest":
            let body = try decoder.decode(PermissionRequestBody.self, from: jsonData)
            return .permissionRequest(body)
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

// MARK: - Tool Input Types

/// Input for the Bash tool
public struct BashToolInput: Codable, Sendable, Equatable {
    public let command: String
    public let description: String?
    public let timeout: Int?
    public let runInBackground: Bool?
    public let dangerouslyDisableSandbox: Bool?

    enum CodingKeys: String, CodingKey {
        case command
        case description
        case timeout
        case runInBackground = "run_in_background"
        case dangerouslyDisableSandbox
    }
}

/// Option for an AskUserQuestion question
public struct QuestionOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String?
}

/// A question in the AskUserQuestion tool
public struct Question: Codable, Sendable, Equatable {
    public let question: String
    public let header: String
    public let options: [QuestionOption]
    public let multiSelect: Bool
}

/// Input for the AskUserQuestion tool
public struct AskUserQuestionToolInput: Codable, Sendable, Equatable {
    public let questions: [Question]
    public let answers: [String: String]?
}

/// Strongly-typed tool input that varies based on tool_name
public enum ToolInput: Sendable, Equatable {
    case bash(BashToolInput)
    case askUserQuestion(AskUserQuestionToolInput)
    case other([String: AnyCodable])
}

extension ToolInput: Codable {
    public init(from decoder: Decoder) throws {
        // This will be called with context from PreToolUseBody
        // Default to decoding as generic dictionary
        let container = try decoder.singleValueContainer()
        let dictionary = try container.decode([String: AnyCodable].self)
        self = .other(dictionary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bash(input):
            try container.encode(input)
        case let .askUserQuestion(input):
            try container.encode(input)
        case let .other(dictionary):
            try container.encode(dictionary)
        }
    }

    /// Decode tool input based on tool name
    static func decode(from decoder: Decoder, toolName: String?) throws -> ToolInput? {
        let container = try decoder.singleValueContainer()

        guard !container.decodeNil() else {
            return nil
        }

        switch toolName {
        case "Bash":
            let input = try container.decode(BashToolInput.self)
            return .bash(input)
        case "AskUserQuestion":
            let input = try container.decode(AskUserQuestionToolInput.self)
            return .askUserQuestion(input)
        default:
            let dictionary = try container.decode([String: AnyCodable].self)
            return .other(dictionary)
        }
    }
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for handling arbitrary JSON values
public struct AnyCodable: Codable, Sendable, Equatable {
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
public enum AnyCodableValue: Sendable, Equatable {
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
