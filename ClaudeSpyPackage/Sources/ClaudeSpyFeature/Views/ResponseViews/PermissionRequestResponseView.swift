import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Permission UI Extensions

extension PermissionDestination {
    /// Badge text for UI display
    var badgeText: String {
        switch self {
        case .session: "THIS SESSION"
        case .localSettings: "ALWAYS"
        case let .other(val): val.uppercased()
        }
    }

    /// Badge color for UI display
    var badgeColor: Color {
        switch self {
        case .session: .blue
        case .localSettings: .orange
        case .other: .gray
        }
    }
}

extension PermissionSuggestion {
    /// Human-readable description of the suggestion
    var humanReadableDescription: String {
        switch (type, destination) {
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
            [type?.displayName, "for", destination?.stringValue.lowercased()]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }
}

// MARK: - Permission Request Response View

/// Accept/Reject buttons with permission suggestions for permission requests.
struct PermissionRequestResponseView: View {
    let request: PermissionRequestBody
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    @State private var customInstructions = ""
    @FocusState private var isTextFieldFocused: Bool

    private var suggestions: [PermissionSuggestion] {
        request.permissionSuggestions ?? []
    }

    private var isInputEmpty: Bool {
        customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if let response = state.response {
            if case .rejected = response {
                VStack(spacing: 12) {
                    responseFeedback(response)
                    PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state)
                }
            } else {
                responseFeedback(response)
            }
        } else {
            permissionContent
        }
    }

