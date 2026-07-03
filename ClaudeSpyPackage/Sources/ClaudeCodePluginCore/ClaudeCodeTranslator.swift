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
    /// A plain tool-use permission prompt. Retains whether the request carried
    /// permission suggestions, because that decides the in-terminal menu's
    /// custom-feedback option number (3 with suggestions, 2 without) — the
    /// suggestion list itself is dropped by delivery time.
    case permission(hasSuggestions: Bool)
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
        /// Context to retain under the `awaiting*` state's `requestID`, if the
        /// event opened a form. `nil` when no form.
        var pending: PendingRequest?
    }

    /// Translate a parsed action into a `PluginEvent`, or `nil` to drop the
    /// frame (no state change — the dispatcher no-ops).
    static func translate(
        action: HookAction,
        pluginID: String,
        tmuxPane: String?,
        contextProjectDir: String?,
        occurrenceID: String,
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

        let notification = Self.notification(for: hookEvent)
        let (state, pending) = Self.state(
            for: action,
            sessionID: sessionID,
            hookEvent: hookEvent,
            occurrenceID: occurrenceID
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
            state == nil,
            notification == nil,
            appActions.isEmpty {
            return nil
        }

        let event = PluginEvent(
            pluginID: pluginID,
            sessionID: sessionID,
            state: state,
            notification: notification,
            appActions: appActions,
            tmuxPane: tmuxPane,
            projectPath: projectPath,
            // Seed the current permission mode off the hook (the four tool/prompt/
            // stop events carry it; others return nil and leave it unchanged), so a
            // session starting in a non-default mode shows its chip immediately
            // rather than waiting for an OTEL `permission_mode_changed` (issue #597).
            permissionMode: body.permissionMode
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

    // MARK: - State selection

    /// Maps one hook into the session's `AgentState` (spec §"Translator mapping")
    /// and the `PendingRequest` to retain for an opened form. Priority order:
    /// blocking forms (permission / question / plan) win; then Stop / StopFailure
    /// → `.doneWorking`; SessionStart → `.idle`; otherwise the working bit
    /// (`true → .working`, `false`/`nil → nil` "no opinion").
    ///
    /// `requestID` is unique per opened form via the core-supplied `occurrenceID`
    /// so a Mac-side answer and an iOS answer can't double-fire, and a *second*
    /// form of the same type never reuses the first's id:
    /// `"\(sessionID):\(eventName):\(occurrenceID)"`.
    private static func state(
        for action: HookAction,
        sessionID: String,
        hookEvent: HookEvent,
        occurrenceID: String
    ) -> (AgentState?, PendingRequest?) {
        switch action {
        case let .permissionRequest(body):
            let id = requestID(sessionID: sessionID, action: action, occurrenceID: occurrenceID)
            switch body.toolInput {
            case let .askUserQuestion(params):
                return (
                    .awaitingReplies(askUserQuestionRequest(from: params), requestID: id),
                    .askUserQuestion(params)
                )

            case let .exitPlanMode(params):
                let plan = ApprovePlanRequest(
                    title: "Plan Approval",
                    plan: params.plan ?? "",
                    // iOS sends "3" to approve / Escape to reject — it never
                    // submits an edited plan (ExitPlanModeResponseView).
                    allowsEdit: false
                )
                return (.awaitingPlanApproval(plan, requestID: id), .approvePlan)

            default:
                let hasSuggestions = !(body.permissionSuggestions?.isEmpty ?? true)
                return (
                    .awaitingPermission(permissionRequest(from: body), requestID: id),
                    .permission(hasSuggestions: hasSuggestions)
                )
            }

        case let .stop(body):
            // The agent stopped cleanly; the last assistant message is the summary.
            return (.doneWorking(summary: body.lastAssistantMessage), nil)

        case let .stopFailure(body):
            return (.doneWorking(summary: body.errorType), nil)

        case .sessionStart:
            return (.idle, nil)

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
            // Fall back to the working bit. `true` → working; `false` (SessionEnd)
            // and `nil` (compaction, file/config/cwd, subagent, …) → no opinion.
            return (hookEvent.isWorking == true ? .working : nil, nil)
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

    /// Stable, occurrence-unique request id: `"\(sessionID):\(eventName):\(occurrenceID)"`.
    /// The `occurrenceID` is minted fresh by the core for each ingress frame
    /// (Claude hooks carry NO timestamp/sequence — verified against the hook spec,
    /// see `IngressSocketServer`), so a second permission/question form in the same
    /// session gets a distinct id. Without it, every form collapsed to
    /// `"\(sessionID):PermissionRequest:"` and iOS restored the first form's
    /// persisted answer onto the second, showing "All questions answered" for a
    /// brand-new question.
    static func requestID(sessionID: String, action: HookAction, occurrenceID: String) -> String {
        "\(sessionID):\(action.eventName):\(occurrenceID)"
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
                isPlan: MarkdownPath.isPlan(params.filePath, projectPath: projectPath),
                projectDir: projectPath
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
