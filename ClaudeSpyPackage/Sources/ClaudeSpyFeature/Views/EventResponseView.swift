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
        sendCommand: @escaping CommandSender,
        state: ResponseState
    ) -> AnyView? {
        switch action {
        case .sessionStart,
             .stop:
            AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state))
        case let .permissionRequest(body):
            // Check if this is actually an AskUserQuestion disguised as a permission request
            if let toolInput = body.toolInput, case let .askUserQuestion(params) = toolInput {
                AnyView(AskUserQuestionResponseView(
                    params: params,
                    isConnected: isConnected,
                    sendCommand: sendCommand,
                    state: state
                ))
            } else {
                AnyView(PermissionRequestResponseView(
                    request: body,
                    isConnected: isConnected,
                    sendCommand: sendCommand,
                    state: state
                ))
            }
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
    let state: ResponseState

    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        textField
            .padding(.vertical, 8)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if state.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Send") {
                            sendMessage()
                        }
                        .disabled(isInputEmpty || !isConnected)
                    }
                }
            }
    }

    private var textField: some View {
        TextField("Send a message to Claude...", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(textFieldBackground)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .disabled(state.isSending || !isConnected)
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.isSending = true

        Task {
            await sendCommand(.sendKeystroke([.text(trimmed), .enter]))
            inputText = ""
            state.isSending = false
        }
    }
}

// MARK: - Ask User Question Response View

/// Interactive question response view for AskUserQuestion tool calls.
struct AskUserQuestionResponseView: View {
    let params: AskUserQuestionParameters
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    /// Tracks which question index we're currently on
    @State private var currentQuestionIndex = 0
    /// For multi-select questions, tracks selected option indices
    @State private var selectedOptions: Set<Int> = []
    /// For "Other" option custom input
    @State private var customInputText = ""
    /// Whether we're showing the custom input field
    @State private var showingCustomInput = false
    @FocusState private var isTextFieldFocused: Bool

    private var questions: [AskUserQuestionParameters.AskUserQuestion] {
        params.questions
    }

    private var currentQuestion: AskUserQuestionParameters.AskUserQuestion? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    private var isComplete: Bool {
        currentQuestionIndex >= questions.count
    }

    var body: some View {
        if isComplete {
            completionFeedback
        } else if let question = currentQuestion {
            questionContent(question)
        }
    }

