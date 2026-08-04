import Foundation
import Testing
@testable import ClaudeSpyNetworking

// MARK: - Fixtures

private func permissionState(
    suggestions: [PermissionSuggestionOption] = [],
    requestID: String = "s1:PermissionRequest:occ1"
) -> AgentState {
    .awaitingPermission(
        PermissionRequest(title: "Run Command", description: "ls -la", suggestions: suggestions),
        requestID: requestID
    )
}

private func question(
    id: String,
    text: String = "Which one?",
    options: [AskUserQuestionRequest.Option],
    multiSelect: Bool = false,
    allowsFreeText: Bool = true
) -> AskUserQuestionRequest.Question {
    AskUserQuestionRequest.Question(
        id: id,
        question: text,
        header: "Choice",
        options: options,
        multiSelect: multiSelect,
        allowsFreeText: allowsFreeText
    )
}

private func option(_ id: String, label: String = "Option") -> AskUserQuestionRequest.Option {
    AskUserQuestionRequest.Option(id: id, label: label, description: "desc", preview: "preview")
}

// MARK: - Context building

@Suite("NotificationActionContext.make")
struct NotificationActionContextMakeTests {
    @Test("permission with suggestions carries the first suggestion id")
    func permissionWithSuggestions() {
        let state = permissionState(suggestions: [
            PermissionSuggestionOption(id: "suggestion-0", label: "Allow for this session"),
            PermissionSuggestionOption(id: "suggestion-1", label: "Remember and always allow"),
        ])
        let context = NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "claude-code")

        #expect(context?.sessionId == "%1")
        #expect(context?.pluginId == "claude-code")
        #expect(context?.requestId == "s1:PermissionRequest:occ1")
        #expect(context?.form == .permission(PermissionActions(alwaysSuggestionID: "suggestion-0")))
    }

    @Test("permission without suggestions has no Always id")
    func permissionWithoutSuggestions() {
        let context = NotificationActionContext.make(
            state: permissionState(),
            sessionId: "%1",
            pluginId: "claude-code"
        )
        #expect(context?.form == .permission(PermissionActions(alwaysSuggestionID: nil)))
    }

    @Test("single-select questions map to trimmed question actions")
    func singleSelectQuestions() {
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [
                question(id: "q0", options: [option("q0-o0", label: "Red"), option("q0-o1", label: "Blue")]),
                question(id: "q1", options: [option("q1-o0", label: "Small")], allowsFreeText: false),
            ]),
            requestID: "r1"
        )
        let context = NotificationActionContext.make(state: state, sessionId: "%2", pluginId: "claude-code")

        guard case let .askUserQuestion(actions)? = context?.form else {
            Issue.record("Expected question form, got \(String(describing: context))")
            return
        }
        #expect(actions.questions.count == 2)
        #expect(actions.questions[0].id == "q0")
        #expect(actions.questions[0].options.map(\.label) == ["Red", "Blue"])
        #expect(actions.questions[0].allowsFreeText == true)
        #expect(actions.questions[1].allowsFreeText == false)
    }

    @Test("any multi-select question drops the whole action set")
    func multiSelectRejected() {
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [
                question(id: "q0", options: [option("q0-o0")]),
                question(id: "q1", options: [option("q1-o0")], multiSelect: true),
            ]),
            requestID: "r1"
        )
        #expect(NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p") == nil)
    }

    @Test("empty question list and option-less questions are rejected")
    func degenerateQuestionsRejected() {
        let empty = AgentState.awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "r1")
        #expect(NotificationActionContext.make(state: empty, sessionId: "%1", pluginId: "p") == nil)

        let optionless = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [question(id: "q0", options: [], allowsFreeText: false)]),
            requestID: "r1"
        )
        #expect(NotificationActionContext.make(state: optionless, sessionId: "%1", pluginId: "p") == nil)
    }

    @Test("option-less question with free text is still actionable")
    func optionlessFreeTextAllowed() {
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [question(id: "q0", options: [], allowsFreeText: true)]),
            requestID: "r1"
        )
        #expect(NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p") != nil)
    }

    @Test("long question text and labels are truncated with an ellipsis")
    func truncation() {
        let longText = String(repeating: "x", count: 400)
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [
                question(id: "q0", text: longText, options: [option("q0-o0", label: longText)]),
            ]),
            requestID: "r1"
        )
        let context = NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p")

        guard case let .askUserQuestion(actions)? = context?.form else {
            Issue.record("Expected question form")
            return
        }
        let limits = NotificationActionContext.Limits.self
        #expect(actions.questions[0].question.count == limits.questionLength + 1)
        #expect(actions.questions[0].question.hasSuffix("…"))
        #expect(actions.questions[0].options[0].label.count == limits.optionLabelLength + 1)
    }

    @Test("more options than the cap drops the action set")
    func tooManyOptionsRejected() {
        let options = (0..<10).map { option("q0-o\($0)") }
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: [question(id: "q0", options: options)]),
            requestID: "r1"
        )
        #expect(NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p") == nil)
    }

    @Test("an oversized encoded context degrades to nil")
    func oversizedContextRejected() {
        // 4 questions × 6 options with near-limit labels blows the byte budget
        // even after per-string truncation.
        let questions = (0..<4).map { qIndex in
            question(
                id: "q\(qIndex)",
                text: String(repeating: "q", count: 140),
                options: (0..<6).map {
                    option("q\(qIndex)-o\($0)", label: String(repeating: "o", count: 55))
                }
            )
        }
        let state = AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: questions),
            requestID: "r1"
        )
        #expect(NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p") == nil)
    }

    @Test("non-form states produce no context")
    func nonFormStates() {
        let plan = AgentState.awaitingPlanApproval(
            ApprovePlanRequest(title: "Plan", plan: "steps"),
            requestID: "r1"
        )
        for state in [AgentState.working, .idle, .doneWorking(summary: "done"), plan] {
            #expect(NotificationActionContext.make(state: state, sessionId: "%1", pluginId: "p") == nil)
        }
    }
}

