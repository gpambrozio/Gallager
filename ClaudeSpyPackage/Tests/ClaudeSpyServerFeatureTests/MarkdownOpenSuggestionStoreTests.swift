import ClaudeSpyNetworking
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
        let store = MarkdownOpenSuggestionStore(autoDismissDelay: .milliseconds(20))
        try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
        try store.handleHookEvent(promptEvent(), sessionName: "s")
        // Suggestion should still be present immediately after the prompt.
        #expect(store.suggestionsBySession["s"] != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.suggestionsBySession["s"] == nil)
    }

    @Test("Subsequent UserPromptSubmit does not reset the auto-dismiss timer")
    func subsequentPromptDoesNotResetTimer() async throws {
        let store = MarkdownOpenSuggestionStore(autoDismissDelay: .milliseconds(50))
        try store.handleHookEvent(writeEvent(filePath: "/p/a.md"), sessionName: "s")
        try store.handleHookEvent(promptEvent(), sessionName: "s")
        // Wait roughly half the delay, then fire another prompt — should NOT extend the timer.
        try await Task.sleep(for: .milliseconds(30))
        try store.handleHookEvent(promptEvent(), sessionName: "s")
        // After enough total time has passed since the *first* prompt, the suggestion should be gone.
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.suggestionsBySession["s"] == nil)
    }
}
