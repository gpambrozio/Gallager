import ClaudeSpyCommon
import SwiftUI

/// Overlay displaying recent Claude session events in the top-right corner
struct SessionEventsOverlay: View {
    let session: ClaudeSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                eventsPanel
            }
            Spacer()
        }
        .padding(8)
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Symbols.boltFill.image
                    .foregroundStyle(.orange)
                Text("Claude Session")
                    .font(.caption.bold())
            }

            Divider()

            // Events list (newest first, already sorted that way)
            if session.events.isEmpty {
                Text("No events yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.events.prefix(5)) { event in
                    EventRow(event: event)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: HookEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            eventIcon
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle)
                    .font(.caption2.bold())
                    .lineLimit(1)

                if let subtitle = eventSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // TimelineView redraws periodically to keep relative timestamp current
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(formatTimestamp(event.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var eventIcon: some View {
        Group {
            switch event.action {
            case .sessionStart:
                Symbols.playFill.image
                    .foregroundStyle(.green)
            case .sessionEnd:
                Symbols.stopFill.image
                    .foregroundStyle(.red)
            case .preToolUse:
                Symbols.wrenchAndScrewdriver.image
                    .foregroundStyle(.blue)
            case .permissionRequest:
                Symbols.lockFill.image
                    .foregroundStyle(.orange)
            case .unknown:
                Symbols.questionmark.image
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var eventTitle: String {
        switch event.action {
        case .sessionStart:
            return "Session Started"
        case .sessionEnd:
            return "Session Ended"
        case let .preToolUse(body):
            return body.toolName ?? "Tool Use"
        case .permissionRequest:
            return "Permission Request"
        case let .unknown(body):
            return body.hookEventName
        }
    }

    private var eventSubtitle: String? {
        switch event.action {
        case let .preToolUse(body):
            return toolInputSummary(body.toolInput)
        case let .permissionRequest(body):
            return body.toolName
        case let .sessionStart(body):
            return body.source
        default:
            return nil
        }
    }

    private func toolInputSummary(_ input: ToolInput?) -> String? {
        guard let input else { return nil }

        switch input {
        case let .bash(bashInput):
            // Show first 50 chars of command
            let command = bashInput.command
            if command.count > 50 {
                return String(command.prefix(47)) + "..."
            }
            return command
        case let .askUserQuestion(questionInput):
            return questionInput.questions.first?.question
        case .other:
            return nil
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        DateFormatters.relativeTime(for: date)
    }
}