    private func responseFeedback(_ response: ResponseType) -> some View {
        HStack {
            (response.feedbackColor == .green ? Symbols.checkmarkCircleFill.image :
                response.feedbackColor == .red ? Symbols.xmarkCircleFill.image : Symbols.arrowUpCircleFill.image)
                .foregroundStyle(response.feedbackColor)
            Text(response.feedbackMessage)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: - Permission Content

    private var permissionContent: some View {
        VStack(spacing: 12) {
            // Tool request card
            toolRequestCard

            // Side-by-side action buttons
            actionButtonRow

            // Permission suggestions card (if any)
            if !suggestions.isEmpty {
                suggestionCard
            }

            // Custom instructions
            customInstructionsSection

            if state.isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tool Request Card

    private var toolRequestCard: some View {
        Group {
            if let tool = request.toolInput {
                ToolInputView(tool: tool)
            } else if let toolName = request.toolName {
                HStack {
                    Text("Tool:")
                        .foregroundStyle(.secondary)
                    Text(toolName)
                        .fontWeight(.medium)
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
    }

    // MARK: - Action Buttons

    private var actionButtonRow: some View {
        HStack(spacing: 12) {
            // Reject button (left)
            Button {
                Task {
                    await sendCommand(.sendKeystroke([.escape]))
                    state.response = .rejected
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || state.isSending)

            // Accept button (right)
            Button {
                Task {
                    await sendCommand(.sendKeystroke([.text("1")]))
                    state.response = .accepted
                }
            } label: {
                Label("Accept", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || state.isSending)
        }
    }

    // MARK: - Suggestion Card

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Symbols.lockFill.image
                    .foregroundStyle(.blue)
                Text("Save Permission Rule")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            // Suggestions list (group by destination - only show header for first in each group)
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                let previousDestination = index > 0 ? suggestions[index - 1].destination : nil
                let showHeader = suggestion.destination != previousDestination
                SuggestionRow(suggestion: suggestion, showHeader: showHeader)
            }

            // Accept with suggestion button
            Button {
                Task {
                    await sendCommand(.sendKeystroke([.text("2")]))
                    state.response = .acceptedWithSuggestion
                }
            } label: {
                Text("Accept with Rule")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.blue)
            .disabled(!isConnected || state.isSending)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Custom Instructions

    private var customInstructionsSection: some View {
        VStack(spacing: 8) {
            TextField("Custom instructions...", text: $customInstructions, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .focused($isTextFieldFocused)
                .disabled(state.isSending || !isConnected)

            if !isInputEmpty {
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await sendCustomInstructions()
                        }
                    } label: {
                        Text("Send")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInputEmpty || state.isSending || !isConnected)
                }
            }
        }
    }

    private func sendCustomInstructions() async {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optionNumber = suggestions.isEmpty ? 2 : 3
        state.isSending = true
        await sendCommand(.sendKeystroke([.text("\(optionNumber)"), .text(trimmed), .enter]))
        let sentText = customInstructions
        customInstructions = ""
        state.isSending = false
        state.response = .customInstructions(sentText)
    }
}

// MARK: - Suggestion Row

private struct SuggestionRow: View {
    let suggestion: PermissionSuggestion
    var showHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Destination badge + description (only shown for first in each destination group)
            if showHeader {
                HStack(spacing: 8) {
                    if let destination = suggestion.destination {
                        DestinationBadge(destination: destination)
                    }
                    Text(suggestion.humanReadableDescription)
                        .font(.subheadline)
                    Spacer()
                }
            }

            // Rules (always shown)
            if let rules = suggestion.rules, !rules.isEmpty {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    RuleRow(rule: rule)
                }
            }
        }
    }
}

// MARK: - Destination Badge

private struct DestinationBadge: View {
    let destination: PermissionDestination

    var body: some View {
        Text(destination.badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(destination.badgeColor))
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    let rule: PermissionRule

    var body: some View {
        HStack(spacing: 6) {
            if let toolName = rule.toolName {
                Text(toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            if let content = rule.ruleContent {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
    }
}

// MARK: - Tool Input View

struct ToolInputView: View {
    let tool: ClaudeCodeTool

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            switch tool {
            case let .read(params):
                headerRow("Read File")
                detailRow("File:", params.filePath)
                if let offset = params.offset {
                    detailRow("Starting at line:", "\(offset)")
                }
                if let limit = params.limit {
                    detailRow("Reading:", "\(limit) lines")
                }

            case let .edit(params):
                headerRow("Edit File")
                detailRow("File:", params.filePath)
                detailRow("Replacing:", params.oldString, maxLines: 2)
                detailRow("With:", params.newString, maxLines: 2)
                if let replaceAll = params.replaceAll, replaceAll {
                    detailRow("Mode:", "Replace all occurrences")
                }

            case let .write(params):
                headerRow("Write File")
                detailRow("File:", params.filePath)
                detailRow("Content length:", "\(params.content.count) characters")

            case let .multiEdit(params):
                headerRow("Multi-Edit File")
                detailRow("File:", params.filePath)
                detailRow("Number of edits:", "\(params.edits.count)")

            case let .grep(params):
                headerRow("Search with Grep")
                detailRow("Pattern:", params.pattern)
                if let path = params.path {
                    detailRow("In:", path)
                }
                if let glob = params.glob {
                    detailRow("Files:", glob)
                }
                if let mode = params.outputMode {
                    detailRow("Mode:", mode.rawValue.replacingOccurrences(of: "_", with: " "))
                }

            case let .glob(params):
                headerRow("Find Files")
                detailRow("Pattern:", params.pattern)
                if let path = params.path {
                    detailRow("In:", path)
                }

            case let .bash(params):
                headerRow("Run Command")
                detailRow("Command:", params.command, maxLines: 3)
                if let desc = params.description {
                    detailRow("Description:", desc, maxLines: 3)
                }

            case let .bashOutput(params):
                headerRow("Read Command Output")
                detailRow("Bash ID:", params.bashId)
                if let filter = params.filter {
                    detailRow("Filter:", filter)
                }

            case let .killShell(params):
                headerRow("Kill Shell")
                detailRow("Shell ID:", params.shellId)

            case let .task(params):
                headerRow("Run Subagent Task")
                detailRow("Subagent:", params.subagentType.rawValue)
                detailRow("Task:", params.description)

            case let .todoWrite(params):
                headerRow("Manage Todo List")
                detailRow("Managing:", "\(params.todos.count) todo items")

            case let .exitPlanMode(params):
                headerRow("Exit Plan Mode")
                if let prompts = params.allowedPrompts {
                    detailRow("Permissions:", "\(prompts.count) requested")
                }
                if params.plan != nil {
                    detailRow("Plan:", "Included")
                }

            case let .webFetch(params):
                headerRow("Fetch Web Page")
                detailRow("URL:", params.url)
                detailRow("Purpose:", params.prompt, maxLines: 2)

            case let .webSearch(params):
                headerRow("Search the Web")
                detailRow("Query:", params.query)
                if let allowed = params.allowedDomains, !allowed.isEmpty {
                    detailRow("Allowed domains:", allowed.joined(separator: ", "))
                }
                if let blocked = params.blockedDomains, !blocked.isEmpty {
                    detailRow("Blocked domains:", blocked.joined(separator: ", "))
                }

            case let .notebookEdit(params):
                headerRow("Edit Jupyter Notebook")
                detailRow("Notebook:", params.notebookPath)
                if let cellId = params.cellId {
                    detailRow("Cell ID:", cellId)
                }
                if let cellType = params.cellType {
                    detailRow("Cell type:", cellType.rawValue)
                }
                if let mode = params.editMode {
                    detailRow("Mode:", mode.rawValue)
                }

            case let .slashCommand(params):
                headerRow("Run Slash Command")
                detailRow("Command:", params.command)

            case let .askUserQuestion(params):
                headerRow("Ask User Questions")
                detailRow("Questions:", "\(params.questions.count)")
                ForEach(Array(params.questions.enumerated()), id: \.offset) { index, question in
                    detailRow("\(index + 1).", question.question, maxLines: 2)
                }

            case let .mcp(params):
                headerRow("MCP Tool")
                detailRow("Server:", params.server)
                detailRow("Tool:", params.tool)

            case let .other(name, _):
                headerRow(name)
            }
        }
        .font(.headline)
    }

    private func headerRow(_ text: String) -> some View {
        GridRow {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
                .gridCellColumns(2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func detailRow(_ label: String, _ value: String, maxLines: Int = 1) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
                .lineLimit(maxLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
    }
}

// MARK: - Preview Helpers

extension PermissionRequestBody {
    static var preview: PermissionRequestBody {
        PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: .bash(
                .init(
                    command: "swift compile --verbose --enable-testing",
                    description: "Compile your code"
                )
            )
        )
    }

    static var previewWithSuggestions: PermissionRequestBody {
        PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: .bash(
                .init(
                    command: "git status",
                    description: "Check git status"
                )
            ),
            permissionSuggestions: [
                // Two session-scoped suggestions (badge shown only on first)
                PermissionSuggestion(
                    type: .addRules,
                    rules: [
                        PermissionRule(toolName: "Bash", ruleContent: "git status"),
                    ],
                    behavior: .allow,
                    destination: .session
                ),
                PermissionSuggestion(
                    type: .addRules,
                    rules: [
                        PermissionRule(toolName: "Bash", ruleContent: "git diff"),
                    ],
                    behavior: .allow,
                    destination: .session
                ),
                // Different destination - badge shown again
                PermissionSuggestion(
                    type: .addRules,
                    rules: [
                        PermissionRule(toolName: "Bash", ruleContent: "git *"),
                    ],
                    behavior: .allow,
                    destination: .localSettings
                ),
            ]
        )
    }
}

// MARK: - Previews

#Preview("Permission Request") {
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody.preview),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                PermissionRequestResponseView(
                    request: PermissionRequestBody.preview,
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}

#Preview("Permission Request with Suggestions") {
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody.previewWithSuggestions),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                PermissionRequestResponseView(
                    request: PermissionRequestBody.previewWithSuggestions,
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}
