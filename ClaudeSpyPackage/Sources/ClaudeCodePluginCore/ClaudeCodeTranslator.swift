import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - PendingRequest

/// Per-`requestID` context the core retains after emitting an
/// `AgentResponseRequest`, so it can translate the structured `AgentResponse`
/// that comes back into agent-specific keystrokes (spec §7.1). Only the shapes
/// that need delivery-time context carry payloads; the rest are tagged plainly.
enum PendingRequest: Equatable {
    /// AskUserQuestion — retains the raw Claude params so selected option ids
    /// (`"q0-o2"`) and free text map back to the arrow-key navigation sequence.
    case askUserQuestion(AskUserQuestionParameters)
    /// ExitPlanMode plan approval.
    case approvePlan
    /// A plain tool-use permission prompt.
    case permission
    /// Free-text prompt (sessionStart).
    case prompt
    /// Reply offered after the agent stopped.
    case replyAfterStop
}

// MARK: - ClaudeCodeTranslator

/// Pure, stateless mapping from a parsed Claude `HookAction` (+ ingress frame
/// context) to a `PluginEvent` and the optional `PendingRequest` the core must
/// retain. Kept separate from the actor so it is directly unit-testable.
///
/// Faithfully ports the existing behavior that was previously spread across:
/// - `HookEvent.isWorking` (working state),
/// - `HookEvent.wouldTriggerNotification` (attention + notification),
/// - `HookEventMessage.buildNotification()` (notification copy),
/// - `EventResponseView.responseView` (which iOS form an event opens),
/// - the iOS response views' request construction,
/// - `MarkdownOpenSuggestionStore.handleHookEvent` (markdown suggestions),
/// - `MirrorWindowManager` session-end pane-close handling.
enum ClaudeCodeTranslator {
    /// Agent-flavored notification copy (replaces the deleted `CodingAgent`).
    static let agentDisplayName = "Claude Code"
    static let agentShortName = "Claude"

    /// The result of translating one ingress frame.
    struct Output: Equatable {
        var event: PluginEvent
        /// Context to retain under `event.responseRequest?.requestID`, if the
        /// event opened a form. `nil` when no form (or a retraction).
        var pending: PendingRequest?
    }

    /// Translate a parsed action into a `PluginEvent`, or `nil` to drop the
    /// frame (no state change — the dispatcher no-ops).
    static func translate(
        action: HookAction,
        pluginID: String,
        tmuxPane: String?,
        contextProjectDir: String?,
        closePaneOnSessionEnd: Bool = false
    ) -> Output? {
        let body = action.body
        let sessionID = body.sessionId

        // Project path: prefer the harvested CLAUDE_PROJECT_DIR context, fall
        // back to the payload `cwd` (mirrors how hooks set projectPath upstream).
        let projectPath = contextProjectDir ?? Self.cwd(of: action)

        // Wrap in a HookEvent so we can reuse the durable working/notification
        // semantics rather than duplicating the 30-case logic.
        let hookEvent = HookEvent(
            action: action,
            projectPath: projectPath,
            tmuxPane: tmuxPane
        )

        let working = hookEvent.isWorking
        let attention = hookEvent.wouldTriggerNotification(
            agentDisplayName: Self.agentDisplayName,
            agentShortName: Self.agentShortName
        )
        let notification = Self.notification(for: hookEvent)
        let (responseRequest, pending) = Self.responseRequest(
            for: action,
            sessionID: sessionID
        )
        // App actions are keyed by PANE (the app resolves a session name from it),
        // not the agent's internal session id — fall back to sessionID if no pane.
        let appActions = Self.appActions(
            for: action,
            sessionID: tmuxPane ?? sessionID,
            projectPath: projectPath,
            closePaneOnSessionEnd: closePaneOnSessionEnd
        )

        // Drop frames that produce no state change at all, so the dispatcher
        // no-ops (spec §5 — `handleIngress` returns nil for log-and-ignore).
        if
            working == nil,
            !attention,
            notification == nil,
            responseRequest == nil,
            appActions.isEmpty {
            return nil
        }

        let event = PluginEvent(
            pluginID: pluginID,
            sessionID: sessionID,
            working: working,
            attention: attention,
            notification: notification,
            responseRequest: responseRequest,
            appActions: appActions,
            tmuxPane: tmuxPane,
            projectPath: projectPath
        )
        return Output(event: event, pending: pending)
    }

