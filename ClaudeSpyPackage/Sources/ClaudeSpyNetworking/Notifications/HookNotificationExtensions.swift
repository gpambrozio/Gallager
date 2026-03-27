public extension HookEventMessage {
    /// Convert HookEventMessage to a notification title and body if applicable
    func buildNotification() -> (title: String, body: String)? {
        let projectName = projectName ?? "Claude Code"

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
            if let message = notifBody.message {
                body = "\(projectName): \(message)"
            } else {
                return nil
            }
        case let .stopFailure(failureBody):
            body = "\(projectName): Error — \(failureBody.errorType ?? "unknown failure")"
        case let .taskCreated(taskBody):
            body = "\(projectName): Task created — \(taskBody.taskSubject ?? "unknown")"
        default:
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
