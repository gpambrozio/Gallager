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
        case let .stopFailure(failureBody):
            if let error = failureBody.error {
                body = "\(projectName): API error — \(error)"
            } else {
                body = "\(projectName): Claude Code encountered an API error"
            }
        case let .notification(notifBody):
            if let message = notifBody.message {
                body = "\(projectName): \(message)"
            } else {
                return nil
            }
        case let .elicitation(elicitBody):
            let server = elicitBody.mcpServerName ?? "MCP server"
            if let message = elicitBody.message {
                body = "\(projectName): \(server) — \(message)"
            } else {
                body = "\(projectName): \(server) needs your input"
            }
        case let .taskCreated(taskBody):
            let subject = taskBody.taskSubject ?? "New task"
            body = "\(projectName): \(subject)"
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
