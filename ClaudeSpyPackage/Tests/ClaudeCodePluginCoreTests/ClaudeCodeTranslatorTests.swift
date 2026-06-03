import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Drives the raw Claude hook payload → `PluginEvent` translation through the
/// real `ClaudeCodePluginCore.handleIngress`, using realistic hook JSON shapes
/// copied from the E2E scenarios. Asserts the `state` (incl. the open form) /
/// notification / appActions fields the dispatcher fans out.
@Suite("ClaudeCodeTranslator")
struct ClaudeCodeTranslatorTests {
    // MARK: - Helpers

    /// Builds an initialized core wired to a fresh mock host.
    private func makeCore() async throws -> (ClaudeCodePluginCore, MockPluginHost) {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-test-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: Data(),
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)
        return (core, host)
    }

    private func frame(
        _ json: String,
        pane: String = "%1",
        projectDir: String? = "/Users/test/MyProject"
    ) -> IngressFrame {
        var context = ["TMUX_PANE": pane]
        if let projectDir { context["CLAUDE_PROJECT_DIR"] = projectDir }
        return IngressFrame(
            pluginID: ClaudeCodePluginCore.pluginID,
            context: context,
            payload: Data(json.utf8)
        )
    }

    // MARK: - Subagent event filtering

    @Test("a subagent hook event (agent_id set) is dropped, except PermissionRequest")
    func subagentEventsDropped() async throws {
        let (core, _) = try await makeCore()

        // A trailing SubagentStop carries an agent_id and maps to isWorking=true; if
        // applied it would flip the just-stopped main session back to "Working". Drop it.
        let subagentStop = """
        {
            "hook_event_name": "SubagentStop",
            "session_id": "sess-1",
            "agent_id": "sub-123"
        }
        """
        #expect(await core.handleIngress(frame(subagentStop)) == nil)

        // A subagent's permission prompt still needs a user response — NOT dropped.
        let subagentPermission = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-1",
            "agent_id": "sub-123",
            "tool_name": "Bash",
            "tool_input": { "command": "ls", "description": "list" }
        }
        """
        #expect(await core.handleIngress(frame(subagentPermission)) != nil)

        // A main-agent Stop (no agent_id) is processed normally → doneWorking.
        let mainStop = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-1"
        }
        """
        let event = try #require(await core.handleIngress(frame(mainStop)))
        #expect(event.state == .doneWorking(summary: nil))
    }

    @Test("a top-level SubagentStop without agent_id never flips the session to working")
    func topLevelSubagentStopDoesNotWork() async throws {
        let (core, _) = try await makeCore()

        // Defense-in-depth for the case the agent_id drop can't see: a SubagentStop
        // with no agent_id. The .subagentStart/.subagentStop cases map to
        // isWorking=nil, so the event carries no state change and the translator
        // drops it — it can never flip the main session back to "Working".
        let subagentStop = """
        {
            "hook_event_name": "SubagentStop",
            "session_id": "sess-1"
        }
        """
        #expect(await core.handleIngress(frame(subagentStop)) == nil)
    }

    // MARK: - Plain permission request

    @Test("plain permissionRequest opens a .permission form and needs attention")
    func plainPermission() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-1",
            "tool_name": "Bash",
            "tool_input": { "command": "rm -rf build", "description": "clean" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))

        #expect(event.sessionID == "sess-1")
        // A permission request awaits the user (needsAttention derives true).
        #expect(event.state?.needsAttention == true)
        #expect(event.state?.isActiveWorking == false)
        #expect(event.tmuxPane == "%1")
        #expect(event.projectPath == "/Users/test/MyProject")

        let form = try #require(event.state?.openForm)
        guard case let .permission(permission) = form.request else {
            Issue.record("expected .permission, got \(form.request)")
            return
        }
        // Title is the friendly action verb (Bash → "Run Command"), formatted
        // Mac-side so iOS renders it verbatim.
        #expect(permission.title == "Run Command")
        #expect(permission.description == "rm -rf build")
        #expect(permission.allowsCustomInstructions == true)
        // Bash is yolo-auto-approvable, so isAutoApprovable is true.
        #expect(permission.isAutoApprovable == true)
        // requestID is `<session>:<event>:<timestamp>` (timestamp makes repeated
        // events of the same type unique); this payload has no timestamp.
        #expect(form.requestID.hasPrefix("sess-1:PermissionRequest") == true)
    }

    @Test("permissionRequest maps permission_suggestions to chips")
    func permissionSuggestions() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-s",
            "tool_name": "Bash",
            "tool_input": { "command": "git status", "description": "status" },
            "permission_suggestions": [
                {
                    "type": "addRules",
                    "destination": "session",
                    "behavior": "allow",
                    "rules": [ { "toolName": "Bash", "ruleContent": "git status" } ]
                }
            ]
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        guard case let .permission(permission)? = event.state?.openForm?.request else {
            Issue.record("expected .permission")
            return
        }
        #expect(permission.suggestions.count == 1)
        #expect(permission.suggestions.first?.id == "suggestion-0")
        #expect(permission.suggestions.first?.label == "Allow for this session")
        #expect(permission.suggestions.first?.detail == "Bash git status")
    }

    // MARK: - AskUserQuestion

    @Test("permissionRequest + AskUserQuestion opens an .askUserQuestion form")
    func askUserQuestion() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-aq",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "What is your favorite fruit?",
                        "header": "Fruit",
                        "options": [
                            {"label": "Apple", "description": "Crisp"},
                            {"label": "Banana", "description": "Soft"}
                        ],
                        "multiSelect": false
                    }
                ]
            }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state?.needsAttention == true)

        let form = try #require(event.state?.openForm)
        guard case let .askUserQuestion(aq) = form.request else {
            Issue.record("expected .askUserQuestion, got \(form.request)")
            return
        }
        #expect(aq.questions.count == 1)
        let question = try #require(aq.questions.first)
        #expect(question.id == "q0")
        #expect(question.question == "What is your favorite fruit?")
        #expect(question.header == "Fruit")
        #expect(question.multiSelect == false)
        #expect(question.allowsFreeText == true)
        #expect(question.options.map(\.id) == ["q0-o0", "q0-o1"])
        #expect(question.options.map(\.label) == ["Apple", "Banana"])
    }

    @Test("AskUserQuestion notification copy uses the question text")
    func askUserQuestionNotification() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-aq2",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Pick one",
                        "header": "Pick",
                        "options": [ {"label": "A", "description": ""} ],
                        "multiSelect": false
                    }
                ]
            }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let notification = try #require(event.notification)
        #expect(notification.title == "Claude wants answers")
        #expect(notification.body.contains("Pick one"))
    }

    // MARK: - ExitPlanMode

    @Test("permissionRequest + ExitPlanMode opens an .approvePlan form")
    func exitPlanMode() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-plan",
            "tool_name": "ExitPlanMode",
            "tool_input": { "plan": "# My Plan\\n1. Do the thing" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let form = try #require(event.state?.openForm)
        guard case let .approvePlan(plan) = form.request else {
            Issue.record("expected .approvePlan, got \(form.request)")
            return
        }
        #expect(plan.plan == "# My Plan\n1. Do the thing")
        #expect(plan.allowsEdit == false)
        #expect(plan.title == "Plan Approval")
    }

    // MARK: - Stop

    @Test("stop leaves the loop and is doneWorking with the assistant message as summary")
    func stop() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-stop",
            "last_assistant_message": "All done with the refactor."
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state == .doneWorking(summary: "All done with the refactor."))
        #expect(event.state?.needsAttention == true)
        #expect(event.state?.isActiveWorking == false)

        let notification = try #require(event.notification)
        #expect(notification.body.contains("All done with the refactor."))
    }

    // MARK: - SessionStart

    @Test("sessionStart maps to idle and still fires a notification")
    func sessionStart() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "SessionStart",
            "session_id": "sess-start",
            "source": "startup"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        // SessionStart → idle (the "session started" push still fires; no bell).
        #expect(event.state == .idle)
        #expect(event.state?.needsAttention == false)
        #expect(event.state?.openForm == nil)
    }

    // MARK: - PostToolUse Write markdown

    @Test("PostToolUse Write of a .md path emits openFileSuggestion")
    func markdownWriteSuggestion() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "sess-md",
            "tool_name": "Write",
            "tool_input": { "file_path": "/tmp/notes/summary.md", "content": "hi" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json, projectDir: "/Users/test/MyProject")))
        let action = try #require(event.appActions.first)
        guard case let .openFileSuggestion(sessionID, path, displayName, isPlan, projectDir) = action else {
            Issue.record("expected .openFileSuggestion, got \(action)")
            return
        }
        // appAction is keyed by PANE (so the app resolves a session name), not the agent session id.
        #expect(sessionID == "%1")
        #expect(path == "/tmp/notes/summary.md")
        #expect(displayName == "summary.md")
        #expect(isPlan == false)
        // The project dir rides the action so the opened tab roots at the project,
        // not the file's immediate folder.
        #expect(projectDir == "/Users/test/MyProject")
    }

    @Test("PostToolUse Write of a plan file marks isPlan true")
    func markdownPlanSuggestion() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "sess-plan-md",
            "tool_name": "Write",
            "tool_input": { "file_path": "/tmp/plans/plan-xyz.md", "content": "steps" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json, projectDir: "/Users/test/MyProject")))
        let action = try #require(event.appActions.first)
        guard case let .openFileSuggestion(_, _, _, isPlan, _) = action else {
            Issue.record("expected .openFileSuggestion")
            return
        }
        #expect(isPlan == true)
    }

    @Test("PostToolUse Write of a non-markdown path drops the frame")
    func nonMarkdownWriteDropped() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "sess-code",
            "tool_name": "Write",
            "tool_input": { "file_path": "/tmp/main.swift", "content": "code" }
        }
        """
        // postToolUse has working == true, so it is NOT dropped, but it carries
        // no app action.
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.appActions.isEmpty)
        #expect(event.state == .working)
    }

    // MARK: - UserPromptSubmit

    @Test("userPromptSubmit dismisses file suggestions")
    func userPromptSubmit() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "sess-ups",
            "prompt": "do the thing"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .dismissFileSuggestions(sessionID) = action else {
            Issue.record("expected .dismissFileSuggestions, got \(action)")
            return
        }
        #expect(sessionID == "%1") // appAction keyed by pane
        #expect(event.state == .working)
    }

    // MARK: - SessionEnd

    @Test("sessionEnd with prompt_input_exit signals end + close-eligible")
    func sessionEndCloses() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-end",
            "reason": "prompt_input_exit"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .sessionEnded(sessionID, closePaneEligible) = action else {
            Issue.record("expected .sessionEnded, got \(action)")
            return
        }
        #expect(sessionID == "%1") // appAction keyed by pane
        #expect(closePaneEligible == false) // pref off (default) → not eligible even on clean exit
    }

    @Test("sessionEnd with another reason still signals end but not close-eligible")
    func sessionEndOtherReasonResetsButDoesNotClose() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-end",
            "reason": "user_quit"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .sessionEnded(sessionID, closePaneEligible) = action else {
            Issue.record("expected .sessionEnded, got \(action)")
            return
        }
        #expect(sessionID == "%1")
        // Non-prompt-exit end still resets session-scoped state (yolo) but the
        // pane is not close-eligible.
        #expect(closePaneEligible == false)
    }

    @Test("sessionEnd carries no state opinion and signals .sessionEnded")
    func sessionEndMarksIdle() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-end-2",
            "reason": "clear"
        }
        """
        // SessionEnd carries no state opinion (working=false → nil); the
        // `.sessionEnded` app action removes the session (so the row reverts to a
        // terminal glyph). It signals `.sessionEnded` for every reason (so the app
        // resets the pane's yolo); a non-prompt-exit reason is not close-eligible.
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state == nil)
        #expect(event.appActions == [.sessionEnded(sessionID: "%1", closePaneEligible: false)])
    }

    // MARK: - SessionEnd × closePaneOnSessionEnd pref

    private func makeCore(closePaneOnSessionEnd: Bool) async throws -> (ClaudeCodePluginCore, MockPluginHost) {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        let settingsData = try JSONEncoder().encode(
            ClaudeCodeSettings(closePaneOnSessionEnd: closePaneOnSessionEnd)
        )
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-test-pref-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settingsData,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)
        return (core, host)
    }

    @Test("clean prompt-exit + closePaneOnSessionEnd:true → closePaneEligible true")
    func sessionEndClosePrefOnCleanExit() async throws {
        let (core, _) = try await makeCore(closePaneOnSessionEnd: true)
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-pref-on",
            "reason": "prompt_input_exit"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .sessionEnded(_, closePaneEligible) = action else {
            Issue.record("expected .sessionEnded, got \(action)")
            return
        }
        // clean exit AND pref on → eligible
        #expect(closePaneEligible == true)
    }

    @Test("clean prompt-exit + closePaneOnSessionEnd:false → closePaneEligible false")
    func sessionEndClosePrefOffCleanExit() async throws {
        let (core, _) = try await makeCore(closePaneOnSessionEnd: false)
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-pref-off",
            "reason": "prompt_input_exit"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .sessionEnded(_, closePaneEligible) = action else {
            Issue.record("expected .sessionEnded, got \(action)")
            return
        }
        // pref off → not eligible even on clean exit
        #expect(closePaneEligible == false)
    }

    @Test("non-clean exit + closePaneOnSessionEnd:true → closePaneEligible false")
    func sessionEndClosePrefOnNonCleanExit() async throws {
        let (core, _) = try await makeCore(closePaneOnSessionEnd: true)
        let json = """
        {
            "hook_event_name": "SessionEnd",
            "session_id": "sess-pref-on-dirty",
            "reason": "user_quit"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .sessionEnded(_, closePaneEligible) = action else {
            Issue.record("expected .sessionEnded, got \(action)")
            return
        }
        // non-clean exit → not eligible regardless of pref
        #expect(closePaneEligible == false)
    }

    // MARK: - Project path fallback

    @Test("projectPath falls back to payload cwd when no CLAUDE_PROJECT_DIR")
    func projectPathFallback() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-cwd",
            "cwd": "/Users/test/FromCwd",
            "last_assistant_message": "done"
        }
        """
        let event = try #require(await core.handleIngress(frame(json, projectDir: nil)))
        #expect(event.projectPath == "/Users/test/FromCwd")
    }

    // MARK: - Neutral events dropped

    @Test("a neutral event (preToolUse) with working state is kept but form-less")
    func neutralPreToolUse() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PreToolUse",
            "session_id": "sess-pre",
            "tool_name": "Read",
            "tool_input": { "file_path": "/tmp/x.txt" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state == .working)
        #expect(event.state?.needsAttention == false)
        #expect(event.state?.openForm == nil)
        #expect(event.notification == nil)
        #expect(event.appActions.isEmpty)
    }

    @Test("unparseable payload is dropped and logged")
    func unparseableDropped() async throws {
        let (core, host) = try await makeCore()
        let event = await core.handleIngress(frame("{ not valid"))
        #expect(event == nil)
        let logs = await host.logLines
        #expect(logs.contains { $0.level == .warn })
    }
}
