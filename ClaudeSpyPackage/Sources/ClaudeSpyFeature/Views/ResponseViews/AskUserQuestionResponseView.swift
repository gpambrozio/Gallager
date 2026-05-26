import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Ask User Question Response View

/// Interactive multi-question response view for `AskUserQuestionRequest`.
/// Walks the user through the prompt's questions, collects answers, then
/// shows a summary and submits a structured `AskUserQuestionResponse`.
///
/// All keystroke construction lives in the plugin sidecar now (per Spec
/// §7.5.1); iOS only ships the structured indices and free-text strings.
struct AskUserQuestionResponseView: View {
    let hostID: String
    let sessionID: String
    let pluginID: String
    let requestID: String
    let request: AskUserQuestionRequest
    let isConnected: Bool
    let submitter: AgentResponseSubmitter

    /// Index of the question currently being answered. Once it walks past
    /// `questions.count`, the summary takes over.
    @State private var currentQuestionIndex = 0

    /// Collected answers keyed by question index.
    @State private var collectedAnswers: [Int: QuestionAnswerDraft] = [:]

    /// For multi-select questions, in-flight selection set for the current
    /// question. Committed into `collectedAnswers` on "Next".
    @State private var selectedOptions: Set<Int> = []

    /// Free-text buffer for the "Other" answer. Mirrored into the draft
    /// alongside selections for multi-select; for single-select, submitting
    /// "Other" advances on its own.
    @State private var customInputText = ""

    /// Whether the "Other" text field is open.
    @State private var showingCustomInput = false

    @State private var isSending = false
    @State private var hasSubmitted = false
    @FocusState private var isTextFieldFocused: Bool

    private var questions: [AskUserQuestionRequest.Question] { request.questions }

    private var currentQuestion: AskUserQuestionRequest.Question? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    private var isReadyForReview: Bool {
        currentQuestionIndex >= questions.count
    }

    var body: some View {
        if hasSubmitted {
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

    // MARK: - Summary

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Symbols.checkmarkCircle.image
                    .foregroundStyle(.blue)
                Text("Review Your Answers")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    summaryRow(for: question, at: index)
                }
            }

            HStack(spacing: 12) {
                Button {
                    startOver()
                } label: {
                    Label("Start Over", symbol: .arrowClockwise)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await confirmAndSubmit() }
                } label: {
                    Label("Confirm", symbol: .checkmarkCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected || isSending)
            }

            if isSending {
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
        for question: AskUserQuestionRequest.Question,
        at index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.prompt)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let draft = collectedAnswers[index] {
                Text(draft.displayText(for: question))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
    }

    // MARK: - Question Content

    private func questionContent(_ question: AskUserQuestionRequest.Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if questions.count > 1 {
                HStack {
                    Text("Question \(currentQuestionIndex + 1) of \(questions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Text(question.prompt)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            optionsList(question)

            if question.allowFreeText {
                otherOptionSection
            }

            if
                question.allowMultiple
                && hasMultiSelectAnswer
                && !showingCustomInput {
                nextQuestionButton
            }
        }
        .padding(.vertical, 4)
    }

    private func optionsList(_ question: AskUserQuestionRequest.Question) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionButton(option, index: index, isMultiSelect: question.allowMultiple)
            }
        }
    }

    private func optionButton(
        _ option: AskUserQuestionRequest.Option,
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selectedOptions.contains(index) ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedOptions.contains(index) ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
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
        collectedAnswers[currentQuestionIndex] = QuestionAnswerDraft(selectedIndices: [index])
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
        collectedAnswers[currentQuestionIndex] = QuestionAnswerDraft(
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
        if currentQuestion?.allowMultiple == true { return }

        collectedAnswers[currentQuestionIndex] = QuestionAnswerDraft(customText: trimmed)
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
        isSending = true

        // Walk the questions in order and emit one `QuestionAnswer` per
        // question. Missing drafts fall back to an empty answer (sidecar
        // decides how to interpret) so the response array always lines up
        // 1:1 with the request's questions array.
        let answers = (0..<questions.count).map { index -> AskUserQuestionResponse.QuestionAnswer in
            let draft = collectedAnswers[index] ?? QuestionAnswerDraft()
            return draft.makeResponse()
        }

        await submitter.submit(
            hostID: hostID,
            sessionID: sessionID,
            pluginID: pluginID,
            requestID: requestID,
            response: .askUserQuestion(AskUserQuestionResponse(answers: answers))
        )
        isSending = false
        hasSubmitted = true
    }
}

// MARK: - Question Answer Draft

/// In-flight answer for a single question. Multi-select questions can carry
/// both selected option indices and custom "Other" text in the same answer.
///
/// `Equatable` so SwiftUI's `@State` diffing works correctly across renders.
struct QuestionAnswerDraft: Equatable {
    var selectedIndices: Set<Int> = []
    var customText: String?

    var isEmpty: Bool { selectedIndices.isEmpty && customText == nil }

    /// Human-readable summary for the review-and-confirm screen.
    func displayText(for question: AskUserQuestionRequest.Question) -> String {
        var parts: [String] = []
        let labels = selectedIndices.sorted().compactMap { index -> String? in
            guard index < question.options.count else { return nil }
            return question.options[index].label
        }
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        if let customText { parts.append("Other: \(customText)") }
        return parts.joined(separator: ", ")
    }

    /// Snapshot of the draft as a wire `AskUserQuestionResponse.QuestionAnswer`.
    /// `selectedOptionIndices` is sorted for a stable wire order.
    func makeResponse() -> AskUserQuestionResponse.QuestionAnswer {
        AskUserQuestionResponse.QuestionAnswer(
            selectedOptionIndices: selectedIndices.sorted(),
            freeText: customText
        )
    }
}

// MARK: - Previews

#Preview("Ask User Question - single select") {
    NavigationStack {
        List {
            Section("Question") {
                AskUserQuestionResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: AskUserQuestionRequest(
                        questions: [
                            AskUserQuestionRequest.Question(
                                prompt: "Should I add new WebSocket message types for live streaming?",
                                options: [
                                    AskUserQuestionRequest.Option(
                                        label: "Yes, new message types (Recommended)",
                                        detail: "Cleaner architecture, more efficient."
                                    ),
                                    AskUserQuestionRequest.Option(
                                        label: "Polling with existing snapshots",
                                        detail: "Simpler but higher latency."
                                    ),
                                ],
                                allowMultiple: false,
                                allowFreeText: false
                            ),
                        ]
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}

#Preview("Ask User Question - multi-select with Other") {
    NavigationStack {
        List {
            Section("Question") {
                AskUserQuestionResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: AskUserQuestionRequest(
                        questions: [
                            AskUserQuestionRequest.Question(
                                prompt: "Which features should the dashboard include?",
                                options: [
                                    AskUserQuestionRequest.Option(label: "Real-time updates", detail: nil),
                                    AskUserQuestionRequest.Option(label: "Dark mode", detail: nil),
                                    AskUserQuestionRequest.Option(label: "Export to CSV", detail: nil),
                                ],
                                allowMultiple: true,
                                allowFreeText: true
                            ),
                        ]
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}
