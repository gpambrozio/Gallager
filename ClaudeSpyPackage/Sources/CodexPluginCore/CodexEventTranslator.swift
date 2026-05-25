import ClaudeCodePluginCore
import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - CodexEventTranslator

/// Translates one inbound Codex hook payload into a `PluginEvent`
/// envelope (or `nil` if the payload should be log-and-dropped per Spec
/// §17.2). Mirrors `ClaudeCodeEventTranslator` — Codex's hook event set is
/// a subset of Claude's plus `PostCompact` and `SubagentStart`, and the
/// dispatch logic is identical for the cases Codex supports.
///
/// Codex-specific behavior: on `SessionStart` the translator also writes a
/// sidecar correlation file at `~/.claudespy/codex-sessions/<tmux_pane>.json`
/// via the injected `CodexSessionCorrelationStore`. The Mac app reads
/// that file to correlate a Codex session id to the tmux pane it lives in.
///
/// Permission rendering (the human-readable description of a tool input)
/// is delegated to `ClaudeCodePermissionRendering` — Claude and Codex share
/// the same tool vocabulary today, and the spec lets the sidecar own its
/// own copy if formatting diverges later. For now we reuse Claude's
/// rendering verbatim.
///
/// `translate(...)` is `async throws`: `async` because the supplied
/// `PluginRequestStore` is an actor and the correlation store may perform
/// disk I/O, `throws` so a malformed payload (or a correlation-store
/// failure) surfaces rather than silently dropping.
public struct CodexEventTranslator: Sendable {
    /// Plugin id this translator owns. Wire-stable — matches the `id`
    /// field of `PluginBundles/codex/plugin.json`.
    public static let pluginID = "codex"

    private let logger: Logger
    private let correlationStore: CodexSessionCorrelationStore

    public init(
        correlationStore: CodexSessionCorrelationStore = CodexSessionCorrelationStore.liveValue,
        logger: Logger = Logger(label: "codex.event-translator")
    ) {
        self.correlationStore = correlationStore
        self.logger = logger
    }

    /// Translate one inbound Codex hook payload into a `PluginEvent`.
    /// Returns `nil` for events that should be log-and-dropped per Spec §17.2.
    ///
    /// The supplied `requestStore` is consulted to remember response-request
    /// shapes so the keystroke builder can match the original request later.
    public func translate(
        rawPayload: JSONValue,
        context: IngressContext,
        requestStore: PluginRequestStore
    ) async throws -> PluginEvent? {
        let action = try Self.decodeHookAction(from: rawPayload)
        return try await dispatch(
            action: action,
            rawPayload: rawPayload,
            context: context,
            requestStore: requestStore
        )
    }

    // MARK: - Decode helpers

    /// The raw frame the bridge writes is either the bare `HookEvent`
    /// (`{ action: { type, body }, ... }`) or — when callers want to bypass
    /// the wrapping envelope — a plain hook payload (`{ session_id,
    /// hook_event_name, ... }`). Try the wrapped shape first; fall back to
    /// the bare-payload shape if that fails.
    static func decodeHookAction(from value: JSONValue) throws -> HookActionPayload {
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        if let action = try? decoder.decode(HookActionPayload.self, from: data) {
            return action
        }
        return try HookActionPayload.from(jsonData: data)
    }

    // MARK: - Dispatch

    private func dispatch(
        action: HookActionPayload,
        rawPayload: JSONValue,
        context: IngressContext,
        requestStore: PluginRequestStore
    ) async throws -> PluginEvent? {
        switch action {
        case let .sessionStart(body):
            try await sessionStart(
                body: body,
                rawPayload: rawPayload,
                context: context
            )
        case .setup:
            nil
        case let .preToolUse(body):
            preToolUse(body: body)
        case let .postToolUse(body):
            postToolUse(body: body)
        case let .postToolUseFailure(body):
            postToolUseFailure(body: body)
        case let .sessionEnd(body):
            sessionEnd(body: body)
        case let .permissionRequest(body):
            await permissionRequest(
                body: body,
                context: context,
                requestStore: requestStore
            )
        case .permissionDenied:
            nil
        case let .notification(body):
            notification(body: body, context: context)
        case let .userPromptSubmit(body):
            userPromptSubmit(body: body)
        case let .stop(body):
            await stop(
                body: body,
                requestStore: requestStore
            )
        case let .subagentStart(body):
            subagentStart(body: body)
        case .subagentStop:
            nil
        case let .teammateIdle(body):
            teammateIdle(body: body)
        case let .taskCompleted(body):
            taskCompleted(body: body)
        case .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .postToolBatch:
            nil
        case let .stopFailure(body):
            stopFailure(body: body)
        case let .elicitation(body):
            elicitation(body: body)
        case let .userPromptExpansion(body):
            userPromptExpansion(body: body)
        case let .taskCreated(body):
            taskCreated(body: body)
        case let .unknown(body):
            unknown(body: body)
        }
    }

