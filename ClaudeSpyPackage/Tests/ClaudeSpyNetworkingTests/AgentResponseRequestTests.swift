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

        // The WebSocket transport encodes/decodes with a plain coder (no
        // key strategy); `AgentSessionStatusUpdate` carries explicit
        // snake_case `CodingKeys`, so round-trip through the production coder.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
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

        // Production transport uses a plain encoder; the explicit snake_case
        // `CodingKeys` are what put `session_id`/`plugin_id` on the wire.
        let encoder = JSONEncoder()
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

// MARK: - AgentResponseRequestMessage round-trip tests

@Suite("AgentResponseRequestMessage Codable round-trip")
struct AgentResponseRequestMessageTests {
    @Test("Round-trip preserves a populated request body")
    func roundTripPreservesRequest() throws {
        let original = AgentResponseRequestMessage(
            sessionId: "sess-1",
            pluginId: "claude-code",
            requestId: "req-1",
            request: .prompt(PromptRequest(placeholder: "Send a message..."))
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequestMessage.self, from: data)

        #expect(decoded == original)
    }

    @Test("nil request encodes as a dismiss envelope and round-trips")
    func nilRequestRoundTrips() throws {
        let original = AgentResponseRequestMessage(
            sessionId: "sess-1",
            pluginId: "claude-code",
            requestId: "req-1",
            request: nil
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseRequestMessage.self, from: data)

        #expect(decoded == original)
        #expect(decoded.request == nil)
    }

    @Test("Encodes snake_case keys and discriminator")
    func encodesSnakeCaseKeys() throws {
        let original = AgentResponseRequestMessage(
            sessionId: "sess-1",
            pluginId: "claude-code",
            requestId: "req-1",
            request: .prompt(PromptRequest(placeholder: "Hi"))
        )

        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"agent_response_request\""))
        #expect(json.contains("\"session_id\":\"sess-1\""))
        #expect(json.contains("\"plugin_id\":\"claude-code\""))
        #expect(json.contains("\"request_id\":\"req-1\""))
    }

    @Test("Rejects payloads with the wrong discriminator")
    func rejectsWrongDiscriminator() throws {
        let json = """
        {"type":"wrong_type","session_id":"s","plugin_id":"p","request_id":"r"}
        """
        let decoder = snakeCaseDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(AgentResponseRequestMessage.self, from: Data(json.utf8))
        }
    }
}

// MARK: - AgentResponseSubmission round-trip tests

@Suite("AgentResponseSubmission Codable round-trip")
struct AgentResponseSubmissionTests {
    @Test("Round-trip preserves the response payload")
    func roundTripPreservesResponse() throws {
        let original = AgentResponseSubmission(
            sessionId: "sess-1",
            pluginId: "claude-code",
            requestId: "req-1",
            response: .permission(
                PermissionResponse(decision: .allow, appliedSuggestionId: "always_allow")
            )
        )

        let data = try snakeCaseEncoder().encode(original)
        let decoded = try snakeCaseDecoder().decode(AgentResponseSubmission.self, from: data)

        #expect(decoded == original)
    }

    @Test("Encodes snake_case keys and discriminator")
    func encodesSnakeCaseKeys() throws {
        let original = AgentResponseSubmission(
            sessionId: "sess-1",
            pluginId: "claude-code",
            requestId: "req-1",
            response: .prompt(PromptResponse(text: "hi"))
        )

        let data = try snakeCaseEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"agent_response_submission\""))
        #expect(json.contains("\"session_id\":\"sess-1\""))
        #expect(json.contains("\"plugin_id\":\"claude-code\""))
        #expect(json.contains("\"request_id\":\"req-1\""))
    }

    @Test("Rejects payloads with the wrong discriminator")
    func rejectsWrongDiscriminator() throws {
        let json = """
        {"type":"wrong_type","session_id":"s","plugin_id":"p","request_id":"r",
         "response":{"type":"prompt","body":{"text":"x"}}}
        """
        let decoder = snakeCaseDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(AgentResponseSubmission.self, from: Data(json.utf8))
        }
    }
}

