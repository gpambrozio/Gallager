import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - ClaudeCodeEventTranslator

/// Translates one inbound Claude Code hook payload into a `PluginEvent`
/// envelope (or `nil` if the payload should be log-and-dropped per Spec
/// §17.2). The translator owns Claude-specific UX policy: which events
/// surface a notification, which become a response request, which trigger
/// an `AppAction`, and what the per-event copy reads.
///
/// `translate(...)` is `async throws`: it's `async` because the supplied
/// `PluginRequestStore` is an actor (every response-request emission
/// also writes to the store), and `throws` so a malformed payload surfaces
/// as a decoding error rather than a silent drop. Callers (the sidecar
/// `translate_event` handler) typically log + drop on throws.
public struct ClaudeCodeEventTranslator: Sendable {
    /// Plugin id this translator owns. Wire-stable — matches the `id`
    /// field of `PluginBundles/claude-code/plugin.json`.
    public static let pluginID = "claude-code"

    private let logger: Logger

    public init(logger: Logger = Logger(label: "claude-code.event-translator")) {
        self.logger = logger
    }

    /// Translate one inbound Claude Code hook payload into a `PluginEvent`.
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
            context: context,
            requestStore: requestStore
        )?.withTmuxPane(context.tmuxPane)
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
        context: IngressContext,
        requestStore: PluginRequestStore
    ) async throws -> PluginEvent? {
        switch action {
        case let .sessionStart(body):
            sessionStart(body: body, context: context)
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

    private func sessionStart(body: SessionStartPayload, context: IngressContext) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: false,
            attention: false,
            notification: .init(
                title: ClaudeCodeNotificationCopy.agentDisplayName,
                body: ClaudeCodeNotificationCopy.sessionStartedBody
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
            ?? ClaudeCodeNotificationCopy.agentDisplayName
        return envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: false,
            notification: .init(
                title: ClaudeCodeNotificationCopy.agentDisplayName,
                body: ClaudeCodeNotificationCopy.notificationBody(
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
        let notifBody = summary.map { ClaudeCodeNotificationCopy.stopSummaryBody(
            project: ClaudeCodeNotificationCopy.agentDisplayName,
            summary: $0
        ) } ?? ClaudeCodeNotificationCopy.waitingBody
        return envelope(
            sessionID: body.sessionId,
            working: false,
            attention: true,
            notification: .init(
                title: ClaudeCodeNotificationCopy.stoppedTitle,
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
                title: ClaudeCodeNotificationCopy.teammateIdleTitle,
                body: ClaudeCodeNotificationCopy.teammateIdleTitle
            )
        )
    }

    private func taskCompleted(body: TaskCompletedPayload) -> PluginEvent {
        envelope(
            sessionID: body.sessionId,
            working: nil,
            attention: false,
            notification: .init(
                title: ClaudeCodeNotificationCopy.taskCompletedTitle,
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
                title: ClaudeCodeNotificationCopy.agentDisplayName,
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
            "Dropped unknown Claude Code hook payload",
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
            ?? ClaudeCodeNotificationCopy.agentDisplayName
        switch body.toolInput {
        case let .askUserQuestion(params):
            let request = ClaudeCodePermissionRendering.askUserQuestionRequest(from: params)
            let notif: PluginEvent.NotificationSpec
            if params.questions.count == 1, let only = params.questions.first {
                notif = PluginEvent.NotificationSpec(
                    title: ClaudeCodeNotificationCopy.wantsAnswersTitle,
                    body: ClaudeCodeNotificationCopy.askQuestionBody(
                        project: projectName,
                        question: only.question
                    )
                )
            } else {
                notif = PluginEvent.NotificationSpec(
                    title: ClaudeCodeNotificationCopy.wantsAnswersTitle,
                    body: ClaudeCodeNotificationCopy.askMultipleQuestionsBody(
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
                title: ClaudeCodeNotificationCopy.agentDisplayName,
                body: ClaudeCodeNotificationCopy.needsApprovalBody(project: projectName)
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
                title: ClaudeCodeNotificationCopy.agentDisplayName,
                body: ClaudeCodeNotificationCopy.needsApprovalBody(project: projectName)
            )
            return (.permission(request), notif)
        }
    }

    // MARK: - Misc helpers

    /// Returns the last path component of `context.projectPath` (e.g. the
    /// "MyApp" folder name) used in user-facing notification copy. `nil`
    /// when the project path isn't known.
    static func projectName(from context: IngressContext) -> String? {
        guard let path = context.projectPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Whether `path` ends with a markdown-style extension recognised by the
    /// `openFileSuggestion` AppAction.
    static func isMarkdownPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}
