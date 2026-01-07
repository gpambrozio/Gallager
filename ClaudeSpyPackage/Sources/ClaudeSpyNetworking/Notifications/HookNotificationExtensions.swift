public extension HookEventMessage {
    /// Convert HookEventMessage to a notification title and body if applicable
    func buildNotification() -> (title: String, body: String)? {
        let projectName = projectName ?? "Claude Code"

        let title: String
        let body: String

        switch event.action {
        case .permissionRequest:
            title = "Permission Required"
            body = "\(projectName): Claude needs your approval"
        case .sessionStart:
            title = "Session Started"
            body = "\(projectName): Claude Code session started"
        case .stop:
            title = "Session Idle"
            body = "\(projectName): Claude Code is waiting for your input"
        case let .notification(notifBody):
            if let message = notifBody.message {
                title = "Notification"
                body = "\(projectName): \(message)"
            } else {
                return nil
            }
        default:
            return nil
        }
        return (title, body)
    }
}

public extension HookEvent {
    /// Whether this event would trigger a notification
    var wouldTriggerNotification: Bool {
        HookEventMessage(pairId: "", event: self).buildNotification() != nil
    }
}
