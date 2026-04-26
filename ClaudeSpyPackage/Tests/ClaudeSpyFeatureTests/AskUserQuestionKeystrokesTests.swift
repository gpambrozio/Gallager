import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@Suite("AskUserQuestion Keystrokes")
struct AskUserQuestionKeystrokesTests {
    private let delay = 200

    // MARK: - Helpers

    private func question(
        _ optionCount: Int,
        multiSelect: Bool
    ) -> AskUserQuestionParameters.AskUserQuestion {
        let options = (0..<optionCount).map { index in
            AskUserQuestionParameters.AskUserQuestionOption(
                label: "Option \(index + 1)",
                description: nil
            )
        }
        return .init(
            question: "Q?",
            header: "Q",
            options: options,
            multiSelect: multiSelect
        )
    }

    private func params(_ questions: AskUserQuestionParameters.AskUserQuestion...) -> AskUserQuestionParameters {
        AskUserQuestionParameters(questions: questions, answers: nil)
    }

    private func build(
        _ params: AskUserQuestionParameters,
        _ answers: [Int: QuestionAnswer]
    ) -> [TmuxKey] {
        AskUserQuestionKeystrokes.build(for: params, answers: answers, delayMs: delay)
    }

    private var d: TmuxKey {
        .delay(delay)
    }

    // MARK: - Single-select

    @Test("Single-select option 1 sends just Enter (no trailing)")
    func singleSelectOptionOne() {
        let p = params(question(3, multiSelect: false))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [0])])
        #expect(keys == [.enter, d])
    }

    @Test("Single-select option N navigates with N-1 down arrows")
    func singleSelectOptionN() {
        let p = params(question(3, multiSelect: false))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [2])])
        #expect(keys == [.down, d, .down, d, .enter, d])
    }

    @Test("Single-select Other navigates past all options, types text, then Enter")
    func singleSelectOther() {
        let p = params(question(3, multiSelect: false))
        let keys = build(p, [0: QuestionAnswer(customText: "hello")])
        #expect(keys == [
            .down, d, .down, d, .down, d,
            .text("hello"), d,
            .enter, d,
        ])
    }

    @Test("Single single-select answer has no trailing Enter")
    func singleSelectNoTrailingEnter() {
        let p = params(question(2, multiSelect: false))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [1])])
        // The per-question Enter is the submit; nothing after it.
        #expect(keys.last == d)
        #expect(keys[keys.count - 2] == .enter)
        #expect(keys.filter { $0 == .enter }.count == 1)
    }

    // MARK: - Multi-select

    @Test("Multi-select with one option toggles it and commits with Right + trailing Enter")
    func multiSelectSingleOption() {
        let p = params(question(3, multiSelect: true))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [0])])
        #expect(keys == [
            .enter, d, // toggle option 0
            .right, d, // commit multi-select page
            d, .enter, d, // trailing Enter to submit batch
        ])
    }

    @Test("Multi-select with non-contiguous indices navigates incrementally")
    func multiSelectIncrementalNavigation() {
        let p = params(question(4, multiSelect: true))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [0, 2])])
        #expect(keys == [
            .enter, d, // toggle 0
            .down, d, .down, d, // navigate from 0 to 2
            .enter, d, // toggle 2
            .right, d, // commit
            d, .enter, d, // trailing
        ])
    }

    @Test("Multi-select with only Other walks past all options and uses Space+Down+Enter")
    func multiSelectOtherOnly() {
        let p = params(question(3, multiSelect: true))
        let keys = build(p, [0: QuestionAnswer(customText: "hi")])
        #expect(keys == [
            .down, d, .down, d, .down, d, // navigate to Other (past 3 options)
            .text("hi"), d,
            .space, d,
            .down, d,
            .enter, d,
            d, .enter, d, // trailing
        ])
    }

    @Test("Multi-select with options + Other walks from last toggle to Other")
    func multiSelectOptionsAndOther() {
        let p = params(question(3, multiSelect: true))
        let keys = build(p, [0: QuestionAnswer(selectedIndices: [1], customText: "x")])
        #expect(keys == [
            .down, d, // navigate to 1
            .enter, d, // toggle 1
            .down, d, .down, d, // navigate from 1 to Other (slot 3)
            .text("x"), d,
            .space, d,
            .down, d,
            .enter, d,
            d, .enter, d, // trailing
        ])
    }

    // MARK: - Multi-question

    @Test("Multi-question with mixed types appends each answer and one trailing Enter")
    func multiQuestionMix() {
        let q1 = question(3, multiSelect: false)
        let q2 = question(2, multiSelect: true)
        let p = params(q1, q2)
        let keys = build(p, [
            0: QuestionAnswer(selectedIndices: [1]),
            1: QuestionAnswer(selectedIndices: [0]),
        ])
        #expect(keys == [
            // Q1: single-select option 2
            .down, d, .enter, d,
            // Q2: multi-select option 0
            .enter, d, .right, d,
            // Trailing Enter to submit the batch
            d, .enter, d,
        ])
    }

    @Test("Two single-select questions still get a trailing Enter")
    func twoSingleSelectsHaveTrailingEnter() {
        let p = params(question(2, multiSelect: false), question(2, multiSelect: false))
        let keys = build(p, [
            0: QuestionAnswer(selectedIndices: [0]),
            1: QuestionAnswer(selectedIndices: [1]),
        ])
        #expect(keys == [
            .enter, d, // Q1 option 1
            .down, d, .enter, d, // Q2 option 2
            d, .enter, d, // trailing
        ])
    }

    // MARK: - Edge cases

    @Test("Questions with empty answers are skipped entirely")
    func emptyAnswerSkipped() {
        let p = params(question(2, multiSelect: false), question(2, multiSelect: false))
        let keys = build(p, [
            0: QuestionAnswer(selectedIndices: [0]),
            1: QuestionAnswer(), // empty
        ])
        // Q2 contributes no keystrokes, but a trailing Enter still fires
        // because the prompt is multi-question.
        #expect(keys == [
            .enter, d,
            d, .enter, d,
        ])
    }

    @Test("QuestionAnswer.isEmpty returns true only when both selections and text are empty")
    func questionAnswerIsEmpty() {
        #expect(QuestionAnswer().isEmpty)
        #expect(!QuestionAnswer(selectedIndices: [0]).isEmpty)
        #expect(!QuestionAnswer(customText: "x").isEmpty)
        #expect(!QuestionAnswer(selectedIndices: [0], customText: "x").isEmpty)
    }

    @Test("QuestionAnswer.displayText combines option labels and Other text")
    func questionAnswerDisplayText() {
        let q = question(3, multiSelect: true)
        #expect(QuestionAnswer(selectedIndices: [0, 2]).displayText(for: q) == "Option 1, Option 3")
        #expect(QuestionAnswer(customText: "hi").displayText(for: q) == "Other: hi")
        #expect(
            QuestionAnswer(selectedIndices: [1], customText: "hi").displayText(for: q)
                == "Option 2, Other: hi"
        )
    }
}
