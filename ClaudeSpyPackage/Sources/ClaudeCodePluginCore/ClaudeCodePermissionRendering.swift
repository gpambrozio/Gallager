import ClaudeSpyNetworking
import Foundation

// MARK: - ClaudeCodePermissionRendering

/// Helper namespace for turning legacy `PermissionRequestBody` content into
/// the wire-stable shapes the iOS app expects. Lives in the sidecar core so
/// the rendering of "what is Claude about to do" happens on the Mac (per
/// Spec §7.2: "description is rendered to plain text BY THE SIDECAR; iOS
/// just displays").
///
/// The iOS `PermissionRequestResponseView` and `ExitPlanModeResponseView`
/// formatters today live in `ClaudeSpyFeature/Views/ResponseViews/`. The
/// strings produced here mirror the pieces of that UI's `ToolInputView`
/// detail rows so the plain-text description shown by iOS in v1.33+ stays
/// recognisable to users.
public enum ClaudeCodePermissionRendering {
    // MARK: - Description rendering

    /// Plain-text description shown by the iOS permission card. Lines are
    /// joined with `\n`; consumers display verbatim.
    ///
    /// `public` so `CodexPluginCore`'s translator can share the same
    /// rendering for the tool subset Codex inherits from Claude (per the
    /// "Before You Begin" note in Task 10's plan).
    public static func description(toolInput: ClaudeCodeTool?, toolName: String?) -> String {
        guard let toolInput else {
            return toolName ?? "Permission request"
        }
        switch toolInput {
        case let .read(params):
            return lines([
                "Read File",
                "File: \(params.filePath)",
                params.offset.map { "Starting at line: \($0)" },
                params.limit.map { "Reading: \($0) lines" },
            ])
        case let .edit(params):
            var l: [String?] = [
                "Edit File",
                "File: \(params.filePath)",
                "Replacing: \(truncate(params.oldString))",
                "With: \(truncate(params.newString))",
            ]
            if params.replaceAll == true {
                l.append("Mode: Replace all occurrences")
            }
            return lines(l)
        case let .write(params):
            return lines([
                "Write File",
                "File: \(params.filePath)",
                "Content length: \(params.content.count) characters",
            ])
        case let .grep(params):
            return lines([
                "Search with Grep",
                "Pattern: \(params.pattern)",
                params.path.map { "In: \($0)" },
                params.glob.map { "Files: \($0)" },
                params.outputMode.map {
                    "Mode: \($0.rawValue.replacingOccurrences(of: "_", with: " "))"
                },
            ])
        case let .glob(params):
            return lines([
                "Find Files",
                "Pattern: \(params.pattern)",
                params.path.map { "In: \($0)" },
            ])
        case let .bash(params):
            return lines([
                "Run Command",
                "Command: \(truncate(params.command))",
                params.description.map { "Description: \($0)" },
            ])
        case let .monitor(params):
            return lines([
                "Monitor Command",
                "Command: \(truncate(params.command))",
                "Description: \(params.description)",
                params.timeoutMs.map { "Timeout: \($0) ms" },
                (params.persistent == true) ? "Mode: Persistent" : nil,
            ])
        case let .agent(params):
            return lines([
                "Run Agent",
                "Type: \(params.subagentType)",
                "Task: \(params.description)",
                params.model.map { "Model: \($0.displayName)" },
            ])
        case let .todoWrite(params):
            return lines([
                "Manage Todo List",
                "Managing: \(params.todos.count) todo items",
            ])
        case let .exitPlanMode(params):
            return lines([
                "Exit Plan Mode",
                params.allowedPrompts.map { "Permissions: \($0.count) requested" },
                params.plan != nil ? "Plan: Included" : nil,
            ])
        case let .webFetch(params):
            return lines([
                "Fetch Web Page",
                "URL: \(params.url)",
                "Purpose: \(params.prompt)",
            ])
        case let .webSearch(params):
            return lines([
                "Search the Web",
                "Query: \(params.query)",
                params.allowedDomains.flatMap { $0.isEmpty ? nil : "Allowed domains: \($0.joined(separator: ", "))" },
                params.blockedDomains.flatMap { $0.isEmpty ? nil : "Blocked domains: \($0.joined(separator: ", "))" },
            ])
        case let .notebookEdit(params):
            return lines([
                "Edit Jupyter Notebook",
                "Notebook: \(params.notebookPath)",
                params.cellId.map { "Cell ID: \($0)" },
                params.cellType.map { "Cell type: \($0.rawValue)" },
                params.editMode.map { "Mode: \($0.rawValue)" },
            ])
        case let .skill(params):
            return lines([
                "Run Skill",
                "Skill: \(params.skill)",
                params.args.map { "Arguments: \($0)" },
            ])
        case let .toolSearch(params):
            return lines([
                "Search Tools",
                "Query: \(params.query)",
                params.maxResults.map { "Max results: \($0)" },
            ])
        case let .askUserQuestion(params):
            var l: [String?] = ["Ask User Questions", "Questions: \(params.questions.count)"]
            for (i, q) in params.questions.enumerated() {
                l.append("\(i + 1). \(q.question)")
            }
            return lines(l)
        case let .taskOutput(params):
            return lines([
                "Get Task Output",
                "Task ID: \(params.taskId)",
                "Block: \(params.block ? "Yes" : "No")",
                "Timeout: \(params.timeout)",
            ])
        case let .taskStop(params):
            return lines([
                "Stop Task",
                params.taskId.map { "Task ID: \($0)" },
                params.shellId.map { "Shell ID: \($0)" },
            ])
        case let .enterWorktree(params):
            return lines([
                "Enter Worktree",
                params.name.map { "Name: \($0)" },
                params.path.map { "Path: \($0)" },
            ])
        case let .listMcpResources(params):
            return lines([
                "List MCP Resources",
                params.server.map { "Server: \($0)" },
            ])
        case let .readMcpResource(params):
            return lines([
                "Read MCP Resource",
                "Server: \(params.server)",
                "URI: \(params.uri)",
            ])
        case let .mcp(params):
            return lines([
                "MCP Tool",
                "Server: \(params.server)",
                "Tool: \(params.tool)",
            ])
        case let .other(name, _):
            return name
        }
    }