// MARK: - WebSocketMessage envelope round-trip tests

@Suite("WebSocketMessage plugin-system envelope round-trip")
struct WebSocketMessagePluginEnvelopeTests {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("agentSessionStatus envelope round-trips")
    func agentSessionStatusRoundTrips() throws {
        let payload = AgentSessionStatusUpdate(
            sessionId: "s1",
            pluginId: "claude-code",
            working: true,
            attention: false,
            timestamp: Date(timeIntervalSince1970: 1_716_575_531)
        )
        let original = WebSocketMessage.agentSessionStatus(payload)

        let data = try encoder().encode(original)
        let decoded = try decoder().decode(WebSocketMessage.self, from: data)

        guard case let .agentSessionStatus(decodedPayload) = decoded else {
            Issue.record("Expected agentSessionStatus case")
            return
        }
        #expect(decodedPayload == payload)
        // Logger-friendly type string uses the snake_case wire value so
        // log searches match what's actually on the wire.
        #expect(original.messageType == "agent_session_status")
    }

    @Test("agentResponseRequest envelope round-trips")
    func agentResponseRequestRoundTrips() throws {
        let payload = AgentResponseRequestMessage(
            sessionId: "s1",
            pluginId: "claude-code",
            requestId: "r1",
            request: .approvePlan(ApprovePlanRequest(plan: "do it", allowEdit: true))
        )
        let original = WebSocketMessage.agentResponseRequest(payload)

        let data = try encoder().encode(original)
        let decoded = try decoder().decode(WebSocketMessage.self, from: data)

        guard case let .agentResponseRequest(decodedPayload) = decoded else {
            Issue.record("Expected agentResponseRequest case")
            return
        }
        #expect(decodedPayload == payload)
        #expect(original.messageType == "agent_response_request")
    }

    @Test("agentResponseSubmission envelope round-trips")
    func agentResponseSubmissionRoundTrips() throws {
        let payload = AgentResponseSubmission(
            sessionId: "s1",
            pluginId: "claude-code",
            requestId: "r1",
            response: .prompt(PromptResponse(text: "hello"))
        )
        let original = WebSocketMessage.agentResponseSubmission(payload)

        let data = try encoder().encode(original)
        let decoded = try decoder().decode(WebSocketMessage.self, from: data)

        guard case let .agentResponseSubmission(decodedPayload) = decoded else {
            Issue.record("Expected agentResponseSubmission case")
            return
        }
        #expect(decodedPayload == payload)
        #expect(original.messageType == "agent_response_submission")
    }

    @Test("pluginPresentations envelope round-trips")
    func pluginPresentationsRoundTrips() throws {
        let presentation = PluginPresentation(
            id: "claude-code",
            version: "1.0.0",
            displayName: "Claude Code",
            shortName: "Claude",
            color: "#cb6f3a",
            iconPNGData: Data([0x01, 0x02, 0x03])
        )
        let payload = PluginPresentationsMessage(presentations: [presentation])
        let original = WebSocketMessage.pluginPresentations(payload)

        let data = try encoder().encode(original)
        let decoded = try decoder().decode(WebSocketMessage.self, from: data)

        guard case let .pluginPresentations(decodedPayload) = decoded else {
            Issue.record("Expected pluginPresentations case")
            return
        }
        #expect(decodedPayload == payload)
        #expect(original.messageType == "plugin_presentations")
    }

