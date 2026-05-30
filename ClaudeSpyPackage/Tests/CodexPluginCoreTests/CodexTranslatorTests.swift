import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Drives the raw Codex hook payload → `PluginEvent` translation through the
/// real `CodexPluginCore.handleIngress`, using realistic hook JSON shapes. Codex
/// routes through the SAME `/api/hooks` → `HookAction.from` path with
/// `agent=codex`, so the payloads parse into the same `HookAction` enum; the
/// notification copy differs (Codex-flavored). Asserts the working / attention /
/// notification / responseRequest / appActions fields the dispatcher fans out.
@Suite("CodexTranslator")
struct CodexTranslatorTests {
    // MARK: - Helpers

    /// Builds an initialized core wired to a fresh mock host. The pane↔session
    /// correlation store is pointed at a throwaway temp dir so tests never touch
    /// the real `~/.claudespy/codex-sessions/`.
    private func makeCore() async throws -> (CodexPluginCore, MockPluginHost) {
        let host = MockPluginHost()
        let correlationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-corr-\(UUID().uuidString)")
        let core = CodexPluginCore(correlation: CodexSessionCorrelation(root: correlationRoot))
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cx-test-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: Data()
        )
        try await core.initialize(env, host: host)
        return (core, host)
    }

    private func frame(
        _ json: String,
        pane: String = "%1"
    ) -> IngressFrame {
        let context = ["TMUX_PANE": pane]
        return IngressFrame(
            pluginID: CodexPluginCore.pluginID,
            context: context,
            payload: Data(json.utf8)
        )
    }

    // MARK: - Plain permission request

    @Test("plain permissionRequest opens a .permission form and needs attention")
    func plainPermission() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-1",
            "cwd": "/Users/test/MyProject",
            "tool_name": "Bash",
            "tool_input": { "command": "rm -rf build", "description": "clean" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))

        #expect(event.sessionID == "sess-1")
        #expect(event.working == true) // permissionRequest enters the agent loop
        #expect(event.attention == true)
        #expect(event.tmuxPane == "%1")
        #expect(event.projectPath == "/Users/test/MyProject")

        let request = try #require(event.responseRequest?.request)
        guard case let .permission(permission) = request else {
            Issue.record("expected .permission, got \(request)")
            return
        }
        #expect(permission.title == "Bash")
        #expect(permission.description == "rm -rf build")
        #expect(permission.allowsCustomInstructions == true)
        #expect(permission.isAutoApprovable == true)
        // requestID is `<session>:<event>:<timestamp>`; this payload has no timestamp.
        #expect(event.responseRequest?.requestID.hasPrefix("sess-1:PermissionRequest") == true)
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
        guard case let .permission(permission)? = event.responseRequest?.request else {
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
        #expect(event.attention == true)

        let request = try #require(event.responseRequest?.request)
        guard case let .askUserQuestion(aq) = request else {
            Issue.record("expected .askUserQuestion, got \(request)")
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

    @Test("AskUserQuestion notification copy is Codex-flavored")
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
        // agent: .codex → "Codex wants answers" (not "Claude wants answers").
        #expect(notification.title == "Codex wants answers")
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
        let request = try #require(event.responseRequest?.request)
        guard case let .approvePlan(plan) = request else {
            Issue.record("expected .approvePlan, got \(request)")
            return
        }
        #expect(plan.plan == "# My Plan\n1. Do the thing")
        #expect(plan.allowsEdit == false)
        #expect(plan.title == "Plan Approval")
    }

    // MARK: - Stop

    @Test("stop leaves the loop, needs attention, and offers replyAfterStop")
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
        #expect(event.working == false)
        #expect(event.attention == true)

        let request = try #require(event.responseRequest?.request)
        guard case let .replyAfterStop(reply) = request else {
            Issue.record("expected .replyAfterStop, got \(request)")
            return
        }
        #expect(reply.title == "Codex is waiting")
        #expect(reply.summary == "All done with the refactor.")

        let notification = try #require(event.notification)
        #expect(notification.body.contains("All done with the refactor."))
    }

    // MARK: - SessionStart

    @Test("sessionStart offers a prompt form and a Codex-flavored notification")
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
        // sessionStart is neutral for working state.
        #expect(event.working == nil)
        #expect(event.attention == true)

        let request = try #require(event.responseRequest?.request)
        guard case let .prompt(prompt) = request else {
            Issue.record("expected .prompt, got \(request)")
            return
        }
        #expect(prompt.title == "Send a message to Codex")

        let notification = try #require(event.notification)
        #expect(notification.body.contains("Codex session started"))
    }

    // MARK: - PostToolUse Write markdown

    @Test("PostToolUse Write of a .md path emits openFileSuggestion")
    func markdownWriteSuggestion() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "sess-md",
            "cwd": "/Users/test/MyProject",
            "tool_name": "Write",
            "tool_input": { "file_path": "/tmp/notes/summary.md", "content": "hi" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .openFileSuggestion(sessionID, path, displayName, isPlan) = action else {
            Issue.record("expected .openFileSuggestion, got \(action)")
            return
        }
        // appAction is keyed by PANE (so the app resolves a session name), not the agent session id.
        #expect(sessionID == "%1")
        #expect(path == "/tmp/notes/summary.md")
        #expect(displayName == "summary.md")
        #expect(isPlan == false)
    }

    @Test("PostToolUse Write of a plan file marks isPlan true")
    func markdownPlanSuggestion() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "sess-plan-md",
            "cwd": "/Users/test/MyProject",
            "tool_name": "Write",
            "tool_input": { "file_path": "/tmp/plans/plan-xyz.md", "content": "steps" }
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        let action = try #require(event.appActions.first)
        guard case let .openFileSuggestion(_, _, _, isPlan) = action else {
            Issue.record("expected .openFileSuggestion")
            return
        }
        #expect(isPlan == true)
    }

    @Test("PostToolUse Write of a non-markdown path keeps working but no app action")
    func nonMarkdownWriteNoAction() async throws {
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
        #expect(event.working == true)
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
        #expect(event.working == true)
    }

    // MARK: - Neutral / dropped events

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
        #expect(event.working == true)
        #expect(event.attention == false)
        #expect(event.notification == nil)
        #expect(event.responseRequest == nil)
        #expect(event.appActions.isEmpty)
    }

    @Test("PreCompact (neutral, no notification) is dropped")
    func preCompactDropped() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "PreCompact",
            "session_id": "sess-pc",
            "trigger": "auto"
        }
        """
        // preCompact has nil working, no attention/notification/form/appAction.
        let event = await core.handleIngress(frame(json))
        #expect(event == nil)
    }

    @Test("projectPath comes from the payload cwd (Codex has no project-dir env)")
    func projectPathFromCwd() async throws {
        let (core, _) = try await makeCore()
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-cwd",
            "cwd": "/Users/test/FromCwd",
            "last_assistant_message": "done"
        }
        """
        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.projectPath == "/Users/test/FromCwd")
    }

    @Test("unparseable payload is dropped and logged")
    func unparseableDropped() async throws {
        let (core, host) = try await makeCore()
        let event = await core.handleIngress(frame("{ not valid"))
        #expect(event == nil)
        let logs = await host.logLines
        #expect(logs.contains { $0.level == .warn })
    }

    // MARK: - Pane correlation (spec §12)

    @Test("sessionStart writes the pane↔session correlation, later events resolve by session id")
    func paneCorrelation() async throws {
        let (core, _) = try await makeCore()

        // SessionStart carries the pane → correlation persisted.
        let startJSON = """
        {
            "hook_event_name": "SessionStart",
            "session_id": "sess-corr",
            "cwd": "/Users/test/MyProject",
            "source": "startup"
        }
        """
        let startEvent = try #require(await core.handleIngress(frame(startJSON, pane: "%7")))
        #expect(startEvent.tmuxPane == "%7")

        // A later Stop with NO pane in context resolves the pane via the
        // correlation file written on session start.
        let stopJSON = """
        {
            "hook_event_name": "Stop",
            "session_id": "sess-corr",
            "last_assistant_message": "done"
        }
        """
        let stopFrame = IngressFrame(
            pluginID: CodexPluginCore.pluginID,
            context: [:], // no TMUX_PANE
            payload: Data(stopJSON.utf8)
        )
        let stopEvent = try #require(await core.handleIngress(stopFrame))
        #expect(stopEvent.tmuxPane == "%7")
    }
}
