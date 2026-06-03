import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - ClaudeCodeKeystrokes

/// Pure translation from a structured `AgentResponse` (+ the retained
/// `PendingRequest` context) into the Claude-specific keystroke sequence(s) the
/// core sends back through the host.
///
/// Faithfully ports the iOS response views:
/// - `PromptView` / `StopResponseView`: `[.text(trimmed), .enter]` for non-empty
///   text; empty reply-after-stop just interrupts with `.escape`.
/// - `PermissionRequestResponseView`: Accept = `[.text("1")]`, Reject =
///   `[.escape]`, Accept-with-rule = `[.text("2")]`, custom instructions =
///   `[.text(N), .text(trimmed), .enter]` where N is 2 (no suggestions) or 3.
/// - `ExitPlanModeResponseView`: Approve = `[.text("3")]`, Reject = `[.escape]`.
/// - `AskUserQuestionKeystrokes.build`: arrow-key menu navigation.
enum ClaudeCodeKeystrokes {
    /// A single delivery step: either verbatim text or a key sequence. The actor
    /// runs these through `host.sendText` / `host.sendKeys` in order.
    enum Delivery: Equatable {
        case text(String)
        case keys([TmuxKey])
    }

    /// Build the delivery steps for a response. `pending` is the context the core
    /// retained when it opened the form (needed for AskUserQuestion). Returns an
    /// empty array when there is nothing to send.
    static func deliveries(for response: AgentResponse, pending: PendingRequest?) -> [Delivery] {
        switch response {
        case let .prompt(text):
            return promptDeliveries(text: text, allowEmptyInterrupt: false)

        case let .replyAfterStop(text):
            return promptDeliveries(text: text, allowEmptyInterrupt: true)

        case let .permission(decision, appliedSuggestionID):
            // The in-terminal menu gains an "Accept with Rule" row when the
            // request carried suggestions, which shifts the custom-feedback
            // option from 2 to 3. Recover that from the retained pending context;
            // an applied suggestion id also implies suggestions were present.
            var hasSuggestions = appliedSuggestionID != nil
            if case let .permission(pendingHasSuggestions) = pending {
                hasSuggestions = hasSuggestions || pendingHasSuggestions
            }
            return permissionDeliveries(
                decision: decision,
                appliedSuggestionID: appliedSuggestionID,
                hasSuggestions: hasSuggestions
            )

        case let .approvePlan(decision, _):
            // ExitPlanModeResponseView: "3" approves, Escape rejects. iOS never
            // submits an edited plan (allowsEdit == false), so editedPlan is
            // ignored — matching current behavior.
            switch decision {
            case .approve: return [.keys([.text("3")])]
            case .reject: return [.keys([.escape])]
            }

        case let .askUserQuestion(answers):
            guard case let .askUserQuestion(params) = pending else { return [] }
            let keys = askUserQuestionKeys(params: params, answers: answers)
            return keys.isEmpty ? [] : [.keys(keys)]
        }
    }

    // MARK: - Prompt / reply