    @Test("Production encoder pins the real WebSocket wire keys")
    func productionWireFormatIsPinned() throws {
        // The per-type tests above encode through `snakeCaseEncoder()`
        // (`.convertToSnakeCase`), but the WebSocket transport
        // (`WebSocketMessage.encrypt`, `ConnectedViewer.send`,
        // `ExternalServerClient.send`) uses a plain `JSONEncoder` with only
        // `dateEncodingStrategy = .iso8601` — it never sets that strategy.
        // This test encodes through that exact production config so it pins
        // the bytes that actually travel over the wire, rather than what the
        // snake_case strategy would synthesize.

        // `AgentSessionStatusUpdate` has explicit snake_case `CodingKeys`, so
        // its envelope keys are genuinely snake_case on the wire.
        let statusData = try encoder().encode(
            WebSocketMessage.agentSessionStatus(AgentSessionStatusUpdate(
                sessionId: "s1",
                pluginId: "claude-code",
                working: true,
                attention: false,
                timestamp: Date(timeIntervalSince1970: 1_716_575_531)
            ))
        )
        let statusJSON = try #require(String(data: statusData, encoding: .utf8))
        #expect(statusJSON.contains("\"session_id\":\"s1\""))
        #expect(statusJSON.contains("\"plugin_id\":\"claude-code\""))

        // `AgentResponseRequestMessage`/`AgentResponseSubmission` use bare
        // `CodingKeys` (no snake_case raw values), so without the conversion
        // strategy the envelope keys are emitted as camelCase on the wire.
        // The discriminator strings remain snake_case because they are enum
        // raw values, not key names. Pinning the actual camelCase keys here
        // documents the real contract and keeps the symmetric round-trip
        // tests below from masking it.
        let requestData = try encoder().encode(
            WebSocketMessage.agentResponseRequest(AgentResponseRequestMessage(
                sessionId: "s1",
                pluginId: "claude-code",
                requestId: "r1",
                request: .approvePlan(ApprovePlanRequest(plan: "do it", allowEdit: true))
            ))
        )
        let requestJSON = try #require(String(data: requestData, encoding: .utf8))
        #expect(requestJSON.contains("\"type\":\"agent_response_request\""))
        #expect(requestJSON.contains("\"sessionId\":\"s1\""))
        #expect(requestJSON.contains("\"pluginId\":\"claude-code\""))
        #expect(requestJSON.contains("\"requestId\":\"r1\""))
        #expect(!requestJSON.contains("\"session_id\""))

        let submissionData = try encoder().encode(
            WebSocketMessage.agentResponseSubmission(AgentResponseSubmission(
                sessionId: "s1",
                pluginId: "claude-code",
                requestId: "r1",
                response: .replyAfterStop(ReplyAfterStopResponse(text: "ok"))
            ))
        )
        let submissionJSON = try #require(String(data: submissionData, encoding: .utf8))
        #expect(submissionJSON.contains("\"type\":\"agent_response_submission\""))
        #expect(submissionJSON.contains("\"sessionId\":\"s1\""))
        #expect(submissionJSON.contains("\"pluginId\":\"claude-code\""))
        #expect(submissionJSON.contains("\"requestId\":\"r1\""))
        #expect(!submissionJSON.contains("\"plugin_id\""))
    }

    @Test("All new envelopes are gated for E2EE")
    func envelopesAreEncrypted() {
        let status = WebSocketMessage.agentSessionStatus(AgentSessionStatusUpdate(
            sessionId: "s",
            pluginId: "p",
            working: false,
            attention: false,
            timestamp: Date()
        ))
        let request = WebSocketMessage.agentResponseRequest(AgentResponseRequestMessage(
            sessionId: "s",
            pluginId: "p",
            requestId: "r",
            request: nil
        ))
        let submission = WebSocketMessage.agentResponseSubmission(AgentResponseSubmission(
            sessionId: "s",
            pluginId: "p",
            requestId: "r",
            response: .prompt(PromptResponse(text: "x"))
        ))
        let presentations = WebSocketMessage.pluginPresentations(
            PluginPresentationsMessage(presentations: [])
        )

        // Each new envelope carries per-session or plugin-private data and
        // must travel through the E2EE wrapper before hitting the relay.
        #expect(status.shouldEncrypt)
        #expect(request.shouldEncrypt)
        #expect(submission.shouldEncrypt)
        #expect(presentations.shouldEncrypt)
    }
}