    // MARK: - Per-action handlers

    private func sessionStart(
        body: SessionStartPayload,
        rawPayload: JSONValue,
        context: IngressContext
    ) async throws -> PluginEvent {
        // Codex-specific behavior per Spec §17.2 footnote: persist a
        // correlation entry keyed by tmux pane so the Mac app can later
        // map a Codex session id to a pane id. We only attempt this when
        // a pane id is present in the context; sessions launched outside
        // a tmux pane (rare) just skip the write.
        if let pane = context.tmuxPane, !pane.isEmpty {
            try await correlationStore.record(tmuxPane: pane, payload: rawPayload)
        } else {
            logger.debug("SessionStart with no TMUX_PANE; skipping correlation write")
        }
        return envelope(
            sessionID: body.sessionId,
            working: false,
            attention: false,
            notification: .init(
                title: CodexNotificationCopy.agentDisplayName,
                body: CodexNotificationCopy.sessionStartedBody
            )
        )
    }

    private func preToolUse(body: PreToolUsePayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false
        )
    }

    private func postToolUse(body: PostToolUsePayload) -> PluginEvent {
        var actions: [AppAction] = []
        if
            case let .write(write) = body.toolInput,
            Self.isMarkdownPath(write.filePath) {
            let displayName = URL(fileURLWithPath: write.filePath).lastPathComponent
            actions.append(.openFileSuggestion(
                sessionId: body.sessionId,
                path: write.filePath,
                displayName: displayName,
                isPlan: false
            ))
        }
        return envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false,
            appActions: actions
        )
    }

    private func postToolUseFailure(body: PostToolUseFailurePayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false
        )
    }

    private func sessionEnd(body: SessionEndPayload) -> PluginEvent {
        var actions: [AppAction] = []
        if body.reason == .promptInputExit {
            actions.append(.closePaneIfPreferenceAllows(sessionId: body.sessionId))
        }
        return envelope(
            sessionID: body.sessionId,
            working: false,
            attention: false,
            appActions: actions
        )
    }

    private func permissionRequest(
        body: PermissionRequestPayload,
        context: IngressContext,
        requestStore: PluginRequestStore
    ) async -> PluginEvent {
        let (request, notif) = buildResponseRequest(
            body: body,
            context: context
        )
        let requestID = UUID().uuidString
        await requestStore.remember(requestID: requestID, request: request)
        return envelope(
            sessionID: body.sessionId,
            working: true,
            attention: true,
            notification: notif,
            responseRequest: .init(requestID: requestID, request: request)
        )
    }

    private func notification(body: NotificationPayload, context: IngressContext) -> PluginEvent? {
        // Per Spec §17.2: filter out internal permission/idle prompts and
        // payloads that don't carry user-visible copy.
        guard
            body.notificationType != "permission_prompt",
            body.notificationType != "idle_prompt",
            let message = body.message
        else { return nil }
        let projectName = Self.projectName(from: context)
            ?? CodexNotificationCopy.agentDisplayName
        return envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: false,
            notification: .init(
                title: CodexNotificationCopy.agentDisplayName,
                body: CodexNotificationCopy.notificationBody(
                    project: projectName,
                    message: message
                )
            )
        )
    }

    private func userPromptSubmit(body: UserPromptSubmitPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false,
            appActions: [.dismissFileSuggestions(sessionId: body.sessionId)]
        )
    }

    private func stop(
        body: StopPayload,
        requestStore: PluginRequestStore
    ) async -> PluginEvent {
        let summary = body.lastAssistantMessage
        let request: AgentResponseRequest = .replyAfterStop(
            ReplyAfterStopRequest(lastAssistantMessage: summary)
        )
        let requestID = UUID().uuidString
        await requestStore.remember(requestID: requestID, request: request)
        let notifBody = summary.map { CodexNotificationCopy.stopSummaryBody(
            project: CodexNotificationCopy.agentDisplayName,
            summary: $0
        ) } ?? CodexNotificationCopy.waitingBody
        return envelope(
            sessionID: body.sessionId,
            working: false,
            attention: true,
            notification: .init(
                title: CodexNotificationCopy.stoppedTitle,
                body: notifBody
            ),
            responseRequest: .init(requestID: requestID, request: request)
        )
    }

    private func subagentStart(body: SubagentStartPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false
        )
    }

    private func teammateIdle(body: TeammateIdlePayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: true,
            notification: .init(
                title: CodexNotificationCopy.teammateIdleTitle,
                body: CodexNotificationCopy.teammateIdleTitle
            )
        )
    }

    private func taskCompleted(body: TaskCompletedPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: false,
            notification: .init(
                title: CodexNotificationCopy.taskCompletedTitle,
                body: body.taskSubject ?? ""
            )
        )
    }

    private func stopFailure(body: StopFailurePayload) -> PluginEvent {
        let errorType = body.errorType ?? "unknown"
        return envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: true,
            notification: .init(
                title: CodexNotificationCopy.agentDisplayName,
                body: "Stop error: \(errorType)"
            )
        )
    }

    private func elicitation(body: ElicitationPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false
        )
    }

    private func userPromptExpansion(body: UserPromptExpansionPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: true,
            attention: false
        )
    }

    private func taskCreated(body: TaskCreatedPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: false,
            notification: .init(
                title: "Task created",
                body: body.taskSubject ?? ""
            )
        )
    }

    private func unknown(body: HookCommonFields) -> PluginEvent? {
        logger.warning(
            "Dropped unknown Codex hook payload",
            metadata: ["event_name": .string(body.hookEventName)]
        )
        return nil
    }

    // MARK: - Envelope helper

    private func envelope(
        sessionID: String,
        working: Bool?,
        attention: Bool,
        notification: PluginEvent.NotificationSpec? = nil,
        responseRequest: PluginEvent.ResponseRequestPayload? = nil,
        appActions: [AppAction] = []
    ) -> PluginEvent {
        PluginEvent(
            pluginID: Self.pluginID,
            sessionID: sessionID,
            working: working,
            attention: attention,
            notification: notification,
            responseRequest: responseRequest,
            appActions: appActions
        )
    }

    // MARK: - Permission-request shaping

    private func buildResponseRequest(
        body: PermissionRequestPayload,
        context: IngressContext
    ) -> (AgentResponseRequest, PluginEvent.NotificationSpec) {
        let projectName = Self.projectName(from: context)
            ?? CodexNotificationCopy.agentDisplayName
        switch body.toolInput {
        case let .askUserQuestion(params):
            let request = ClaudeCodePermissionRendering.askUserQuestionRequest(from: params)
            let notif: PluginEvent.NotificationSpec
            if params.questions.count == 1, let only = params.questions.first {
                notif = PluginEvent.NotificationSpec(
                    title: CodexNotificationCopy.wantsAnswersTitle,
                    body: CodexNotificationCopy.askQuestionBody(
                        project: projectName,
                        question: only.question
                    )
                )
            } else {
                notif = PluginEvent.NotificationSpec(
                    title: CodexNotificationCopy.wantsAnswersTitle,
                    body: CodexNotificationCopy.askMultipleQuestionsBody(
                        project: projectName,
                        count: params.questions.count
                    )
                )
            }
            return (.askUserQuestion(request), notif)
        case let .exitPlanMode(params):
            let request = ApprovePlanRequest(
                plan: params.plan ?? "",
                allowEdit: true
            )
            let notif = PluginEvent.NotificationSpec(
                title: CodexNotificationCopy.agentDisplayName,
                body: CodexNotificationCopy.needsApprovalBody(project: projectName)
            )
            return (.approvePlan(request), notif)
        default:
            let request = PermissionRequest(
                toolName: body.toolName,
                description: ClaudeCodePermissionRendering.description(
                    toolInput: body.toolInput,
                    toolName: body.toolName
                ),
                suggestions: ClaudeCodePermissionRendering.mappedSuggestions(
                    legacy: body.permissionSuggestions ?? []
                ),
                isAutoApprovable: body.isYoloAutoApprovable
            )
            let notif = PluginEvent.NotificationSpec(
                title: CodexNotificationCopy.agentDisplayName,
                body: CodexNotificationCopy.needsApprovalBody(project: projectName)
            )
            return (.permission(request), notif)
        }
    }

    // MARK: - Misc helpers

    /// Returns the last path component of the Codex project path (e.g.
    /// "MyApp") used in user-facing notification copy. `nil` when the
    /// project path isn't known.
    static func projectName(from context: IngressContext) -> String? {
        guard let path = context.codexProjectPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Whether `path` ends with a markdown-style extension recognised by the
    /// `openFileSuggestion` AppAction.
    static func isMarkdownPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}
