import Foundation

// MARK: - Claude Code Tool Enum

public enum ClaudeCodeTool: Sendable, Equatable {
    // File Operations
    case read(ReadParameters)
    case edit(EditParameters)
    case write(WriteParameters)

    // Search Tools
    case grep(GrepParameters)
    case glob(GlobParameters)

    // Execution
    case bash(BashParameters)

    // Subagents & Planning
    case agent(AgentParameters)
    case exitPlanMode

    // Web Operations
    case webFetch(WebFetchParameters)
    case webSearch(WebSearchParameters)

    // User Interaction
    case askUserQuestion(AskUserQuestionParameters)

    // MCP Tools (mcp__<server>__<tool>)
    case mcp(MCPToolParameters)

    // Fallback for unknown tools
    case other(String, [String: AnyCodable])

    public var toolName: String {
        switch self {
        case .read: "Read"
        case .edit: "Edit"
        case .write: "Write"
        case .grep: "Grep"
        case .glob: "Glob"
        case .bash: "Bash"
        case .agent: "Agent"
        case .exitPlanMode: "ExitPlanMode"
        case .webFetch: "WebFetch"
        case .webSearch: "WebSearch"
        case .askUserQuestion: "AskUserQuestion"
        case let .mcp(params): params.fullToolName
        case let .other(name, _): name
        }
    }

    /// A short summary of what this tool invocation does
    public var summary: String? {
        switch self {
        case let .read(params):
            params.filePath
        case let .edit(params):
            params.filePath
        case let .write(params):
            params.filePath
        case let .grep(params):
            params.pattern
        case let .glob(params):
            params.pattern
        case let .bash(params):
            params.command
        case let .agent(params):
            params.description
        case .exitPlanMode:
            nil
        case let .webFetch(params):
            params.url
        case let .webSearch(params):
            params.query
        case let .askUserQuestion(params):
            params.questions.first?.question
        case let .mcp(params):
            params.tool
        case .other:
            nil
        }
    }

    public static func decode(from decoder: Decoder, toolName: String?) throws -> ClaudeCodeTool? {
        let container = try decoder.singleValueContainer()

        guard !container.decodeNil() else {
            return nil
        }

        switch toolName {
        case "Read":
            return try .read(container.decode(ReadParameters.self))
        case "Edit":
            return try .edit(container.decode(EditParameters.self))
        case "Write":
            return try .write(container.decode(WriteParameters.self))
        case "Grep":
            return try .grep(container.decode(GrepParameters.self))
        case "Glob":
            return try .glob(container.decode(GlobParameters.self))
        case "Bash":
            return try .bash(container.decode(BashParameters.self))
        case "Agent":
            return try .agent(container.decode(AgentParameters.self))
        case "ExitPlanMode":
            return .exitPlanMode
        case "WebFetch":
            return try .webFetch(container.decode(WebFetchParameters.self))
        case "WebSearch":
            return try .webSearch(container.decode(WebSearchParameters.self))
        case "AskUserQuestion":
            return try .askUserQuestion(container.decode(AskUserQuestionParameters.self))
        default:
            if let name = toolName, name.hasPrefix("mcp__") {
                return try .mcp(container.decode(MCPToolParameters.self))
            }
            let dictionary = try container.decode([String: AnyCodable].self)
            return .other(toolName ?? "Unknown", dictionary)
        }
    }
}

// MARK: - Tool Parameter Structs

public struct ReadParameters: Codable, Sendable, Equatable {
    public let filePath: String
    public let offset: Int?
    public let limit: Int?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case offset
        case limit
    }
}

public struct EditParameters: Codable, Sendable, Equatable {
    public let filePath: String
    public let oldString: String
    public let newString: String
    public let replaceAll: Bool?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case oldString = "old_string"
        case newString = "new_string"
        case replaceAll = "replace_all"
    }
}

public struct WriteParameters: Codable, Sendable, Equatable {
    public let filePath: String
    public let content: String

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case content
    }
}

