import ClaudeSpyCommon
import ClaudeSpyNetworking
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
                ForEach(session.events.prefix(10)) { event in
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
                Text(event.action.title)
                    .font(.caption2.bold())
                    .lineLimit(1)

                if let subtitle = event.action.subtitle {
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
        event.action.symbol.image
            .foregroundStyle(event.action.symbolColor)
            .font(.caption2)
    }

    private func formatTimestamp(_ date: Date) -> String {
        DateFormatters.relativeTime(for: date)
    }
}
