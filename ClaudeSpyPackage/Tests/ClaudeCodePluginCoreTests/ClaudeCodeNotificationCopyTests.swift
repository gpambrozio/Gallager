import Testing
@testable import ClaudeCodePluginCore

@Suite("ClaudeCodeNotificationCopy")
struct ClaudeCodeNotificationCopyTests {
    @Test("Agent display names match CodingAgent defaults")
    func agentNames() {
        // Lock the copy strings in — Task 21 deletes the legacy code path
        // that derives these from `CodingAgent`, but the public copy must
        // stay byte-identical so notifications don't visibly change shape.
        #expect(ClaudeCodeNotificationCopy.agentDisplayName == "Claude Code")
        #expect(ClaudeCodeNotificationCopy.agentShortName == "Claude")
    }

    @Test("Session-started body composes project + display name")
    func sessionStartedBody() {
        #expect(
            ClaudeCodeNotificationCopy.sessionStartedBody(project: "MyApp")
                == "MyApp: Claude Code session started"
        )
    }

    @Test("Permission-request body composes project + short name")
    func needsApprovalBody() {
        #expect(
            ClaudeCodeNotificationCopy.needsApprovalBody(project: "MyApp")
                == "MyApp: Claude needs your approval"
        )
    }

    @Test("Stop-summary body truncates long summaries to 256 + ellipsis")
    func stopSummaryTruncation() {
        let long = String(repeating: "x", count: 300)
        let body = ClaudeCodeNotificationCopy.stopSummaryBody(
            project: "MyApp",
            summary: long
        )
        let expectedPrefix = "MyApp: " + String(repeating: "x", count: 256) + "..."
        #expect(body == expectedPrefix)
    }

    @Test("Single-question askQuestionBody composes verbatim")
    func askQuestionBody() {
        #expect(
            ClaudeCodeNotificationCopy.askQuestionBody(
                project: "MyApp",
                question: "Run tests?"
            ) == "MyApp: Run tests?"
        )
    }

    @Test("Multi-question askMultipleQuestionsBody pluralises with count")
    func askMultipleQuestionsBody() {
        #expect(
            ClaudeCodeNotificationCopy.askMultipleQuestionsBody(
                project: "MyApp",
                count: 3
            ) == "MyApp: Claude has 3 questions"
        )
    }
}
