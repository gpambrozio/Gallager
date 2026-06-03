import Foundation

// Notification-copy derivation for parsed Claude/Codex hook events. Migrated out
// of `ClaudeSpyNetworking` into the core (spec §16 "Moved into cores: the 30→5
// event mapping"): the wire no longer carries raw `HookEvent`s, so the copy is
// baked by the core's translator and travels as a pre-formatted `NotificationSpec`.
//
// The `agentDisplayName` / `agentShortName` are supplied by the owning core so the
// copy is agent-flavored without a shared `CodingAgent` enum.

public extension HookEvent {
    /// Derives a notification title and body from this event, or `nil` if the
    /// event should not surface a notification.
    func buildNotification(
        agentDisplayName: String,
        agentShortName: String
    ) -> (title: String, body: String)? {
        let projectName = projectName ?? agentDisplayName

        // AskUserQuestion gets a dedicated, more descriptive notification
        // (the question text or a count) instead of the generic permission copy.
        if
            case let .permissionRequest(permissionBody) = action,
            case let .askUserQuestion(params) = permissionBody.toolInput {
            let detail: String = if params.questions.count == 1, let only = params.questions.first {
                only.question
            } else {
                "\(agentShortName) has \(params.questions.count) questions"
            }
            return (title: "\(agentShortName) wants answers", body: "\(projectName): \(detail)")
        }

        let body: String

        switch action {
        case .permissionRequest:
            body = "\(projectName): \(agentShortName) needs your approval"
        case .sessionStart:
            body = "\(projectName): \(agentDisplayName) session started"
        case let .stop(stopBody):
            if let summary = stopBody.lastAssistantMessage {
                let truncated = summary.count > 256
                    ? String(summary.prefix(256)) + "..."
                    : summary
                body = "\(projectName): \(truncated)"
            } else {
                body = "\(projectName): \(agentDisplayName) is waiting for your input"
            }
        case let .notification(notifBody):
            guard notifBody.shouldSendToServer, let message = notifBody.message else {
                return nil
            }
            body = "\(projectName): \(message)"
        case let .stopFailure(failureBody):
            body = "\(projectName): Error — \(failureBody.errorType ?? "unknown failure")"
        case .setup,
             .sessionEnd,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .postToolBatch,
             .permissionDenied,
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
            return nil
        }
        return (title: action.title, body: body)
    }
}