    /// `PromptView.sendMessage`: trim, and if non-empty send the text then Enter.
    /// For reply-after-stop an empty string means "just interrupt" → `.escape`.
    private static func promptDeliveries(text: String, allowEmptyInterrupt: Bool) -> [Delivery] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allowEmptyInterrupt ? [.keys([.escape])] : []
        }
        return [.text(trimmed), .keys([.enter])]
    }

    // MARK: - Permission

    /// `PermissionRequestResponseView`. Accept sends "1". Applying a suggestion
    /// uses the "Accept with Rule" option, which the legacy view maps to "2".
    /// `denyWithFeedback` ports `sendCustomInstructions`: the custom-feedback
    /// option is 3 when the request carried suggestions (the menu has the extra
    /// "Accept with Rule" row) and 2 when it didn't — matching the legacy
    /// `suggestions.isEmpty ? 2 : 3`. Plain deny sends Escape.
    private static func permissionDeliveries(
        decision: PermissionDecision,
        appliedSuggestionID: String?,
        hasSuggestions: Bool
    ) -> [Delivery] {
        switch decision {
        case .allow:
            // Applying a suggestion = the "Accept with Rule" path ("2").
            if appliedSuggestionID != nil {
                return [.keys([.text("2")])]
            }
            return [.keys([.text("1")])]

        case .deny:
            return [.keys([.escape])]

        case let .denyWithFeedback(feedback):
            let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            // The custom-feedback row is 3 when suggestions are present (the menu
            // shows Accept / Accept-with-Rule / No+feedback) and 2 otherwise.
            let optionNumber = hasSuggestions ? "3" : "2"
            if trimmed.isEmpty {
                // Nothing to say — fall back to a plain deny.
                return [.keys([.escape])]
            }
            return [.keys([.text(optionNumber)]), .text(trimmed), .keys([.enter])]
        }
    }

    // MARK: - AskUserQuestion

    /// Reverses the contract answers (option ids like `"q0-o2"`, free text) back
    /// into per-question index sets, then runs the ported arrow-nav builder.
    static func askUserQuestionKeys(
        params: AskUserQuestionParameters,
        answers: [QuestionAnswer]
    ) -> [TmuxKey] {
        var byIndex: [Int: AskUserQuestionAnswer] = [:]
        for answer in answers {
            guard let qIndex = questionIndex(from: answer.questionID) else { continue }
            let indices = answer.selectedOptionIDs.compactMap { optionIndex(from: $0) }
            let custom = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
            byIndex[qIndex] = AskUserQuestionAnswer(
                selectedIndices: Set(indices),
                customText: (custom?.isEmpty ?? true) ? nil : custom
            )
        }
        return AskUserQuestionKeystrokes.build(for: params, answers: byIndex)
    }

    /// Parses `"q3"` → `3`.
    private static func questionIndex(from id: String) -> Int? {
        guard id.hasPrefix("q") else { return nil }
        return Int(id.dropFirst())
    }

    /// Parses `"q3-o5"` → `5` (the option index within its question).
    private static func optionIndex(from id: String) -> Int? {
        guard let dashRange = id.range(of: "-o") else { return nil }
        return Int(id[dashRange.upperBound...])
    }
}

// MARK: - AskUserQuestion arrow-key builder (ported)

/// An answer to one AskUserQuestion: toggled option indices and optional "Other"
/// text. Ported from the iOS `KeystrokeQuestionAnswer`.
struct AskUserQuestionAnswer: Equatable {
    var selectedIndices: Set<Int> = []
    var customText: String?

    var isEmpty: Bool {
        selectedIndices.isEmpty && customText == nil
    }
}

/// Accumulates `TmuxKey` values, inserting a delay after every state-changing
/// keystroke so the receiving terminal can process each one. Ported from the iOS
/// `KeystrokeBuilder`.
private struct KeystrokeBuilder {
    let delayMs: Int
    private(set) var keys: [TmuxKey] = []

    mutating func append(_ key: TmuxKey) {
        keys.append(key)
        keys.append(.delay(delayMs))
    }

    mutating func pause() {
        keys.append(.delay(delayMs))
    }

    mutating func navigate(down count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            append(.down)
        }
    }
}

/// Pure keystroke generation for AskUserQuestion answers. Ported verbatim from
/// the iOS `AskUserQuestionKeystrokes` so the in-terminal navigation matches.
///
/// Claude Code's AskUserQuestion prompt navigates with arrow keys, not numbers:
/// option N is reached by (N-1) down arrows from the top, then Enter selects it.
/// "Other" sits one slot past the listed options. Every state-changing keystroke
/// is followed by a short delay so the terminal has time to react.
enum AskUserQuestionKeystrokes {
    /// Default per-keystroke delay in milliseconds.
    static let defaultDelayMs = 200

    static func build(
        for params: AskUserQuestionParameters,
        answers: [Int: AskUserQuestionAnswer],
        delayMs: Int = defaultDelayMs
    ) -> [TmuxKey] {
        var b = KeystrokeBuilder(delayMs: delayMs)
        for (index, question) in params.questions.enumerated() {
            guard let answer = answers[index], !answer.isEmpty else { continue }
            appendAnswer(answer, for: question, into: &b)
        }
        // A single single-select question is self-submitting; a multi-question
        // batch or any multi-select question needs an explicit trailing Enter.
        if params.questions.count > 1 || params.questions.contains(where: \.multiSelect) {
            b.pause()
            b.append(.enter)
        }
        return b.keys
    }

    private static func appendAnswer(
        _ answer: AskUserQuestionAnswer,
        for question: AskUserQuestionParameters.AskUserQuestion,
        into b: inout KeystrokeBuilder
    ) {
        if question.multiSelect {
            // Enter toggles the highlighted option without moving the cursor, so
            // each toggle navigates incrementally from the previous one.
            var pos = 0
            for index in answer.selectedIndices.sorted() {
                b.navigate(down: index - pos)
                b.append(.enter)
                pos = index
            }
            if let other = answer.customText {
                // Walk past the listed options to "Other", type the text, then
                // Space + Down + Enter to commit and advance past it.
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
