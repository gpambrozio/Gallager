import Foundation

// MARK: - CodexNotificationCopy

/// Codex-specific user-facing strings used by the sidecar to build
/// notifications, session-status updates, and permission prompts.
///
/// Mirrors `ClaudeCodeNotificationCopy`. Keep this enum stable
/// wire-format-wise: the sidecar passes these values into
/// `PluginNotificationRequest` / `PluginSessionStatusUpdate` which fan out
/// to macOS notifications, iOS push notifications, and the in-app sidebar.
public enum CodexNotificationCopy {
    // MARK: - Agent display

    /// Long-form display name shown in the sidebar header and in fallback
    /// "<agent> session started" copy when a project name is unavailable.
    /// Matches `CodingAgent.codex.displayName` so behaviour doesn't shift
    /// when the sidecar replaces the legacy path.
    public static let agentDisplayName = "Codex"

    /// Short form used inside notification titles like
    /// "<short> is working" / "<short> wants answers". Matches
    /// `CodingAgent.codex.shortName`.
    public static let agentShortName = "Codex"

    // MARK: - Notification titles

    /// Status pill shown while the agent is mid-tool-call. Mirrors the
    /// macOS sidebar's "Codex is working" indicator.
    public static let workingTitle = "Codex is working"

    /// Status pill shown when the agent is idle waiting for user input.
    public static let stoppedTitle = "Codex is waiting…"

    /// Title for the task-completion push notification.
    public static let taskCompletedTitle = "Task completed"

    /// Title for the teammate-idle push notification.
    public static let teammateIdleTitle = "Teammate is idle"

    // MARK: - Notification bodies

    /// Body for the session-started notification fired by `SessionStart`.
    /// Used when the host can't supply a project name (e.g. terminal-only
    /// pane).
    public static let sessionStartedBody = "Session started"

    /// Body for the "stop" / "waiting" notification when the agent
    /// pauses for input without a summarised last message.
    public static let waitingBody = "Codex is waiting for your input"

    /// Body for the permission-request notification when the agent
    /// needs the user to approve a tool call.
    public static let needsApprovalBody = "\(agentShortName) needs your approval"

    /// Title for an AskUserQuestion notification with a single question.
    public static let wantsAnswersTitle = "\(agentShortName) wants answers"

    // MARK: - Composers

    /// Builds the project-scoped variant of `wantsAnswersTitle`'s body
    /// when one question is in flight.
    public static func askQuestionBody(project: String, question: String) -> String {
        "\(project): \(question)"
    }

    /// Builds the project-scoped variant when multiple questions are
    /// queued ("Codex has 3 questions").
    public static func askMultipleQuestionsBody(project: String, count: Int) -> String {
        "\(project): \(agentShortName) has \(count) questions"
    }

    /// "<project>: <agent display name> session started" composer.
    public static func sessionStartedBody(project: String) -> String {
        "\(project): \(agentDisplayName) session started"
    }

    /// "<project>: <agent short name> needs your approval" composer.
    public static func needsApprovalBody(project: String) -> String {
        "\(project): \(needsApprovalBody)"
    }

    /// "<project>: <agent display name> is waiting for your input" composer.
    public static func waitingBody(project: String) -> String {
        "\(project): \(agentDisplayName) is waiting for your input"
    }

    /// "<project>: <summary>" composer used for the stop-with-summary path.
    public static func stopSummaryBody(project: String, summary: String) -> String {
        let truncated = summary.count > 256
            ? String(summary.prefix(256)) + "..."
            : summary
        return "\(project): \(truncated)"
    }

    /// "<project>: <message>" composer for free-form notification hook
    /// payloads.
    public static func notificationBody(project: String, message: String) -> String {
        "\(project): \(message)"
    }

    /// "<project>: Error — <reason>" composer for stop-failure events.
    public static func errorBody(project: String, reason: String) -> String {
        "\(project): Error — \(reason)"
    }
}
