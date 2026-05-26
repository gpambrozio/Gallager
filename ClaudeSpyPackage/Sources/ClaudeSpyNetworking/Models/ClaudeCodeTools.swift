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
    case powerShell(PowerShellParameters)

    // Subagents & Planning
    case agent(AgentParameters)
    case todoWrite(TodoWriteParameters)
    case enterPlanMode([String: AnyCodable])
    case exitPlanMode(ExitPlanModeParameters)

    // Web Operations
    case webFetch(WebFetchParameters)
    case webSearch(WebSearchParameters)

    /// Jupyter Notebooks
    case notebookEdit(NotebookEditParameters)

    /// Skills (formerly Slash Commands)
    case skill(SkillParameters)

    /// Tool Discovery
    case toolSearch(ToolSearchParameters)

    /// User Interaction
    case askUserQuestion(AskUserQuestionParameters)

    /// Code Intelligence
    case lsp([String: AnyCodable])

    // Background Tasks
    case taskOutput(TaskOutputParameters)
    case taskStop(TaskStopParameters)

    // Task Management
    case taskCreate([String: AnyCodable])
    case taskGet([String: AnyCodable])
    case taskList([String: AnyCodable])
    case taskUpdate([String: AnyCodable])

    /// Worktrees
    case enterWorktree(EnterWorktreeParameters)
    case exitWorktree([String: AnyCodable])

    /// Scheduled Tasks
    case cronCreate([String: AnyCodable])
    case cronDelete([String: AnyCodable])
    case cronList([String: AnyCodable])
    case scheduleWakeup([String: AnyCodable])

    /// Notifications
    case pushNotification([String: AnyCodable])

    /// Routines
    case remoteTrigger([String: AnyCodable])

    /// Agent Teams
    case sendMessage([String: AnyCodable])
    case teamCreate([String: AnyCodable])
    case teamDelete([String: AnyCodable])

    /// Onboarding
    case shareOnboardingGuide([String: AnyCodable])

    /// MCP Servers
    case waitForMcpServers([String: AnyCodable])

    // MCP Resources
    case listMcpResources(ListMcpResourcesParameters)
    case readMcpResource(ReadMcpResourceParameters)

    /// MCP Tools (mcp__<server>__<tool>)
    case mcp(MCPToolParameters)

    /// Fallback for unknown tools
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
        case .powerShell: "PowerShell"
        case .agent: "Agent"
        case .todoWrite: "TodoWrite"
        case .enterPlanMode: "EnterPlanMode"
        case .exitPlanMode: "ExitPlanMode"
        case .webFetch: "WebFetch"
        case .webSearch: "WebSearch"
        case .notebookEdit: "NotebookEdit"
        case .skill: "Skill"
        case .toolSearch: "ToolSearch"
        case .askUserQuestion: "AskUserQuestion"
        case .lsp: "LSP"
        case .taskOutput: "TaskOutput"
        case .taskStop: "TaskStop"
        case .taskCreate: "TaskCreate"
        case .taskGet: "TaskGet"
        case .taskList: "TaskList"
        case .taskUpdate: "TaskUpdate"
        case .enterWorktree: "EnterWorktree"
        case .exitWorktree: "ExitWorktree"
        case .cronCreate: "CronCreate"
        case .cronDelete: "CronDelete"
        case .cronList: "CronList"
        case .scheduleWakeup: "ScheduleWakeup"
        case .pushNotification: "PushNotification"
        case .remoteTrigger: "RemoteTrigger"
        case .sendMessage: "SendMessage"
        case .teamCreate: "TeamCreate"
        case .teamDelete: "TeamDelete"
        case .shareOnboardingGuide: "ShareOnboardingGuide"
        case .waitForMcpServers: "WaitForMcpServers"
        case .listMcpResources: "ListMcpResourcesTool"
        case .readMcpResource: "ReadMcpResourceTool"
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
        case let .monitor(params):
            params.command
        case let .powerShell(params):
            params.command
        case let .agent(params):
            params.description
        case .todoWrite:
            nil
        case .enterPlanMode:
            nil
        case let .exitPlanMode(params):
            params.planFilePath
        case let .webFetch(params):
            params.url
        case let .webSearch(params):
            params.query
        case let .notebookEdit(params):
            params.notebookPath
        case let .skill(params):
            params.skill
        case let .toolSearch(params):
            params.query
        case let .askUserQuestion(params):
            params.questions.first?.question
        case .lsp:
            nil
        case let .taskOutput(params):
            params.taskId
        case let .taskStop(params):
            params.taskId ?? params.shellId
        case .taskCreate,
             .taskGet,
             .taskList,
             .taskUpdate:
            nil
        case let .enterWorktree(params):
            params.name ?? params.path
        case .exitWorktree:
            nil
        case .cronCreate,
             .cronDelete,
             .cronList,
             .scheduleWakeup:
            nil
        case .pushNotification:
            nil
        case .remoteTrigger:
            nil
        case .sendMessage,
             .teamCreate,
             .teamDelete:
            nil
        case .shareOnboardingGuide:
            nil
        case .waitForMcpServers:
            nil
        case let .listMcpResources(params):
            params.server
        case let .readMcpResource(params):
            params.uri
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
        case "Monitor":
            return try .monitor(container.decode(MonitorParameters.self))
        case "PowerShell":
            return try .powerShell(container.decode(PowerShellParameters.self))
        case "Agent":
            return try .agent(container.decode(AgentParameters.self))
        case "TodoWrite":
            return try .todoWrite(container.decode(TodoWriteParameters.self))
        case "EnterPlanMode":
            return try .enterPlanMode(container.decode([String: AnyCodable].self))
        case "ExitPlanMode":
            return try .exitPlanMode(container.decode(ExitPlanModeParameters.self))
        case "WebFetch":
            return try .webFetch(container.decode(WebFetchParameters.self))
        case "WebSearch":
            return try .webSearch(container.decode(WebSearchParameters.self))
        case "NotebookEdit":
            return try .notebookEdit(container.decode(NotebookEditParameters.self))
        case "Skill":
            return try .skill(container.decode(SkillParameters.self))
        case "ToolSearch":
            return try .toolSearch(container.decode(ToolSearchParameters.self))
        case "AskUserQuestion":
            return try .askUserQuestion(container.decode(AskUserQuestionParameters.self))
        case "LSP":
            return try .lsp(container.decode([String: AnyCodable].self))
        case "TaskOutput":
            return try .taskOutput(container.decode(TaskOutputParameters.self))
        case "TaskStop":
            return try .taskStop(container.decode(TaskStopParameters.self))
        case "TaskCreate":
            return try .taskCreate(container.decode([String: AnyCodable].self))
        case "TaskGet":
            return try .taskGet(container.decode([String: AnyCodable].self))
        case "TaskList":
            return try .taskList(container.decode([String: AnyCodable].self))
        case "TaskUpdate":
            return try .taskUpdate(container.decode([String: AnyCodable].self))
        case "EnterWorktree":
            return try .enterWorktree(container.decode(EnterWorktreeParameters.self))
        case "ExitWorktree":
            return try .exitWorktree(container.decode([String: AnyCodable].self))
        case "CronCreate":
            return try .cronCreate(container.decode([String: AnyCodable].self))
        case "CronDelete":
            return try .cronDelete(container.decode([String: AnyCodable].self))
        case "CronList":
            return try .cronList(container.decode([String: AnyCodable].self))
        case "ScheduleWakeup":
            return try .scheduleWakeup(container.decode([String: AnyCodable].self))
        case "PushNotification":
            return try .pushNotification(container.decode([String: AnyCodable].self))
        case "RemoteTrigger":
            return try .remoteTrigger(container.decode([String: AnyCodable].self))
        case "SendMessage":
            return try .sendMessage(container.decode([String: AnyCodable].self))
        case "TeamCreate":
            return try .teamCreate(container.decode([String: AnyCodable].self))
        case "TeamDelete":
            return try .teamDelete(container.decode([String: AnyCodable].self))
        case "ShareOnboardingGuide":
            return try .shareOnboardingGuide(container.decode([String: AnyCodable].self))
        case "WaitForMcpServers":
            return try .waitForMcpServers(container.decode([String: AnyCodable].self))
        case "ListMcpResourcesTool":
            return try .listMcpResources(container.decode(ListMcpResourcesParameters.self))
        case "ReadMcpResourceTool":
            return try .readMcpResource(container.decode(ReadMcpResourceParameters.self))
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
    public let type: String?
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
        case type
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

    public init(
        command: String,
        description: String,
        timeoutMs: Int? = nil,
        persistent: Bool? = nil
    ) {
        self.command = command
        self.description = description
        self.timeoutMs = timeoutMs
        self.persistent = persistent
    }
}

