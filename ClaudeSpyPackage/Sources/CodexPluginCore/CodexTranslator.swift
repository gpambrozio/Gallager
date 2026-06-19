import ClaudeCodePluginCore
import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - PendingRequest

/// Per-`requestID` context the core retains after emitting an
/// `AgentResponseRequest`, so it can translate the structured `AgentResponse`
/// that comes back into agent-specific keystrokes (spec §7.1). Only the shapes
/// that need delivery-time context carry payloads; the rest are tagged plainly.
///
/// Identical in shape to the Claude core's `PendingRequest`: Codex routes
/// through the same `HookAction` enum, so the same five forms apply.
enum PendingRequest: Equatable {
    /// AskUserQuestion — retains the raw params so selected option ids
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

// MARK: - CodexTranslator

/// Pure, stateless mapping from a parsed Codex `HookAction` (+ ingress frame
/// context) to a `PluginEvent` and the optional `PendingRequest` the core must
/// retain. Kept separate from the actor so it is directly unit-testable.
///
/// Codex routes through the SAME `/api/hooks` → `HookAction.from` path with
/// `agent=codex` today, so Codex hook events parse into the SAME `HookAction`
/// enum. The mapping is therefore identical to the Claude core's, with two
/// differences:
/// - it builds the `HookEvent` with `agent: .codex` so the reused
///   `HookEventMessage.buildNotification()` produces Codex-flavored copy
///   ("Codex wants answers", "Codex session started", …); and
/// - the pane is resolved by the actor (from `frame.tmuxPane`, or the pane↔
///   session correlation file when only a session id is present) and passed in.
enum CodexTranslator {
    /// Agent-flavored notification copy (replaces the deleted `CodingAgent`).
    static let agentDisplayName = "Codex"
    static let agentShortName = "Codex"

    /// The result of translating one ingress frame.
    struct Output: Equatable {
        var event: PluginEvent
        /// Context to retain under the `awaiting*` state's `requestID`, if the
        /// event opened a form. `nil` when no form.
        var pending: PendingRequest?
        /// True when a permission request was silenced because Codex's
        /// guardian will decide it (the event maps to plain `working`). Lets
        /// the core log the suppression without re-deriving the decision.
        var guardianHandled = false
    }

    /// Translate a parsed action into a `PluginEvent`, or `nil` to drop the
    /// frame (no state change — the dispatcher no-ops).
    ///
    /// `approvalsReviewer` is the EFFECTIVE posture of this event's session,
    /// resolved by the actor: the live `config.toml` value gated by the
    /// session's start snapshot (the file is global, the runtime value is
    /// per-session). It only matters for `PermissionRequest` — see
    /// `isGuardianHandled`.
    static func translate(
        action: HookAction,
        pluginID: String,
        tmuxPane: String?,
        contextProjectDir: String?,
        occurrenceID: String,
        closePaneOnSessionEnd: Bool = false,
        approvalsReviewer: CodexApprovalsReviewer = .user
    ) -> Output? {
        let body = action.body
        let sessionID = body.sessionId

        // Project path: prefer the harvested project-dir context, fall back to
        // the payload `cwd`. Codex doesn't expose a project-dir env var, so the
        // `cwd` is usually the only source.
        let projectPath = contextProjectDir ?? Self.cwd(of: action)

        // Wrap in a HookEvent so we can reuse the durable working / notification
        // semantics rather than duplicating the logic. Codex-flavored copy comes
        // from the agent-name constants passed into the notification builder.
        let hookEvent = HookEvent(
            action: action,
            projectPath: projectPath,
            tmuxPane: tmuxPane
        )

        // Guardian posture: when Codex's auto-reviewer — not the user — will
        // decide this permission request, stay silent: plain `working` (the
        // session already was — PreToolUse just fired), no notification, no
        // form. The guardian's outcome arrives via subsequent hooks
        // (PostToolUse on allow; Stop after the model reacts to a deny).
        let guardianHandled = Self.isGuardianHandled(
            action: action,
            approvalsReviewer: approvalsReviewer
        )

        let notification = guardianHandled ? nil : Self.notification(for: hookEvent)
        let (state, pending): (AgentState?, PendingRequest?) = guardianHandled
            ? (.working, nil)
            : Self.state(
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
            projectPath: projectPath
        )
        return Output(event: event, pending: pending, guardianHandled: guardianHandled)
    }

    // MARK: - cwd extraction

    /// The `cwd` from a hook body. `HookBodyProtocol` doesn't expose `cwd`, so we
    /// switch over the concrete bodies (every body carries it).
    static func cwd(of action: HookAction) -> String? {
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

    /// Whether this action is a session start (used by the core to write the
    /// pane↔session correlation file — spec §12).
    static func isSessionStart(_ action: HookAction) -> Bool {
        if case .sessionStart = action { return true }
        return false
    }

    // MARK: - Notification copy

    /// Reuses the migrated `HookEvent.buildNotification()` so the copy stays
    /// identical to the legacy path (Codex-flavored via the agent-name args).
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
    /// and the `PendingRequest` to retain for an opened form. Identical to the
    /// Claude core's rule (Codex shares `HookAction` and `HookEvent.isWorking`).
    /// Priority order: blocking forms (permission / question / plan) win; then
    /// Stop / StopFailure → `.doneWorking`; SessionStart → `.idle`; otherwise the
    /// working bit (`true → .working`, `false`/`nil → nil` "no opinion").
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
                    // submits an edited plan.
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
            return (hookEvent.isWorking == true ? .working : nil, nil)
        }
    }

