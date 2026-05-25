import Testing
@testable import CodexPluginCore

@Suite("CodexNotificationCopy")
struct CodexNotificationCopyTests {
    @Test("Agent display names match CodingAgent defaults")
    func agentNames() {
        // Lock the copy strings in — Task 21 deletes the legacy code path
        // that derives these from `CodingAgent`, but the public copy must
        // stay byte-identical so notifications don't visibly change shape.
        #expect(CodexNotificationCopy.agentDisplayName == "Codex")
        #expect(CodexNotificationCopy.agentShortName == "Codex")
    }

    @Test("Session-started body composes project + display name")
    func sessionStartedBody() {
        #expect(
            CodexNotificationCopy.sessionStartedBody(project: "MyApp")
                == "MyApp: Codex session started"
        )
    }

    @Test("Permission-request body composes project + short name")
    func needsApprovalBody() {
        #expect(
            CodexNotificationCopy.needsApprovalBody(project: "MyApp")
                == "MyApp: Codex needs your approval"
        )
    }

    @Test("Stop-summary body truncates long summaries to 256 + ellipsis")
    func stopSummaryTruncation() {
        let long = String(repeating: "x", count: 300)
        let body = CodexNotificationCopy.stopSummaryBody(
            project: "MyApp",
            summary: long
        )
        let expectedPrefix = "MyApp: " + String(repeating: "x", count: 256) + "..."
        #expect(body == expectedPrefix)
    }

    @Test("Single-question askQuestionBody composes verbatim")
    func askQuestionBody() {
        #expect(
            CodexNotificationCopy.askQuestionBody(
                project: "MyApp",
                question: "Run tests?"
            ) == "MyApp: Run tests?"
        )
    }

    @Test("Multi-question askMultipleQuestionsBody pluralises with count")
    func askMultipleQuestionsBody() {
        #expect(
            CodexNotificationCopy.askMultipleQuestionsBody(
                project: "MyApp",
                count: 3
            ) == "MyApp: Codex has 3 questions"
        )
    }
}
