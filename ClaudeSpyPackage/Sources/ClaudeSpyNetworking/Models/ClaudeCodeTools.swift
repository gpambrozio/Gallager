import Foundation

// MARK: - Claude Code Tool Enum
// Reference: https://code.claude.com/docs/en/tools-reference

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

    // Task Management
    case taskOutput(TaskOutputParameters)
    case taskStop(TaskStopParameters)
    case taskCreate(GenericToolParameters)
    case taskGet(GenericToolParameters)
    case taskList(GenericToolParameters)
    case taskUpdate(GenericToolParameters)

    // Subagents & Planning
    case agent(AgentParameters)
    case todoWrite(TodoWriteParameters)
    case enterPlanMode(GenericToolParameters)
    case exitPlanMode(ExitPlanModeParameters)

    // Worktrees
    case enterWorktree(GenericToolParameters)
    case exitWorktree(GenericToolParameters)

    // Web Operations
    case webFetch(WebFetchParameters)
    case webSearch(WebSearchParameters)

    // Jupyter Notebooks
    case notebookEdit(NotebookEditParameters)

    // Skills
    case skill(SkillParameters)

    // User Interaction
    case askUserQuestion(AskUserQuestionParameters)

    // Scheduled Tasks
    case cronCreate(GenericToolParameters)
    case cronDelete(GenericToolParameters)
    case cronList(GenericToolParameters)

    // Code Intelligence
    case lsp(GenericToolParameters)

    // Tool Discovery
    case toolSearch(GenericToolParameters)

    // MCP Tools (mcp__<server>__<tool>)
    case mcp(MCPToolParameters)
    case listMcpResources(GenericToolParameters)
    case readMcpResource(GenericToolParameters)

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
        case .taskOutput: "TaskOutput"
        case .taskStop: "TaskStop"
        case .taskCreate: "TaskCreate"
        case .taskGet: "TaskGet"
        case .taskList: "TaskList"
        case .taskUpdate: "TaskUpdate"
        case .agent: "Agent"
        case .todoWrite: "TodoWrite"
        case .enterPlanMode: "EnterPlanMode"
        case .exitPlanMode: "ExitPlanMode"
        case .enterWorktree: "EnterWorktree"
        case .exitWorktree: "ExitWorktree"
        case .webFetch: "WebFetch"
        case .webSearch: "WebSearch"
        case .notebookEdit: "NotebookEdit"
        case .skill: "Skill"
        case .askUserQuestion: "AskUserQuestion"
        case .cronCreate: "CronCreate"
        case .cronDelete: "CronDelete"
        case .cronList: "CronList"
        case .lsp: "LSP"
        case .toolSearch: "ToolSearch"
        case let .mcp(params): params.fullToolName
        // "Tool" suffix matches official Claude Code tool names (see tools reference)
        case .listMcpResources: "ListMcpResourcesTool"
        case .readMcpResource: "ReadMcpResourceTool"
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
        case let .multiEdit(params):
            params.filePath
        case let .grep(params):
            params.pattern
        case let .glob(params):
            params.pattern
        case let .bash(params):
            params.command
        case let .taskOutput(params):
            params.taskId
        case let .taskStop(params):
            params.taskId
        case .taskCreate, .taskGet, .taskList, .taskUpdate:
            nil
        case let .agent(params):
            params.taskDescription
        case .todoWrite:
            nil
        case .enterPlanMode, .exitPlanMode:
            nil
        case .enterWorktree, .exitWorktree:
            nil
        case let .webFetch(params):
            params.url
        case let .webSearch(params):
            params.query
        case let .notebookEdit(params):
            params.notebookPath
        case let .skill(params):
            params.skill
        case let .askUserQuestion(params):
            params.questions.first?.question
        case .cronCreate, .cronDelete, .cronList:
            nil
        case .lsp:
            nil
        case .toolSearch:
            nil
        case let .mcp(params):
            params.tool
        case .listMcpResources, .readMcpResource:
            nil
        case .other:
            nil
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        case "MultiEdit":
            return try .multiEdit(container.decode(MultiEditParameters.self))
        case "Grep":
            return try .grep(container.decode(GrepParameters.self))
        case "Glob":
            return try .glob(container.decode(GlobParameters.self))
        case "Bash":
            return try .bash(container.decode(BashParameters.self))
        case "TaskOutput":
            return try .taskOutput(container.decode(TaskOutputParameters.self))
        case "TaskStop":
            return try .taskStop(container.decode(TaskStopParameters.self))
        case "TaskCreate":
            return try .taskCreate(container.decode(GenericToolParameters.self))
        case "TaskGet":
            return try .taskGet(container.decode(GenericToolParameters.self))
        case "TaskList":
            return try .taskList(container.decode(GenericToolParameters.self))
        case "TaskUpdate":
            return try .taskUpdate(container.decode(GenericToolParameters.self))
        case "Agent":
            return try .agent(container.decode(AgentParameters.self))
        case "TodoWrite":
            return try .todoWrite(container.decode(TodoWriteParameters.self))
        case "EnterPlanMode":
            return try .enterPlanMode(container.decode(GenericToolParameters.self))
        case "ExitPlanMode":
            return try .exitPlanMode(container.decode(ExitPlanModeParameters.self))
        case "EnterWorktree":
            return try .enterWorktree(container.decode(GenericToolParameters.self))
        case "ExitWorktree":
            return try .exitWorktree(container.decode(GenericToolParameters.self))
        case "WebFetch":
            return try .webFetch(container.decode(WebFetchParameters.self))
        case "WebSearch":
            return try .webSearch(container.decode(WebSearchParameters.self))
        case "NotebookEdit":
            return try .notebookEdit(container.decode(NotebookEditParameters.self))
        case "Skill":
            return try .skill(container.decode(SkillParameters.self))
        case "AskUserQuestion":
            return try .askUserQuestion(container.decode(AskUserQuestionParameters.self))
        case "CronCreate":
            return try .cronCreate(container.decode(GenericToolParameters.self))
        case "CronDelete":
            return try .cronDelete(container.decode(GenericToolParameters.self))
        case "CronList":
            return try .cronList(container.decode(GenericToolParameters.self))
        case "LSP":
            return try .lsp(container.decode(GenericToolParameters.self))
        case "ToolSearch":
            return try .toolSearch(container.decode(GenericToolParameters.self))
        case "ListMcpResourcesTool":
            return try .listMcpResources(container.decode(GenericToolParameters.self))
        case "ReadMcpResourceTool":
            return try .readMcpResource(container.decode(GenericToolParameters.self))
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

