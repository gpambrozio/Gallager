import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// A row view for displaying a single hook event.
struct EventRowView: View {
    let event: HookEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Event type icon
            eventIcon
                .frame(width: 32, height: 32)
                .background(iconBackgroundColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Event details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(eventTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text(DateFormatters.relativeTime(for: event.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let subtitle = eventSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Event Display Properties

    private var eventIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        switch event.action {
        case .sessionStart:
            "play.fill"
        case .sessionEnd:
            "stop.fill"
        case .preToolUse, .postToolUse:
            "wrench.and.screwdriver"
        case .permissionRequest:
            "lock.fill"
        case .notification:
            "bell.fill"
        case .userPromptSubmit:
            "text.bubble.fill"
        case .stop, .subagentStop:
            "stop.circle.fill"
        case .preCompact:
            "arrow.down.right.and.arrow.up.left"
        case .unknown:
            "questionmark"
        }
    }

    private var iconColor: Color {
        switch event.action {
        case .sessionStart:
            .green
        case .sessionEnd:
            .red
        case .preToolUse, .postToolUse:
            .blue
        case .permissionRequest:
            .orange
        case .notification:
            .purple
        case .userPromptSubmit:
            .cyan
        case .stop, .subagentStop:
            .red
        case .preCompact:
            .indigo
        case .unknown:
            .gray
        }
    }

    private var iconBackgroundColor: Color {
        iconColor
    }

    private var eventTitle: String {
        switch event.action {
        case .sessionStart:
            "Session Started"
        case .sessionEnd:
            "Session Ended"
        case let .preToolUse(body):
            "Tool: \(body.toolName ?? "Unknown")"
        case let .postToolUse(body):
            "Completed: \(body.toolName ?? "Unknown")"
        case let .permissionRequest(body):
            "Permission: \(body.toolName ?? "Unknown")"
        case let .notification(body):
            "Notification: \(body.notificationType ?? "Unknown")"
        case .userPromptSubmit:
            "Prompt Submitted"
        case .stop:
            "Agent Stopped"
        case .subagentStop:
            "Subagent Stopped"
        case let .preCompact(body):
            "Compacting (\(body.trigger ?? "unknown"))"
        case let .unknown(body):
            body.hookEventName
        }
    }

    private var eventSubtitle: String? {
        switch event.action {
        case let .sessionStart(body):
            body.cwd.map { "Working directory: \($0)" }

        case .sessionEnd:
            nil

        case let .preToolUse(body):
            toolInputDescription(body.toolInput)

        case let .postToolUse(body):
            toolInputDescription(body.toolInput)

        case let .permissionRequest(body):
            body.permissionMode.map { "Mode: \($0)" }

        case let .notification(body):
            body.message?.truncated(to: 80)

        case let .userPromptSubmit(body):
            body.prompt?.truncated(to: 80)

        case .stop, .subagentStop:
            nil

        case let .preCompact(body):
            body.customInstructions?.truncated(to: 80)

        case .unknown:
            nil
        }
    }

    private func toolInputDescription(_ input: ClaudeCodeTool?) -> String? {
        guard let input else { return nil }

        switch input {
        case let .bash(params):
            return params.command.truncated(to: 80)
        case let .askUserQuestion(params):
            return params.questions.first?.question.truncated(to: 80)
        default:
            return nil
        }
    }
}

// MARK: - String Extension

private extension String {
    func truncated(to length: Int) -> String {
        if count <= length {
            return self
        }
        return String(prefix(length - 3)) + "..."
    }
}

// MARK: - Preview

#Preview {
    List {
        // Preview events using JSON decoding
        ForEach(PreviewEvents.samples) { event in
            EventRowView(event: event)
        }
    }
}

/// Helper to create sample events for previews
private enum PreviewEvents {
    static let samples: [HookEvent] = {
        let sessionStartJSON = """
        {"session_id":"123","cwd":"/Users/user/project","hook_event_name":"SessionStart","source":"cli"}
        """
        let preToolUseJSON = """
        {"session_id":"123","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la","description":"List files"}}
        """
        let sessionEndJSON = """
        {"session_id":"123","hook_event_name":"SessionEnd"}
        """

        return [
            createEvent(from: sessionStartJSON, pane: "%1"),
            createEvent(from: preToolUseJSON, pane: "%1"),
            createEvent(from: sessionEndJSON, pane: "%1"),
        ].compactMap { $0 }
    }()

    private static func createEvent(from json: String, pane: String) -> HookEvent? {
        guard let data = json.data(using: .utf8),
              let action = try? HookAction.from(jsonData: data)
        else {
            return nil
        }
        return HookEvent(action: action, projectPath: nil, tmuxPane: pane)
    }
}