    // MARK: - cwd extraction

    /// The `cwd` from a hook body. `HookBodyProtocol` doesn't expose `cwd`, so we
    /// switch over the concrete bodies (every Claude body carries it).
    private static func cwd(of action: HookAction) -> String? {
        switch action {
        case let .sessionStart(body): body.cwd
        case let .setup(body): body.cwd
        case let .preToolUse(body): body.cwd
        case let .postToolUse(body): body.cwd
        case let .postToolUseFailure(body): body.cwd
        case let .sessionEnd(body): body.cwd
        case let .permissionRequest(body): body.cwd
        case let .permissionDenied(body): body.cwd
        case let .notification(body): body.cwd
        case let .userPromptSubmit(body): body.cwd
        case let .stop(body): body.cwd
        case let .subagentStart(body): body.cwd
        case let .subagentStop(body): body.cwd
        case let .teammateIdle(body): body.cwd
        case let .taskCompleted(body): body.cwd
        case let .preCompact(body): body.cwd
        case let .postCompact(body): body.cwd
        case let .instructionsLoaded(body): body.cwd
        case let .stopFailure(body): body.cwd
        case let .configChange(body): body.cwd
        case let .cwdChanged(body): body.cwd
        case let .fileChanged(body): body.cwd
        case let .elicitation(body): body.cwd
        case let .elicitationResult(body): body.cwd
        case let .worktreeCreate(body): body.cwd
        case let .worktreeRemove(body): body.cwd
        case let .taskCreated(body): body.cwd
        case let .userPromptExpansion(body): body.cwd
        case let .postToolBatch(body): body.cwd
        case let .unknown(body): body.cwd
        }
    }

    // MARK: - Notification copy

    /// Reuses the migrated `HookEvent.buildNotification()` so the copy stays
    /// identical to the legacy path.
    private static func notification(for event: HookEvent) -> NotificationSpec? {
        guard
            let (title, body) = event.buildNotification(
                agentDisplayName: agentDisplayName,
                agentShortName: agentShortName
            ) else {
            return nil
        }
        return NotificationSpec(title: title, body: body)
    }

    // MARK: - Response form selection

    /// Mirrors `EventResponseView.responseView`: which of the five contract forms
    /// (if any) an event opens, and the `PendingRequest` to retain for delivery.
    ///
    /// `requestID` is stable per (session, event) so a Mac-side answer and an iOS
    /// answer can't double-fire: `"\(sessionID):\(eventName)"`.
    private static func responseRequest(
        for action: HookAction,
        sessionID: String
    ) -> (ResponseRequestPayload?, PendingRequest?) {
        switch action {
        case .sessionStart:
            // EventResponseView offers a free-text PromptView on sessionStart.
            let request = AgentResponseRequest.prompt(
                // The placeholder is what iOS renders + exposes as the field's
                // accessibility label, so make it the human-readable prompt.
                PromptRequest(title: "Send a message to Claude", placeholder: "Send a message to Claude")
            )
            return (payload(action: action, sessionID: sessionID, request: request), .prompt)

        case let .stop(body):
            // StopResponseView: summary (last assistant message) + a prompt to
            // reply or interrupt.
            let request = AgentResponseRequest.replyAfterStop(
                ReplyAfterStopRequest(
                    title: "Claude is waiting",
                    summary: body.lastAssistantMessage,
                    placeholder: "Reply to Claude"
                )
            )
            return (payload(action: action, sessionID: sessionID, request: request), .replyAfterStop)

        case let .permissionRequest(body):
            return permissionResponseRequest(body: body, action: action, sessionID: sessionID)

        case .setup,
             .sessionEnd,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .postToolBatch,
             .permissionDenied,
             .notification,
             .userPromptSubmit,
             .userPromptExpansion,
             .stopFailure,
             .subagentStart,
             .subagentStop,
             .teammateIdle,
             .taskCreated,
             .taskCompleted,
             .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitation,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .unknown:
            return (nil, nil)
        }
    }

