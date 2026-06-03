import Foundation
import Testing
@testable import ClaudeSpyNetworking

/// Guards the wire contract for carrying open response forms in the session-state
/// snapshot (the fix for "a question that opened while the viewer was offline
/// doesn't render on reconnect"). The field is additive and optional, exactly
/// like `agentProjects`, so an older host that omits it must still decode.
@Suite("SessionStateMessage open response forms")
struct SessionStateOpenRequestSyncTests {
    private func sampleForm() -> PaneOpenResponseRequest {
        PaneOpenResponseRequest(
            sessionId: "%1",
            pluginId: "claude-code",
            requestId: "%1:AskUserQuestion",
            request: .askUserQuestion(AskUserQuestionRequest(questions: [
                .init(
                    id: "q1",
                    question: "Which approach?",
                    header: "Approach",
                    options: [.init(id: "a", label: "A", description: "first")],
                    multiSelect: false
                ),
            ]))
        )
    }

    @Test("an older host's snapshot without the field decodes to nil (back-compat)")
    func missingFieldDecodesToNil() throws {
        // No `openResponseRequests` key — the shape an older host emits.
        let json = """
        {
            "pairId": "pair-1",
            "paneStates": {},
            "homeDirectory": "/Users/test"
        }
        """
        let message = try JSONDecoder().decode(SessionStateMessage.self, from: Data(json.utf8))
        #expect(message.openResponseRequests == nil)
    }

    @Test("open forms survive an encode/decode round-trip")
    func roundTripsOpenForms() throws {
        let original = SessionStateMessage(
            pairId: "pair-1",
            paneStates: [:],
            homeDirectory: "/Users/test",
            openResponseRequests: [sampleForm()]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: data)

        #expect(decoded.openResponseRequests == [sampleForm()])
    }

    @Test("an empty array is preserved (authoritative \"no forms open\")")
    func emptyArrayIsDistinctFromNil() throws {
        let message = SessionStateMessage(
            pairId: "pair-1",
            paneStates: [:],
            openResponseRequests: []
        )
        let decoded = try JSONDecoder().decode(
            SessionStateMessage.self,
            from: JSONEncoder().encode(message)
        )
        #expect(decoded.openResponseRequests == [])
    }

    @Test("withPairId forwards the open forms")
    func withPairIdForwardsForms() {
        let message = SessionStateMessage(
            pairId: "",
            paneStates: [:],
            openResponseRequests: [sampleForm()]
        )
        #expect(message.withPairId("pair-2").openResponseRequests == [sampleForm()])
    }
}
