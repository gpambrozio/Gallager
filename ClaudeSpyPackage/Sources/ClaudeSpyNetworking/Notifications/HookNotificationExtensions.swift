public extension HookEventMessage {
    /// Convert HookEventMessage to a notification title and body if applicable
    func buildNotification() -> (title: String, body: String)? {
        let projectName = projectName ?? "Claude Code"

        // AskUserQuestion gets a dedicated, more descriptive notification
        // (the question text or a count) instead of the generic permission copy.
        if
            case let .permissionRequest(body) = event.action,
            case let .askUserQuestion(params) = body.toolInput {
            let detail: String = if params.questions.count == 1, let only = params.questions.first {
                only.question
            } else {
                "Claude has \(params.questions.count) questions"
            }
            return (title: "Claude wants answers", body: "\(projectName): \(detail)")
        }

        let body: String

        switch event.action {
        case .permissionRequest:
            body = "\(projectName): Claude needs your approval"
        case .sessionStart:
            body = "\(projectName): Claude Code session started"
        case let .stop(stopBody):
            if let summary = stopBody.lastAssistantMessage {
                let truncated = summary.count > 256
                    ? String(summary.prefix(256)) + "..."
                    : summary
                body = "\(projectName): \(truncated)"
            } else {
                body = "\(projectName): Claude Code is waiting for your input"
            }
        case let .notification(notifBody):
            guard notifBody.shouldSendToServer, let message = notifBody.message else {
                return nil
            }
            body = "\(projectName): \(message)"
        case let .stopFailure(failureBody):
            body = "\(projectName): Error — \(failureBody.errorType ?? "unknown failure")"
        case let .teammateIdle(idleBody):
            let name = idleBody.teammateName ?? "A teammate"
            body = "\(projectName): \(name) is idle"
        case let .taskCompleted(taskBody):
            let subject = taskBody.taskSubject ?? "A task"
            body = "\(projectName): \(subject) completed"
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
             .taskCreated,
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
        return (title: event.action.title, body: body)
    }
}

public extension HookEvent {
    /// Whether this event would trigger a notification
    var wouldTriggerNotification: Bool {
        HookEventMessage(pairId: "", event: self).buildNotification() != nil
    }
}