    // MARK: - Suggestion mapping

    /// Map legacy `PermissionSuggestion`s into the new closed-set
    /// `PermissionRequest.Suggestion`. Empty input → empty output.
    public static func mappedSuggestions(
        legacy: [PermissionSuggestion]
    ) -> [PermissionRequest.Suggestion] {
        var result: [PermissionRequest.Suggestion] = []
        result.reserveCapacity(legacy.count)
        for (index, suggestion) in legacy.enumerated() {
            let id = String(index)
            let label = suggestionLabel(for: suggestion)
            let badge = suggestion.destination?.badgeText
            result.append(.init(id: id, label: label, badge: badge))
        }
        return result
    }

    /// Ask-user-question request mapper.
    public static func askUserQuestionRequest(
        from params: AskUserQuestionParameters
    ) -> AskUserQuestionRequest {
        AskUserQuestionRequest(questions: params.questions.map { q in
            AskUserQuestionRequest.Question(
                prompt: q.question,
                options: q.options.map { opt in
                    AskUserQuestionRequest.Option(
                        label: opt.label,
                        detail: opt.description.isEmpty ? nil : opt.description
                    )
                },
                allowMultiple: q.multiSelect,
                // Claude Code's AskUserQuestion always exposes an "Other"
                // free-text path; the original UI surfaced it on every
                // question regardless of `multiSelect`.
                allowFreeText: true
            )
        })
    }

    // MARK: - Internal helpers

    private static func lines(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: "\n")
    }

    private static func truncate(_ s: String, max: Int = 200) -> String {
        guard s.count > max else { return s }
        return s.prefix(max) + "…"
    }

    private static func suggestionLabel(for suggestion: PermissionSuggestion) -> String {
        switch (suggestion.type, suggestion.destination) {
        case (.addRules, .session):
            "Allow for this session"
        case (.addRules, .localSettings):
            "Remember and always allow"
        case (.addDirectories, .session):
            "Allow directory for this session"
        case (.addDirectories, .localSettings):
            "Remember and always allow directory"
        case (.setMode, .session):
            "Set mode for this session"
        case (.setMode, .localSettings):
            "Save mode to settings"
        default:
            [suggestion.type?.displayName, "for", suggestion.destination?.stringValue.lowercased()]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }
}

// MARK: - Internal extensions

extension PermissionDestination {
    /// Badge text mirrors the iOS `PermissionRequestResponseView` copy
    /// ("THIS SESSION", "ALWAYS", ...).
    var badgeText: String {
        switch self {
        case .session: "THIS SESSION"
        case .localSettings: "ALWAYS"
        case let .other(val): val.uppercased()
        }
    }
}
