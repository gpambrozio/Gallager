import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("Hook Notification - AskUserQuestion")
struct HookNotificationAskUserQuestionTests {
    // MARK: - Helpers

    private func askUserQuestionParams(_ texts: String...) -> AskUserQuestionParameters {
        let questions = texts.map { text in
            AskUserQuestionParameters.AskUserQuestion(
                question: text,
                header: "Q",
                options: [
                    AskUserQuestionParameters.AskUserQuestionOption(label: "Yes", description: nil),
                    AskUserQuestionParameters.AskUserQuestionOption(label: "No", description: nil),
                ],
                multiSelect: false
            )
        }
        return AskUserQuestionParameters(questions: questions, answers: nil)
    }

    private func message(
        params: AskUserQuestionParameters,
        projectPath: String?
    ) -> HookEventMessage {
        let body = PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .askUserQuestion(params)
        )
        let event = HookEvent(
            action: .permissionRequest(body),
            projectPath: projectPath,
            tmuxPane: nil
        )
        return HookEventMessage(pairId: "pair-1", event: event)
    }

    // MARK: - Title

    @Test("Title is the fixed copy regardless of project")
    func titleIsFixed() throws {
        let withProject = try #require(
            message(params: askUserQuestionParams("Q?"), projectPath: "/Users/x/MyApp")
                .buildNotification()
        )
        let withoutProject = try #require(
            message(params: askUserQuestionParams("Q?"), projectPath: nil).buildNotification()
        )
        #expect(withProject.title == "Claude wants answers")
        #expect(withoutProject.title == "Claude wants answers")
    }

    // MARK: - Body

    @Test("Single question body is the question text prefixed with the project name")
    func singleQuestionBodyUsesQuestionText() throws {
        let result = try #require(
            message(
                params: askUserQuestionParams("Should we ship it?"),
                projectPath: "/Users/x/MyApp"
            )
            .buildNotification()
        )
        #expect(result.body == "MyApp: Should we ship it?")
    }

    @Test("Multiple questions body shows the count")
    func multipleQuestionsBodyShowsCount() throws {
        let result = try #require(
            message(
                params: askUserQuestionParams("A?", "B?", "C?"),
                projectPath: "/Users/x/MyApp"
            )
            .buildNotification()
        )
        #expect(result.body == "MyApp: Claude has 3 questions")
    }

    @Test("Missing project path falls back to a Claude Code label")
    func missingProjectFallsBack() throws {
        let result = try #require(
            message(params: askUserQuestionParams("Hello?"), projectPath: nil).buildNotification()
        )
        #expect(result.body == "Claude Code: Hello?")
    }

    @Test("Two questions body shows the count, not the first question")
    func twoQuestionsShowCount() throws {
        let result = try #require(
            message(
                params: askUserQuestionParams("First?", "Second?"),
                projectPath: "/Users/x/MyApp"
            )
            .buildNotification()
        )
        #expect(result.body == "MyApp: Claude has 2 questions")
    }

    // MARK: - Other permission requests are unaffected

    @Test("Permission request for a non-AskUserQuestion tool keeps generic copy")
    func nonAskUserQuestionPermissionStillGeneric() throws {
        let body = PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "Bash"
        )
        let event = HookEvent(
            action: .permissionRequest(body),
            projectPath: "/Users/x/MyApp",
            tmuxPane: nil
        )
        let result = try #require(
            HookEventMessage(pairId: "pair-1", event: event).buildNotification()
        )
        #expect(result.title == "Permission: Bash")
        #expect(result.body == "MyApp: Claude needs your approval")
    }
}
