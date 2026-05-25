import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

@Suite("CodexEventTranslator")
struct CodexEventTranslatorTests {
    // MARK: - Fixtures

    /// Build a raw hook payload matching the shape the Codex bridge script
    /// writes: a bare hook body (`session_id`, `hook_event_name`, …) at
    /// the top level. The translator's `decodeHookAction(from:)` runs the
    /// same fallback path the sidecar uses on these payloads.
    private func payload(
        action: String,
        body: [String: Any] = [:],
        sessionId: String = "S1",
        tmuxPane: String = "%0",
        projectPath: String = "/proj/MyApp"
    ) -> (payload: JSONValue, context: IngressContext) {
        var body = body
        if body["session_id"] == nil { body["session_id"] = sessionId }
        if body["hook_event_name"] == nil {
            body["hook_event_name"] = Self.hookEventName(forAction: action)
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let value = try! JSONDecoder().decode(JSONValue.self, from: data)
        let context = IngressContext(envMap: [
            "TMUX_PANE": tmuxPane,
            "CODEX_PROJECT_DIR": projectPath,
            "CODEX_SESSION_ID": sessionId,
        ])
        return (value, context)
    }

    /// Map a `HookAction.<case>` discriminator to the matching
    /// `hook_event_name` Codex (and Claude) injects on the wire.
    private static func hookEventName(forAction action: String) -> String {
        switch action {
        case "sessionStart": "SessionStart"
        case "setup": "Setup"
        case "preToolUse": "PreToolUse"
        case "postToolUse": "PostToolUse"
        case "postToolUseFailure": "PostToolUseFailure"
        case "sessionEnd": "SessionEnd"
        case "permissionRequest": "PermissionRequest"
        case "permissionDenied": "PermissionDenied"
        case "notification": "Notification"
        case "userPromptSubmit": "UserPromptSubmit"
        case "stop": "Stop"
        case "subagentStart": "SubagentStart"
        case "subagentStop": "SubagentStop"
        case "teammateIdle": "TeammateIdle"
        case "taskCompleted": "TaskCompleted"
        case "preCompact": "PreCompact"
        case "postCompact": "PostCompact"
        case "instructionsLoaded": "InstructionsLoaded"
        case "stopFailure": "StopFailure"
        case "configChange": "ConfigChange"
        case "cwdChanged": "CwdChanged"
        case "fileChanged": "FileChanged"
        case "elicitation": "Elicitation"
        case "elicitationResult": "ElicitationResult"
        case "worktreeCreate": "WorktreeCreate"
        case "worktreeRemove": "WorktreeRemove"
        case "taskCreated": "TaskCreated"
        case "userPromptExpansion": "UserPromptExpansion"
        case "postToolBatch": "PostToolBatch"
        default: "Unknown"
        }
    }

    /// Translate and return (optional event, store). The translator is fresh
    /// per call. The correlation store is a no-op by default (tests that
    /// care override it via `translateRecording`).
    private func translate(
        action: String,
        body: [String: Any] = [:],
        sessionId: String = "S1",
        tmuxPane: String = "%0",
        projectPath: String = "/proj/MyApp"
    ) async throws -> (PluginEvent?, PluginRequestStore) {
        let store = PluginRequestStore()
        let (p, ctx) = payload(
            action: action,
            body: body,
            sessionId: sessionId,
            tmuxPane: tmuxPane,
            projectPath: projectPath
        )
        let translator = CodexEventTranslator(
            correlationStore: CodexSessionCorrelationStore(record: { _, _ in })
        )
        let event = try await translator.translate(
            rawPayload: p,
            context: ctx,
            requestStore: store
        )
        return (event, store)
    }

    // MARK: - sessionStart

    @Test("sessionStart → working:false, attention:false, notification(Session started); pluginID==codex")
    func sessionStart() async throws {
        let (raw, _) = try await translate(action: "sessionStart")
        let event = try #require(raw)
        #expect(event.pluginID == "codex")
        #expect(event.sessionID == "S1")
        #expect(event.working == false)
        #expect(event.attention == false)
        #expect(event.notification?.title == "Codex")
        #expect(event.notification?.body == "Session started")
        #expect(event.responseRequest == nil)
        #expect(event.appActions.isEmpty)
    }

    // MARK: - setup

    @Test("setup → nil")
    func setupReturnsNil() async throws {
        let (raw, _) = try await translate(
            action: "setup",
            body: ["trigger": "init"]
        )
        #expect(raw == nil)
    }

    // MARK: - preToolUse

    @Test("preToolUse → working:true, attention:false")
    func preToolUse() async throws {
        let (raw, _) = try await translate(action: "preToolUse")
        let event = try #require(raw)
        #expect(event.pluginID == "codex")
        #expect(event.working == true)
        #expect(event.attention == false)
        #expect(event.notification == nil)
        #expect(event.responseRequest == nil)
        #expect(event.appActions.isEmpty)
    }

    // MARK: - postToolUse

    @Test("postToolUse without markdown write → working:true, no actions")
    func postToolUseNoMarkdown() async throws {
        let (raw, _) = try await translate(
            action: "postToolUse",
            body: [
                "tool_name": "Read",
                "tool_input": ["file_path": "/proj/MyApp/main.swift"],
            ]
        )
        let event = try #require(raw)
        #expect(event.working == true)
        #expect(event.attention == false)
        #expect(event.appActions.isEmpty)
    }

    @Test("postToolUse with markdown Write → adds openFileSuggestion action")
    func postToolUseMarkdown() async throws {
        let (raw, _) = try await translate(
            action: "postToolUse",
            body: [
                "tool_name": "Write",
                "tool_input": ["file_path": "/proj/MyApp/README.md", "content": "hi"],
            ]
        )
        let event = try #require(raw)
        #expect(event.working == true)
        #expect(event.attention == false)
        #expect(event.appActions == [
            .openFileSuggestion(
                sessionId: "S1",
                path: "/proj/MyApp/README.md",
                displayName: "README.md",
                isPlan: false
            ),
        ])
    }

    @Test("postToolUse Write to non-markdown → no openFileSuggestion")
    func postToolUseNonMarkdownWrite() async throws {
        let (raw, _) = try await translate(
            action: "postToolUse",
            body: [
                "tool_name": "Write",
                "tool_input": ["file_path": "/proj/MyApp/main.swift", "content": "hi"],
            ]
        )
        let event = try #require(raw)
        #expect(event.appActions.isEmpty)
    }

    // MARK: - postToolUseFailure

    @Test("postToolUseFailure → working:true")
    func postToolUseFailure() async throws {
        let (raw, _) = try await translate(
            action: "postToolUseFailure",
            body: [
                "tool_name": "Bash",
                "error": "Command failed",
                "tool_use_id": "id",
                "is_interrupt": false,
            ]
        )
        let event = try #require(raw)
        #expect(event.working == true)
        #expect(event.attention == false)
    }

    // MARK: - sessionEnd

    @Test("sessionEnd without promptInputExit → working:false, no actions")
    func sessionEndOther() async throws {
        let (raw, _) = try await translate(
            action: "sessionEnd",
            body: ["reason": "clear"]
        )
        let event = try #require(raw)
        #expect(event.working == false)
        #expect(event.attention == false)
        #expect(event.appActions.isEmpty)
    }

    @Test("sessionEnd with promptInputExit → closePaneIfPreferenceAllows")
    func sessionEndPromptInputExit() async throws {
        let (raw, _) = try await translate(
            action: "sessionEnd",
            body: ["reason": "prompt_input_exit"]
        )
        let event = try #require(raw)
        #expect(event.working == false)
        #expect(event.attention == false)
        #expect(event.appActions == [.closePaneIfPreferenceAllows(sessionId: "S1")])
    }

    // MARK: - permissionRequest

    @Test("permissionRequest Bash → response_request .permission, isAutoApprovable:true")
    func permissionRequestBash() async throws {
        let (raw, store) = try await translate(
            action: "permissionRequest",
            body: [
                "tool_name": "Bash",
                "tool_input": ["command": "ls -la", "description": "list files"],
            ]
        )
        let event = try #require(raw)
        #expect(event.pluginID == "codex")
        #expect(event.working == true)
        #expect(event.attention == true)
        #expect(event.notification?.title == "Codex")
        #expect(event.notification?.body == "MyApp: Codex needs your approval")
        let rr = try #require(event.responseRequest)
        guard case let .permission(req) = rr.request else {
            Issue.record("Expected .permission response request")
            return
        }
        #expect(req.toolName == "Bash")
        #expect(req.isAutoApprovable == true)
        #expect(req.description.contains("Run Command"))
        #expect(req.description.contains("ls -la"))
        let pending = await store.pending()
        #expect(pending.count == 1)
    }

    @Test("permissionRequest AskUserQuestion → response_request .askUserQuestion")
    func permissionRequestAskUserQuestion() async throws {
        let (raw, store) = try await translate(
            action: "permissionRequest",
            body: [
                "tool_name": "AskUserQuestion",
                "tool_input": [
                    "questions": [[
                        "question": "Run tests?",
                        "header": "Tests",
                        "multiSelect": false,
                        "options": [["label": "Yes", "description": "Run them"]],
                    ]],
                ],
            ]
        )
        let event = try #require(raw)
        #expect(event.attention == true)
        #expect(event.notification?.title == "Codex wants answers")
        #expect(event.notification?.body == "MyApp: Run tests?")
        let rr = try #require(event.responseRequest)
        guard case let .askUserQuestion(req) = rr.request else {
            Issue.record("Expected .askUserQuestion response request")
            return
        }
        #expect(req.questions.count == 1)
        #expect(req.questions[0].prompt == "Run tests?")
        #expect(req.questions[0].allowMultiple == false)
        let pending = await store.pending()
        #expect(pending.count == 1)
    }

    @Test("permissionRequest AskUserQuestion with multiple questions → count-based body")
    func permissionRequestAskMultipleQuestions() async throws {
        let (raw, _) = try await translate(
            action: "permissionRequest",
            body: [
                "tool_name": "AskUserQuestion",
                "tool_input": [
                    "questions": [
                        [
                            "question": "First?",
                            "header": "1",
                            "multiSelect": false,
                            "options": [["label": "A", "description": ""]],
                        ],
                        [
                            "question": "Second?",
                            "header": "2",
                            "multiSelect": true,
                            "options": [["label": "B", "description": ""]],
                        ],
                    ],
                ],
            ]
        )
        let event = try #require(raw)
        #expect(event.notification?.body == "MyApp: Codex has 2 questions")
    }

    @Test("permissionRequest ExitPlanMode → response_request .approvePlan")
    func permissionRequestExitPlanMode() async throws {
        let (raw, store) = try await translate(
            action: "permissionRequest",
            body: [
                "tool_name": "ExitPlanMode",
                "tool_input": ["plan": "# Plan\n\nStep 1"],
            ]
        )
        let event = try #require(raw)
        let rr = try #require(event.responseRequest)
        guard case let .approvePlan(req) = rr.request else {
            Issue.record("Expected .approvePlan response request")
            return
        }
        #expect(req.plan == "# Plan\n\nStep 1")
        #expect(req.allowEdit == true)
        let pending = await store.pending()
        #expect(pending.count == 1)
    }

    // MARK: - permissionDenied

    @Test("permissionDenied → nil")
    func permissionDenied() async throws {
        let (raw, _) = try await translate(
            action: "permissionDenied",
            body: ["reason": "user rejected"]
        )
        #expect(raw == nil)
    }

    // MARK: - notification

    @Test("notification with non-permission/idle type and message → notification")
    func notificationNormal() async throws {
        let (raw, _) = try await translate(
            action: "notification",
            body: ["message": "hello", "notification_type": "info"]
        )
        let event = try #require(raw)
        #expect(event.notification?.title == "Codex")
        #expect(event.notification?.body == "MyApp: hello")
    }

    @Test("notification with permission_prompt → nil")
    func notificationPermissionPrompt() async throws {
        let (raw, _) = try await translate(
            action: "notification",
            body: ["message": "x", "notification_type": "permission_prompt"]
        )
        #expect(raw == nil)
    }

    @Test("notification with idle_prompt → nil")
    func notificationIdlePrompt() async throws {
        let (raw, _) = try await translate(
            action: "notification",
            body: ["message": "x", "notification_type": "idle_prompt"]
        )
        #expect(raw == nil)
    }

    @Test("notification with missing message → nil")
    func notificationNoMessage() async throws {
        let (raw, _) = try await translate(
            action: "notification",
            body: ["notification_type": "info"]
        )
        #expect(raw == nil)
    }

    // MARK: - userPromptSubmit

    @Test("userPromptSubmit → working:true, attention:false, dismissFileSuggestions")
    func userPromptSubmit() async throws {
        let (raw, _) = try await translate(
            action: "userPromptSubmit",
            body: ["prompt": "Hi"]
        )
        let event = try #require(raw)
        #expect(event.working == true)
        #expect(event.attention == false)
        #expect(event.appActions == [.dismissFileSuggestions(sessionId: "S1")])
    }

    // MARK: - stop

    @Test("stop → working:false, attention:true, replyAfterStop with summary")
    func stopWithSummary() async throws {
        let (raw, store) = try await translate(
            action: "stop",
            body: ["last_assistant_message": "All done"]
        )
        let event = try #require(raw)
        #expect(event.working == false)
        #expect(event.attention == true)
        #expect(event.notification?.title == "Codex is waiting…")
        let rr = try #require(event.responseRequest)
        guard case let .replyAfterStop(req) = rr.request else {
            Issue.record("Expected .replyAfterStop response request")
            return
        }
        #expect(req.lastAssistantMessage == "All done")
        let pending = await store.pending()
        #expect(pending.count == 1)
    }

    @Test("stop without summary → notification body is fallback waiting copy")
    func stopWithoutSummary() async throws {
        let (raw, _) = try await translate(
            action: "stop",
            body: [:]
        )
        let event = try #require(raw)
        #expect(event.notification?.body == "Codex is waiting for your input")
    }

    // MARK: - subagentStart / subagentStop

    @Test("subagentStart → working:true (Codex-extra case per Spec §17.2 footnote)")
    func subagentStart() async throws {
        let (raw, _) = try await translate(action: "subagentStart")
        let event = try #require(raw)
        #expect(event.working == true)
        #expect(event.attention == false)
    }

    @Test("subagentStop → nil")
    func subagentStop() async throws {
        let (raw, _) = try await translate(
            action: "subagentStop",
            body: ["stop_hook_active": true]
        )
        #expect(raw == nil)
    }

    // MARK: - teammateIdle / taskCompleted / taskCreated

    @Test("teammateIdle → attention:true with Teammate-is-idle notification")
    func teammateIdle() async throws {
        let (raw, _) = try await translate(
            action: "teammateIdle",
            body: ["teammate_name": "Alice", "team_name": "Eng"]
        )
        let event = try #require(raw)
        #expect(event.attention == true)
        #expect(event.notification?.title == "Teammate is idle")
    }

    @Test("taskCompleted → Task completed notification with subject")
    func taskCompleted() async throws {
        let (raw, _) = try await translate(
            action: "taskCompleted",
            body: ["task_subject": "Refactor"]
        )
        let event = try #require(raw)
        #expect(event.notification?.title == "Task completed")
        #expect(event.notification?.body == "Refactor")
    }

    @Test("taskCreated → Task created notification with subject")
    func taskCreated() async throws {
        let (raw, _) = try await translate(
            action: "taskCreated",
            body: ["task_subject": "Investigate"]
        )
        let event = try #require(raw)
        #expect(event.notification?.title == "Task created")
        #expect(event.notification?.body == "Investigate")
    }

    // MARK: - log-and-drop set

    @Test("preCompact → nil")
    func preCompact() async throws {
        let (raw, _) = try await translate(
            action: "preCompact",
            body: ["trigger": "auto"]
        )
        #expect(raw == nil)
    }

    @Test("postCompact → nil (Codex-extra case, log-and-drop)")
    func postCompact() async throws {
        let (raw, _) = try await translate(
            action: "postCompact",
            body: ["trigger": "auto"]
        )
        #expect(raw == nil)
    }

    @Test("instructionsLoaded → nil")
    func instructionsLoaded() async throws {
        let (raw, _) = try await translate(action: "instructionsLoaded")
        #expect(raw == nil)
    }

    @Test("configChange → nil")
    func configChange() async throws {
        let (raw, _) = try await translate(action: "configChange")
        #expect(raw == nil)
    }

    @Test("cwdChanged → nil")
    func cwdChanged() async throws {
        let (raw, _) = try await translate(action: "cwdChanged")
        #expect(raw == nil)
    }

    @Test("fileChanged → nil")
    func fileChanged() async throws {
        let (raw, _) = try await translate(action: "fileChanged")
        #expect(raw == nil)
    }

    @Test("elicitationResult → nil")
    func elicitationResult() async throws {
        let (raw, _) = try await translate(action: "elicitationResult")
        #expect(raw == nil)
    }

    @Test("worktreeCreate → nil")
    func worktreeCreate() async throws {
        let (raw, _) = try await translate(action: "worktreeCreate")
        #expect(raw == nil)
    }

    @Test("worktreeRemove → nil")
    func worktreeRemove() async throws {
        let (raw, _) = try await translate(action: "worktreeRemove")
        #expect(raw == nil)
    }

    @Test("postToolBatch → nil")
    func postToolBatch() async throws {
        let (raw, _) = try await translate(action: "postToolBatch")
        #expect(raw == nil)
    }

    // MARK: - stopFailure

    @Test("stopFailure → attention:true with Stop error notification")
    func stopFailure() async throws {
        let (raw, _) = try await translate(
            action: "stopFailure",
            body: ["error_type": "timeout"]
        )
        let event = try #require(raw)
        #expect(event.attention == true)
        #expect(event.notification?.body == "Stop error: timeout")
    }

    // MARK: - elicitation / userPromptExpansion

    @Test("elicitation → working:true")
    func elicitation() async throws {
        let (raw, _) = try await translate(
            action: "elicitation",
            body: ["mcp_server_name": "weather"]
        )
        let event = try #require(raw)
        #expect(event.working == true)
    }

    @Test("userPromptExpansion → working:true")
    func userPromptExpansion() async throws {
        let (raw, _) = try await translate(
            action: "userPromptExpansion",
            body: ["command_name": "fix"]
        )
        let event = try #require(raw)
        #expect(event.working == true)
    }

    // MARK: - unknown

    @Test("unknown → nil (WARN log)")
    func unknown() async throws {
        let (raw, _) = try await translate(action: "unknown")
        #expect(raw == nil)
    }

    // MARK: - Project path fallback

    @Test("Empty project path → notification uses display name fallback")
    func projectNameFallback() async throws {
        let (raw, _) = try await translate(
            action: "notification",
            body: ["message": "hi", "notification_type": "info"],
            projectPath: ""
        )
        let event = try #require(raw)
        #expect(event.notification?.body == "Codex: hi")
    }

    // MARK: - Request store remembers requestID

    @Test("Request store remembers permission requests by emitted request ID")
    func storeRemembersPermission() async throws {
        let (raw, store) = try await translate(
            action: "permissionRequest",
            body: [
                "tool_name": "Read",
                "tool_input": ["file_path": "/a"],
            ]
        )
        let rr = try #require(raw?.responseRequest)
        let pending = await store.pending()
        #expect(pending[rr.requestID] != nil)
        let consumed = await store.consume(requestID: rr.requestID)
        #expect(consumed != nil)
        let after = await store.pending()
        #expect(after.isEmpty)
    }

    // MARK: - SessionStart correlation file (Codex-specific)

    /// Test recorder that captures every `record(...)` call so we can
    /// assert the SessionStart path writes a correlation file.
    actor CorrelationRecorder {
        var records: [(tmuxPane: String, payload: JSONValue)] = []

        func append(tmuxPane: String, payload: JSONValue) {
            records.append((tmuxPane, payload))
        }

        /// `nonisolated` so the constructor can be reached from outside
        /// the actor; the closure hops back inside on each call.
        nonisolated var client: CodexSessionCorrelationStore {
            CodexSessionCorrelationStore(record: { [self] pane, payload in
                await append(tmuxPane: pane, payload: payload)
            })
        }
    }

    @Test("sessionStart writes a correlation entry keyed by tmux pane")
    func sessionStartWritesCorrelationFile() async throws {
        let recorder = CorrelationRecorder()
        let store = PluginRequestStore()
        let translator = CodexEventTranslator(correlationStore: recorder.client)
        let (raw, ctx) = payload(action: "sessionStart", tmuxPane: "%7")
        let event = try await translator.translate(
            rawPayload: raw,
            context: ctx,
            requestStore: store
        )
        #expect(event != nil)
        let records = await recorder.records
        #expect(records.count == 1)
        #expect(records.first?.tmuxPane == "%7")
    }

    @Test("sessionStart without TMUX_PANE skips correlation write")
    func sessionStartSkipsCorrelationWithoutPane() async throws {
        let recorder = CorrelationRecorder()
        let store = PluginRequestStore()
        let translator = CodexEventTranslator(correlationStore: recorder.client)
        // Empty TMUX_PANE means the bridge couldn't capture it (rare).
        let (raw, ctx) = payload(action: "sessionStart", tmuxPane: "")
        let event = try await translator.translate(
            rawPayload: raw,
            context: ctx,
            requestStore: store
        )
        #expect(event != nil)
        let records = await recorder.records
        #expect(records.isEmpty)
    }
}
