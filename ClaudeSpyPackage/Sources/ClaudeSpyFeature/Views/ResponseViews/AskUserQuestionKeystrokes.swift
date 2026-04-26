import ClaudeSpyNetworking

// MARK: - Question Answer

/// Represents an answer to a question. Multi-select questions can carry both
/// selected option indices and custom "Other" text in the same answer.
struct QuestionAnswer: Equatable {
    var selectedIndices: Set<Int> = []
    var customText: String?

    var isEmpty: Bool { selectedIndices.isEmpty && customText == nil }

    func displayText(for question: AskUserQuestionParameters.AskUserQuestion) -> String {
        var parts: [String] = []
        let labels = selectedIndices.sorted().compactMap { index -> String? in
            guard index < question.options.count else { return nil }
            return question.options[index].label
        }
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        if let customText { parts.append("Other: \(customText)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Keystroke Builder

/// Accumulates `TmuxKey` values, inserting a delay after every state-changing
/// keystroke so the receiving terminal can process each one before the next.
struct KeystrokeBuilder {
    let delayMs: Int
    private(set) var keys: [TmuxKey] = []

    mutating func append(_ key: TmuxKey) {
        keys.append(key)
        keys.append(.delay(delayMs))
    }

    /// Inserts an extra delay without a preceding keystroke.
    mutating func pause() {
        keys.append(.delay(delayMs))
    }

    /// Appends `count` down-arrow keystrokes, each followed by a delay.
    mutating func navigate(down count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            append(.down)
        }
    }
}

// MARK: - Keystroke Generation

/// Pure keystroke generation for AskUserQuestion answers. The translation from
/// (questions, answers) to a `[TmuxKey]` sequence lives here so it can be
/// unit-tested without instantiating the SwiftUI view.
///
/// Claude Code's AskUserQuestion prompt navigates with arrow keys, not numbers:
/// option N is reached by (N-1) down arrows from the top, then Enter selects
/// it. "Other" sits one slot past the listed options. Every state-changing
/// keystroke is followed by a short delay so the terminal has time to react
/// before the next one fires.
enum AskUserQuestionKeystrokes {
    /// Default per-keystroke delay in milliseconds. Tuned to a value that
    /// reliably round-trips through the relay + tmux + Claude Code's input
    /// loop without making the user wait too long.
    static let defaultDelayMs = 200

    static func build(
        for params: AskUserQuestionParameters,
        answers: [Int: QuestionAnswer],
        delayMs: Int = defaultDelayMs
    ) -> [TmuxKey] {
        var b = KeystrokeBuilder(delayMs: delayMs)
        for (index, question) in params.questions.enumerated() {
            guard let answer = answers[index], !answer.isEmpty else { continue }
            appendAnswer(answer, for: question, into: &b)
        }
        // The per-question commit doesn't submit a multi-question batch or a
        // multi-select question; only a single single-select question is
        // self-submitting. Everything else needs an explicit trailing Enter.
        if params.questions.count > 1 || params.questions.contains(where: \.multiSelect) {
            b.pause()
            b.append(.enter)
        }
        return b.keys
    }

    private static func appendAnswer(
        _ answer: QuestionAnswer,
        for question: AskUserQuestionParameters.AskUserQuestion,
        into b: inout KeystrokeBuilder
    ) {
        if question.multiSelect {
            // Enter toggles the highlighted option without moving the cursor,
            // so each toggle navigates incrementally from the previous one.
            var pos = 0
            for index in answer.selectedIndices.sorted() {
                b.navigate(down: index - pos)
                b.append(.enter)
                pos = index
            }
            if let other = answer.customText {
                // Walk past the listed options to "Other", type the text
                // (Claude Code engages Other on input), then Space + Down +
                // Enter to commit and advance past it.
                b.navigate(down: question.options.count - pos)
                b.append(.text(other))
                b.append(.space)
                b.append(.down)
                b.append(.enter)
            } else {
                b.append(.right)
            }
        } else if let index = answer.selectedIndices.first {
            b.navigate(down: index)
            b.append(.enter)
        } else if let other = answer.customText {
            b.navigate(down: question.options.count)
            b.append(.text(other))
            b.append(.enter)
        }
    }
}
