#if os(macOS)
    import ClaudeSpyNetworking
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("AgentResponseSubmissionGuard")
    struct AgentResponseSubmissionGuardTests {
        private let blockingResponses: [AgentResponse] = [
            .permission(decision: .allow, appliedSuggestionID: nil),
            .askUserQuestion(answers: [QuestionAnswer(questionID: "q0", selectedOptionIDs: ["q0-o0"])]),
            .approvePlan(decision: .approve, editedPlan: nil),
        ]

        @Test("blocking responses deliver only while the open form matches")
        func blockingRequiresMatchingForm() {
            for response in blockingResponses {
                #expect(AgentResponseSubmissionGuard.shouldDeliver(
                    response: response,
                    openFormRequestID: "r1",
                    submittedRequestID: "r1"
                ) == true)
                // Form was answered elsewhere and a NEW form opened.
                #expect(AgentResponseSubmissionGuard.shouldDeliver(
                    response: response,
                    openFormRequestID: "r2",
                    submittedRequestID: "r1"
                ) == false)
                // Form retracted (agent moved on) or pane gone.
                #expect(AgentResponseSubmissionGuard.shouldDeliver(
                    response: response,
                    openFormRequestID: nil,
                    submittedRequestID: "r1"
                ) == false)
            }
        }

        @Test("prompt and reply-after-stop pass through regardless of form state")
        func nonBlockingAlwaysDelivers() {
            for response in [AgentResponse.prompt(text: "hi"), .replyAfterStop(text: "go on")] {
                for openForm in [nil, "r1", "other"] {
                    #expect(AgentResponseSubmissionGuard.shouldDeliver(
                        response: response,
                        openFormRequestID: openForm,
                        submittedRequestID: "r1"
                    ) == true)
                }
            }
        }
    }
#endif
