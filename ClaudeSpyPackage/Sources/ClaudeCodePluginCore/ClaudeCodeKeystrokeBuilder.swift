import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - ClaudeCodeKeystrokeBuilder

/// Builds the `[KeystrokeStep]` sequence that drives Claude Code's TUI in
/// response to an `AgentResponse`. Everything Claude-specific about
/// keystroke navigation lives here — the iOS app sends a structured
/// `AgentResponse`, and the sidecar translates that into the right key
/// sequence using this builder. (Spec §7.5.1.)
///
/// The logic for AskUserQuestion is ported from the legacy
/// `ClaudeSpyFeature/Views/ResponseViews/AskUserQuestionKeystrokes.swift`,
/// which iOS used until v1.33. Permission and plan-approval flows mirror
/// the keystrokes the iOS `PermissionRequestResponseView` /
/// `ExitPlanModeResponseView` sent in v1.32.
public struct ClaudeCodeKeystrokeBuilder: Sendable {
    public init() { }

    // MARK: - Ask user question

    /// Build the keystrokes for an `AskUserQuestionResponse` paired with
    /// the originating `AskUserQuestionRequest`.
    ///
    /// Claude Code's AskUserQuestion UI navigates with the arrow keys.
    /// For each question the cursor starts on the first option:
    /// - Navigate down `selectedOptionIndices[0]` times.
    /// - Multi-select: toggle with Enter, then navigate to the next
    ///   chosen index relative to current position, repeat.
    /// - Single-select: just press Enter on the chosen option.
    /// - Free-text "Other": navigate past the listed options, type the
    ///   text, then Space+Down+Enter (multi) or Enter (single).
    /// - After answering, a multi-select or multi-question batch needs a
    ///   trailing Enter to commit. Single single-select questions
    ///   self-submit.
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

        // Per the legacy logic, anything other than a single
        // single-select question requires a trailing Enter.
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
            keys.append(.down)
        }
        accumulator.appendKeys(keys)
    }

    // MARK: - Permission

    /// Build the keystrokes for a `PermissionResponse`.
    ///
    /// Claude Code's permission prompt accepts numeric shortcuts mapped to
    /// the suggestions list. We mirror the v1.32 iOS behavior:
    /// - `.allow` with no suggestion → Enter (default action).
    /// - `.allow` with a suggestion id → if the id is `"0"` Enter still
    ///   wins (matches v1.32's "Accept" button which sends `1` for the
    ///   first suggestion). For other indices we send Enter and rely on
    ///   the sidecar tracking. TODO: verify against the Claude TUI when
    ///   the sidecar lands (Task 12).
    /// - `.deny` → Escape.
    public func keystrokes(
        for response: PermissionResponse,
        matching _: PermissionRequest
    ) -> [KeystrokeStep] {
        switch response.decision {
        case .allow:
            // v1.32 iOS sent "1" for the default Accept (no suggestion)
            // and "2" for "Accept with Rule". We don't have a stable
            // suggestion ordering on the wire any more — the sidecar
            // hands the id back as a string — so we conservatively send
            // Enter (Claude's default highlight) and let the sidecar
            // refine in Task 12 once we can verify against the live TUI.
            [.keys([.enter])]
        case .deny:
            [.keys([.escape])]
        }
    }

    // MARK: - Approve plan

    /// Build the keystrokes for an `ApprovePlanResponse`.
    ///
    /// v1.32 iOS sent `"3"` to approve a plan (the third option in the
    /// list — "Yes, and auto-accept edits"). Rejection sent Escape.
    /// Edits: the v1.32 UI didn't expose an in-place edit, so this is a
    /// best-effort port — we send the edited plan text after approval.
    public func keystrokes(
        for response: ApprovePlanResponse,
        matching _: ApprovePlanRequest
    ) -> [KeystrokeStep] {
        switch response.decision {
        case .approve:
            var steps: [KeystrokeStep] = []
            // Matches the v1.32 ExitPlanModeResponseView "Approve" button
            // sending `.text("3")`. TODO: confirm against Claude TUI on
            // sidecar integration.
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

// MARK: - StepAccumulator

/// Helper for assembling `KeystrokeStep` sequences while coalescing
/// adjacent `.keys` runs into a single step (so the wire sees one
/// `send_keys` call per logical batch).
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
