import ClaudeSpyNetworking
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyServerFeature

@Suite("MarkdownOpenSuggestionStore")
@MainActor
struct MarkdownOpenSuggestionStoreTests {
    /// Builds a PostToolUse Write hook event for testing.
    private func writeEvent(filePath: String, projectPath: String? = nil) throws -> HookEvent {
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "timestamp": "2026-04-25T10:00:00.000000Z",
            "tool_name": "Write",
            "tool_input": { "file_path": "\(filePath)", "content": "x" },
            "tool_response": {}
        }
        """
        let action = try HookAction.from(jsonData: Data(json.utf8))
        return HookEvent(action: action, projectPath: projectPath, tmuxPane: "%0")
    }

    /// Builds a UserPromptSubmit hook event for testing.
    private func promptEvent() throws -> HookEvent {
        let json = """
        {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s",
            "timestamp": "2026-04-25T10:01:00.000000Z",
            "prompt": "next"
        }
        """
        let action = try HookAction.from(jsonData: Data(json.utf8))
        return HookEvent(action: action, projectPath: nil, tmuxPane: "%0")
    }

    @Test("Markdown extensions trigger a suggestion")
    func mdAndMarkdownExtensions() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/notes.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.fileName == "notes.md")

        try store.handleHookEvent(writeEvent(filePath: "/p/notes.MARKDOWN"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.fileName == "notes.MARKDOWN")
    }

    @Test("Non-markdown writes are ignored")
    func nonMarkdownIgnored() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/notes.txt"), sessionName: "s")
        #expect(store.suggestionsBySession["s"] == nil)
    }

    @Test("`/plans/` directory tags the suggestion as a plan")
    func plansDirectory() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(
            writeEvent(filePath: "/p/plans/8f3c.md"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == true)
    }

    @Test("Bare `plan.md` and `plan-foo.md` are tagged as plans")
    func planBasenames() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/plan.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.isPlan == true)

        try store.handleHookEvent(writeEvent(filePath: "/p/plan-overview.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.isPlan == true)

        try store.handleHookEvent(writeEvent(filePath: "/p/plan_v2.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.isPlan == true)
    }

    @Test("Names that merely start with 'plan' are NOT tagged as plans")
    func planLookalikesAreNotPlans() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/planning.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.isPlan == false)

        try store.handleHookEvent(writeEvent(filePath: "/p/planet.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.isPlan == false)
    }

    @Test("Files inside the project are NOT plans even with `plans/` parent or `plan.md` name")
    func filesInsideProjectAreNotPlans() throws {
        let store = MarkdownOpenSuggestionStore()
        // `plans/` directory inside the project — project documentation, not a Claude plan.
        try store.handleHookEvent(
            writeEvent(filePath: "/repo/plans/feature.md", projectPath: "/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == false)

        // Bare `plan.md` checked into the project root.
        try store.handleHookEvent(
            writeEvent(filePath: "/repo/plan.md", projectPath: "/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == false)

        // `plan-foo.md` deeper inside the project.
        try store.handleHookEvent(
            writeEvent(filePath: "/repo/docs/plan-overview.md", projectPath: "/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == false)
    }

    @Test("Files outside the project still tag as plans when projectPath is set")
    func filesOutsideProjectStillTagAsPlans() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(
            writeEvent(filePath: "/tmp/plans/8f3c.md", projectPath: "/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == true)
    }

    @Test("Sibling directories with shared prefix are not treated as inside the project")
    func siblingPrefixIsNotInsideProject() throws {
        let store = MarkdownOpenSuggestionStore()
        // `/repo-other/plan.md` must NOT be considered inside `/repo`.
        try store.handleHookEvent(
            writeEvent(filePath: "/repo-other/plan.md", projectPath: "/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.isPlan == true)
    }

    @Test("`projectPath` populates the suggestion's directoryPath, fall back to file's parent")
    func directoryPathFromProjectPath() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(
            writeEvent(filePath: "/abs/repo/notes.md", projectPath: "/abs/repo"),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.directoryPath == "/abs/repo")

        try store.handleHookEvent(
            writeEvent(filePath: "/abs/repo/sub/note.md", projectPath: nil),
            sessionName: "s"
        )
        #expect(store.suggestionsBySession["s"]?.directoryPath == "/abs/repo/sub")
    }

    @Test("New write replaces an existing suggestion for the same session")
    func suggestionReplaces() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
        try store.handleHookEvent(writeEvent(filePath: "/p/b.md"), sessionName: "s")
        #expect(store.suggestionsBySession["s"]?.fileName == "b.md")
    }

    @Test("Dismiss clears the suggestion")
    func dismissClears() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
        store.dismiss(sessionName: "s")
        #expect(store.suggestionsBySession["s"] == nil)
    }

    @Test("UserPromptSubmit alone does not create a suggestion")
    func promptWithoutSuggestionIsNoop() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(promptEvent(), sessionName: "s")
        #expect(store.suggestionsBySession["s"] == nil)
    }

    @Test("sessionRemoved clears any pending suggestion for the session")
    func sessionRemovedClears() throws {
        let store = MarkdownOpenSuggestionStore()
        try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
        store.sessionRemoved(sessionName: "s")
        #expect(store.suggestionsBySession["s"] == nil)
    }

    @Test("UserPromptSubmit auto-dismisses the suggestion after the configured delay")
    func userPromptSubmitAutoDismisses() async throws {
        await withMainSerialExecutor {
            let clock = TestClock()
            try? await withDependencies {
                $0.continuousClock = clock
            } operation: {
                let store = MarkdownOpenSuggestionStore(autoDismissDelay: .seconds(30))
                try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
                try store.handleHookEvent(promptEvent(), sessionName: "s")
                // Suggestion is still present immediately after the prompt.
                #expect(store.suggestionsBySession["s"] != nil)
                // Just under the deadline — still present.
                await clock.advance(by: .seconds(29))
                #expect(store.suggestionsBySession["s"] != nil)
                // Cross the deadline — dismissal fires.
                await clock.advance(by: .seconds(2))
                #expect(store.suggestionsBySession["s"] == nil)
            }
        }
    }

    @Test("Subsequent UserPromptSubmit does not reset the auto-dismiss timer")
    func subsequentPromptDoesNotResetTimer() async throws {
        await withMainSerialExecutor {
            let clock = TestClock()
            try? await withDependencies {
                $0.continuousClock = clock
            } operation: {
                let store = MarkdownOpenSuggestionStore(autoDismissDelay: .seconds(30))
                try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
                try store.handleHookEvent(promptEvent(), sessionName: "s")
                // Halfway through the original timer, fire another prompt.
                await clock.advance(by: .seconds(15))
                try store.handleHookEvent(promptEvent(), sessionName: "s")
                // The original deadline (30s after the FIRST prompt) still fires —
                // the second prompt did not extend it. If it had, the suggestion
                // would still be present at +31s.
                await clock.advance(by: .seconds(16))
                #expect(store.suggestionsBySession["s"] == nil)
            }
        }
    }
}