// MARK: - Planner

@Suite("NotificationActionPlanner")
struct NotificationActionPlannerTests {
    private let permissionContext = NotificationActionContext(
        sessionId: "%1",
        pluginId: "claude-code",
        requestId: "r1",
        form: .permission(PermissionActions(alwaysSuggestionID: "suggestion-0"))
    )

    private func questionContext(_ questions: [QuestionActions.Question]) -> NotificationActionContext {
        NotificationActionContext(
            sessionId: "%1",
            pluginId: "claude-code",
            requestId: "r1",
            form: .askUserQuestion(QuestionActions(questions: questions))
        )
    }

    @Test("permission taps map to allow / allow+suggestion / deny")
    func permissionTaps() {
        #expect(NotificationActionPlanner.plan(
            context: permissionContext,
            progress: nil,
            actionIdentifier: NotificationActionID.permissionAllow,
            userText: nil
        ) == .submit(.permission(decision: .allow, appliedSuggestionID: nil)))

        #expect(NotificationActionPlanner.plan(
            context: permissionContext,
            progress: nil,
            actionIdentifier: NotificationActionID.permissionAlways,
            userText: nil
        ) == .submit(.permission(decision: .allow, appliedSuggestionID: "suggestion-0")))

        #expect(NotificationActionPlanner.plan(
            context: permissionContext,
            progress: nil,
            actionIdentifier: NotificationActionID.permissionDeny,
            userText: nil
        ) == .submit(.permission(decision: .deny, appliedSuggestionID: nil)))
    }

    @Test("Always without a stored suggestion degrades to plain allow")
    func alwaysWithoutSuggestion() {
        let context = NotificationActionContext(
            sessionId: "%1",
            pluginId: "p",
            requestId: "r1",
            form: .permission(PermissionActions(alwaysSuggestionID: nil))
        )
        #expect(NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.permissionAlways,
            userText: nil
        ) == .submit(.permission(decision: .allow, appliedSuggestionID: nil)))
    }

    @Test("default tap and unknown identifiers are not handled")
    func unknownIdentifiers() {
        for identifier in ["com.apple.UNNotificationDefaultActionIdentifier", "bogus", ""] {
            #expect(NotificationActionPlanner.plan(
                context: permissionContext,
                progress: nil,
                actionIdentifier: identifier,
                userText: nil
            ) == nil)
        }
    }

    @Test("single question option tap submits immediately")
    func singleQuestionSubmits() {
        let context = questionContext([
            QuestionActions.Question(
                id: "q0",
                question: "Pick one",
                options: [QuestionActions.Option(id: "q0-o1", label: "Blue")],
                allowsFreeText: true
            ),
        ])
        let plan = NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.questionOption("q0-o1"),
            userText: nil
        )
        #expect(plan == .submit(.askUserQuestion(answers: [
            QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o1"]),
        ])))
    }

    @Test("multi-question flow advances then submits accumulated answers")
    func multiQuestionProgression() {
        let context = questionContext([
            QuestionActions.Question(
                id: "q0",
                question: "First?",
                options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                allowsFreeText: false
            ),
            QuestionActions.Question(
                id: "q1",
                question: "Second?",
                options: [QuestionActions.Option(id: "q1-o0", label: "B")],
                allowsFreeText: false
            ),
        ])

        let first = NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.questionOption("q0-o0"),
            userText: nil
        )
        let expectedProgress = NotificationActionProgress(
            questionIndex: 1,
            answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0"])]
        )
        #expect(first == .nextQuestion(index: 1, progress: expectedProgress))

        let second = NotificationActionPlanner.plan(
            context: context,
            progress: expectedProgress,
            actionIdentifier: NotificationActionID.questionOption("q1-o0"),
            userText: nil
        )
        #expect(second == .submit(.askUserQuestion(answers: [
            QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0"]),
            QuestionAnswer(questionID: "q1", selectedOptionIDs: ["q1-o0"]),
        ])))
    }

    @Test("free-text Other answers the current question")
    func freeTextAnswer() {
        let context = questionContext([
            QuestionActions.Question(
                id: "q0",
                question: "Pick",
                options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                allowsFreeText: true
            ),
        ])
        let plan = NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.questionOther,
            userText: "  custom answer  "
        )
        #expect(plan == .submit(.askUserQuestion(answers: [
            QuestionAnswer(questionID: "q0", selectedOptionIDs: [], freeText: "custom answer"),
        ])))
    }

    @Test("empty free text and options from another question are rejected")
    func invalidQuestionAnswers() {
        let context = questionContext([
            QuestionActions.Question(
                id: "q0",
                question: "Pick",
                options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                allowsFreeText: true
            ),
        ])
        #expect(NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.questionOther,
            userText: "   "
        ) == nil)
        #expect(NotificationActionPlanner.plan(
            context: context,
            progress: nil,
            actionIdentifier: NotificationActionID.questionOption("q9-o9"),
            userText: nil
        ) == nil)
    }

    @Test("out-of-range progress index is rejected")
    func outOfRangeProgress() {
        let context = questionContext([
            QuestionActions.Question(
                id: "q0",
                question: "Pick",
                options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                allowsFreeText: false
            ),
        ])
        #expect(NotificationActionPlanner.plan(
            context: context,
            progress: NotificationActionProgress(questionIndex: 5, answers: []),
            actionIdentifier: NotificationActionID.questionOption("q0-o0"),
            userText: nil
        ) == nil)
    }
}

