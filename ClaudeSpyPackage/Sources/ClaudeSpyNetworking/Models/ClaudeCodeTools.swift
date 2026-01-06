import Foundation

// MARK: - Claude Code Tool Enum

public enum ClaudeCodeTool: Sendable, Equatable {
    // File Operations
    case read(ReadParameters)
    case edit(EditParameters)
    case write(WriteParameters)
    case multiEdit(MultiEditParameters)

    // Search Tools
    case grep(GrepParameters)
    case glob(GlobParameters)

    // Execution
    case bash(BashParameters)
    case bashOutput(BashOutputParameters)
    case killShell(KillShellParameters)

    // Subagents & Planning
    case task(TaskParameters)
    case todoWrite(TodoWriteParameters)
    case exitPlanMode(ExitPlanModeParameters)

    // Web Operations
    case webFetch(WebFetchParameters)
    case webSearch(WebSearchParameters)

    // Jupyter Notebooks
    case notebookEdit(NotebookEditParameters)

    // Slash Commands
    case slashCommand(SlashCommandParameters)

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
        case .multiEdit: "MultiEdit"
        case .grep: "Grep"
        case .glob: "Glob"
        case .bash: "Bash"
        case .bashOutput: "BashOutput"
        case .killShell: "KillShell"
        case .task: "Task"
        case .todoWrite: "TodoWrite"
        case .exitPlanMode: "ExitPlanMode"
        case .webFetch: "WebFetch"
        case .webSearch: "WebSearch"
        case .notebookEdit: "NotebookEdit"
        case .slashCommand: "SlashCommand"
        case .askUserQuestion: "AskUserQuestion"
        case .mcp(let params): params.fullToolName
        case .other(let name, _): name
        }
    }

    public static func decode(from decoder: Decoder, toolName: String?) throws -> ClaudeCodeTool? {
        let container = try decoder.singleValueContainer()

        guard !container.decodeNil() else {
            return nil
        }

        switch toolName {
        case "Read":
            return .read(try container.decode(ReadParameters.self))
        case "Edit":
            return .edit(try container.decode(EditParameters.self))
        case "Write":
            return .write(try container.decode(WriteParameters.self))
        case "MultiEdit":
            return .multiEdit(try container.decode(MultiEditParameters.self))
        case "Grep":
            return .grep(try container.decode(GrepParameters.self))
        case "Glob":
            return .glob(try container.decode(GlobParameters.self))
        case "Bash":
            return .bash(try container.decode(BashParameters.self))
        case "BashOutput":
            return .bashOutput(try container.decode(BashOutputParameters.self))
        case "KillShell":
            return .killShell(try container.decode(KillShellParameters.self))
        case "Task":
            return .task(try container.decode(TaskParameters.self))
        case "TodoWrite":
            return .todoWrite(try container.decode(TodoWriteParameters.self))
        case "ExitPlanMode":
            return .exitPlanMode(try container.decode(ExitPlanModeParameters.self))
        case "WebFetch":
            return .webFetch(try container.decode(WebFetchParameters.self))
        case "WebSearch":
            return .webSearch(try container.decode(WebSearchParameters.self))
        case "NotebookEdit":
            return .notebookEdit(try container.decode(NotebookEditParameters.self))
        case "SlashCommand":
            return .slashCommand(try container.decode(SlashCommandParameters.self))
        case "AskUserQuestion":
            return .askUserQuestion(try container.decode(AskUserQuestionParameters.self))
        default:
            if let name = toolName, name.hasPrefix("mcp__") {
                return .mcp(try container.decode(MCPToolParameters.self))
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

public struct MultiEditParameters: Codable, Sendable, Equatable {
    public let filePath: String
    public let edits: [EditOperation]

    public struct EditOperation: Codable, Sendable, Equatable {
        public let oldString: String
        public let newString: String

        enum CodingKeys: String, CodingKey {
            case oldString = "old_string"
            case newString = "new_string"
        }
    }

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case edits
    }
}

public struct GrepParameters: Codable, Sendable, Equatable {
    public let pattern: String
    public let path: String?
    public let outputMode: OutputMode?
    public let glob: String?
    public let type: String?
    public let linesAfter: Int?
    public let linesBefore: Int?
    public let linesContext: Int?
    public let caseInsensitive: Bool?
    public let showLineNumbers: Bool?
    public let multiline: Bool?
    public let headLimit: Int?

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
        case type
        case linesAfter = "-A"
        case linesBefore = "-B"
        case linesContext = "-C"
        case caseInsensitive = "-i"
        case showLineNumbers = "-n"
        case multiline
        case headLimit = "head_limit"
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
    public let dangerouslyDisableSandbox: Bool?

    enum CodingKeys: String, CodingKey {
        case command
        case description
        case timeout
        case runInBackground = "run_in_background"
        case dangerouslyDisableSandbox
    }
}

public struct BashOutputParameters: Codable, Sendable, Equatable {
    public let bashId: String
    public let filter: String?

    enum CodingKeys: String, CodingKey {
        case bashId = "bash_id"
        case filter
    }
}

public struct KillShellParameters: Codable, Sendable, Equatable {
    public let shellId: String

    enum CodingKeys: String, CodingKey {
        case shellId = "shell_id"
    }
}

public struct TaskParameters: Codable, Sendable, Equatable {
    public let subagentType: SubagentType
    public let prompt: String
    public let description: String

    public enum SubagentType: String, Codable, Sendable, Equatable {
        case generalPurpose = "general-purpose"
        case statusLineSetup = "statusline-setup"
        case outputStyleSetup = "output-style-setup"
    }

    enum CodingKeys: String, CodingKey {
        case subagentType = "subagent_type"
        case prompt
        case description
    }
}

public struct TodoItem: Codable, Sendable, Equatable {
    /// Imperative form (e.g., "Run tests")
    public let content: String
    /// Present continuous form (e.g., "Running tests")
    public let activeForm: String
    public let status: TodoStatus

    public enum TodoStatus: String, Codable, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    enum CodingKeys: String, CodingKey {
        case content
        case activeForm
        case status
    }
}

public struct TodoWriteParameters: Codable, Sendable, Equatable {
    public let todos: [TodoItem]
}

public struct ExitPlanModeParameters: Codable, Sendable, Equatable {
    public let plan: String
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

public struct NotebookEditParameters: Codable, Sendable, Equatable {
    public let notebookPath: String
    public let newSource: String
    public let cellId: String?
    public let cellType: CellType?
    public let editMode: EditMode?

    public enum CellType: String, Codable, Sendable, Equatable {
        case code
        case markdown
    }

    public enum EditMode: String, Codable, Sendable, Equatable {
        case replace
        case insert
        case delete
    }

    enum CodingKeys: String, CodingKey {
        case notebookPath = "notebook_path"
        case newSource = "new_source"
        case cellId = "cell_id"
        case cellType = "cell_type"
        case editMode = "edit_mode"
    }
}

public struct SlashCommandParameters: Codable, Sendable, Equatable {
    public let command: String
}

public struct AskUserQuestionParameters: Codable, Sendable, Equatable {
    public let questions: [AskUserQuestion]
    public let answers: [String: String]?

    public struct AskUserQuestion: Codable, Sendable, Equatable {
        public let question: String
        /// Short label for chip/tag display (max 12 chars)
        public let header: String
        public let options: [AskUserQuestionOption]
        public let multiSelect: Bool
    }

    public struct AskUserQuestionOption: Codable, Sendable, Equatable {
        public let label: String
        public let description: String?
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
        case let .multiEdit(params):
            try container.encode(params)
        case let .grep(params):
            try container.encode(params)
        case let .glob(params):
            try container.encode(params)
        case let .bash(params):
            try container.encode(params)
        case let .bashOutput(params):
            try container.encode(params)
        case let .killShell(params):
            try container.encode(params)
        case let .task(params):
            try container.encode(params)
        case let .todoWrite(params):
            try container.encode(params)
        case let .exitPlanMode(params):
            try container.encode(params)
        case let .webFetch(params):
            try container.encode(params)
        case let .webSearch(params):
            try container.encode(params)
        case let .notebookEdit(params):
            try container.encode(params)
        case let .slashCommand(params):
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