public struct TaskOutputParameters: Codable, Sendable, Equatable {
    public let taskId: String
    public let filter: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case filter
    }
}

public struct TaskStopParameters: Codable, Sendable, Equatable {
    public let taskId: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
    }
}

public struct AgentParameters: Codable, Sendable, Equatable {
    public let prompt: String
    public let taskDescription: String
    public let subagentType: String?
    public let isolation: String?
    public let model: String?
    public let resume: String?
    public let runInBackground: Bool?

    enum CodingKeys: String, CodingKey {
        case prompt
        case taskDescription = "description"
        case subagentType = "subagent_type"
        case isolation
        case model
        case resume
        case runInBackground = "run_in_background"
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
    /// The markdown plan content (may be nil if not provided)
    public let plan: String?
    /// Prompt-based permissions requested for plan implementation
    public let allowedPrompts: [AllowedPrompt]?

    public init(plan: String?, allowedPrompts: [AllowedPrompt]?) {
        self.plan = plan
        self.allowedPrompts = allowedPrompts
    }

    public struct AllowedPrompt: Codable, Sendable, Equatable {
        /// The tool this prompt applies to (e.g., "Bash")
        public let tool: String
        /// Semantic description of the action (e.g., "run tests")
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

public struct SkillParameters: Codable, Sendable, Equatable {
    public let skill: String
    public let args: String?
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

/// Generic parameters for tools without a known parameter schema.
/// Stores raw key-value pairs to handle any parameters received over the wire.
public struct GenericToolParameters: Codable, Sendable, Equatable {
    public let rawParameters: [String: AnyCodable]

    public init(rawParameters: [String: AnyCodable] = [:]) {
        self.rawParameters = rawParameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawParameters = try container.decode([String: AnyCodable].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawParameters)
    }
}

// MARK: - ClaudeCodeTool Codable

extension ClaudeCodeTool: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dictionary = try container.decode([String: AnyCodable].self)
        self = .other("Unknown", dictionary)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        case let .taskOutput(params):
            try container.encode(params)
        case let .taskStop(params):
            try container.encode(params)
        case let .taskCreate(params):
            try container.encode(params)
        case let .taskGet(params):
            try container.encode(params)
        case let .taskList(params):
            try container.encode(params)
        case let .taskUpdate(params):
            try container.encode(params)
        case let .agent(params):
            try container.encode(params)
        case let .todoWrite(params):
            try container.encode(params)
        case let .enterPlanMode(params):
            try container.encode(params)
        case let .exitPlanMode(params):
            try container.encode(params)
        case let .enterWorktree(params):
            try container.encode(params)
        case let .exitWorktree(params):
            try container.encode(params)
        case let .webFetch(params):
            try container.encode(params)
        case let .webSearch(params):
            try container.encode(params)
        case let .notebookEdit(params):
            try container.encode(params)
        case let .skill(params):
            try container.encode(params)
        case let .askUserQuestion(params):
            try container.encode(params)
        case let .cronCreate(params):
            try container.encode(params)
        case let .cronDelete(params):
            try container.encode(params)
        case let .cronList(params):
            try container.encode(params)
        case let .lsp(params):
            try container.encode(params)
        case let .toolSearch(params):
            try container.encode(params)
        case let .mcp(params):
            try container.encode(params)
        case let .listMcpResources(params):
            try container.encode(params)
        case let .readMcpResource(params):
            try container.encode(params)
        case let .other(_, dictionary):
            try container.encode(dictionary)
        }
    }
}