// MARK: - Identifiers

@Suite("NotificationActionID")
struct NotificationActionIDTests {
    @Test("option ids round-trip through the action identifier")
    func optionIdRoundTrip() {
        let identifier = NotificationActionID.questionOption("q2-o3")
        #expect(NotificationActionID.optionId(fromActionIdentifier: identifier) == "q2-o3")
        #expect(NotificationActionID.optionId(fromActionIdentifier: "other.prefix") == nil)
        #expect(NotificationActionID.optionId(
            fromActionIdentifier: NotificationActionID.questionOptionPrefix
        ) == nil)
    }
}

// MARK: - Wire compatibility

@Suite("Notification action wire compatibility")
struct NotificationActionWireTests {
    @Test("NotificationContent decodes legacy JSON without an action field")
    func legacyNotificationContent() throws {
        let legacy = """
        {"title":"T","body":"B","eventType":"PermissionRequest","pairId":"pair1",
         "paneId":"%1","timestamp":740000000}
        """
        let content = try JSONDecoder().decode(
            NotificationContent.self,
            from: Data(legacy.utf8)
        )
        #expect(content.action == nil)
        #expect(content.title == "T")
    }

    @Test("AgentNotificationMessage decodes legacy JSON and round-trips the action")
    func agentNotificationMessage() throws {
        let legacy = """
        {"pairId":"pair1","sessionId":"%1","title":"T","body":"B","timestamp":740000000}
        """
        let decoded = try JSONDecoder().decode(
            AgentNotificationMessage.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.action == nil)

        let context = NotificationActionContext(
            sessionId: "%1",
            pluginId: "claude-code",
            requestId: "r1",
            form: .permission(PermissionActions(alwaysSuggestionID: "suggestion-0"))
        )
        let message = AgentNotificationMessage(
            pairId: "pair1",
            sessionId: "%1",
            title: "T",
            body: "B",
            timestamp: Date(timeIntervalSince1970: 1),
            action: context
        )
        let roundTripped = try JSONDecoder().decode(
            AgentNotificationMessage.self,
            from: JSONEncoder().encode(message)
        )
        #expect(roundTripped == message)
        #expect(roundTripped.withPairId("pair2").action == context)
    }