public struct GrepParameters: Codable, Sendable, Equatable {
    public let pattern: String
    public let path: String?
    public let outputMode: OutputMode?
    public let glob: String?
    public let caseInsensitive: Bool?
    public let multiline: Bool?

    public enum OutputMode: String, Codable, Sendable, Equatable {
        case content
        case filesWithMatches = "files_with_matches"
        case count
    }

    enum CodingKeys: String, CodingKey {
        case pattern
        case path
        case outputMode = "output_mode"
        case glob
        case caseInsensitive = "-i"
        case multiline
    }
}

public struct GlobParameters: Codable, Sendable, Equatable {
    public let pattern: String
    public let path: String?
}

public struct BashParameters: Codable, Sendable, Equatable {
    public let command: String
    public let description: String?
    /// Timeout in milliseconds (default: 120000, max: 600000)
    public let timeout: Int?
    public let runInBackground: Bool?

    enum CodingKeys: String, CodingKey {
        case command
        case description
        case timeout
        case runInBackground = "run_in_background"
    }

    public init(
        command: String,
        description: String? = nil,
        timeout: Int? = nil,
        runInBackground: Bool? = nil
    ) {
        self.command = command
        self.description = description
        self.timeout = timeout
        self.runInBackground = runInBackground
    }
}

public struct AgentParameters: Codable, Sendable, Equatable {
    public let prompt: String
    public let description: String
    public let subagentType: String?
    public let model: String?

    enum CodingKeys: String, CodingKey {
        case prompt
        case description
        case subagentType = "subagent_type"
        case model
    }
}

public struct WebFetchParameters: Codable, Sendable, Equatable {
    public let url: String
    public let prompt: String
}

public struct WebSearchParameters: Codable, Sendable, Equatable {
    public let query: String
    public let allowedDomains: [String]?
    public let blockedDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case query
        case allowedDomains = "allowed_domains"
        case blockedDomains = "blocked_domains"
    }
}

public struct AskUserQuestionParameters: Codable, Sendable, Equatable {
    public let questions: [AskUserQuestion]
    public let answers: [String: String]?

    public init(questions: [AskUserQuestion], answers: [String: String]?) {
        self.questions = questions
        self.answers = answers
    }

    public struct AskUserQuestion: Codable, Sendable, Equatable {
        public let question: String
        /// Short label for chip/tag display (max 12 chars)
        public let header: String
        public let options: [AskUserQuestionOption]
        public let multiSelect: Bool

        public init(question: String, header: String, options: [AskUserQuestionOption], multiSelect: Bool) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public struct AskUserQuestionOption: Codable, Sendable, Equatable {
        public let label: String
        public let description: String?

        public init(label: String, description: String?) {
            self.label = label
            self.description = description
        }
    }
}

public struct MCPToolParameters: Codable, Sendable, Equatable {
    public let server: String
    public let tool: String
    public let input: [String: AnyCodable]?

    public var fullToolName: String {
        "mcp__\(server)__\(tool)"
    }
}

// MARK: - ClaudeCodeTool Codable

extension ClaudeCodeTool: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dictionary = try container.decode([String: AnyCodable].self)
        self = .other("Unknown", dictionary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .read(params):
            try container.encode(params)
        case let .edit(params):
            try container.encode(params)
        case let .write(params):
            try container.encode(params)
        case let .grep(params):
            try container.encode(params)
        case let .glob(params):
            try container.encode(params)
        case let .bash(params):
            try container.encode(params)
        case let .agent(params):
            try container.encode(params)
        case .exitPlanMode:
            try container.encode([String: String]())
        case let .webFetch(params):
            try container.encode(params)
        case let .webSearch(params):
            try container.encode(params)
        case let .askUserQuestion(params):
            try container.encode(params)
        case let .mcp(params):
            try container.encode(params)
        case let .other(_, dictionary):
            try container.encode(dictionary)
        }
    }
}