    private var completionFeedback: some View {
        HStack {
            Symbols.checkmarkCircleFill.image
                .foregroundStyle(.green)
            Text("All questions answered")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func questionContent(_ question: AskUserQuestionParameters.AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Progress indicator
            if questions.count > 1 {
                progressHeader
            }

            // Question header and text
            questionHeader(question)

            // Options
            optionsList(question)

            // "Other" option
            otherOptionSection

            // Multi-select submit button
            if question.multiSelect && !selectedOptions.isEmpty && !showingCustomInput {
                submitMultiSelectButton
            }

            if state.isSending {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var progressHeader: some View {
        HStack {
            Text("Question \(currentQuestionIndex + 1) of \(questions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func questionHeader(_ question: AskUserQuestionParameters.AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header tag
            Text(question.header.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.blue))

            // Question text
            Text(question.question)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func optionsList(_ question: AskUserQuestionParameters.AskUserQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionButton(option, index: index, isMultiSelect: question.multiSelect)
            }
        }
    }

    private func optionButton(
        _ option: AskUserQuestionParameters.AskUserQuestionOption,
        index: Int,
        isMultiSelect: Bool
    ) -> some View {
        Button {
            if isMultiSelect {
                toggleMultiSelectOption(index)
            } else {
                selectSingleOption(index)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // Selection indicator
                if isMultiSelect {
                    (selectedOptions.contains(index) ? Symbols.checkmarkSquareFill.image : Symbols.square.image)
                        .foregroundStyle(selectedOptions.contains(index) ? .blue : .secondary)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.blue))
                }

                // Option content
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(optionBackground(isSelected: selectedOptions.contains(index)))
            .overlay(optionBorder(isSelected: selectedOptions.contains(index)))
        }
        .buttonStyle(.plain)
        .disabled(!isConnected || state.isSending)
    }

    private func optionBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
    }

    private func optionBorder(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
    }

    @ViewBuilder
    private var otherOptionSection: some View {
        if showingCustomInput {
            VStack(spacing: 8) {
                TextField("Enter your response...", text: $customInputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue, lineWidth: 1))
                    .focused($isTextFieldFocused)
                    .disabled(state.isSending || !isConnected)

                HStack {
                    Button("Cancel") {
                        showingCustomInput = false
                        customInputText = ""
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Submit") {
                        submitCustomInput()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            Button {
                showingCustomInput = true
                isTextFieldFocused = true
            } label: {
                HStack(spacing: 12) {
                    Symbols.pencilLine.image
                        .foregroundStyle(.secondary)
                    Text("Other...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || state.isSending)
        }
    }

    private var submitMultiSelectButton: some View {
        Button {
            submitMultiSelect()
        } label: {
            Label("Submit Selection", symbol: .checkmarkCircleFill)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!isConnected || state.isSending || selectedOptions.isEmpty)
    }

    // MARK: - Actions

    private func selectSingleOption(_ index: Int) {
        state.isSending = true
        Task {
            // Send the option number (1-indexed as shown in UI)
            await sendCommand(.sendKeystroke([.text("\(index + 1)")]))
            state.response = .questionAnswered(
                questionIndex: currentQuestionIndex,
                selectedOptions: [index]
            )
            advanceToNextQuestion()
        }
    }

    private func toggleMultiSelectOption(_ index: Int) {
        if selectedOptions.contains(index) {
            selectedOptions.remove(index)
        } else {
            selectedOptions.insert(index)
        }
    }

    private func submitMultiSelect() {
        guard !selectedOptions.isEmpty else { return }

        state.isSending = true
        Task {
            // For multi-select, send each selected option number separated by commas
            // This is a reasonable assumption for how the CLI might handle it
            let sortedSelections = selectedOptions.sorted()
            let selectionString = sortedSelections.map { String($0 + 1) }.joined(separator: ",")
            await sendCommand(.sendKeystroke([.text(selectionString), .enter]))
            state.response = .questionAnswered(
                questionIndex: currentQuestionIndex,
                selectedOptions: selectedOptions
            )
            advanceToNextQuestion()
        }
    }

    private func submitCustomInput() {
        let trimmed = customInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.isSending = true
        Task {
            // Send the "Other" option number (options count + 1) followed by the custom text
            let otherOptionNumber = (currentQuestion?.options.count ?? 0) + 1
            await sendCommand(.sendKeystroke([.text("\(otherOptionNumber)"), .text(trimmed), .enter]))
            state.response = .customInstructions(trimmed)
            customInputText = ""
            showingCustomInput = false
            advanceToNextQuestion()
        }
    }

    private func advanceToNextQuestion() {
        state.isSending = false
        currentQuestionIndex += 1
        selectedOptions = []

        if isComplete {
            state.response = .allQuestionsAnswered
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

            // Permission suggestions (single combined button)
            if !suggestions.isEmpty {
                combinedSuggestionsButton
            }

            // Reject button
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

            // Custom instructions text area
            VStack(spacing: 8) {
                TextField("Custom instructions...", text: $customInstructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(textFieldBackground)
                    .overlay(textFieldBorder)
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

            if state.isSending {
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
                state.response = .acceptedWithSuggestion
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accept Suggestion:")
                    .fontWeight(.medium)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    suggestionLabel(for: suggestion)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .tint(.blue)
        .disabled(!isConnected || state.isSending)
    }

    private func suggestionLabel(for suggestion: PermissionSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Build a descriptive label from the suggestion
            let parts: [String?] = [
                suggestion.type?.stringValue,
                suggestion.behavior?.stringValue,
                "to",
                suggestion.destination?.stringValue,
            ]

            HStack(spacing: 4) {
                Text(parts.compactMap(\.self).joined(separator: " "))
                Spacer()
            }

            if let rules = suggestion.rules {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    HStack(alignment: .top, spacing: 4) {
                        if let toolName = rule.toolName {
                            Text(toolName)
                        }

                        if let ruleContent = rule.ruleContent {
                            Text(ruleContent)
                        }

                        Spacer()
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        state.isSending = true
        await sendCommand(.sendKeystroke([.text("\(optionNumber)"), .text(trimmed), .enter]))
        let sentText = customInstructions
        customInstructions = ""
        state.isSending = false
        state.response = .customInstructions(sentText)
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
    let event = HookEvent(
        action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
        Section("Response") {
            PromptView(
                isConnected: true,
                sendCommand: { _ in },
                state: state
            )
        }
    }
}

#Preview("Permission Request") {
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody.preview),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
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

#Preview("Permission Request with Suggestions") {
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody.previewWithSuggestions),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
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

#Preview("Ask User Question - Single Select") {
    let params = AskUserQuestionParameters.previewSingleSelect
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .askUserQuestion(params)
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
        Section("Question") {
            AskUserQuestionResponseView(
                params: params,
                isConnected: true,
                sendCommand: { _ in },
                state: state
            )
        }
    }
}

#Preview("Ask User Question - Multi Select") {
    let params = AskUserQuestionParameters.previewMultiSelect
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .askUserQuestion(params)
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
        Section("Question") {
            AskUserQuestionResponseView(
                params: params,
                isConnected: true,
                sendCommand: { _ in },
                state: state
            )
        }
    }
}

#Preview("Ask User Question - Multiple Questions") {
    let params = AskUserQuestionParameters.previewMultipleQuestions
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .askUserQuestion(params)
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return List {
        Section("Question") {
            AskUserQuestionResponseView(
                params: params,
                isConnected: true,
                sendCommand: { _ in },
                state: state
            )
        }
    }
}

// MARK: - Preview Helpers

extension AskUserQuestionParameters {
    static var previewSingleSelect: AskUserQuestionParameters {
        AskUserQuestionParameters(
            questions: [
                AskUserQuestion(
                    question: "The current networking only supports request/response. For live streaming, should I add new WebSocket message types?",
                    header: "Streaming",
                    options: [
                        AskUserQuestionOption(
                            label: "Yes, new message types (Recommended)",
                            description: "Add dedicated streaming messages for continuous data flow. More efficient, cleaner architecture."
                        ),
                        AskUserQuestionOption(
                            label: "Polling with existing snapshots",
                            description: "Request snapshots repeatedly at intervals. Simpler but higher latency and network overhead."
                        ),
                    ],
                    multiSelect: false
                ),
            ],
            answers: nil
        )
    }

    static var previewMultiSelect: AskUserQuestionParameters {
        AskUserQuestionParameters(
            questions: [
                AskUserQuestion(
                    question: "Which features do you want to enable for the new dashboard?",
                    header: "Features",
                    options: [
                        AskUserQuestionOption(
                            label: "Real-time updates",
                            description: "Live data streaming via WebSockets"
                        ),
                        AskUserQuestionOption(
                            label: "Dark mode",
                            description: "Support for dark color scheme"
                        ),
                        AskUserQuestionOption(
                            label: "Export to CSV",
                            description: "Download data in CSV format"
                        ),
                        AskUserQuestionOption(
                            label: "Charts and graphs",
                            description: "Visual data representation"
                        ),
                    ],
                    multiSelect: true
                ),
            ],
            answers: nil
        )
    }

    static var previewMultipleQuestions: AskUserQuestionParameters {
        AskUserQuestionParameters(
            questions: [
                AskUserQuestion(
                    question: "For live streaming, should I add new WebSocket message types?",
                    header: "Streaming",
                    options: [
                        AskUserQuestionOption(
                            label: "Yes, new message types (Recommended)",
                            description: "More efficient, cleaner architecture."
                        ),
                        AskUserQuestionOption(
                            label: "Polling with existing snapshots",
                            description: "Simpler but higher latency."
                        ),
                    ],
                    multiSelect: false
                ),
                AskUserQuestion(
                    question: "Who controls the terminal dimensions for the iOS streaming view?",
                    header: "Terminal sizing",
                    options: [
                        AskUserQuestionOption(
                            label: "iOS requests specific dimensions",
                            description: "iOS calculates desired size based on screen space."
                        ),
                        AskUserQuestionOption(
                            label: "Mac sends actual tmux pane dimensions",
                            description: "iOS receives whatever size the tmux pane actually is."
                        ),
                        AskUserQuestionOption(
                            label: "Match the pane dimensions",
                            description: "iOS view should match the actual tmux pane size."
                        ),
                    ],
                    multiSelect: false
                ),
            ],
            answers: nil
        )
    }
}

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
                    type: .addRules,
                    behavior: .allow,
                    destination: .session
                ),
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
                        PermissionRule(toolName: "Bash", ruleContent: "git *"),
                    ],
                    behavior: .allow,
                    destination: .localSettings
                ),
            ]
        )
    }
}
