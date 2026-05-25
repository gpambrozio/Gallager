import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - CodexKeystrokeBuilder

// swiftlint:disable todo
// Each `TODO: verify against Codex TUI` below is a deliberate breadcrumb tracked
// against Task 13 — keystroke mappings here are ported verbatim from the Claude
// builder until the Codex sidecar can exercise them end-to-end against a live
// session. The swiftlint todo rule is suppressed for this file accordingly.

/// Builds the `[KeystrokeStep]` sequence that drives Codex's TUI in
/// response to an `AgentResponse`. Mirrors `ClaudeCodeKeystrokeBuilder` —
/// Codex's TUI shares the same broad navigation idiom (arrow keys / Enter /
/// Escape) but the specific key mapping has not yet been verified against
/// a live Codex session.
///
/// **For v1, the safe approach is to copy the Claude keystroke logic
/// verbatim** and mark each uncertain mapping with `TODO: verify against
/// Codex TUI`. The Codex sidecar built in Task 13 will exercise this
/// builder end-to-end against a real session; we'll refine the mappings
/// there once we can observe actual TUI behaviour.
public struct CodexKeystrokeBuilder: Sendable {
    public init() { }

    // MARK: - Ask user question

    /// Build the keystrokes for an `AskUserQuestionResponse` paired with
    /// the originating `AskUserQuestionRequest`.
    ///
    /// Ported verbatim from Claude's builder. Codex's AskUserQuestion UI
    /// is believed to share the same arrow-key navigation, Enter-to-toggle
    /// pattern, and "Other" free-text affordance.
    ///
    /// TODO: verify against Codex TUI — in particular whether Codex uses
    /// j/k for nav (instead of arrows) and whether multi-select submits
    /// with a trailing Enter or a different commit key.
    public func keystrokes(
        for response: AskUserQuestionResponse,
        matching request: AskUserQuestionRequest
    ) -> [KeystrokeStep] {
        var accumulator = StepAccumulator()
        var hasMultiSelect = false

        for (index, question) in request.questions.enumerated() {
            guard index < response.answers.count else { continue }
            let answer = response.answers[index]
            if question.allowMultiple { hasMultiSelect = true }
            appendAnswer(
                answer,
                question: question,
                into: &accumulator
            )
        }

        // Matches Claude's logic: anything other than a single
        // single-select question requires a trailing Enter.
        // TODO: verify against Codex TUI.
        if request.questions.count > 1 || hasMultiSelect {
            accumulator.appendKey(.enter)
        }

        return accumulator.finish()
    }

    private func appendAnswer(
        _ answer: AskUserQuestionResponse.QuestionAnswer,
        question: AskUserQuestionRequest.Question,
        into accumulator: inout StepAccumulator
    ) {
        let indices = answer.selectedOptionIndices.sorted()

        if question.allowMultiple {
            // Multi-select: walk through chosen indices toggling Enter.
            // TODO: verify against Codex TUI.
            var position = 0
            for index in indices {
                navigateDown(from: position, to: index, into: &accumulator)
                accumulator.appendKey(.enter)
                position = index
            }
            if let other = answer.freeText, !other.isEmpty {
                navigateDown(
                    from: position,
                    to: question.options.count,
                    into: &accumulator
                )
                accumulator.appendText(other)
                accumulator.appendKey(.space)
                accumulator.appendKey(.down)
                accumulator.appendKey(.enter)
            }
        } else if let only = indices.first {
            navigateDown(from: 0, to: only, into: &accumulator)
            accumulator.appendKey(.enter)
        } else if let other = answer.freeText, !other.isEmpty {
            navigateDown(
                from: 0,
                to: question.options.count,
                into: &accumulator
            )
            accumulator.appendText(other)
            accumulator.appendKey(.enter)
        }
    }

    private func navigateDown(
        from: Int,
        to: Int,
        into accumulator: inout StepAccumulator
    ) {
        let steps = to - from
        guard steps > 0 else { return }
        var keys: [PluginTmuxKey] = []
        keys.reserveCapacity(steps)
        for _ in 0..<steps {
            // TODO: verify against Codex TUI — some TUIs use j/k instead
            // of arrow keys. Default to the Claude mapping until we can
            // exercise Codex's UI end-to-end (Task 13).
            keys.append(.down)
        }
        accumulator.appendKeys(keys)
    }

    // MARK: - Permission

    /// Build the keystrokes for a `PermissionResponse`.
    ///
    /// TODO: verify against Codex TUI. Codex's permission prompt is
    /// believed to mirror Claude's (Enter approves, Escape denies) but
    /// this has not been observed against a live session.
    public func keystrokes(
        for response: PermissionResponse,
        matching _: PermissionRequest
    ) -> [KeystrokeStep] {
        switch response.decision {
        case .allow:
            [.keys([.enter])]
        case .deny:
            [.keys([.escape])]
        }
    }

    // MARK: - Approve plan

    /// Build the keystrokes for an `ApprovePlanResponse`.
    ///
    /// TODO: verify against Codex TUI. Codex's plan-approval prompt may
    /// not share Claude's "press 3" shortcut; we copy the Claude shape
    /// here so the sidecar has a believable default to test against.
    public func keystrokes(
        for response: ApprovePlanResponse,
        matching _: ApprovePlanRequest
    ) -> [KeystrokeStep] {
        switch response.decision {
        case .approve:
            var steps: [KeystrokeStep] = []
            steps.append(.text("3"))
            if let edited = response.editedPlan, !edited.isEmpty {
                steps.append(.text(edited))
                steps.append(.keys([.enter]))
            }
            return steps
        case .reject:
            return [.keys([.escape])]
        }
    }

    // MARK: - Text-only responses

    /// Build the keystrokes for a simple text-only response
    /// (`PromptResponse` / `ReplyAfterStopResponse`). An empty `text` is
    /// treated as "interrupt without input" and sends just Enter.
    public func keystrokes(forText text: String) -> [KeystrokeStep] {
        if text.isEmpty {
            return [.keys([.enter])]
        }
        return [
            .text(text),
            .keys([.enter]),
        ]
    }
}

// swiftlint:enable todo

// MARK: - StepAccumulator

/// Helper for assembling `KeystrokeStep` sequences while coalescing
/// adjacent `.keys` runs into a single step (so the wire sees one
/// `send_keys` call per logical batch). Mirrors the Claude version.
private struct StepAccumulator {
    private(set) var steps: [KeystrokeStep] = []
    private var pendingKeys: [PluginTmuxKey] = []

    mutating func appendKey(_ key: PluginTmuxKey) {
        pendingKeys.append(key)
    }

    mutating func appendKeys(_ keys: [PluginTmuxKey]) {
        pendingKeys.append(contentsOf: keys)
    }

    mutating func appendText(_ text: String) {
        flushPendingKeys()
        steps.append(.text(text))
    }

    mutating func finish() -> [KeystrokeStep] {
        flushPendingKeys()
        return steps
    }

    private mutating func flushPendingKeys() {
        guard !pendingKeys.isEmpty else { return }
        steps.append(.keys(pendingKeys))
        pendingKeys.removeAll(keepingCapacity: false)
    }
}
