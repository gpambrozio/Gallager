import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

@Suite("CodexKeystrokeBuilder")
struct CodexKeystrokeBuilderTests {
    // MARK: - Fixtures

    private static func singleSelectQuestion(
        optionCount: Int = 3
    ) -> AskUserQuestionRequest.Question {
        AskUserQuestionRequest.Question(
            prompt: "Pick one",
            options: (0..<optionCount).map { i in
                AskUserQuestionRequest.Option(label: "Opt \(i)", detail: nil)
            },
            allowMultiple: false,
            allowFreeText: true
        )
    }

    private static func multiSelectQuestion(
        optionCount: Int = 3
    ) -> AskUserQuestionRequest.Question {
        AskUserQuestionRequest.Question(
            prompt: "Pick many",
            options: (0..<optionCount).map { i in
                AskUserQuestionRequest.Option(label: "Opt \(i)", detail: nil)
            },
            allowMultiple: true,
            allowFreeText: true
        )
    }

    // MARK: - Ask user question — single select
    //
    // The Codex keystroke mapping is copy-and-adapt from Claude's. These
    // tests pin the v1 behaviour until the Codex sidecar (Task 13) can
    // verify against a live TUI.

    @Test("Single-select question, option index 0 → just Enter")
    func singleSelectFirstOption() {
        let q = Self.singleSelectQuestion()
        let request = AskUserQuestionRequest(questions: [q])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [0], freeText: nil),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.keys([.enter])])
    }

    @Test("Single-select question, option index 2 → down, down, enter")
    func singleSelectThirdOption() {
        let q = Self.singleSelectQuestion()
        let request = AskUserQuestionRequest(questions: [q])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [2], freeText: nil),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.keys([.down, .down, .enter])])
    }

    // MARK: - Multi-select

    @Test("Multi-select question, options 0 and 2 → enter, down, down, enter, trailing enter")
    func multiSelectTwoOptions() {
        let q = Self.multiSelectQuestion()
        let request = AskUserQuestionRequest(questions: [q])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [0, 2], freeText: nil),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.keys([.enter, .down, .down, .enter, .enter])])
    }

    // MARK: - Free-text

    @Test("Single-select free-text Other → navigate past options, type, enter")
    func singleSelectOther() {
        let q = Self.singleSelectQuestion(optionCount: 2)
        let request = AskUserQuestionRequest(questions: [q])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [], freeText: "custom"),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [
            .keys([.down, .down]),
            .text("custom"),
            .keys([.enter]),
        ])
    }

    @Test("Multi-select with Other → enter on selected then navigate, type, space+down+enter, trailing enter")
    func multiSelectOther() {
        let q = Self.multiSelectQuestion(optionCount: 2)
        let request = AskUserQuestionRequest(questions: [q])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [0], freeText: "custom"),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [
            .keys([.enter, .down, .down]),
            .text("custom"),
            .keys([.space, .down, .enter, .enter]),
        ])
    }

    // MARK: - Multiple questions

    @Test("Two single-select questions both first option → enter, enter, trailing enter")
    func twoSingleSelectQuestions() {
        let q1 = Self.singleSelectQuestion()
        let q2 = Self.singleSelectQuestion()
        let request = AskUserQuestionRequest(questions: [q1, q2])
        let response = AskUserQuestionResponse(answers: [
            .init(selectedOptionIndices: [0], freeText: nil),
            .init(selectedOptionIndices: [0], freeText: nil),
        ])
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.keys([.enter, .enter, .enter])])
    }

    // MARK: - Permission

    @Test("Permission allow → Enter")
    func permissionAllow() {
        let response = PermissionResponse(decision: .allow, appliedSuggestionId: nil)
        let req = PermissionRequest(
            toolName: "Bash",
            description: "Run Command",
            suggestions: [],
            isAutoApprovable: true
        )
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: req
        )
        #expect(steps == [.keys([.enter])])
    }

    @Test("Permission deny → Escape")
    func permissionDeny() {
        let response = PermissionResponse(decision: .deny, appliedSuggestionId: nil)
        let req = PermissionRequest(
            toolName: "Bash",
            description: "Run Command",
            suggestions: [],
            isAutoApprovable: true
        )
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: req
        )
        #expect(steps == [.keys([.escape])])
    }

    // MARK: - Approve plan

    @Test("Plan approve without edit → '3' text key")
    func planApproveWithoutEdit() {
        let response = ApprovePlanResponse(decision: .approve, editedPlan: nil)
        let request = ApprovePlanRequest(plan: "Plan", allowEdit: true)
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.text("3")])
    }

    @Test("Plan approve with edit → '3' then edited text then enter")
    func planApproveWithEdit() {
        let response = ApprovePlanResponse(decision: .approve, editedPlan: "edited")
        let request = ApprovePlanRequest(plan: "Plan", allowEdit: true)
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [
            .text("3"),
            .text("edited"),
            .keys([.enter]),
        ])
    }

    @Test("Plan reject → Escape")
    func planReject() {
        let response = ApprovePlanResponse(decision: .reject, editedPlan: nil)
        let request = ApprovePlanRequest(plan: "Plan", allowEdit: true)
        let steps = CodexKeystrokeBuilder().keystrokes(
            for: response,
            matching: request
        )
        #expect(steps == [.keys([.escape])])
    }

    // MARK: - Text-only

    @Test("Text-only response with non-empty text → text + enter")
    func textOnlyNonEmpty() {
        let steps = CodexKeystrokeBuilder().keystrokes(forText: "hi")
        #expect(steps == [.text("hi"), .keys([.enter])])
    }

    @Test("Text-only response with empty text → just Enter (interrupt)")
    func textOnlyEmpty() {
        let steps = CodexKeystrokeBuilder().keystrokes(forText: "")
        #expect(steps == [.keys([.enter])])
    }
}
