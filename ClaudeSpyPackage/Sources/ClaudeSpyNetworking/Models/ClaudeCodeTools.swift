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
    case monitor(MonitorParameters)

    // Subagents & Planning
    case agent(AgentParameters)
    case todoWrite(TodoWriteParameters)
    case exitPlanMode(ExitPlanModeParameters)

    // Task Management
    case taskOutput(TaskOutputParameters)
    case taskStop(TaskStopParameters)

    // Web Operations
    case webFetch(WebFetchParameters)
    case webSearch(WebSearchParameters)

    // Jupyter Notebooks
    case notebookEdit(NotebookEditParameters)

    // User Interaction
    case askUserQuestion(AskUserQuestionParameters)

    // MCP Tools
    case listMcpResources(ListMcpResourcesParameters)
    case readMcpResource(ReadMcpResourceParameters)
    case mcp(MCPToolParameters)

    // Git Worktrees
    case enterWorktree(EnterWorktreeParameters)

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
        case .monitor: "Monitor"
        case .agent: "Agent"
        case .todoWrite: "TodoWrite"
        case .exitPlanMode: "ExitPlanMode"
        case .taskOutput: "TaskOutput"
        case .taskStop: "TaskStop"
        case .webFetch: "WebFetch"
        case .webSearch: "WebSearch"
        case .notebookEdit: "NotebookEdit"
        case .askUserQuestion: "AskUserQuestion"
        case .listMcpResources: "ListMcpResources"
        case .readMcpResource: "ReadMcpResource"
        case let .mcp(params): params.fullToolName
        case .enterWorktree: "EnterWorktree"
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
        case let .monitor(params):
            params.description
        case let .agent(params):
            params.description
        case .todoWrite:
            nil
        case .exitPlanMode:
            nil
        case let .taskOutput(params):
            params.taskId
        case let .taskStop(params):
            params.taskId
        case let .webFetch(params):
            params.url
        case let .webSearch(params):
            params.query
        case let .notebookEdit(params):
            params.notebookPath
        case let .askUserQuestion(params):
            params.questions.first?.question
        case let .listMcpResources(params):
            params.server
        case let .readMcpResource(params):
            params.uri
        case let .mcp(params):
            params.tool
        case let .enterWorktree(params):
            params.name ?? params.path
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
        case "Monitor":
            return try .monitor(container.decode(MonitorParameters.self))
        case "Agent", "Task":
            return try .agent(container.decode(AgentParameters.self))
        case "TodoWrite":
            return try .todoWrite(container.decode(TodoWriteParameters.self))
        case "ExitPlanMode":
            return try .exitPlanMode(container.decode(ExitPlanModeParameters.self))
        case "TaskOutput":
            return try .taskOutput(container.decode(TaskOutputParameters.self))
        case "TaskStop":
            return try .taskStop(container.decode(TaskStopParameters.self))
        case "WebFetch":
            return try .webFetch(container.decode(WebFetchParameters.self))
        case "WebSearch":
            return try .webSearch(container.decode(WebSearchParameters.self))
        case "NotebookEdit":
            return try .notebookEdit(container.decode(NotebookEditParameters.self))
        case "AskUserQuestion":
            return try .askUserQuestion(container.decode(AskUserQuestionParameters.self))
        case "ListMcpResources":
            return try .listMcpResources(container.decode(ListMcpResourcesParameters.self))
        case "ReadMcpResource":
            return try .readMcpResource(container.decode(ReadMcpResourceParameters.self))
        case "EnterWorktree":
            return try .enterWorktree(container.decode(EnterWorktreeParameters.self))
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
    public let pages: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case offset
        case limit
        case pages
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
    public let type: String?
    public let linesAfter: Int?
    public let linesBefore: Int?
    public let linesContext: Int?
    public let context: Int?
    public let caseInsensitive: Bool?
    public let showLineNumbers: Bool?
    public let multiline: Bool?
    public let headLimit: Int?
    public let offset: Int?

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
        case context
        case caseInsensitive = "-i"
        case showLineNumbers = "-n"
        case multiline
        case headLimit = "head_limit"
        case offset
    }
}