    @Test("a present-but-undecodable action degrades to nil, not a decode failure")
    func lenientActionDecoding() throws {
        // A future host may send a `Form` case this build doesn't know. The
        // whole content must still decode (the NSE would otherwise show its
        // "decryption failed / re-pair" failure notification).
        let futureContent = """
        {"title":"T","body":"B","eventType":"PermissionRequest","pairId":"pair1",
         "paneId":"%1","timestamp":740000000,
         "action":{"sessionId":"%1","pluginId":"p","requestId":"r1",
                   "form":{"someFutureForm":{"_0":{"x":1}}}}}
        """
        let content = try JSONDecoder().decode(
            NotificationContent.self,
            from: Data(futureContent.utf8)
        )
        #expect(content.action == nil)
        #expect(content.title == "T")

        let futureMessage = """
        {"pairId":"pair1","sessionId":"%1","title":"T","body":"B","timestamp":740000000,
         "action":{"sessionId":"%1","pluginId":"p","requestId":"r1",
                   "form":{"someFutureForm":{"_0":{"x":1}}}}}
        """
        let message = try JSONDecoder().decode(
            AgentNotificationMessage.self,
            from: Data(futureMessage.utf8)
        )
        #expect(message.action == nil)
        #expect(message.title == "T")
    }

    @Test("a cap-sized context still fits the APNs 4 KB envelope after double base64")
    func worstCaseAPNsEnvelopeFitsBudget() throws {
        // The `Limits.maxEncodedBytes` cap is measured on the RAW context, but
        // the wire applies double base64: NotificationContent JSON → ChaChaPoly
        // seal → base64 ciphertext inside EncryptedPayload JSON → that whole
        // JSON base64'd again into the push's `encrypted` field. This test
        // walks a cap-sized context through that exact envelope arithmetic —
        // an oversized push is rejected wholesale by APNs, which would mean NO
        // notification at all.
        func context(padding: Int) -> NotificationActionContext {
            NotificationActionContext(
                sessionId: "%42",
                pluginId: "claude-code",
                requestId: "session-uuid-0000:PermissionRequest:occurrence-uuid-0000",
                form: .askUserQuestion(QuestionActions(questions: [
                    QuestionActions.Question(
                        id: "q0",
                        question: String(repeating: "q", count: 150),
                        options: [QuestionActions.Option(
                            id: "q0-o0",
                            // Direct init bypasses `make`'s truncation on
                            // purpose: pad to land exactly at the cap.
                            label: String(repeating: "x", count: padding)
                        )],
                        allowsFreeText: true
                    ),
                ]))
            )
        }
        let base = try JSONEncoder().encode(context(padding: 0)).count
        let capped = context(padding: NotificationActionContext.Limits.maxEncodedBytes - base)
        let cappedBytes = try JSONEncoder().encode(capped).count
        #expect(cappedBytes == NotificationActionContext.Limits.maxEncodedBytes)

        // Worst-case surrounding content: long title/body (Stop summaries are
        // truncated at 256; question bodies carry the question text).
        let content = NotificationContent(
            title: String(repeating: "t", count: 300),
            body: String(repeating: "b", count: 300),
            eventType: "PermissionRequest",
            pairId: UUID().uuidString,
            paneId: "%42",
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            action: capped
        )
        let plaintext = try JSONEncoder().encode(content)

        // ChaChaPoly's sealed box is size-deterministic: 12-byte nonce +
        // plaintext + 16-byte tag. EncryptedPayload's JSON shape is emulated
        // exactly (base64 ciphertext + senderKeyId + version).
        let ciphertext = Data(count: plaintext.count + 28)
        let payloadJSON = """
        {"ciphertext":"\(ciphertext.base64EncodedString())",\
        "senderKeyId":"\(UUID().uuidString)","version":1}
        """
        let encryptedField = Data(payloadJSON.utf8).base64EncodedString()

        // The APNs envelope APNsService emits: placeholder alert + badge +
        // mutable-content, plus the encrypted field and pairId at the root.
        let envelope = """
        {"aps":{"alert":{"title":"Gallager","body":"New activity"},"badge":42,\
        "mutable-content":1},"encrypted":"\(encryptedField)","pairId":"\(UUID().uuidString)"}
        """
        #expect(envelope.utf8.count <= 4096)
    }

    @Test("NotificationContent round-trips the action context")
    func notificationContentRoundTrip() throws {
        let context = NotificationActionContext(
            sessionId: "%1",
            pluginId: "claude-code",
            requestId: "r1",
            form: .askUserQuestion(QuestionActions(questions: [
                QuestionActions.Question(
                    id: "q0",
                    question: "Pick",
                    options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                    allowsFreeText: true
                ),
            ]))
        )
        let content = NotificationContent(
            title: "T",
            body: "B",
            eventType: "PermissionRequest",
            pairId: "pair1",
            paneId: "%1",
            timestamp: Date(timeIntervalSince1970: 1),
            action: context
        )
        let decoded = try JSONDecoder().decode(
            NotificationContent.self,
            from: JSONEncoder().encode(content)
        )
        #expect(decoded == content)
    }
}
