import Foundation
import Testing
@testable import ClaudeSpyNetworking

// MARK: - Helpers

private func snakeCaseEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func snakeCaseDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

// MARK: - AgentResponseRequest round-trip tests

@Suite("AgentResponseRequest Codable round-trip")
struct AgentResponseRequestTests {
    @Test("prompt case round-trips through snake_case JSON")
    func promptRoundTrips() throws {
        let original = AgentResponseRequest.prompt(
            PromptRequest(placeholder: "Send a message to Claude...")
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("prompt case encodes with snake_case discriminator")
    func promptDiscriminatorIsSnakeCase() throws {
        let original = AgentResponseRequest.prompt(PromptRequest(placeholder: "Hi"))
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        // Discriminator: type=prompt, body=PromptRequest
        #expect(json.contains("\"type\":\"prompt\""))
        #expect(json.contains("\"placeholder\":\"Hi\""))
    }

    @Test("replyAfterStop case round-trips with snake_case fields")
    func replyAfterStopRoundTrips() throws {
        let original = AgentResponseRequest.replyAfterStop(
            ReplyAfterStopRequest(lastAssistantMessage: "Done, what's next?")
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("replyAfterStop discriminator uses snake_case")
    func replyAfterStopDiscriminatorIsSnakeCase() throws {
        let original = AgentResponseRequest.replyAfterStop(
            ReplyAfterStopRequest(lastAssistantMessage: "msg")
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"reply_after_stop\""))
        #expect(json.contains("\"last_assistant_message\":\"msg\""))
    }

    @Test("permission case round-trips with suggestions and isAutoApprovable")
    func permissionRoundTrips() throws {
        let original = AgentResponseRequest.permission(
            PermissionRequest(
                toolName: "Bash",
                description: "Run `ls -la`",
                suggestions: [
                    PermissionRequest.Suggestion(id: "allow_once", label: "Allow once", badge: nil),
                    PermissionRequest.Suggestion(id: "always_allow", label: "Always allow", badge: "ALWAYS"),
                ],
                isAutoApprovable: true
            )
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("permission encodes is_auto_approvable as snake_case")
    func permissionAutoApprovableSnakeCase() throws {
        let original = AgentResponseRequest.permission(
            PermissionRequest(
                toolName: "Read",
                description: "Read file",
                suggestions: [],
                isAutoApprovable: false
            )
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"permission\""))
        #expect(json.contains("\"is_auto_approvable\":false"))
        #expect(json.contains("\"tool_name\":\"Read\""))
    }

    @Test("askUserQuestion case round-trips with multiple questions")
    func askUserQuestionRoundTrips() throws {
        let q1 = AskUserQuestionRequest.Question(
            prompt: "Pick a colour",
            options: [
                AskUserQuestionRequest.Option(label: "Red", detail: "Warm"),
                AskUserQuestionRequest.Option(label: "Blue", detail: nil),
            ],
            allowMultiple: false,
            allowFreeText: false
        )
        let q2 = AskUserQuestionRequest.Question(
            prompt: "Any extra info?",
            options: [
                AskUserQuestionRequest.Option(label: "Yes", detail: nil),
            ],
            allowMultiple: true,
            allowFreeText: true
        )
        let original = AgentResponseRequest.askUserQuestion(
            AskUserQuestionRequest(questions: [q1, q2])
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("askUserQuestion discriminator and field snake_case")
    func askUserQuestionDiscriminatorIsSnakeCase() throws {
        let original = AgentResponseRequest.askUserQuestion(
            AskUserQuestionRequest(questions: [
                AskUserQuestionRequest.Question(
                    prompt: "p",
                    options: [],
                    allowMultiple: true,
                    allowFreeText: false
                ),
            ])
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"ask_user_question\""))
        #expect(json.contains("\"allow_multiple\":true"))
        #expect(json.contains("\"allow_free_text\":false"))
    }

    @Test("approvePlan case round-trips")
    func approvePlanRoundTrips() throws {
        let original = AgentResponseRequest.approvePlan(
            ApprovePlanRequest(plan: "# Plan\n\n- Step 1\n- Step 2", allowEdit: true)
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("approvePlan discriminator and field snake_case")
    func approvePlanDiscriminatorIsSnakeCase() throws {
        let original = AgentResponseRequest.approvePlan(
            ApprovePlanRequest(plan: "p", allowEdit: false)
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"approve_plan\""))
        #expect(json.contains("\"allow_edit\":false"))
    }
}

// MARK: - AgentResponse round-trip tests

@Suite("AgentResponse Codable round-trip")
struct AgentResponseTests {
    @Test("prompt case round-trips")
    func promptResponseRoundTrips() throws {
        let original = AgentResponse.prompt(PromptResponse(text: "Hello, agent."))

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("prompt response uses snake_case discriminator")
    func promptResponseDiscriminatorIsSnakeCase() throws {
        let original = AgentResponse.prompt(PromptResponse(text: "hi"))
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"prompt\""))
        #expect(json.contains("\"text\":\"hi\""))
    }

    @Test("replyAfterStop response round-trips")
    func replyAfterStopResponseRoundTrips() throws {
        let original = AgentResponse.replyAfterStop(ReplyAfterStopResponse(text: ""))

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("replyAfterStop response discriminator is snake_case")
    func replyAfterStopResponseDiscriminatorIsSnakeCase() throws {
        let original = AgentResponse.replyAfterStop(ReplyAfterStopResponse(text: "x"))
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"reply_after_stop\""))
    }

    @Test("permission response round-trips with applied suggestion")
    func permissionResponseRoundTripsWithSuggestion() throws {
        let original = AgentResponse.permission(
            PermissionResponse(decision: .allow, appliedSuggestionId: "always_allow")
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("permission response round-trips without applied suggestion")
    func permissionResponseRoundTripsWithoutSuggestion() throws {
        let original = AgentResponse.permission(
            PermissionResponse(decision: .deny, appliedSuggestionId: nil)
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("permission response discriminator and decision strings are stable")
    func permissionResponseDecisionStable() throws {
        let allowData = try snakeCaseEncoder().encode(
            AgentResponse.permission(PermissionResponse(decision: .allow, appliedSuggestionId: nil))
        )
        let allowJSON = try #require(String(data: allowData, encoding: .utf8))
        #expect(allowJSON.contains("\"type\":\"permission\""))
        #expect(allowJSON.contains("\"decision\":\"allow\""))

        let denyData = try snakeCaseEncoder().encode(
            AgentResponse.permission(PermissionResponse(decision: .deny, appliedSuggestionId: "x"))
        )
        let denyJSON = try #require(String(data: denyData, encoding: .utf8))
        #expect(denyJSON.contains("\"decision\":\"deny\""))
        #expect(denyJSON.contains("\"applied_suggestion_id\":\"x\""))
    }

    @Test("askUserQuestion response round-trips")
    func askUserQuestionResponseRoundTrips() throws {
        let original = AgentResponse.askUserQuestion(
            AskUserQuestionResponse(answers: [
                AskUserQuestionResponse.QuestionAnswer(
                    selectedOptionIndices: [0],
                    freeText: nil
                ),
                AskUserQuestionResponse.QuestionAnswer(
                    selectedOptionIndices: [1, 2],
                    freeText: "Other answer"
                ),
            ])
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("askUserQuestion response discriminator and fields are snake_case")
    func askUserQuestionResponseSnakeCase() throws {
        let original = AgentResponse.askUserQuestion(
            AskUserQuestionResponse(answers: [
                AskUserQuestionResponse.QuestionAnswer(
                    selectedOptionIndices: [3],
                    freeText: "free"
                ),
            ])
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"ask_user_question\""))
        #expect(json.contains("\"selected_option_indices\":[3]"))
        #expect(json.contains("\"free_text\":\"free\""))
    }

    @Test("approvePlan response round-trips with edited plan")
    func approvePlanResponseRoundTripsWithEdit() throws {
        let original = AgentResponse.approvePlan(
            ApprovePlanResponse(decision: .approve, editedPlan: "# Edited Plan\n- new step")
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("approvePlan response round-trips with reject and no edit")
    func approvePlanResponseRejectRoundTrips() throws {
        let original = AgentResponse.approvePlan(
            ApprovePlanResponse(decision: .reject, editedPlan: nil)
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponse.self, from: data)

        #expect(decoded == original)
    }

    @Test("approvePlan response decision strings stable")
    func approvePlanDecisionStable() throws {
        let approveData = try snakeCaseEncoder().encode(
            AgentResponse.approvePlan(
                ApprovePlanResponse(decision: .approve, editedPlan: nil)
            )
        )
        let approveJSON = try #require(String(data: approveData, encoding: .utf8))
        #expect(approveJSON.contains("\"type\":\"approve_plan\""))
        #expect(approveJSON.contains("\"decision\":\"approve\""))

        let rejectData = try snakeCaseEncoder().encode(
            AgentResponse.approvePlan(
                ApprovePlanResponse(decision: .reject, editedPlan: "x")
            )
        )
        let rejectJSON = try #require(String(data: rejectData, encoding: .utf8))
        #expect(rejectJSON.contains("\"decision\":\"reject\""))
        #expect(rejectJSON.contains("\"edited_plan\":\"x\""))
    }
}

// MARK: - AgentSessionStatusUpdate round-trip tests

@Suite("AgentSessionStatusUpdate Codable round-trip")
struct AgentSessionStatusUpdateTests {
    @Test("Round-trip preserves fields")
    func roundTripPreservesFields() throws {
        let original = AgentSessionStatusUpdate(
            sessionId: "abc-123",
            pluginId: "claude-code",
            working: true,
            attention: false,
            timestamp: Date(timeIntervalSince1970: 1_716_575_531)
        )

        let encoder = snakeCaseEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = snakeCaseDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSessionStatusUpdate.self, from: data)

        #expect(decoded == original)
    }

    @Test("Encodes session_id and plugin_id as snake_case")
    func encodesSnakeCaseFields() throws {
        let original = AgentSessionStatusUpdate(
            sessionId: "abc-123",
            pluginId: "claude-code",
            working: true,
            attention: false,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let encoder = snakeCaseEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"session_id\":\"abc-123\""))
        #expect(json.contains("\"plugin_id\":\"claude-code\""))
        #expect(json.contains("\"working\":true"))
        #expect(json.contains("\"attention\":false"))
    }
}

// MARK: - AppAction round-trip tests

@Suite("AppAction Codable round-trip")
struct AppActionTests {
    @Test("openFileSuggestion round-trips")
    func openFileSuggestionRoundTrips() throws {
        let original = AppAction.openFileSuggestion(
            sessionId: "sess-1",
            path: "/tmp/file.md",
            displayName: "file.md",
            isPlan: false
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AppAction.self, from: data)

        #expect(decoded == original)
    }

    @Test("openFileSuggestion encodes snake_case fields")
    func openFileSuggestionFieldsSnakeCase() throws {
        let original = AppAction.openFileSuggestion(
            sessionId: "s",
            path: "/p",
            displayName: "n",
            isPlan: true
        )
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"open_file_suggestion\""))
        #expect(json.contains("\"session_id\":\"s\""))
        #expect(json.contains("\"display_name\":\"n\""))
        #expect(json.contains("\"is_plan\":true"))
    }

    @Test("dismissFileSuggestions round-trips")
    func dismissFileSuggestionsRoundTrips() throws {
        let original = AppAction.dismissFileSuggestions(sessionId: "sess-2")

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AppAction.self, from: data)

        #expect(decoded == original)
    }

    @Test("dismissFileSuggestions discriminator is snake_case")
    func dismissFileSuggestionsDiscriminatorIsSnakeCase() throws {
        let original = AppAction.dismissFileSuggestions(sessionId: "s")
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"dismiss_file_suggestions\""))
        #expect(json.contains("\"session_id\":\"s\""))
    }

    @Test("closePaneIfPreferenceAllows round-trips")
    func closePaneIfPreferenceAllowsRoundTrips() throws {
        let original = AppAction.closePaneIfPreferenceAllows(sessionId: "sess-3")

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AppAction.self, from: data)

        #expect(decoded == original)
    }

    @Test("closePaneIfPreferenceAllows discriminator is snake_case")
    func closePaneIfPreferenceAllowsDiscriminatorIsSnakeCase() throws {
        let original = AppAction.closePaneIfPreferenceAllows(sessionId: "s")
        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"close_pane_if_preference_allows\""))
    }
}
