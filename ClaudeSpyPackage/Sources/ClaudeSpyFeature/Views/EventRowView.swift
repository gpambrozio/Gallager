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
                    Text(event.action.title)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text(DateFormatters.relativeTime(for: event.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let subtitle = event.action.subtitle {
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
        event.action.symbol.image
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(event.action.symbolColor)
    }

    private var iconBackgroundColor: Color {
        event.action.symbolColor
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
    static let samples: [HookEvent] = [
        HookEvent(
            action: .sessionStart(SessionStartBody(
                sessionId: "123",
                cwd: "/Users/user/project",
                hookEventName: "SessionStart",
                source: "cli"
            )),
            projectPath: nil,
            tmuxPane: "%1"
        ),
        HookEvent(
            action: .preToolUse(PreToolUseBody(
                sessionId: "123",
                hookEventName: "PreToolUse",
                toolName: "Bash",
                toolInput: .bash(BashParameters(
                    command: "ls -la",
                    description: "List files"
                ))
            )),
            projectPath: nil,
            tmuxPane: "%1"
        ),
        HookEvent(
            action: .sessionEnd(SessionEndBody(
                sessionId: "123",
                hookEventName: "SessionEnd"
            )),
            projectPath: nil,
            tmuxPane: "%1"
        ),
    ]
}
