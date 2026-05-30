import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Verifies that `deliverResponse` translates each structured `AgentResponse`
/// into exactly the keystrokes the legacy iOS response views sent.
@Suite("ClaudeCodeKeystrokes")
struct ClaudeCodeKeystrokesTests {
    private func makeCore() async throws -> (ClaudeCodePluginCore, MockPluginHost) {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-ks-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: Data()
        )
        try await core.initialize(env, host: host)
        return (core, host)
    }

    // MARK: - Prompt / reply

    @Test("prompt sends trimmed text then Enter")
    func promptText() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "  hello world  "))

        let texts = await host.sentText
        let keys = await host.sentKeys
        #expect(texts.map(\.text) == ["hello world"])
        #expect(keys.map(\.keys) == [[.enter]])
    }

    @Test("empty prompt sends nothing")
    func promptEmpty() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "   "))
        let texts = await host.sentText
        let keys = await host.sentKeys
        #expect(texts.isEmpty)
        #expect(keys.isEmpty)
    }

    @Test("replyAfterStop with text sends text then Enter")
    func replyAfterStopText() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(sessionID: "s", requestID: "r", .replyAfterStop(text: "keep going"))
        let texts = await host.sentText
        let keys = await host.sentKeys
        #expect(texts.map(\.text) == ["keep going"])
        #expect(keys.map(\.keys) == [[.enter]])
    }

    @Test("empty replyAfterStop just interrupts with Escape")
    func replyAfterStopEmptyInterrupts() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(sessionID: "s", requestID: "r", .replyAfterStop(text: ""))
        let texts = await host.sentText
        let keys = await host.sentKeys
        #expect(texts.isEmpty)
        #expect(keys.map(\.keys) == [[.escape]])
    }

    // MARK: - Permission

    @Test("permission allow sends 1")
    func permissionAllow() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .permission(decision: .allow, appliedSuggestionID: nil)
        )
        let keys = await host.allSentKeys
        #expect(keys == [.text("1")])
    }

    @Test("permission allow with a suggestion sends 2 (Accept with Rule)")
    func permissionAllowWithSuggestion() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .permission(decision: .allow, appliedSuggestionID: "suggestion-0")
        )
        let keys = await host.allSentKeys
        #expect(keys == [.text("2")])
    }

    @Test("permission deny sends Escape")
    func permissionDeny() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .permission(decision: .deny, appliedSuggestionID: nil)
        )
        let keys = await host.allSentKeys
        #expect(keys == [.escape])
    }

    @Test("permission denyWithFeedback sends 2, text, Enter")
    func permissionDenyWithFeedback() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .permission(decision: .denyWithFeedback("use tabs"), appliedSuggestionID: nil)
        )
        let texts = await host.sentText
        let keys = await host.sentKeys
        #expect(texts.map(\.text) == ["use tabs"])
        // Order: keys[2], text, keys[enter]
        #expect(keys.map(\.keys) == [[.text("2")], [.enter]])
    }

    // MARK: - Plan

    @Test("approvePlan approve sends 3")
    func planApprove() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .approvePlan(decision: .approve, editedPlan: nil)
        )
        let keys = await host.allSentKeys
        #expect(keys == [.text("3")])
    }

    @Test("approvePlan reject sends Escape")
    func planReject() async throws {
        let (core, host) = try await makeCore()
        await core.deliverResponse(
            sessionID: "s", requestID: "r",
            .approvePlan(decision: .reject, editedPlan: nil)
        )
        let keys = await host.allSentKeys
        #expect(keys == [.escape])
    }

    // MARK: - AskUserQuestion (end-to-end: open form, then deliver)

    @Test("askUserQuestion single-select navigates to the chosen option")
    func askSingleSelect() async throws {
        let (core, host) = try await makeCore()
        // Open the form so the core retains the question context.
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-aq",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Pick a fruit",
                        "header": "Fruit",
                        "options": [
                            {"label": "Apple", "description": ""},
                            {"label": "Banana", "description": ""},
                            {"label": "Cherry", "description": ""}
                        ],
                        "multiSelect": false
                    }
                ]
            }
        }
        """
        let frame = IngressFrame(
            pluginID: ClaudeCodePluginCore.pluginID,
            context: ["TMUX_PANE": "%1"],
            payload: Data(json.utf8)
        )
        let event = try #require(await core.handleIngress(frame))
        let requestID = try #require(event.responseRequest?.requestID)

        // Answer: choose "Cherry" (index 2).
        await core.deliverResponse(
            sessionID: "sess-aq",
            requestID: requestID,
            .askUserQuestion(answers: [
                QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o2"]),
            ])
        )

        let keys = await host.allSentKeys
        // index 2 → two downs then Enter, each followed by a delay; single
        // single-select question is self-submitting (no trailing Enter).
        #expect(keys == [.down, .delay(200), .down, .delay(200), .enter, .delay(200)])
    }

    @Test("askUserQuestion clears retained context after delivery")
    func askClearsContext() async throws {
        let (core, host) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-aq3",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Pick",
                        "header": "Pick",
                        "options": [ {"label": "A", "description": ""} ],
                        "multiSelect": false
                    }
                ]
            }
        }
        """
        let frame = IngressFrame(
            pluginID: ClaudeCodePluginCore.pluginID,
            context: ["TMUX_PANE": "%1"],
            payload: Data(json.utf8)
        )
        let event = try #require(await core.handleIngress(frame))
        let requestID = try #require(event.responseRequest?.requestID)

        await core.deliverResponse(
            sessionID: "sess-aq3", requestID: requestID,
            .askUserQuestion(answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0"])])
        )
        let firstCount = await host.allSentKeys.count
        #expect(firstCount > 0)

        // A second delivery for the same requestID now has no retained context,
        // so it produces no keystrokes.
        await core.deliverResponse(
            sessionID: "sess-aq3", requestID: requestID,
            .askUserQuestion(answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0"])])
        )
        let secondCount = await host.allSentKeys.count
        #expect(secondCount == firstCount) // unchanged
    }

    // MARK: - Pure builder (direct, no actor)

    @Test("multi-select builder toggles options then sends Right and trailing Enter")
    func multiSelectBuilder() {
        let params = AskUserQuestionParameters(
            questions: [
                .init(
                    question: "Colors",
                    header: "Colors",
                    options: [
                        .init(label: "Crimson", description: ""),
                        .init(label: "Emerald", description: ""),
                        .init(label: "Sapphire", description: ""),
                    ],
                    multiSelect: true
                ),
            ],
            answers: nil
        )
        let keys = ClaudeCodeKeystrokes.askUserQuestionKeys(
            params: params,
            answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0", "q0-o2"])]
        )
        // index 0: Enter; then down to index 2 (two downs) + Enter; then Right
        // (no Other); then trailing pause + Enter (multi-select rule).
        #expect(keys == [
            .enter, .delay(200),
            .down, .delay(200), .down, .delay(200), .enter, .delay(200),
            .right, .delay(200),
            .delay(200), .enter, .delay(200),
        ])
    }

    @Test("single-select Other navigates past options, types text, Enter")
    func otherBuilder() {
        let params = AskUserQuestionParameters(
            questions: [
                .init(
                    question: "Fruit",
                    header: "Fruit",
                    options: [
                        .init(label: "Apple", description: ""),
                        .init(label: "Banana", description: ""),
                    ],
                    multiSelect: false
                ),
            ],
            answers: nil
        )
        let keys = ClaudeCodeKeystrokes.askUserQuestionKeys(
            params: params,
            answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: [], freeText: "Mango")]
        )
        // 2 options → two downs to reach "Other", type text, Enter; single
        // single-select question is self-submitting.
        #expect(keys == [
            .down, .delay(200), .down, .delay(200),
            .text("Mango"), .delay(200),
            .enter, .delay(200),
        ])
    }
}