public struct GlobParameters: Codable, Sendable, Equatable {
    public let pattern: String
    public let path: String?
}

public struct BashParameters: Codable, Sendable, Equatable {
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

    public init(
        command: String,
        description: String? = nil,
        timeout: Int? = nil,
        runInBackground: Bool? = nil,
        dangerouslyDisableSandbox: Bool? = nil
    ) {
        self.command = command
        self.description = description
        self.timeout = timeout
        self.runInBackground = runInBackground
        self.dangerouslyDisableSandbox = dangerouslyDisableSandbox
    }
}

public struct MonitorParameters: Codable, Sendable, Equatable {
    public let command: String
    public let description: String
    public let timeoutMs: Int?
    public let persistent: Bool?

    enum CodingKeys: String, CodingKey {
        case command
        case description
        case timeoutMs = "timeout_ms"
        case persistent
    }
}

public struct AgentParameters: Codable, Sendable, Equatable {
    public let description: String
    public let prompt: String
    public let subagentType: String?
    public let model: String?
    public let resume: String?
    public let runInBackground: Bool?
    public let maxTurns: Int?
    public let name: String?
    public let teamName: String?
    public let mode: String?
    public let isolation: String?

    enum CodingKeys: String, CodingKey {
        case description
        case prompt
        case subagentType = "subagent_type"
        case model
        case resume
        case runInBackground = "run_in_background"
        case maxTurns = "max_turns"
        case name
        case teamName = "team_name"
        case mode
        case isolation
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
    public let allowedPrompts: [AllowedPrompt]?

    public init(allowedPrompts: [AllowedPrompt]?) {
        self.allowedPrompts = allowedPrompts
    }

    public struct AllowedPrompt: Codable, Sendable, Equatable {
        public let tool: String
        public let prompt: String

        public init(tool: String, prompt: String) {
            self.tool = tool
            self.prompt = prompt
        }
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

public struct AskUserQuestionParameters: Codable, Sendable, Equatable {
    public let questions: [AskUserQuestion]

    public init(questions: [AskUserQuestion]) {
        self.questions = questions
    }

    public struct AskUserQuestion: Codable, Sendable, Equatable {
        public let question: String
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
        public let preview: String?

        public init(label: String, description: String?, preview: String? = nil) {
            self.label = label
            self.description = description
            self.preview = preview
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

public struct TaskOutputParameters: Codable, Sendable, Equatable {
    public let taskId: String
    public let block: Bool
    public let timeout: Int

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case block
        case timeout
    }
}

public struct TaskStopParameters: Codable, Sendable, Equatable {
    public let taskId: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
    }
}

public struct ListMcpResourcesParameters: Codable, Sendable, Equatable {
    public let server: String?
}

public struct ReadMcpResourceParameters: Codable, Sendable, Equatable {
    public let server: String
    public let uri: String
}

public struct EnterWorktreeParameters: Codable, Sendable, Equatable {
    public let name: String?
    public let path: String?
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
        case let .monitor(params):
            try container.encode(params)
        case let .agent(params):
            try container.encode(params)
        case let .todoWrite(params):
            try container.encode(params)
        case let .exitPlanMode(params):
            try container.encode(params)
        case let .taskOutput(params):
            try container.encode(params)
        case let .taskStop(params):
            try container.encode(params)
        case let .webFetch(params):
            try container.encode(params)
        case let .webSearch(params):
            try container.encode(params)
        case let .notebookEdit(params):
            try container.encode(params)
        case let .askUserQuestion(params):
            try container.encode(params)
        case let .listMcpResources(params):
            try container.encode(params)
        case let .readMcpResource(params):
            try container.encode(params)
        case let .mcp(params):
            try container.encode(params)
        case let .enterWorktree(params):
            try container.encode(params)
        case let .other(_, dictionary):
            try container.encode(dictionary)
        }
    }
}
