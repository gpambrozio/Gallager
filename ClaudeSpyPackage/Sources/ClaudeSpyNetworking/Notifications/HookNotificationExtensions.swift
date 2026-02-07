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
        case .stop:
            body = "\(projectName): Claude Code is waiting for your input"
        case let .notification(notifBody):
            if let message = notifBody.message {
                body = "\(projectName): \(message)"
            } else {
                return nil
            }
        case let .teammateIdle(idleBody):
            let teammate = idleBody.teammateName ?? "A teammate"
            body = "\(projectName): \(teammate) is idle"
        case let .taskCompleted(taskBody):
            let subject = taskBody.taskSubject ?? "A task"
            body = "\(projectName): \(subject) completed"
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
