import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Closure type for sending commands from response views.
/// Takes a CommandType directly - SessionDetailView adds the paneId when sending.
typealias CommandSender = @MainActor (CommandType) async -> Void

// MARK: - Event Response Extension

extension HookEvent {
    /// Returns a contextual response view based on the event type, or nil if no response UI is needed.
    @MainActor
    func responseView(
        isConnected: Bool,
        sendCommand: @escaping CommandSender
    ) -> AnyView? {
        switch action {
        case .sessionStart,
             .stop:
            AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand))
        case let .notification(body) where body.notificationType == "idle_prompt":
            AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand))
        case let .permissionRequest(body):
            AnyView(PermissionRequestResponseView(
                request: body,
                isConnected: isConnected,
                sendCommand: sendCommand
            ))
        default:
            nil
        }
    }
}

// MARK: - Prompt View

/// Text input view for sending messages to Claude.
struct PromptView: View {
    let isConnected: Bool
    let sendCommand: CommandSender

    @State private var inputText = ""
    @State private var isSending = false
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            textField
            sendButtonRow
        }
        .padding(.vertical, 8)
    }

    private var textField: some View {
        TextField("Send a message to Claude...", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(textFieldBackground)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .disabled(isSending || !isConnected)
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private var sendButtonRow: some View {
        HStack {
            Spacer()
            Button {
                sendMessage()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInputEmpty || isSending || !isConnected)
        }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true

        Task {
            await sendCommand(.sendKeystroke([.text(trimmed), .enter]))
            inputText = ""
            isSending = false
        }
    }
}

// MARK: - Permission Response Type

/// Represents the user's response to a permission request
enum PermissionResponse {
    case accepted
    case acceptedWithSuggestion
    case rejected
    case customInstructions(String)

    var feedbackMessage: String {
        switch self {
        case .accepted:
            "Permission accepted"
        case .acceptedWithSuggestion:
            "Permission accepted with suggestion"
        case .rejected:
            "Permission rejected"
        case let .customInstructions(text):
            "Sent: \(text)"
        }
    }

    var feedbackColor: Color {
        switch self {
        case .accepted,
             .acceptedWithSuggestion:
            .green
        case .rejected:
            .red
        case .customInstructions:
            .blue
        }
    }
}

// MARK: - Permission Request Response View

/// Accept/Reject buttons with permission suggestions for permission requests.
struct PermissionRequestResponseView: View {
    let request: PermissionRequestBody
    let isConnected: Bool
    let sendCommand: CommandSender

    @State private var isSending = false
    @State private var customInstructions = ""
    @State private var response: PermissionResponse?
    @FocusState private var isTextFieldFocused: Bool

    private var suggestions: [PermissionSuggestion] {
        request.permissionSuggestions ?? []
    }

    private var isInputEmpty: Bool {
        customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if let response {
            if case .rejected = response {
                VStack(spacing: 12) {
                    responseFeedback(response)
                    PromptView(isConnected: isConnected, sendCommand: sendCommand)
                }
            } else {
                responseFeedback(response)
            }
        } else {
            permissionContent
        }
    }

    private func responseFeedback(_ response: PermissionResponse) -> some View {
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

    private var permissionContent: some View {
        VStack(spacing: 12) {
            // Show what's being requested
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

            // Accept button
            Button {
                Task {
                    await sendCommand(.sendKeystroke([.text("1")]))
                    response = .accepted
                }
            } label: {
                Label("Accept", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || isSending)

            // Permission suggestions (single combined button)
            if !suggestions.isEmpty {
                combinedSuggestionsButton
            }

            // Reject button
            Button {
                Task {
                    await sendCommand(.sendKeystroke([.escape]))
                    response = .rejected
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || isSending)

            // Custom instructions text area
            VStack(spacing: 8) {
                TextField("Custom instructions...", text: $customInstructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(textFieldBackground)
                    .overlay(textFieldBorder)
                    .focused($isTextFieldFocused)
                    .disabled(isSending || !isConnected)

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
                        .disabled(isInputEmpty || isSending || !isConnected)
                    }
                }
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var combinedSuggestionsButton: some View {
        Button {
            Task {
                // Send "2" to select the first suggestion option
                await sendCommand(.sendKeystroke([.text("2")]))
                response = .acceptedWithSuggestion
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accept Suggestion:")
                    .fontWeight(.medium)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    HStack {
                        Text("\(index + 2).")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(suggestionLabel(for: suggestion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .tint(.blue)
        .disabled(!isConnected || isSending)
    }

    private func suggestionLabel(for suggestion: PermissionSuggestion) -> String {
        // Build a descriptive label from the suggestion
        var parts: [String] = []

        if let type = suggestion.type {
            parts.append(type)
        }

        if let rules = suggestion.rules, !rules.isEmpty {
            let ruleDescriptions = rules.compactMap { rule -> String? in
                rule.ruleContent ?? rule.toolName
            }
            if !ruleDescriptions.isEmpty {
                parts.append(contentsOf: ruleDescriptions)
            }
        }

        if let behavior = suggestion.behavior {
            parts.append(behavior)
        }

        if let destination = suggestion.destination {
            parts.append("→ \(destination)")
        }

        return parts.isEmpty ? (suggestion.type?.capitalized ?? "Option") : parts.joined(separator: " ")
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private func sendCustomInstructions() async {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optionNumber = suggestions.isEmpty ? 2 : 3
        isSending = true
        await sendCommand(.sendKeystroke([.text("\(optionNumber)"), .text(trimmed), .enter]))
        let sentText = customInstructions
        customInstructions = ""
        isSending = false
        response = .customInstructions(sentText)
    }
}

private struct ToolInputView: View {
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
                headerRow("Execute Command")
                detailRow("Command:", params.command, maxLines: 3)
                if let desc = params.description {
                    detailRow("Description:", desc, maxLines: 2)
                }
                if let timeout = params.timeout {
                    detailRow("Timeout:", "\(timeout / 1_000)s")
                }
                if params.runInBackground == true {
                    detailRow("Mode:", "Background execution")
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

            case .exitPlanMode:
                headerRow("Exit Plan Mode")

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
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .gridCellColumns(2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func detailRow(_ label: String, _ value: String, maxLines: Int = 1) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(maxLines)
                .truncationMode(.tail)
                .gridColumnAlignment(.leading)
        }
    }
}

#Preview("Prompt View") {
    List {
        Section("Response") {
            PromptView(
                isConnected: true,
                sendCommand: { _ in }
            )
        }
    }
}

#Preview("Permission Request") {
    List {
        Section("Response") {
            PermissionRequestResponseView(
                request: PermissionRequestBody.preview,
                isConnected: true,
                sendCommand: { _ in }
            )
        }
    }
}

#Preview("Permission Request with Suggestions") {
    List {
        Section("Response") {
            PermissionRequestResponseView(
                request: PermissionRequestBody.previewWithSuggestions,
                isConnected: true,
                sendCommand: { _ in }
            )
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
            permissionSuggestions: [
                PermissionSuggestion(
                    type: "allow_once",
                    behavior: "Allow this command once"
                ),
                PermissionSuggestion(
                    type: "allow_session",
                    rules: [
                        PermissionRule(toolName: "Bash", ruleContent: "git status"),
                    ],
                    behavior: "Allow for this session"
                ),
                PermissionSuggestion(
                    type: "allow_always",
                    rules: [
                        PermissionRule(toolName: "Bash", ruleContent: "git *"),
                    ],
                    destination: "project"
                ),
            ]
        )
    }
}