    /// Permission requests fork into three forms by tool input, matching
    /// `EventResponseView`: AskUserQuestion, ExitPlanMode plan approval, or a
    /// plain permission prompt.
    private static func permissionResponseRequest(
        body: PermissionRequestBody,
        action: HookAction,
        sessionID: String
    ) -> (ResponseRequestPayload?, PendingRequest?) {
        switch body.toolInput {
        case let .askUserQuestion(params):
            let request = AgentResponseRequest.askUserQuestion(askUserQuestionRequest(from: params))
            return (
                payload(action: action, sessionID: sessionID, request: request),
                .askUserQuestion(params)
            )

        case let .exitPlanMode(params):
            let request = AgentResponseRequest.approvePlan(
                ApprovePlanRequest(
                    title: "Plan Approval",
                    plan: params.plan ?? "",
                    // iOS sends "3" to approve / Escape to reject — it never
                    // submits an edited plan (ExitPlanModeResponseView).
                    allowsEdit: false
                )
            )
            return (payload(action: action, sessionID: sessionID, request: request), .approvePlan)

        default:
            let request = AgentResponseRequest.permission(permissionRequest(from: body))
            return (payload(action: action, sessionID: sessionID, request: request), .permission)
        }
    }

    /// Builds the agent-blind `PermissionRequest` from a Claude permission body.
    ///
    /// `isAutoApprovable` ports the legacy yolo notion: today the Mac auto-
    /// approves any permission request EXCEPT AskUserQuestion / ExitPlanMode (see
    /// `PermissionRequestBody.isYoloAutoApprovable`). Those two have their own
    /// forms above, so for the plain-permission path this is effectively `true`,
    /// but we still consult `isYoloAutoApprovable` to stay exactly faithful.
    private static func permissionRequest(from body: PermissionRequestBody) -> PermissionRequest {
        // Friendly action verb (e.g. Bash → "Run Command"), formatted Mac-side so
        // iOS renders it verbatim. Falls back to the raw tool name when the tool
        // input isn't parsed into a known case.
        let title = body.toolInput?.friendlyTitle ?? body.toolName ?? "Permission Request"
        let description = body.toolInput?.summary
            ?? body.toolInput?.toolName
            ?? body.toolName
            ?? ""

        // Map Claude permission suggestions to agent-blind chips. iOS shows
        // label + detail and returns the id; the core resolves the id at
        // delivery time. The legacy PermissionRequestResponseView applies a
        // suggestion via the numbered "Accept with Rule" option, so we keep the
        // index encoded in the id.
        let suggestions: [PermissionSuggestionOption] = (body.permissionSuggestions ?? [])
            .enumerated()
            .map { index, suggestion in
                PermissionSuggestionOption(
                    id: "suggestion-\(index)",
                    label: suggestion.humanReadableLabel,
                    detail: suggestion.humanReadableRules
                )
            }

        return PermissionRequest(
            title: title,
            description: description,
            isAutoApprovable: body.isYoloAutoApprovable,
            suggestions: suggestions,
            allowsCustomInstructions: true
        )
    }

    /// Maps Claude `AskUserQuestionParameters` to the contract request, assigning
    /// stable ids (`"q0"`, `"q0-o1"`) so the answer can be reversed into option
    /// indices at delivery time.
    static func askUserQuestionRequest(from params: AskUserQuestionParameters) -> AskUserQuestionRequest {
        let questions = params.questions.enumerated().map { qIndex, question in
            let options = question.options.enumerated().map { oIndex, option in
                AskUserQuestionRequest.Option(
                    id: "q\(qIndex)-o\(oIndex)",
                    label: option.label,
                    description: option.description,
                    preview: option.preview
                )
            }
            return AskUserQuestionRequest.Question(
                id: "q\(qIndex)",
                question: question.question,
                header: question.header,
                options: options,
                multiSelect: question.multiSelect,
                // Claude's AskUserQuestion always offers an "Other" free-text
                // path (AskUserQuestionResponseView), so allow it.
                allowsFreeText: true
            )
        }
        return AskUserQuestionRequest(questions: questions)
    }

    private static func payload(
        action: HookAction,
        sessionID: String,
        request: AgentResponseRequest
    ) -> ResponseRequestPayload {
        ResponseRequestPayload(requestID: requestID(sessionID: sessionID, action: action), request: request)
    }