    // MARK: - Guardian (auto-review) posture

    /// True when Codex's guardian ("Approve for me", `approvals_reviewer =
    /// "auto_review"`) — not the user — will decide this permission request,
    /// so ClaudeSpy must suppress the notification AND the response form.
    ///
    /// Why the form too: the `PermissionRequest` hook fires before Codex
    /// routes the approval to the guardian, whose outcome is a binary
    /// allow/deny that never escalates to the user — no TUI prompt ever
    /// exists. Remote Approve/Deny is keystroke injection into that prompt
    /// (`CodexKeystrokes`), so an actionable form would type "1" into the
    /// composer or Escape-interrupt the running turn; and because the next
    /// hook is PostToolUse, a stale `awaitingPermission` would linger for the
    /// entire tool runtime.
    ///
    /// Conditions (all must hold):
    /// - the live reviewer posture is `auto_review` / `guardian_subagent`;
    /// - `permission_mode == "default"` — under `"bypassPermissions"` (policy
    ///   `never`) guardian routing is off, so a hook firing at all means a
    ///   REAL user prompt follows; a missing/unknown mode also fails safe to
    ///   notifying;
    /// - the tool is positively identified as guardian-reviewable (see
    ///   `isGuardianReviewable`) — anything else keeps notifying and forming.
    static func isGuardianHandled(
        action: HookAction,
        approvalsReviewer: CodexApprovalsReviewer
    ) -> Bool {
        guard
            approvalsReviewer == .autoReview,
            case let .permissionRequest(body) = action,
            body.permissionMode == "default",
            isGuardianReviewable(body)
        else { return false }
        return true
    }

    /// Positive identification of the approval shapes Codex's guardian
    /// reviews. Codex emits `PermissionRequest` hooks only from its approval
    /// orchestrator, whose payload `tool_name` vocabulary is closed (verified
    /// against codex-rs `permission_request_payload()` implementations and
    /// `HookToolName`): `"Bash"` for the whole shell family
    /// (shell / unified_exec / exec_command) and `"apply_patch"` for patches
    /// (`Write`/`Edit` exist only as hook-config matcher aliases — the
    /// serialized payload name stays `apply_patch`). Prompt-style tools
    /// (`request_user_input`, plan flows) never enter the approval
    /// orchestrator, so they can't appear here. The `mcp__` arm future-proofs
    /// the namespaced MCP family — those approvals are guardian-reviewed but
    /// don't emit a permission payload in current codex, and a namespaced
    /// external tool can never be a prompt-style tool.
    ///
    /// Deliberately fails CLOSED, unlike `isYoloAutoApprovable` (which fails
    /// open by design for the yolo path): an unknown or missing tool name
    /// notifies, so a future Codex prompt-style tool can never be silently
    /// suppressed while a real TUI prompt waits.
    static func isGuardianReviewable(_ body: PermissionRequestBody) -> Bool {
        guard let toolName = body.toolName else { return false }
        return toolName == "Bash"
            || toolName == "apply_patch"
            || toolName.hasPrefix("mcp__")
    }

    /// Builds the agent-blind `PermissionRequest` from a permission body. Mirrors
    /// the Claude core: `isAutoApprovable` consults `isYoloAutoApprovable`, and
    /// permission suggestions become agent-blind chips with the index encoded in
    /// the id so the core can resolve it at delivery time.
    private static func permissionRequest(from body: PermissionRequestBody) -> PermissionRequest {
        let title = body.toolName ?? "Permission Request"
        let description = body.toolInput?.summary
            ?? body.toolInput?.toolName
            ?? body.toolName
            ?? ""

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

    /// Maps `AskUserQuestionParameters` to the contract request, assigning stable
    /// ids (`"q0"`, `"q0-o1"`) so the answer can be reversed into option indices
    /// at delivery time.
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
                allowsFreeText: true
            )
        }
        return AskUserQuestionRequest(questions: questions)
    }

    /// Stable, occurrence-unique request id: `"\(sessionID):\(eventName):\(occurrenceID)"`.
    /// The `occurrenceID` is minted fresh by the core for each ingress frame
    /// (hooks carry no timestamp/sequence), so a second permission/question form in
    /// the same session gets a distinct id. Without it, every form collapsed to
    /// `"\(sessionID):PermissionRequest:"` and iOS restored the first form's
    /// persisted answer onto the second.
    static func requestID(sessionID: String, action: HookAction, occurrenceID: String) -> String {
        "\(sessionID):\(action.eventName):\(occurrenceID)"
    }

    // MARK: - App actions

    /// Markdown write suggestion + prompt-submit dismissal + clean-session-end
    /// pane close — identical to the Claude core's app-action mapping.
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
            // session-scoped state (yolo). The pane is only *closed* when the agent
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

/// Markdown / plan path detection (ported from the Claude core's `MarkdownPath`).
enum MarkdownPath {
    /// True when `path` ends with `.md` or `.markdown` (case-insensitive).
    static func isMarkdown(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    /// True when the file is recognisably a generated plan: parent dir is
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
    /// A short human-readable label for a suggestion chip, e.g. "Allow for this
    /// session". Mirrors the Claude core's `humanReadableLabel`.
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
