import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Ask User Question Response View

/// Interactive question response view for AskUserQuestion tool calls.
/// Collects all answers first, shows a summary for confirmation, then submits.
struct AskUserQuestionResponseView: View {
    let params: AskUserQuestionParameters
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    /// Tracks which question index we're currently on
    @State private var currentQuestionIndex = 0
    /// Collected answers for each question (keyed by question index)
    @State private var collectedAnswers: [Int: QuestionAnswer] = [:]
    /// For multi-select questions, tracks selected option indices for current question
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

    /// All questions have been answered, ready to show summary
    private var isReadyForReview: Bool {
        collectedAnswers.count == questions.count
    }

    var body: some View {
        if state.response != nil {
            completionFeedback
        } else if isReadyForReview {
            summaryView
        } else if let question = currentQuestion {
            questionContent(question)
        }
    }

    // MARK: - Completion Feedback

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

    // MARK: - Summary View

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Symbols.checkmarkCircle.image
                    .foregroundStyle(.blue)
                Text("Review Your Answers")
                    .font(.headline)
                Spacer()
            }

            // Answers list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    summaryRow(for: question, at: index)
                }
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    startOver()
                } label: {
                    Label("Start Over", symbol: .arrowClockwise)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await confirmAndSubmit()
                    }
                } label: {
                    Label("Confirm", symbol: .checkmarkCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected || state.isSending)
            }

            if state.isSending {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Submitting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func summaryRow(
        for question: AskUserQuestionParameters.AskUserQuestion,
        at index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Question header tag
            Text(question.header.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.blue))

            // Answer
            if let answer = collectedAnswers[index] {
                Text(answer.displayText(for: question))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
    }

    // MARK: - Question Content

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

            // Multi-select next button
            if
                question.multiSelect
                && hasMultiSelectAnswer
                && !showingCustomInput {
                nextQuestionButton
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
        .disabled(!isConnected)
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
            TextField("Enter your response...", text: $customInputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .focused($isTextFieldFocused)
                .disabled(!isConnected)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showingCustomInput = false
                            customInputText = ""
                            isTextFieldFocused = false
                        } label: {
                            Symbols.xmark.image
                        }
                        .accessibilityLabel("Cancel Other")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if !customInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                saveCustomInput()
                            } label: {
                                Symbols.checkmark.image
                            }
                            .accessibilityLabel("Save Other")
                        }
                    }
                }
        } else {
            Button {
                showingCustomInput = true
                isTextFieldFocused = true
            } label: {
                HStack(spacing: 12) {
                    Symbols.pencilLine.image
                        .foregroundStyle(customInputText.isEmpty ? Color.secondary : Color.blue)
                    if customInputText.isEmpty {
                        Text("Other...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Other: \(customInputText)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(customInputText.isEmpty ? Color.gray.opacity(0.05) : Color.blue.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(customInputText.isEmpty ? Color.gray.opacity(0.2) : Color.blue, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isConnected)
            .accessibilityLabel(customInputText.isEmpty ? "Open Other" : "Edit Other")
        }
    }

    private var nextQuestionButton: some View {
        Button {
            saveMultiSelectAndAdvance()
        } label: {
            Label("Next", symbol: .arrowRight)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!isConnected || !hasMultiSelectAnswer)
    }

    private var hasMultiSelectAnswer: Bool {
        !selectedOptions.isEmpty
            || !customInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func selectSingleOption(_ index: Int) {
        // Save the answer and advance to next question
        collectedAnswers[currentQuestionIndex] = QuestionAnswer(selectedIndices: [index])
        advanceToNextQuestion()
    }

    private func toggleMultiSelectOption(_ index: Int) {
        if selectedOptions.contains(index) {
            selectedOptions.remove(index)
        } else {
            selectedOptions.insert(index)
        }
    }

    private func saveMultiSelectAndAdvance() {
        let trimmed = customInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let other = trimmed.isEmpty ? nil : trimmed
        guard !selectedOptions.isEmpty || other != nil else { return }
        collectedAnswers[currentQuestionIndex] = QuestionAnswer(
            selectedIndices: selectedOptions,
            customText: other
        )
        advanceToNextQuestion()
    }

    private func saveCustomInput() {
        let trimmed = customInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        customInputText = trimmed
        showingCustomInput = false
        isTextFieldFocused = false

        // Multi-select keeps the saved text alongside any toggled options;
        // single-select treats "Other" as the sole answer and advances.
        if currentQuestion?.multiSelect == true {
            return
        }
        collectedAnswers[currentQuestionIndex] = QuestionAnswer(customText: trimmed)
        advanceToNextQuestion()
    }

    private func advanceToNextQuestion() {
        currentQuestionIndex += 1
        selectedOptions = []
        customInputText = ""
        showingCustomInput = false
    }

    private func startOver() {
        currentQuestionIndex = 0
        collectedAnswers = [:]
        selectedOptions = []
        customInputText = ""
        showingCustomInput = false
    }

    private func confirmAndSubmit() async {
        state.isSending = true
        let keys = AskUserQuestionKeystrokes.build(for: params, answers: collectedAnswers)
        await sendCommand(.sendKeystroke(keys))
        state.isSending = false
        state.response = .allQuestionsAnswered
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
                            label: "Host sends actual tmux pane dimensions",
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

// MARK: - Previews

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

    return NavigationStack {
        List {
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

    return NavigationStack {
        List {
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

    return NavigationStack {
        List {
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
}