public struct PowerShellParameters: Codable, Sendable, Equatable {
    public let command: String
    public let description: String?
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
    public let subagentType: String
    public let model: Model?

    public enum Model: Codable, Sendable, Equatable {
        case sonnet
        case opus
        case haiku
        case unknown(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            switch raw {
            case "sonnet": self = .sonnet
            case "opus": self = .opus
            case "haiku": self = .haiku
            default: self = .unknown(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .sonnet: try container.encode("sonnet")
            case .opus: try container.encode("opus")
            case .haiku: try container.encode("haiku")
            case let .unknown(raw): try container.encode(raw)
            }
        }

        public var displayName: String {
            switch self {
            case .sonnet: "sonnet"
            case .opus: "opus"
            case .haiku: "haiku"
            case let .unknown(raw): raw
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case description
        case subagentType = "subagent_type"
        case model
    }

    public init(
        prompt: String,
        description: String,
        subagentType: String,
        model: Model? = nil
    ) {
        self.prompt = prompt
        self.description = description
        self.subagentType = subagentType
        self.model = model
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
    /// The markdown plan content (injected from the plan file on disk)
    public let plan: String?
    /// Path to the plan file on disk (injected)
    public let planFilePath: String?
    /// Prompt-based permissions requested for plan implementation
    public let allowedPrompts: [AllowedPrompt]?

    public init(plan: String?, planFilePath: String? = nil, allowedPrompts: [AllowedPrompt]?) {
        self.plan = plan
        self.planFilePath = planFilePath
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

public struct ToolSearchParameters: Codable, Sendable, Equatable {
    public let query: String
    public let maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
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
        public let description: String
        public let preview: String?

        public init(label: String, description: String, preview: String? = nil) {
            self.label = label
            self.description = description
            self.preview = preview
        }
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

    public init(taskId: String, block: Bool, timeout: Int) {
        self.taskId = taskId
        self.block = block
        self.timeout = timeout
    }
}

public struct TaskStopParameters: Codable, Sendable, Equatable {
    public let taskId: String?
    /// Deprecated: use taskId
    public let shellId: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case shellId = "shell_id"
    }

    public init(taskId: String? = nil, shellId: String? = nil) {
        self.taskId = taskId
        self.shellId = shellId
    }
}

public struct EnterWorktreeParameters: Codable, Sendable, Equatable {
    public let name: String?
    public let path: String?

    public init(name: String? = nil, path: String? = nil) {
        self.name = name
        self.path = path
    }
}

public struct ListMcpResourcesParameters: Codable, Sendable, Equatable {
    public let server: String?

    public init(server: String? = nil) {
        self.server = server
    }
}

public struct ReadMcpResourceParameters: Codable, Sendable, Equatable {
    public let server: String
    public let uri: String

    public init(server: String, uri: String) {
        self.server = server
        self.uri = uri
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
        case let .monitor(params):
            try container.encode(params)
        case let .powerShell(params):
            try container.encode(params)
        case let .agent(params):
            try container.encode(params)
        case let .todoWrite(params):
            try container.encode(params)
        case let .enterPlanMode(params):
            try container.encode(params)
        case let .exitPlanMode(params):
            try container.encode(params)
        case let .webFetch(params):
            try container.encode(params)
        case let .webSearch(params):
            try container.encode(params)
        case let .notebookEdit(params):
            try container.encode(params)
        case let .skill(params):
            try container.encode(params)
        case let .toolSearch(params):
            try container.encode(params)
        case let .askUserQuestion(params):
            try container.encode(params)
        case let .lsp(params):
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
        case let .enterWorktree(params):
            try container.encode(params)
        case let .exitWorktree(params):
            try container.encode(params)
        case let .cronCreate(params):
            try container.encode(params)
        case let .cronDelete(params):
            try container.encode(params)
        case let .cronList(params):
            try container.encode(params)
        case let .scheduleWakeup(params):
            try container.encode(params)
        case let .pushNotification(params):
            try container.encode(params)
        case let .remoteTrigger(params):
            try container.encode(params)
        case let .sendMessage(params):
            try container.encode(params)
        case let .teamCreate(params):
            try container.encode(params)
        case let .teamDelete(params):
            try container.encode(params)
        case let .shareOnboardingGuide(params):
            try container.encode(params)
        case let .waitForMcpServers(params):
            try container.encode(params)
        case let .listMcpResources(params):
            try container.encode(params)
        case let .readMcpResource(params):
            try container.encode(params)
        case let .mcp(params):
            try container.encode(params)
        case let .other(_, dictionary):
            try container.encode(dictionary)
        }
    }
}