    /// Stable, occurrence-unique request id: `"\(sessionID):\(eventName):\(timestamp)"`.
    /// The hook timestamp (microsecond precision) disambiguates repeated events of
    /// the same type in one session — otherwise a second permission/question form
    /// would reuse the first id and iOS would treat it as already-handled.
    static func requestID(sessionID: String, action: HookAction) -> String {
        "\(sessionID):\(action.eventName):\(action.body.timestamp ?? "")"
    }

    // MARK: - App actions

    /// Ports `MarkdownOpenSuggestionStore.handleHookEvent` (markdown write
    /// suggestion + prompt-submit dismissal) and the `MirrorWindowManager`
    /// clean-session-end pane close.
    private static func appActions(
        for action: HookAction,
        sessionID: String,
        projectPath: String?,
        closePaneOnSessionEnd: Bool
    ) -> [AppAction] {
        switch action {
        case let .postToolUse(body):
            guard
                case let .write(params)? = body.toolInput,
                MarkdownPath.isMarkdown(params.filePath)
            else { return [] }
            return [.openFileSuggestion(
                sessionID: sessionID,
                path: params.filePath,
                displayName: URL(fileURLWithPath: params.filePath).lastPathComponent,
                isPlan: MarkdownPath.isPlan(params.filePath, projectPath: projectPath)
            )]

        case .userPromptSubmit:
            return [.dismissFileSuggestions(sessionID: sessionID)]

        case let .sessionEnd(body):
            // Signal the session end for every reason so the app resets the pane's
            // session-scoped state (yolo). The pane is only *closed* when Claude
            // exits cleanly at the prompt (`reason == .promptInputExit`) AND the
            // per-agent pref is on. The core folds both conditions here so the app
            // honors the `closePaneEligible` flag alone.
            return [.sessionEnded(
                sessionID: sessionID,
                closePaneEligible: body.reason == .promptInputExit && closePaneOnSessionEnd
            )]

        default:
            return []
        }
    }
}

// MARK: - Markdown path classification

/// Ports the markdown / plan path detection from `MarkdownOpenSuggestionStore`.
enum MarkdownPath {
    /// True when `path` ends with `.md` or `.markdown` (case-insensitive).
    static func isMarkdown(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    /// True when the file is recognisably a Claude-generated plan: parent dir is
    /// `plans/`, or basename is `plan` / `plan-foo` / `plan_foo`. Files inside the
    /// current project folder are never plans (checked-in docs, not transient).
    static func isPlan(_ path: String, projectPath: String?) -> Bool {
        if let projectPath, isPath(path, inside: projectPath) {
            return false
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        if parent == "plans" { return true }
        let basename = url.deletingPathExtension().lastPathComponent.lowercased()
        if basename == "plan" { return true }
        return basename.hasPrefix("plan-") || basename.hasPrefix("plan_")
    }

    /// True when `path` resolves strictly inside `parent` (both standardized).
    private static func isPath(_ path: String, inside parent: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        let normalizedParent = URL(fileURLWithPath: parent).standardized.path
        let parentWithSlash = normalizedParent.hasSuffix("/") ? normalizedParent : normalizedParent + "/"
        return normalizedPath.hasPrefix(parentWithSlash)
    }
}

// MARK: - Permission suggestion display helpers

private extension PermissionSuggestion {
    /// A short human-readable label for a suggestion chip, e.g.
    /// "Allow for this session". Mirrors the legacy
    /// `PermissionSuggestion.humanReadableDescription` from the iOS view.
    var humanReadableLabel: String {
        switch (type, destination) {
        case (.addRules, .session): "Allow for this session"
        case (.addRules, .localSettings): "Remember and always allow"
        case (.addDirectories, .session): "Allow directory for this session"
        case (.addDirectories, .localSettings): "Remember and always allow directory"
        case (.setMode, .session): "Set mode for this session"
        case (.setMode, .localSettings): "Save mode to settings"
        default:
            [type?.displayName, "for", destination?.stringValue.lowercased()]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    /// The rule strings the suggestion would add, joined for the chip detail.
    var humanReadableRules: String? {
        guard let rules, !rules.isEmpty else { return nil }
        let parts = rules.compactMap { rule -> String? in
            [rule.toolName, rule.ruleContent].compactMap { $0 }.joined(separator: " ")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
